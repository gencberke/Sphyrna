import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import LoomTerminal

/// CP5 A4 / §13 madde 3: every image store behind one terminal is bounded,
/// independent of how many scrollback lines exist, and ordinary terminal
/// bytes after an overflow still arrive.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalImageLimitTests {
    /// Real raster bytes (CGImage bytesPerRow × height) of every stored inline
    /// image per screen, independent of the quota's own estimate.
    private func inlineImages(_ surface: TerminalSurface) -> [(count: Int, rasterBytes: Int)] {
        surface.view.withTerminal { terminal in
            [terminal.normalBuffer, terminal.altBuffer].map { buffer in
                var count = 0
                var bytes = 0
                for index in 0..<buffer.lines.count {
                    for image in buffer.lines[index].images ?? [] {
                        count += 1
                        let stored = (image as! TerminalView.AppleImage).image
                        var rect = CGRect(origin: .zero, size: stored.size)
                        if let raster = stored.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                            bytes += raster.bytesPerRow * raster.height
                        }
                    }
                }
                return (count, bytes)
            }
        }
    }

    /// Feeds off the main actor through the engine's Sendable feed handle,
    /// as the PTY IO queue does in production; heavy parsing on MainActor
    /// would starve other suites' main-actor work.
    private func feed(_ surface: TerminalSurface, _ text: String, times: Int = 1) async {
        let sender = surface.view.feedSender
        await Task.detached { for _ in 0..<times { sender.feed(text: text) } }.value
    }

    /// Sixel with `width`×6 red pixels; `ESC [ H` puts every image on one row,
    /// the case the reviewer showed was unbounded (§13 madde 3).
    private func sixel(width: Int, home: Bool) -> String {
        (home ? "\u{1b}[H" : "") + "\u{1b}Pq\"1;1;\(width);6#1;2;100;0;0#1!\(width)~\u{1b}\\"
    }

    @Test func repeatedSixelOnOneRowStaysWithinCountLimit() async {
        let surface = TerminalSurface()
        await feed(surface, sixel(width: 3, home: true), times: TerminalSurfaceLimits.inlineImagesPerScreen + 1_000)
        await feed(surface, "\u{1b}[20;1HAFTER-IMAGES")
        let stored = inlineImages(surface)[0]
        #expect(stored.count > 0)
        #expect(stored.count <= TerminalSurfaceLimits.inlineImagesPerScreen)
        #expect(surface.screenText().contains("AFTER-IMAGES"))
    }

    /// A fractional font size gives fractional cell and stripe sizes, where
    /// reported and raster sizes differ. Both screens, clear and resize.
    @Test(arguments: [14.0, 13.5])
    func largeSixelStreamsStayWithinRasterLimitOnBothScreens(fontSize: Double) async {
        let surface = TerminalSurface(fontSize: fontSize)
        let wide = sixel(width: 1_200, home: false) + "\r\n"
        // Wide stripes scroll through the 2,000-line history; without the
        // quota every stripe in scrollback would be kept.
        await feed(surface, wide, times: 400)
        await feed(surface, "\u{1b}[?1049h")
        await feed(surface, wide, times: 400)
        var screens = inlineImages(surface)
        for screen in screens {
            #expect(screen.count > 0)
            #expect(screen.count <= TerminalSurfaceLimits.inlineImagesPerScreen)
            #expect(screen.rasterBytes <= TerminalSurfaceLimits.inlineImageBytesPerScreen,
                    "\(screen.rasterBytes) raster bytes at font \(fontSize)")
        }
        // Leaving the alternate screen, clearing and resizing never grow the stores.
        await feed(surface, "\u{1b}[?1049l\u{1b}[2J\u{1b}[3J")
        surface.view.resize(cols: 60, rows: 20)
        await feed(surface, wide, times: 400)
        screens = inlineImages(surface)
        #expect(screens[0].rasterBytes <= TerminalSurfaceLimits.inlineImageBytesPerScreen)
        #expect(screens[1].rasterBytes <= TerminalSurfaceLimits.inlineImageBytesPerScreen)
        await feed(surface, "AFTER-RESIZE")
        #expect(surface.screenText().contains("AFTER-RESIZE"))
    }

    enum InlineKind: String, CaseIterable { case sixel, iterm2 }

    /// Stored inline images with their reported and real raster sizes.
    private func rasters(_ view: TerminalView) -> [(reported: (Int, Int), raster: (Int, Int), bytes: Int)] {
        view.withTerminal { terminal in
            var result: [(reported: (Int, Int), raster: (Int, Int), bytes: Int)] = []
            for buffer in [terminal.normalBuffer, terminal.altBuffer] {
                for index in 0..<buffer.lines.count {
                    for image in buffer.lines[index].images ?? [] {
                        let stored = (image as! TerminalView.AppleImage).image
                        var rect = CGRect(origin: .zero, size: stored.size)
                        guard let raster = stored.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
                        result.append(((image.pixelWidth, image.pixelHeight),
                                       (raster.width, raster.height), raster.bytesPerRow * raster.height))
                    }
                }
            }
            return result
        }
    }

    /// Regression for §21.1 madde 2: tiny images whose stripes have
    /// fractional point sizes, so the truncated reported size is smaller than
    /// the ceiling-sized raster. With only a byte quota, the stored raster
    /// must stay under it; counting `w × h × 4` of the reported size does not.
    @Test(arguments: InlineKind.allCases)
    func byteQuotaCoversRasterRounding(kind: InlineKind) async throws {
        let limit = 64 * 1024
        var options = TerminalSurfaceLimits.options
        options.inlineImageStorageLimitBytesPerScreen = limit
        options.inlineImageLimitPerScreen = nil
        let view = LoomTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                    font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                    options: options)
        // Image scale comes from the view's window, as in the packaged app;
        // a Retina screen gives stripes fractional point widths. Never shown.
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main, "no screen: the rounding fixture needs a display")
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered,
                              defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil }
        let image: String
        switch kind {
        case .sixel:
            image = "\u{1b}[H" + sixel(width: 3, home: false)
        case .iterm2:
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 7, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            // `width=1%` of the terminal width is another fractional-size path.
            image = "\u{1b}[H\u{1b}]1337;File=inline=1;width=1%;size=\(png.count):\(png.base64EncodedString())\u{07}"
        }
        let sender = view.feedSender
        await Task.detached { for _ in 0..<3_000 { sender.feed(text: image) } }.value
        let stored = rasters(view)
        try #require(!stored.isEmpty, "no \(kind) image was stored")
        // Precondition: this fixture really has reported < raster.
        #expect(stored.contains { $0.raster.0 > $0.reported.0 || $0.raster.1 > $0.reported.1 },
                "\(kind): reported \(stored[0].reported) raster \(stored[0].raster)")
        let total = stored.reduce(0) { $0 + $1.bytes }
        #expect(total <= limit, "\(kind): \(total) raster bytes in \(stored.count) images for a \(limit)-byte quota")
    }

    @Test func kittyStorageEvictsBeyondScreenLimit() async {
        let surface = TerminalSurface()
        let side = 1_024 // 4 MiB RGBA per image; limit is 8 MiB per screen.
        let payload = Data(repeating: 0x7f, count: side * side * 4).base64EncodedString()
        let sender = surface.view.feedSender
        await Task.detached { for id in 1...4 {
            var offset = payload.startIndex
            var first = true
            while offset < payload.endIndex {
                let end = payload.index(offset, offsetBy: 4_096, limitedBy: payload.endIndex) ?? payload.endIndex
                let more = end < payload.endIndex ? 1 : 0
                let control = first ? "a=t,f=32,s=\(side),v=\(side),i=\(id),q=2,m=\(more)" : "m=\(more)"
                sender.feed(text: "\u{1b}_G\(control);\(payload[offset..<end])\u{1b}\\")
                first = false
                offset = end
            }
        } }.value
        await feed(surface, "AFTER-KITTY")
        let total = surface.view.withTerminal { $0.kittyGraphicsState.totalImageBytes }
        #expect(total > 0)
        #expect(total <= Int(TerminalSurfaceLimits.kittyBytesPerScreen))
        #expect(surface.screenText().contains("AFTER-KITTY"))
    }

    @Test func oversizedOscIsDroppedAndLaterOutputStillArrives() async throws {
        let surface = TerminalSurface()
        var titles: [String] = []
        surface.onTitle = { titles.append($0) }
        let huge = String(repeating: "t", count: TerminalSurfaceLimits.maximumOscBytes + 1)
        await feed(surface, "\u{1b}]2;\(huge)\u{07}AFTER-OSC\u{1b}]2;small\u{07}")
        #expect(surface.screenText().contains("AFTER-OSC"))
        // Title callbacks arrive on the main queue; the view already truncates
        // what it forwards, so the oversized sequence must not appear at all.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while titles.last != "small", ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!titles.contains { $0.hasPrefix("ttt") })
        #expect(titles.last == "small")
    }
}
