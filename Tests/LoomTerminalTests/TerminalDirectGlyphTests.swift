import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import LoomTerminal

/// CP5 PERF P1 / PERF-2: the Core Graphics direct glyph path draws exactly
/// the pixels of the attributed-string path, and only simple cells use it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalDirectGlyphTests {
    struct Frame {
        let pixels: [UInt8]
        let directCells: Int
    }


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

    /// Renders the whole view through `drawTerminalContents` into an sRGB
    /// bitmap at 2x scale.
    private func render(_ view: TerminalView, direct: Bool) throws -> Frame {
        let viewState = try #require(view.captureFrameViewState())
        view.renderOwner.withUpdatedCursor(viewState: viewState) { _, _ in }
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        let cache = view.coreGraphicsRenderCache
        cache.directGlyphRunsEnabled = direct
        let before = cache.directGlyphCells
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.drawTerminalContents(dirtyRect: view.bounds, context: context, bufferOffset: 0)
        NSGraphicsContext.current = previous
        cache.directGlyphRunsEnabled = true
        let data = try #require(context.data)
        let pixels = [UInt8](UnsafeRawBufferPointer(start: data, count: height * width * 4))
        return Frame(pixels: pixels, directCells: cache.directGlyphCells - before)
    }

    /// Exact comparison; no tolerance: both paths issue the same Core
    /// Graphics operations for the same glyphs, colors and positions.
    private func expectIdentical(_ view: TerminalView, minimumDirectCells: Int,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
        let reference = try render(view, direct: false)
        let direct = try render(view, direct: true)
        #expect(reference.directCells == 0, sourceLocation: sourceLocation)
        #expect(direct.directCells >= minimumDirectCells,
                "direct path drew \(direct.directCells) cells", sourceLocation: sourceLocation)
        let differing = zip(reference.pixels, direct.pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        #expect(differing == 0, "\(differing) differing bytes", sourceLocation: sourceLocation)
        // A blank frame would compare equal for a trivial reason.
        #expect(reference.pixels.contains { $0 != 0 }, sourceLocation: sourceLocation)
    }

    enum Scenario: String, CaseIterable {
        case benchmarkPayload, palette256, trueColor, boldDimItalic, underlineVariants,
             strikethrough, inverse, wideNeighbors, boxAndBlockNeighbors, lineAttributes,
             hyperlinkAndBlink, rightToLeftRow

        var text: String {
            let e = "\u{1b}"
            switch self {
            case .benchmarkPayload:
                return (1...11).map { String(format: "L%09d ", $0) + String(repeating: "x", count: 51) }
                    .joined(separator: "\r\n")
            case .palette256:
                return (0..<10).map { row in
                    (0..<8).map { i in
                        let n = (row * 8 + i) * 3
                        return "\(e)[38;5;\(n)m\(e)[48;5;\(255 - n)mc\(n)."
                    }.joined() + "\(e)[0m"
                }.joined(separator: "\r\n")
            case .trueColor:
                return (0..<10).map { row in
                    (0..<6).map { i in
                        "\(e)[38;2;\(row * 25);\(i * 40);200m\(e)[48;2;\(i * 30);\(row * 20);40mtc \(row)-\(i)"
                    }.joined() + "\(e)[0m plain"
                }.joined(separator: "\r\n")
            case .boldDimItalic:
                return ["\(e)[1mbold text\(e)[0m normal \(e)[2mdim text\(e)[0m",
                        "\(e)[3mitalic\(e)[0m \(e)[1;3mbold italic\(e)[0m \(e)[1;2mbold dim\(e)[0m",
                        "\(e)[1;31mbold red\(e)[0m \(e)[2;38;5;45mdim 256\(e)[0m \(e)[2;38;2;250;100;0;48;2;0;0;90mdim tc\(e)[0m",
                        "\(e)[91mbright\(e)[0m \(e)[3;34mitalic blue\(e)[0m"]
                    .joined(separator: "\r\n")
            case .underlineVariants:
                return ["\(e)[4msingle underline\(e)[0m \(e)[21mdouble\(e)[0m",
                        "\(e)[4:2mdouble style\(e)[0m \(e)[4:3mcurly style\(e)[0m",
                        "\(e)[4:4mdotted style\(e)[0m \(e)[4:5mdashed style\(e)[0m",
                        "\(e)[4;58;2;255;0;0mred underline\(e)[0m \(e)[4:3;58;5;82mcurly green\(e)[0m",
                        "\(e)[4;33;44munderline on bg\(e)[0m"]
                    .joined(separator: "\r\n")
            case .strikethrough:
                return "\(e)[9mstruck through\(e)[0m mid \(e)[9;4;35mstruck underlined\(e)[0m\r\n"
                    + "\(e)[9;1mbold struck\(e)[0m"
            case .inverse:
                return "\(e)[7minverse default\(e)[0m \(e)[7;31;42minverse colors\(e)[0m\r\n"
                    + "\(e)[7;38;2;10;200;30minverse tc\(e)[0m \(e)[7;2mdim inverse\(e)[0m \(e)[7;4minv ul\(e)[0m"
            case .wideNeighbors:
                return ["ab中文cd漢字ef",
                        "x😀y🎉z",
                        "pre \u{2764}\u{FE0F} post \u{263A}\u{FE0F}x\u{263A}\u{FE0E}y",
                        "cafe\u{301} e\u{301}x n\u{303}a q\u{20DD}r",
                        "\(e)[31mred中\(e)[32mgreen😀\(e)[0m tail é→ok"]
                    .joined(separator: "\r\n")
            case .boxAndBlockNeighbors:
                return ["┌──────┐ text",
                        "│ab cd │x\u{2588}y\u{2591}z",
                        "└──────┘\u{2580}q\u{259F}",
                        "\(e)[34m╭─ title ─╮\(e)[0m \u{E0B0}pl\u{E0B2}"]
                    .joined(separator: "\r\n")
            case .lineAttributes:
                return ["normal line",
                        "\(e)#6wide line ab",
                        "\(e)#3tall top",
                        "\(e)#4tall top",
                        "\(e)#3\(e)[4;31mtall ul\(e)[0m",
                        "\(e)#4\(e)[4;31mtall ul\(e)[0m",
                        "after"]
                    .joined(separator: "\r\n")
            case .hyperlinkAndBlink:
                return "see \(e)]8;;https://example.com\u{07}link text\(e)]8;;\u{07} after\r\n"
                    + "\(e)[5mblinking\(e)[0m steady"
            case .rightToLeftRow:
                return "abc \u{05E9}\u{05DC}\u{05D5}\u{05DD} def\r\nplain ascii row"
            }
        }
    }

    @Test(arguments: Scenario.allCases)
    func directPathMatchesAttributedPath(scenario: Scenario) throws {
        let view = makeView()
        if scenario == .hyperlinkAndBlink {
            view.linkHighlightMode = .always
        }
        view.feed(text: scenario.text)
        try expectIdentical(view, minimumDirectCells: 10)
    }

    /// Selection covering part of one run and spanning rows; the cursor sits
    /// inside a run (the caret itself is a separate view in this renderer).
    @Test func selectionAndCursorRowsMatch() throws {
        let view = makeView()
        view.feed(text: "first line of plain text\r\n\u{1b}[31msecond red line\u{1b}[0m and more\r\nthird line\r\ncursor row here")
        view.feed(text: "\u{1b}[4;8H")
        view.selection.setSelection(start: Position(col: 6, row: 0), end: Position(col: 9, row: 1))
        try expectIdentical(view, minimumDirectCells: 40)
    }

    /// The direct path takes exactly the simple cells: wide, combining,
    /// emoji, box drawing and RTL rows stay on the attributed path.
    @Test func onlySimpleCellsTakeTheDirectPath() throws {
        let view = makeView(cols: 40, rows: 6)
        view.feed(text: "ab中cd\r\nx\u{263A}\u{FE0F}y\u{263A}\u{FE0E}e\u{301}\r\n│q─\r\nabc \u{05E9}\u{05DC} d\r\n\u{1b}[5mblink\u{1b}[0mok")
        let viewState = try #require(view.captureFrameViewState())
        view.renderOwner.withUpdatedCursor(viewState: viewState) { _, _ in }
        var directColumns: [[Int]] = []
        var segmentColumns: [[Int]] = []
        let table = DirectGlyphTable()
        view.renderOwner.withSnapshotForDrawing(viewState: viewState) { snapshot, context in
            for row in 0..<5 {
                guard let snapshotRow = snapshot.row(atAbsolute: row) else { continue }
                let info = view.textBuilder.buildAttributedString(
                    row: snapshotRow, absoluteRow: row, context: context, directGlyphs: table)
                directColumns.append(view.textBuilder.directRuns.flatMap { $0.column..<($0.column + $0.count) })
                segmentColumns.append(info.segments.map(\.column))
            }
        }
        let tail = { (from: Int) in Array(from..<40) }
        #expect(directColumns[0] == [0, 1] + tail(4))
        #expect(segmentColumns[0] == [2])
        // x ☺️(2 cells) y ☺︎ é: only x and y and the trailing blanks.
        #expect(directColumns[1] == [0, 3] + tail(6))
        // Box drawing cells go to their renderer through the attributed path.
        #expect(directColumns[2] == [1] + tail(3))
        // RTL content puts the whole row on the attributed path.
        #expect(directColumns[3].isEmpty)
        // Blinking text in its visible phase draws like steady text; only
        // the hidden phase stays on the attributed path.
        #expect(directColumns[4] == tail(0))
    }

    /// The shaping probe accepts the product's four style faces; otherwise
    /// the product would silently never take the direct path.
    @Test func productFontFacesAreVerified() {
        let view = makeView()
        let table = DirectGlyphTable()
        let fonts = view.fontSet
        for face in [fonts.normal, fonts.bold, fonts.italic, fonts.boldItalic] {
            #expect(table.glyphs(for: face)?.count == DirectGlyphTable.codeCount, "\(face.fontName)")
            // Blank spaces are left out of the recorded glyphs.
            #expect(table.drawingGlyphs(for: face)?.spaceIsBlank == true, "\(face.fontName)")
        }
    }

    /// Descriptive release-mode micro-benchmark (LOOM_RENDER_BENCH=1): draw
    /// cost of a 45 × 150 grid of the CPU40 payload, new content per frame.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_RENDER_BENCH"] == "1"))
    func drawCostBenchmark() throws {
        let view = makeView(cols: 150, rows: 45)
        let frames = 120
        let repetitions = 7
        var line = 0
        func feedScreen() {
            var text = ""
            for _ in 0..<45 {
                line += 1
                text += String(format: "L%09d ", line) + String(repeating: "x", count: 51) + "\r\n"
            }
            view.feed(text: text)
        }
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = nil }
        let viewState = try #require(view.captureFrameViewState())
        func measure(direct: Bool) -> Double {
            view.coreGraphicsRenderCache.directGlyphRunsEnabled = direct
            var total: UInt64 = 0
            for _ in 0..<frames {
                feedScreen()
                view.renderOwner.withUpdatedCursor(viewState: viewState) { _, _ in }
                let start = DispatchTime.now().uptimeNanoseconds
                view.drawTerminalContents(dirtyRect: view.bounds, context: context, bufferOffset: 0)
                total += DispatchTime.now().uptimeNanoseconds - start
            }
            return Double(total) / Double(frames) / 1e6
        }
        _ = measure(direct: false)
        _ = measure(direct: true)
        var old: [Double] = []
        var new: [Double] = []
        for _ in 0..<repetitions {
            old.append(measure(direct: false))
            new.append(measure(direct: true))
        }
        view.coreGraphicsRenderCache.directGlyphRunsEnabled = true
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.3f ms range %.3f–%.3f ms", sorted[sorted.count / 2],
                          sorted.first!, sorted.last!)
        }
        print("LOOM_RENDER_BENCH 45x150 frames=\(frames) reps=\(repetitions) old: \(summary(old)) | direct: \(summary(new)) | per-rep old \(old.map { String(format: "%.3f", $0) }) direct \(new.map { String(format: "%.3f", $0) })")
    }
}
