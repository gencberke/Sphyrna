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
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func element(in window: NSWindow, where matches: (AnyObject) -> Bool) async throws -> AnyObject? {
        for _ in 0..<30 {
            if let view = window.contentView, let found = accessibilityElements(in: view).first(where: matches) { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
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
        try await settle(window)
    }

    private func tab(_ section: SettingsSection, in window: NSWindow) async throws -> AnyObject {
        try #require(await element(in: window) { InkAX.identifier($0) == "settings-tab-\(section.title)" },
                     "the \(section.title) tab is drawn")
    }

    @Test func aClickOnATabSwitchesItAndAPageControlAnswersItsClick() async throws {
        enableAccessibilityTree()
        let (model, root) = try SettingsWindowClickShared.settingsTestModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = SettingsNavigation(section: .general)
        let window = SettingsWindowConfiguration.makeWindow(content: SettingsWindowClickShared.settingsTestView(model, navigation), background: .windowBackgroundColor)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        let origin = window.frame.origin

        // From General, the window's first tab.
        try await click(try await tab(.theme, in: window), in: window)
        #expect(navigation.section == .theme, "a click on Theme, from General, opens Theme")

        // From Remora, where Home's ⋯ → Remora opens the window.
        navigation.open(.remora)
        try await settle(window)
        try await click(try await tab(.about, in: window), in: window)
        #expect(navigation.section == .about, "a click on About, from Remora, opens About")
        try await click(try await tab(.general, in: window), in: window)
        #expect(navigation.section == .general, "a click on General, from About, opens General")

        // D-100: while the Chat face is frozen General has no "Sessions run in" switch.
        navigation.open(.general)
        try await settle(window)
        #expect(try await element(in: window) { InkAX.label($0) == "Sessions run in" } == nil, "no face to choose")
        #expect(model.newSessionFace == .terminal)
        #expect(window.frame.origin == origin, "a still click does not move the window")
    }
}
}
