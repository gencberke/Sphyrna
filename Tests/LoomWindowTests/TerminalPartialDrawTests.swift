import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import LoomTerminal
@testable import LoomCatalogUITestRigs

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

    private let e = "\u{1b}"

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
}
