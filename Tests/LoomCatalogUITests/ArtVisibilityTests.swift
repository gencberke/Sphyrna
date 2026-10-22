import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// When the art's clock follows where the view is (DESIGN §17 The budget, D-92 item 8): scrolled out of its scroll view, laid out
/// to nothing or in a closing window it has no timer, and it ticks again when it shows; About's crossing moves each time About
/// shows again. The window is never ordered front: `assumedShowing` stands in for the window's visibility and the app's activity.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ArtVisibilityTests {
    /// A 400 × 300 scroll view over a 2000 pt document, the art the bottom 100 pt of it, in a window nobody sees.
    private struct Scrolled {
        let window: NSWindow
        let scrollView: NSScrollView
        let art: ArtLayerView

        func scroll(to y: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func scrolled(animatedArt: Bool = true) -> Scrolled {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = scrollView
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scrollView.documentView = document
        let art = ArtLayerView(scene: ArtPlace.homeBand.scene, cell: LoomTheme.Art.bandCell, kind: .homeLoop,
                               animatedArt: animatedArt)
        document.addSubview(art)
        art.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let scrolled = Scrolled(window: window, scrollView: scrollView, art: art)
        scrolled.scroll(to: 0)
        art.assumedShowing = true
        return scrolled
    }

    @Test func scrolledOutOfItsScrollViewTheArtHasNoTimerAndScrolledBackItTicksAgain() {
        let s = scrolled()
        defer { s.window.close() }
        #expect(s.art.clockInput.viewOnScreen && s.art.tickerRate == LoomTheme.Art.homeLoopFPS, "on screen, the band ticks")
        s.scroll(to: 1000)
        #expect(!s.art.clockInput.viewOnScreen)
        #expect(!s.art.tickerRunning, "scrolled past, the band has no timer")
        s.scroll(to: 0)
        #expect(s.art.tickerRate == LoomTheme.Art.homeLoopFPS, "scrolled back, it ticks again")
        // The mirror case: reclocked while scrolled out, it still ticks once scrolled back.
        s.scroll(to: 1000)
        s.art.reclock()
        #expect(!s.art.tickerRunning)
        s.scroll(to: 0)
        #expect(s.art.tickerRate == LoomTheme.Art.homeLoopFPS, "scrolled back after a reclock off screen, the band is not frozen")
    }

    @Test func aStillBandIsNotDrawnAgainOnEachScroll() {
        let s = scrolled(animatedArt: false)
        defer { s.window.close() }
        #expect(!s.art.tickerRunning && s.art.clockInput.viewOnScreen)
        let drawn = s.art.stillFrames
        for y in stride(from: CGFloat(5), through: 60, by: 5) { s.scroll(to: y) }
        s.scroll(to: 0)
        #expect(s.art.stillFrames == drawn, "a scroll that keeps it on screen asks for no frame")
        s.scroll(to: 1000)
        #expect(s.art.stillFrames == drawn, "nor one that takes it off screen")
    }

    @Test func laidOutToNothingTheArtHasNoTimer() {
        let s = scrolled()
        defer { s.window.close() }
        #expect(s.art.tickerRunning)
        s.art.setFrameSize(.zero)
        #expect(!s.art.tickerRunning, "a surface laid out to zero keeps no link")
        s.art.setFrameSize(NSSize(width: 400, height: 100))
        #expect(s.art.tickerRate == LoomTheme.Art.homeLoopFPS)
    }

    @Test func aClosingWindowCountsAsNotShowing() {
        let s = scrolled()
        defer { s.window.close() }
        #expect(s.art.tickerRunning)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: s.window)
        #expect(!s.art.tickerRunning, "the window is closing: no timer, though AppKit still reads it as visible")
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: s.window)
        #expect(s.art.tickerRunning, "shown again, it ticks")
    }

    @Test func aboutsCrossingMovesEachTimeAboutShowsAgain() {
        let place = ArtPlace.about
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let art = ArtLayerView(scene: place.scene, cell: place.cell, weight: place.weight, kind: place.kind, mask: place.mask)
        art.replaysWhenShown = true
        window.contentView = art
        art.setFrameSize(NSSize(width: 600, height: 320))
        art.assumedShowing = true
        #expect(art.tickerRate == LoomTheme.Art.ambientFPS, "About opens on its crossing")
        var waited = 0.0
        while art.drawnKind != .resting, waited < 120 {
            art.advance(by: 0.1)
            waited += 0.1
        }
        #expect(art.drawnKind == .resting && !art.tickerRunning, "the hammerhead rests and the art stands still")
        art.assumedShowing = false
        #expect(!art.tickerRunning)
        art.assumedShowing = true
        #expect(art.drawnKind == .ambient, "shown again, the hammerhead crosses again")
        #expect(art.tickerRate == LoomTheme.Art.ambientFPS, "and the crossing moves, not frozen on its first frame")
    }

    /// The art in a SwiftUI `ScrollView` (Home's band and Remora's lane sit in one) finds the AppKit scroll view and follows it.
    @Test func inASwiftUIScrollViewTheArtFollowsTheScroll() async throws {
        let content = ScrollView {
            VStack(spacing: 0) {
                ArtSurface(place: .homeBand).frame(height: 120)
                Color.clear.frame(height: 2000)
            }
        }
        let hosting = NSHostingController(rootView: content.frame(width: 400, height: 300))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 400, height: 300))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let art = try #require(ArtSwitchTests.arts(in: hosting.view).first, "the band is drawn")
        let scrollView = try #require(art.enclosingScrollView, "SwiftUI's ScrollView is an NSScrollView the art can follow")
        let document = try #require(scrollView.documentView)
        art.assumedShowing = true
        #expect(art.tickerRunning, "at the top, the band ticks")
        // Scroll to the document's far end from the band, whichever way the document is flipped.
        let band = art.convert(art.bounds, to: document)
        let far = band.midY < document.bounds.midY ? document.bounds.height - scrollView.contentView.bounds.height : 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: far))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(!art.clockInput.viewOnScreen && !art.tickerRunning, "scrolled past, the band has no timer")
    }
}
