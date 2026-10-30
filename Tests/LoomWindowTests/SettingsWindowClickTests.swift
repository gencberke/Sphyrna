import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

extension WindowEventTests {
/// A click on a section tab switches it, and a page's own control answers its click, in the shown Settings window. In 1.6.0 the
/// page's scroll view reached up under the title strip, over the band, and took the tabs' clicks; the evidence and the other tests
/// switch tabs through `navigation.section`, so only a click in a shown window sees it (a synthesised click does not reach SwiftUI
/// in a window that was never shown).
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SettingsWindowClickTests {
    private func draw(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func element(in window: NSWindow, where matches: (AnyObject) -> Bool) -> AnyObject? {
        window.contentView.flatMap { accessibilityElements(in: $0).first(where: matches) }
    }

    /// Mouse-down and mouse-up at the centre of `element`'s frame, sent as `SearchFocusAndHitTests` sends them. Nothing is posted to
    /// the event queue: a queued event stopped the main run loop, and the test process then exited 0 in the middle of the test.
    private func click(_ element: AnyObject, in window: NSWindow) async throws {
        let frame = InkAX.frame(element)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.sendEvent(try event(.leftMouseDown))
        NSApp.sendEvent(try event(.leftMouseUp))
    }

    private func tab(_ section: SettingsSection, in window: NSWindow) async throws -> AnyObject {
        let identifier = "settings-tab-\(section.title)"
        let found = await waitFor("the \(section.title) tab to be drawn", observe: { () -> AnyObject? in
            draw(window)
            return element(in: window) { InkAX.identifier($0) == identifier }
        }, until: { $0 != nil })
        return try #require(found, "the \(section.title) tab is drawn")
    }

    /// Waits for a click to open `section`.
    private func opens(_ section: SettingsSection, _ navigation: SettingsNavigation, in window: NSWindow) async {
        await waitFor("the \(section.title) section to open") { draw(window); return navigation.section == section }
    }

    /// Waits for `section`'s tab to be drawn as the open one: the band, and the page under it, show it.
    private func shows(_ section: SettingsSection, in window: NSWindow) async {
        let identifier = "settings-tab-\(section.title)"
        await waitFor("the \(section.title) tab to be drawn open") {
            draw(window)
            // UIAccessibilityTraitSelected, the bit SwiftUI sets for `.isSelected` (InkHostTests reads it the same way).
            return element(in: window) { InkAX.identifier($0) == identifier }.map {
                (($0.accessibilityAttributeValue?(NSAccessibility.Attribute(rawValue: "AXTraits")) as? Int) ?? 0) & 0x8 != 0
            } == true
        }
    }

    @Test func aClickOnATabSwitchesItAndAPageControlAnswersItsClick() async throws {
        enableAccessibilityTree()
        let (model, root) = try SettingsWindowClickShared.settingsTestModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = SettingsNavigation(section: .general)
        let window = SettingsWindowConfiguration.makeWindow(content: SettingsWindowClickShared.settingsTestView(model, navigation), background: .windowBackgroundColor)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        let theme = try await tab(.theme, in: window)
        let origin = window.frame.origin

        // From General, the window's first tab.
        try await click(theme, in: window)
        await opens(.theme, navigation, in: window)
        #expect(navigation.section == .theme, "a click on Theme, from General, opens Theme")

        // From Remora, where Home's ⋯ → Remora opens the window.
        navigation.open(.remora)
        await shows(.remora, in: window)
        try await click(try await tab(.about, in: window), in: window)
        await opens(.about, navigation, in: window)
        #expect(navigation.section == .about, "a click on About, from Remora, opens About")
        try await click(try await tab(.general, in: window), in: window)
        await opens(.general, navigation, in: window)
        #expect(navigation.section == .general, "a click on General, from About, opens General")

        // D-100: while the Chat face is frozen General has no "Sessions run in" switch.
        navigation.open(.general)
        await shows(.general, in: window)
        // The negative window: the 3 s the old lookup polled for the switch.
        await holds("General shows no \"Sessions run in\" switch", for: .seconds(3)) {
            draw(window)
            return element(in: window) { InkAX.label($0) == "Sessions run in" } == nil
        }
        #expect(element(in: window) { InkAX.label($0) == "Sessions run in" } == nil, "no face to choose")
        #expect(model.newSessionFace == .terminal)
        #expect(window.frame.origin == origin, "a still click does not move the window")
    }
}
}
