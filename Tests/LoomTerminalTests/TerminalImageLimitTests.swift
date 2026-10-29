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
