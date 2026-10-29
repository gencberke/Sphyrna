import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import LoomTerminal
@testable import LoomCatalogUITestRigs

/// CP5 A4 / §13 madde 3: every image store behind one terminal is bounded,
/// independent of how many scrollback lines exist, and ordinary terminal
/// bytes after an overflow still arrive.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalImageLimitTests {
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
}
