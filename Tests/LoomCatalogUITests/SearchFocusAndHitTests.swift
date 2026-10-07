import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

private func keyEvent(_ characters: String, keyCode: UInt16, in window: NSWindow,
                      modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
}

extension WindowEventTests {
/// I3: Find focuses the search field, Esc clears it; small controls keep a 24 pt hit area;
/// banners fade in only when Reduce Motion is off.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SearchFocusAndHitTests {
    private func model() throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (CatalogModel(catalog: nil, events: SessionEventHub(),
                             preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json"))), root)
    }

    /// Whether a text field's field editor holds the keyboard (the sidebar has one text field, the search).
    private func searchHasFocus(in window: NSWindow) -> Bool { window.firstResponder is NSText }

    @Test func findFocusesTheSearchFieldAndEscapeClearsThenLeavesIt() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, _) = host(SidebarView(model: model), size: NSSize(width: 300, height: 400))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!searchHasFocus(in: window))

        model.requestSearchFocus() // what Edit > Find (Cmd+F) calls
        try await Task.sleep(for: .milliseconds(300))
        #expect(searchHasFocus(in: window))

        model.setSearchText("rocket")
        try await Task.sleep(for: .milliseconds(200))
        NSApp.sendEvent(try keyEvent("\u{1b}", keyCode: 53, in: window))
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.searchText.isEmpty, "Esc clears the search")
        #expect(searchHasFocus(in: window), "the field keeps focus after clearing")

        NSApp.sendEvent(try keyEvent("\u{1b}", keyCode: 53, in: window))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!searchHasFocus(in: window), "Esc on an empty field leaves it")
    }

    @Test func findOnACollapsedSidebarShowsItFirstThenFocuses() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        var toggles = 0
        model.onToggleSidebar = { toggles += 1; model.setSidebarCollapsed(false) }
        model.setSidebarCollapsed(true)
        let before = model.searchFocusRequest
        model.requestSearchFocus()
        #expect(toggles == 1)
        #expect(model.searchFocusRequest == before, "not asked until the sidebar has opened")
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.searchFocusRequest == before + 1)
        model.requestSearchFocus() // already visible: asked at once
        #expect(toggles == 1 && model.searchFocusRequest == before + 2)
    }

    @Test func aSmallChromeButtonAnswersAClickOverAtLeastTheMinimumHitTarget() async throws {
        func hitExtent(of size: CGSize) async throws -> (width: Double, height: Double) {
            var presses = 0
            // Far from the title bar, which swallows clicks in the window's top strip.
            let content = Button { presses += 1 } label: { Image(systemName: "ellipsis") }
                .buttonStyle(ChromeButtonStyle(size: size))
                .frame(width: 120, height: 200).ignoresSafeArea()
            let (window, hosting) = host(content, size: NSSize(width: 120, height: 200))
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
        let regular = try await hitExtent(of: LoomTheme.Layout.chromeButton) // 26 x 24 stays as drawn
        print("HITEXTENT 26x24 control answers", regular.width, "x", regular.height)
        #expect(regular.width >= 25.5 && regular.width <= 26.5 && regular.height >= 23.5 && regular.height <= 24.5)
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
            let (window, hosting) = host(content, size: NSSize(width: 60, height: 60))
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
