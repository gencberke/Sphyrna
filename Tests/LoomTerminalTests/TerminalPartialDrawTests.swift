import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import LoomTerminal

/// CP5 PERF P3: only the rows that changed are invalidated and drawn, and the
/// pixels after any update sequence equal a full redraw.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct TerminalPartialDrawTests {
    private func makeView(cols: Int = 80, rows: Int = 12) -> LoomTerminalView {
        let font = TerminalSurface.font(size: 13)
        let probe = LoomTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), font: font,
                                     options: TerminalSurfaceLimits.options)
        let cell = probe.cellDimension!
        let view = LoomTerminalView(
            frame: NSRect(x: 0, y: 0, width: ceil(cell.width * CGFloat(cols)) + 1,
                          height: ceil(cell.height * CGFloat(rows))),
            font: font, options: TerminalSurfaceLimits.options)
        view.resize(cols: cols, rows: rows)
        return view
    }

    @MainActor private final class Canvas {
        let context: CGContext
        let width: Int, height: Int
        init(_ view: TerminalView) {
            width = Int(view.bounds.width * 2)
            height = Int(view.bounds.height * 2)
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: 2, y: 2)
        }
        func draw(_ view: TerminalView, dirty: CGRect) {
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.drawTerminalContents(dirtyRect: dirty, context: context, bufferOffset: 0)
            NSGraphicsContext.current = previous
        }
        var pixels: [UInt8] {
            [UInt8](UnsafeRawBufferPointer(start: context.data!, count: height * width * 4))
        }
    }

    /// Feeds `text`, prepares one frame and draws it into `incremental` with the
    /// region the frame asks to be invalidated. Returns that region (nil: no draw).
    @discardableResult
    private func step(_ view: LoomTerminalView, _ text: String, into incremental: Canvas) throws -> CGRect? {
        view.feed(text: text)
        let state = try #require(view.captureFrameViewState())
        let prepared = try #require(view.prepareFrame(viewState: state))
        let region = prepared.region
        if let region { incremental.draw(view, dirty: region) }
        return region
    }

    private func fullPixels(_ view: LoomTerminalView) -> [UInt8] {
        let canvas = Canvas(view)
        canvas.draw(view, dirty: view.bounds)
        return canvas.pixels
    }

    private let e = "\u{1b}"

    /// Runs the update sequence; returns bytes differing from a full redraw
    /// after each step and the regions requested.
    private func runSequence(_ view: LoomTerminalView) throws -> (diffs: [Int], regions: [CGRect?]) {
        let incremental = Canvas(view)
        var diffs: [Int] = [], regions: [CGRect?] = []
        func check(_ text: String) throws {
            regions.append(try step(view, text, into: incremental))
            diffs.append(differingBytes(incremental.pixels, fullPixels(view)))
        }
        let rows = view.terminal.rows
        // Initial screen, colors, descenders, box characters.
        try check((1...rows).map { "\(e)[3\($0 % 7 + 1)mrow \($0) gypq|_ \(e)[0m\u{2588}\u{2502} plain text" }
            .joined(separator: "\r\n"))
        // Spinner-like rewrites of the bottom region.
        for frame in 0..<6 {
            let glyph = ["|", "/", "-", "\\", "*", "+"][frame]
            try check("\(e)[\(rows - 3);1H\(e)[2K\(glyph) Working gjpqy (\(frame)s)"
                      + "\(e)[\(rows - 1);1H\(e)[2K\(e)[48;5;\(20 + frame)m  status \(frame)  \(e)[0m"
                      + "\(e)[\(rows);1H\(e)[2K> typing\(frame)")
        }
        // Cursor-only moves across rows.
        try check("\(e)[2;5H")
        try check("\(e)[\(rows - 2);9H")
        // A single row in the middle, with truecolor background.
        try check("\(e)[5;3H\(e)[38;2;255;120;0;48;2;10;40;90mmid row update\(e)[0m")
        // Scroll: output at the bottom pushes lines into scrollback.
        try check("\(e)[\(rows);1H\r\nscrolled line A\r\nscrolled line B")
        // More rewrites after the scroll.
        try check("\(e)[\(rows);1H\(e)[2Kafter scroll")
        // Selection.
        view.selectAll(nil)
        regions.append(try step(view, "", into: incremental) ?? nil)
        // The selection frame may have no data change: draw fully if asked.
        diffs.append(differingBytes(incremental.pixels, fullPixels(view)))
        try check("\(e)[\(rows);1H\(e)[2Kselected tail")
        // Double-width line attribute forces a full redraw.
        try check("\(e)[3;1H\(e)#6wide")
        try check("\(e)[\(rows);1H\(e)[2Kafter wide")
        return (diffs, regions)
    }

    @Test func incrementalDrawEqualsFullRedraw() throws {
        let view = makeView()
        let (diffs, regions) = try runSequence(view)
        #expect(diffs.allSatisfy { $0 == 0 }, "differing bytes per step \(diffs)")
        let partial = regions.compactMap { $0 }.filter { $0.height < view.bounds.height }
        #expect(partial.count >= 6, "partial regions: \(partial.count) of \(regions.count)")
    }

    @Test func singleRowUpdateInvalidatesOnlyThatRow() throws {
        let view = makeView()
        let incremental = Canvas(view)
        try step(view, (1...12).map { "line \($0)" }.joined(separator: "\r\n"), into: incremental)
        let cell = try #require(view.cellDimension)
        let region = try #require(try step(view, "\(e)[5;1Hchanged", into: incremental))
        // Row 5 (index 4) plus the one-row margin below; nothing else.
        let rowMaxY = view.frame.height - 4 * cell.height
        #expect(region.maxY == rowMaxY)
        #expect(region.height == 2 * cell.height)
        // Cursor-only movement invalidates nothing.
        #expect(try step(view, "\(e)[9;3H", into: incremental) == nil)
    }

    /// FB6-11: output that arrives while the view is parked in the scrollback does not repaint the whole view (it used to, on every
    /// frame); the rows the output changes are still what is drawn, and the pixels equal a full redraw.
    @Test func outputWhileParkedInTheScrollbackInvalidatesOnlyTheChangedRows() throws {
        let view = makeView()
        let incremental = Canvas(view)
        try step(view, (1...60).map { "scrollback \($0) gypq" }.joined(separator: "\r\n"), into: incremental)
        view.scrollTo(row: 10)
        let state = try #require(view.captureFrameViewState())
        let parked = try #require(view.prepareFrame(viewState: state))
        // Scrolling changed the layout: that frame is the whole view.
        #expect(parked.region == view.bounds || parked.region.map { $0.height >= view.bounds.height } == true)
        incremental.draw(view, dirty: view.bounds)
        // Output at the bottom changes no row of the parked screen: nothing to draw.
        let quiet = try step(view, "\r\nmore output below", into: incremental)
        #expect(quiet == nil || quiet!.height < view.bounds.height, "parked output repainted \(String(describing: quiet))")
        #expect(differingBytes(incremental.pixels, fullPixels(view)) == 0)
        // A row of the parked screen that changes (a program rewrites the line it printed) is drawn, and only that.
        view.feed(text: "\u{1b}[s\u{1b}[1;1Hrewritten at the top\u{1b}[u")
        let next = try #require(view.captureFrameViewState())
        let frame = try #require(view.prepareFrame(viewState: next))
        if let region = frame.region { incremental.draw(view, dirty: region) }
        #expect(differingBytes(incremental.pixels, fullPixels(view)) == 0)
    }

    @Test func droppedDirtyRowIsDetected() throws {
        let view = makeView()
        let incremental = Canvas(view)
        try step(view, (1...12).map { "line \($0) gypq" }.joined(separator: "\r\n"), into: incremental)
        TerminalView.skipRowForTesting = 11
        defer { TerminalView.skipRowForTesting = nil }
        try step(view, "\(e)[10;1H\(e)[2Kspinner A\(e)[11;1H\(e)[2Kspinner B\(e)[12;1H\(e)[2Kstatus", into: incremental)
        TerminalView.skipRowForTesting = nil
        let bad = differingBytes(incremental.pixels, fullPixels(view))
        // The equality assertion must fail here; the known-issue wrapper records it.
        withKnownIssue("a dropped dirty row breaks pixel equality") {
            #expect(bad == 0, "\(bad) bytes differ from the full redraw")
        }
        #expect(bad > 0)
    }

    /// What WindowServer composited for the window (Core Animation's stored
    /// backing store, not a new draw). CGWindowListCreateImage is looked up
    /// dynamically: it is unavailable to the SDK on current systems.
    /// A TUI that redraws its whole dynamic region every frame rewrites rows
    /// with identical content; only the rows whose content differs are drawn.
    @Test func identicalRewritesAreNotInvalidated() throws {
        let view = makeView()
        let incremental = Canvas(view)
        let rows = 12
        func block(_ spinner: String) -> String {
            "\(e)[\(rows - 4);1H" + [
                "\(e)[2K\(spinner) Working gjpqy",
                "\(e)[2K\(e)[2m  tip: static\(e)[0m",
                "\(e)[2K\u{256D}\(String(repeating: "\u{2500}", count: 20))\u{256E}",
                "\(e)[2K\u{2502} > prompt \u{2502}",
                "\(e)[2K\u{2570}\(String(repeating: "\u{2500}", count: 20))\u{256F}",
            ].joined(separator: "\r\n")
        }
        try step(view, (1...rows).map { "line \($0)" }.joined(separator: "\r\n") + block("|"), into: incremental)
        let cell = try #require(view.cellDimension)
        var sizes: [CGFloat] = []
        for spinner in ["/", "-", "\\", "|", "/"] {
            let region = try #require(try step(view, block(spinner), into: incremental))
            sizes.append(region.height / cell.height)
            #expect(differingBytes(incremental.pixels, fullPixels(view)) == 0)
        }
        // The spinner row plus the margin row below it; not the five rewritten rows.
        #expect(sizes.allSatisfy { $0 == 2 }, "dirty rows per frame \(sizes)")
        // Rewriting everything identically invalidates nothing.
        #expect(try step(view, block("/"), into: incremental) == nil)
    }

    private func windowBytes(_ window: NSWindow) -> [UInt8]? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        guard let image = capture(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue(),
              let data = image.dataProvider?.data else { return nil }
        return [UInt8](UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }

    /// Real AppKit/Core Animation configuration: the layer-backed view in a
    /// window. A partial invalidation must leave the other pixels of the
    /// backing store intact: the layer contents after a partial update equal
    /// the layer contents after a forced full redraw of the same state.
    @Test func layerBackingStorePreservesPixelsOutsideTheDirtyRect() throws {
        let view = makeView()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: view.frame.width, height: view.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        var rects: [CGRect] = []
        view.drawRectObserver = { rects.append($0) }
        func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        func tick(_ text: String) {
            view.feed(text: text)
            view.frameTick()
            spin()
        }
        tick((1...12).map { "\(e)[3\($0 % 7 + 1)mrow \($0) gypq" }.joined(separator: "\r\n"))
        rects = []
        for frame in 0..<4 {
            tick("\(e)[10;1H\(e)[2K spinner \(frame)\(e)[12;1H\(e)[2K> typing \(frame)")
        }
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { $0.height < view.bounds.height }, "dirty rects \(rects)")
        let partial = try #require(windowBytes(window), "window capture unavailable (screen locked or no window server access): this test fails rather than passes without a capture")
        #expect(partial.contains { $0 != 0 })
        // The text rows must be visible, not a blank window.
        #expect(Set(partial).count > 8, "captured image is blank (screen locked or window not composited)")
        rects = []
        view.needsDisplay = true
        spin()
        #expect(rects.contains { $0.height >= view.bounds.height }, "forced redraw was not full: \(rects)")
        let full = try #require(windowBytes(window))
        let maxDelta = zip(partial, full).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        // WindowServer composites the stored backing store with +-1 rounding noise
        // in single channels; any real content difference is far larger.
        #expect(maxDelta <= 1, "composited max channel delta \(maxDelta)")
        view.drawRectObserver = nil
    }

    /// Descriptive release-mode micro-benchmark (LOOM_RENDER_BENCH=1): draw
    /// cost per frame of a 6-row bottom spinner update on a 45 x 150 grid,
    /// partial region (as the frame prepares it) vs the whole view.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_RENDER_BENCH"] == "1"))
    func partialDrawCostBenchmark() throws {
        let view = makeView(cols: 150, rows: 45)
        let canvas = Canvas(view)
        let e = "\u{1b}"
        _ = try step(view, (1...45).map { "L\(String(format: "%09d", $0)) " + String(repeating: "x", count: 51) }
            .joined(separator: "\r\n"), into: canvas)
        let frames = 120, repetitions = 7
        var counter = 0
        func measure(full: Bool) throws -> Double {
            var total: UInt64 = 0
            for _ in 0..<frames {
                counter += 1
                var text = ""
                for row in 40...45 {
                    text += "\(e)[\(row);1H\(e)[2K" + "S\(String(format: "%09d", counter)) " + String(repeating: "y", count: 51)
                }
                view.feed(text: text)
                let state = try #require(view.captureFrameViewState())
                let prepared = try #require(view.prepareFrame(viewState: state))
                let region = try #require(prepared.region)
                let dirty = full ? view.bounds : region
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas.context, flipped: false)
                let start = DispatchTime.now().uptimeNanoseconds
                view.drawTerminalContents(dirtyRect: dirty, context: canvas.context, bufferOffset: 0)
                total += DispatchTime.now().uptimeNanoseconds - start
                NSGraphicsContext.current = previous
            }
            return Double(total) / Double(frames) / 1e6
        }
        _ = try measure(full: true)
        _ = try measure(full: false)
        var partial: [Double] = [], full: [Double] = []
        for _ in 0..<repetitions {
            full.append(try measure(full: true))
            partial.append(try measure(full: false))
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.3f ms range %.3f-%.3f ms", sorted[sorted.count / 2],
                          sorted.first!, sorted.last!)
        }
        print("LOOM_RENDER_BENCH partial 45x150 6-row frames=\(frames) reps=\(repetitions) full: \(summary(full)) | partial: \(summary(partial)) | per-rep full \(full.map { String(format: "%.3f", $0) }) partial \(partial.map { String(format: "%.3f", $0) })")
    }

    /// P3-S diagnostic (LOOM_RENDER_BENCH=1): the exact `spinner1` byte stream
    /// into a product-sized view; per-frame prepare and draw cost and regions.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_RENDER_BENCH"] == "1"))
    func spinnerStreamDiagnostics() throws {
        let view = makeView(cols: 150, rows: 45)
        let canvas = Canvas(view)
        let esc = "\u{1b}"
        var setup = ""
        for index in 0..<200 {
            setup += "Static scrollback line \(String(format: "%03d", index)): the quick brown fox jumps over the lazy dog\r\n"
        }
        setup += "\(esc)[?25l" + String(repeating: "\r\n", count: 6) + "\(esc)[2A"
        _ = try step(view, setup, into: canvas)
        func frameBytes(_ frame: Int) -> String {
            let glyphs = ["·", "✢", "✳", "✶", "✻", "✽"]
            let tokens = frame * 13
            let rows = [
                "\(esc)[2K\(esc)[38;5;208m\(glyphs[(frame / 2) % glyphs.count])\(esc)[0m Thinking… (\(frame / 30)s · ↓ \(tokens / 1000).\((tokens % 1000) / 100)k tokens · esc to interrupt)",
                "\(esc)[2K\(esc)[2m  ⎿  Tip: frame \(frame)\(esc)[0m",
                "\(esc)[2K╭────────────────────────────────────────────────────────╮",
                "\(esc)[2K│ > Try \"refactor the session catalog\"                      │",
                "\(esc)[2K╰────────────────────────────────────────────────────────╯",
            ]
            return "\r\(esc)[4A" + rows.joined(separator: "\r\n")
        }
        let frames = 300
        var prepareNs: UInt64 = 0, drawNs: UInt64 = 0
        var heights: [CGFloat] = [], fulls = 0, nils = 0
        for frame in 0..<frames {
            view.feed(text: frameBytes(frame))
            let state = try #require(view.captureFrameViewState())
            let t0 = DispatchTime.now().uptimeNanoseconds
            let prepared = view.prepareFrame(viewState: state)
            let t1 = DispatchTime.now().uptimeNanoseconds
            prepareNs += t1 - t0
            guard let region = prepared?.region else { nils += 1; continue }
            if region.height >= view.bounds.height { fulls += 1 }
            heights.append(region.height)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas.context, flipped: false)
            let t2 = DispatchTime.now().uptimeNanoseconds
            view.drawTerminalContents(dirtyRect: region, context: canvas.context, bufferOffset: 0)
            drawNs += DispatchTime.now().uptimeNanoseconds - t2
            NSGraphicsContext.current = previous
        }
        let cell = view.cellDimension.height
        let rowsDrawn = heights.map { Int(($0 / cell).rounded()) }
        print("LOOM_RENDER_BENCH spinner frames=\(frames) prepare \(String(format: "%.3f", Double(prepareNs) / Double(frames) / 1e6)) ms/frame draw \(String(format: "%.3f", Double(drawNs) / Double(max(1, heights.count)) / 1e6)) ms/drawn-frame fullRegions=\(fulls) noRegion=\(nils) regionRows(min/max)=\(rowsDrawn.min() ?? -1)/\(rowsDrawn.max() ?? -1)")
    }
}
