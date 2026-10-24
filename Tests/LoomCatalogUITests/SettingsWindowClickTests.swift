import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// The real Settings window (`SettingsWindowConfiguration`, as the app builds it) and what happens to it outside a click.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SettingsWindowTests {
    @Test func closingTheWindowClosesTheSheetOverSettings() throws {
        let (model, root) = try settingsTestModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = SettingsNavigation(section: .remora)
        let window = SettingsWindowConfiguration.makeWindow(content: settingsTestView(model, navigation), background: .windowBackgroundColor)
        navigation.openRemoraMemory()
        #expect(navigation.openSheet == .remoraMemory)
        window.close()
        #expect(navigation.openSheet == nil, "the window comes back without the sheet it was closed under")
    }
}

extension WindowEventTests {
/// A click on a section tab switches it, and a page's own control answers its click, in the shown Settings window. The 1.6.0
/// window moved by its background and swallowed these clicks; the evidence and the other tests switch tabs through
/// `navigation.section`, so only a click in a shown window sees it (a synthesised click does not reach SwiftUI in a window that was
/// never shown).
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

    /// Mouse-down and mouse-up at the centre of `element`'s frame, as the window server would deliver them. The mouse-up is also
    /// queued first, so a window drag that starts on the mouse-down ends instead of waiting for it; what is left is discarded.
    private func click(_ element: AnyObject, in window: NSWindow) async throws {
        let frame = InkAX.frame(element)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        NSApp.sendEvent(try event(.leftMouseDown))
        NSApp.sendEvent(try event(.leftMouseUp))
        NSApp.discardEvents(matching: .leftMouseUp, before: nil)
        try await settle(window)
    }

    private func tab(_ section: SettingsSection, in window: NSWindow) async throws -> AnyObject {
        try #require(await element(in: window) { InkAX.identifier($0) == "settings-tab-\(section.title)" },
                     "the \(section.title) tab is drawn")
    }

    @Test func aClickOnATabSwitchesItAndAPageControlAnswersItsClick() async throws {
        enableAccessibilityTree()
        let (model, root) = try settingsTestModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = SettingsNavigation(section: .general)
        let window = SettingsWindowConfiguration.makeWindow(content: settingsTestView(model, navigation), background: .windowBackgroundColor)
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

        // A page's own control: General's "Sessions run in".
        let other: SessionFace = model.newSessionFace == .chat ? .terminal : .chat
        let group = try #require(await element(in: window) { InkAX.label($0) == "Sessions run in" }, "the segmented control is drawn")
        let segment = try #require(accessibilityElements(in: group).first { InkAX.label($0) == other.title }, "its \(other.title) segment")
        try await click(segment, in: window)
        #expect(model.newSessionFace == other, "a click on \(other.title) picks it")
        #expect(window.frame.origin == origin, "a still click does not move the window")
    }
}
}

@MainActor
private func settingsTestModel() throws -> (CatalogModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-settings-window-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (CatalogModel(catalog: nil, events: SessionEventHub(),
                         preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json"))), root)
}

@MainActor
private func settingsTestView(_ model: CatalogModel, _ navigation: SettingsNavigation) -> SettingsView {
    let root = FileManager.default.temporaryDirectory
    return SettingsView(model: model, usage: nil, navigation: navigation,
                        about: SettingsAbout(version: "Version 1.6.1", dataFolder: root.appendingPathComponent("Loom"),
                                             claudeProfile: nil))
}
