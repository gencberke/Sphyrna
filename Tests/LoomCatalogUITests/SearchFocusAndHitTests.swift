import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

extension WindowEventTests {
/// The sidebar's search is the command palette's door; small controls keep a 24 pt hit area; banners fade in only when Reduce
/// Motion is off.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SearchFocusAndHitTests {
    private func model() throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (CatalogModel(catalog: nil, events: SessionEventHub(),
                             preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json"))), root)
    }

    /// The sidebar's element that reads "Search, opens the command palette", as VoiceOver finds it.
    private func door(in view: NSView) -> AnyObject? {
        accessibilityElements(in: view).first { ($0.accessibilityLabel?() ?? "") == SearchDoor.accessibilityLabel }
    }

    @Test func theSearchDoorOpensThePaletteAndTheSidebarHoldsNoTextField() async throws {
        enableAccessibilityTree()
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 300, height: 400), key: true)
        defer { window.orderOut(nil); model.palette.close() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!(window.firstResponder is NSText), "no field holds the keyboard")
        #expect(!accessibilityElements(in: hosting.view).contains { $0.accessibilityRole?() == .textField },
                "the filter is gone: the sidebar has no text field")

        let door = try #require(door(in: hosting.view), "the door is drawn")
        #expect(door.accessibilityRole?() == .button)
        #expect(!model.palette.isOpen)
        #expect(door.accessibilityPerformPress?() == true)
        #expect(model.palette.isOpen, "a click on the door runs what ⌘K runs")
        #expect(SearchDoor.keyHint == "⌘K")
    }

    @Test func aSmallChromeButtonAnswersAClickOverAtLeastTheMinimumHitTarget() async throws {
        func hitExtent(of size: CGSize) async throws -> (width: Double, height: Double) {
            var presses = 0
            // Far from the title bar, which swallows clicks in the window's top strip.
            let content = Button { presses += 1 } label: { Image(systemName: "ellipsis") }
                .buttonStyle(ChromeButtonStyle(size: size))
                .frame(width: 120, height: 200).ignoresSafeArea()
            let (window, hosting) = host(content, size: NSSize(width: 120, height: 200), key: true)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(400))
            func hits(x: Double, y: Double) async throws -> Bool {
                let before = presses
                let point = hosting.view.convert(NSPoint(x: x, y: y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    NSApp.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(25))
                return presses > before
            }
            var width = 0.0, height = 0.0
            for x in stride(from: 40.0, through: 80.0, by: 0.5) where try await hits(x: x, y: 100) { width += 0.5 }
            for y in stride(from: 80.0, through: 120.0, by: 0.5) where try await hits(x: 60, y: y) { height += 0.5 }
            return (width, height)
        }
        let small = try await hitExtent(of: LoomTheme.Layout.projectMenuButton) // drawn 22 x 20
        print("HITEXTENT 22x20 control answers", small.width, "x", small.height)
        #expect(small.width >= 23.5 && small.height >= 23.5, "a 22 x 20 control answers over at least 24 x 24")
        let regular = try await hitExtent(of: LoomTheme.Layout.chromeButton) // 28 x 28 stays as drawn
        print("HITEXTENT 28x28 control answers", regular.width, "x", regular.height)
        #expect(regular.width >= 27.5 && regular.width <= 28.5 && regular.height >= 27.5 && regular.height <= 28.5)
    }

    /// Mean brightness of a hosted view's rendering.
    private func brightness(of view: NSView) throws -> Double {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let color = try #require(rep.colorAt(x: Int(rep.pixelsWide / 2), y: Int(rep.pixelsHigh / 2))?.usingColorSpace(.sRGB))
        return Double(color.redComponent)
    }

    @Test func aBannerFadesInOverTwoHundredMillisecondsOnlyWithoutReduceMotion() async throws {
        func firstFrames(reduceMotion: Bool) async throws -> (early: Double, late: Double) {
            let content = Color.white.fadesIn()
                .frame(width: 60, height: 60).background(Color.black)
                .transformEnvironment(\.self) { $0._accessibilityReduceMotion = reduceMotion }
            let (window, hosting) = host(content, size: NSSize(width: 60, height: 60), key: true)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(60))
            let early = try brightness(of: hosting.view)
            try await Task.sleep(for: .milliseconds(500))
            return (early, try brightness(of: hosting.view))
        }
        let animated = try await firstFrames(reduceMotion: false)
        #expect(animated.late > 0.95, "fully shown after the transition")
        #expect(animated.early < animated.late, "still fading shortly after it appeared")
        let instant = try await firstFrames(reduceMotion: true)
        #expect(instant.early > 0.95 && instant.late > 0.95, "Reduce Motion: no fade, shown at once")
    }
}
}
