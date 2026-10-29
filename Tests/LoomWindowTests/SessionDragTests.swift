import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

extension WindowEventTests {
/// The sidebar's rows carry the session drag in both views, and a click still selects and a double click still opens a tab.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionDragSourceTests {
    private func fixture(mode: CatalogViewMode = .activity) async throws -> (CatalogModel, URL, [UUID]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-drag-\(UUID())")
        let folder = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let inProject = ManagedSession(provider: .claude, workingDirectory: folder.path)
        let loose = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(inProject, title: "In project", lifecycle: .idle, projectID: project.id)
        try await catalog.insertSession(loose, title: "Loose", lifecycle: .idle)
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("p.json"))
        try preferences.update { $0.viewMode = mode }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(), preferences: preferences)
        model.branchReader = { _ in .unavailable }
        await model.start()
        await model.settle()
        return (model, root, [inProject.id, loose.id])
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// The row VoiceOver reads for `title`.
    private func row(_ title: String, in view: NSView) -> AnyObject? {
        accessibilityElements(in: view).first { ($0.accessibilityLabel?() ?? "").hasPrefix(title + ", ") }
    }

    private func click(_ element: AnyObject, in window: NSWindow, count: Int) throws {
        let frame = try #require(element.accessibilityFrame?())
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for click in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: click, pressure: 1))
                NSApp.sendEvent(event)
            }
        }
    }

    @Test func activityCardsAreDragSources() async throws {
        let (model, root, ids) = try await fixture(mode: .activity)
        defer { SessionDragProbe.stop(); model.stop(); try? FileManager.default.removeItem(at: root) }
        SessionDragProbe.watch()
        let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 320, height: 600), key: true)
        defer { window.orderOut(nil) }
        #expect(await waitUntil { hosting.view.layoutSubtreeIfNeeded(); return SessionDragProbe.sources.isSuperset(of: ids) },
                "both cards carry the drag in the activity view")
    }

    @Test func projectRowsAreDragSourcesAndKeepTheirClickDoubleClickAndAccessibility() async throws {
        enableAccessibilityTree()
        let (model, root, ids) = try await fixture(mode: .projects)
        defer { SessionDragProbe.stop(); model.stop(); try? FileManager.default.removeItem(at: root) }
        SessionDragProbe.watch()
        let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 320, height: 600), key: true)
        defer { window.orderOut(nil) }
        func drawn() -> [String] { ["In project", "Loose"].filter { row($0, in: hosting.view) != nil } }
        #expect(await waitUntil { hosting.view.layoutSubtreeIfNeeded(); return SessionDragProbe.sources.isSuperset(of: ids) },
                "both rows carry the drag in the project view: \(SessionDragProbe.sources.count) of 2, rows drawn: \(drawn())")

        // Still one button each for VoiceOver, with its press selecting the session.
        let loose = try #require(row("Loose", in: hosting.view))
        #expect(loose.accessibilityRole?() == .button)
        #expect(loose.accessibilityPerformPress?() == true)
        #expect(await waitUntil { model.selectedSessionID == ids[1] })
        #expect(!model.tabs.isPinned(ids[1]), "a press selects; it pins nothing")

        // A click selects; a double click opens the session in a tab.
        let inProject = try #require(row("In project", in: hosting.view))
        try click(inProject, in: window, count: 1)
        #expect(await waitUntil { model.selectedSessionID == ids[0] }, "a click selects")
        #expect(!model.tabs.isPinned(ids[0]))
        try click(inProject, in: window, count: 2)
        #expect(await waitUntil { model.tabs.isPinned(ids[0]) }, "a double click opens a tab")
    }
}
}
