import AppKit
import Foundation
import LoomCore
import SwiftUI
import LoomTerminal
import Testing
@testable import LoomCatalogUI

/// V01/V02: the Glass | Solid and launch-view preferences, the per-session inspector, and the detail route.
/// Files live in temporary folders that each test removes.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ShellSeamsTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-seams-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func model(at root: URL, startupError: String? = nil) -> CatalogModel {
        CatalogModel(catalog: nil, startupError: startupError, events: SessionEventHub(),
                     preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
    }

    private func stored(_ root: URL) throws -> UIPreferences {
        try JSONDecoder().decode(UIPreferences.self, from: Data(contentsOf: root.appendingPathComponent("ui-preferences.json")))
    }

    // MARK: Glass | Solid

    @Test func theSidebarStylePersistsAndAppliesLive() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        #expect(model.sidebarStyle == .glass)

        // The sidebar's background reads the style itself (`SidebarBackground(style:)`); there is no bridge
        // through Reduce Transparency any more.
        model.setSidebarStyle(.solid)
        #expect(model.sidebarStyle == .solid)
        #expect(try stored(root).sidebarStyle == .solid)
        #expect(model.preferencesSnapshot.projectColors, "nothing else changed")

        model.setSidebarStyle(.glass)
        #expect(model.sidebarStyle == .glass)
        #expect(try stored(root).sidebarStyle == .glass)

        // A new window reads what was saved.
        model.setSidebarStyle(.solid)
        let again = self.model(at: root)
        #expect(again.sidebarStyle == .solid)
    }

    @Test func theBackgroundDrawsTheStyleTheModelHoldsAndReduceTransparencyForcesSolid() {
        // The tint the sidebar draws for each pair of (style, system Reduce Transparency).
        func tint(_ style: SidebarStyle, _ reduce: Bool) -> Double {
            LoomTheme.Surface.sidebarTintOpacity(for: SidebarBackground.effectiveStyle(style, reduceTransparency: reduce))
        }
        #expect(tint(.glass, false) == LoomTheme.Surface.sidebarTintOpacity)
        #expect(tint(.solid, false) == 1)
        #expect(tint(.glass, true) == 1 && tint(.solid, true) == 1)
    }

    @Test func preferencesRoundTripAndAnOldOrOddFileReadsAsTheDefaults() throws {
        let preferences = UIPreferences(sidebarStyle: .solid, launchView: .home)
        let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(again.sidebarStyle == .solid && again.launchView == .home && again == preferences)

        let old = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(old.sidebarStyle == .glass && old.launchView == .lastSession && old.inspectorOpen.isEmpty)
        let odd = try JSONDecoder().decode(
            UIPreferences.self, from: Data(#"{"sidebarStyle": "frosted", "launchView": 3, "inspectorOpen": ["x", 4]}"#.utf8))
        #expect(odd.sidebarStyle == .glass && odd.launchView == .lastSession && odd.inspectorOpen.isEmpty)
    }

    // MARK: Launch view

    @Test func aLastSessionLaunchRestoresTheSelectionAndAHomeLaunchDoesNot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ui-preferences.json")
        let id = UUID()
        let store = UIPreferencesStore(url: url)
        try store.update { $0.selectedSessionID = id }

        #expect(model(at: root).launchView == .lastSession)
        #expect(model(at: root).selectedSessionID == id)

        try store.update { $0.launchView = .home }
        let home = model(at: root)
        #expect(home.launchView == .home && home.selectedSessionID == nil && home.selectedRow == nil)
        // The saved selection is kept in the file for the next last-session launch.
        #expect(try stored(root).selectedSessionID == id)

        try store.update { $0.launchView = .lastSession }
        #expect(model(at: root).selectedSessionID == id)
    }

    // MARK: Inspector

    @Test func theInspectorIsClosedByDefaultAndRememberedPerSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        let a = UUID(), b = UUID()
        #expect(!model.inspector.isOpen(for: a) && !model.inspector.isOpen(for: nil))

        model.setInspectorOpen(true, for: a)
        #expect(model.inspector.isOpen(for: a) && !model.inspector.isOpen(for: b))
        model.setInspectorOpen(true, for: a)
        #expect(try stored(root).inspectorOpen == [a], "opening twice stores it once")

        let again = self.model(at: root)
        #expect(again.inspector.isOpen(for: a) && !again.inspector.isOpen(for: b))
        again.setInspectorOpen(false, for: a)
        #expect(try stored(root).inspectorOpen.isEmpty)
    }

    @Test func theInspectorMemoryIsCapped() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        let ids = (0..<(UIPreferences.maxInspectorSessions + 5)).map { _ in UUID() }
        for id in ids { model.setInspectorOpen(true, for: id) }
        #expect(model.inspector.openSessions == Array(ids.suffix(UIPreferences.maxInspectorSessions)))
        #expect(!model.inspector.isOpen(for: ids[0]) && model.inspector.isOpen(for: ids.last))
    }

    // MARK: Detail route

    @MainActor
    final class RouteIntents: ConversationIntents {
        var terminal: NSView?
        var screen: TerminalScreenSnapshot?
        func start(provider: ManagedSession.Provider, projectID: UUID?) {}
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { terminal }
        func endedScreen(sessionID: UUID) -> TerminalScreenSnapshot? { screen }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    @Test func theRoutePicksTheEmptyAndErrorCases() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = model(at: root, startupError: "damaged")
        #expect(failed.detailRoute == .startupError("damaged"))
        failed.showDevTerminal(DevTerminal(panel: NSView()))
        #expect(failed.detailRoute == .startupError("damaged"), "an error outranks the development terminal")

        let empty = model(at: root)
        #expect(empty.detailRoute == .noSelection, "before the first page is read")
        await empty.start()
        #expect(empty.detailRoute == .addProject)
        empty.showDevTerminal(DevTerminal(panel: NSView()))
        #expect(empty.detailRoute == .devTerminal)
        empty.stop()
        failed.stop()
    }

    @Test func theRoutePicksTheSessionCasesInOrder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .claude, providerConversationID: "conv", workingDirectory: root.path)
        try await catalog.insertSession(
            session, title: "One", createdAt: Date(timeIntervalSince1970: 1_000),
            lastUsedAt: Date(timeIntervalSince1970: 10_000), lifecycle: .idle)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        let intents = RouteIntents()
        model.intents = intents
        defer { model.stop() }
        await model.start()
        #expect(model.detailRoute == .noSelection, "sessions exist, none selected")

        model.select(session.id)
        #expect(await waitUntil { model.selectedRow != nil })
        #expect(model.detailRoute == .record(sessionID: session.id))

        let surface = TerminalSurface()
        surface.view.feed(text: "last screen")
        intents.screen = try #require(surface.captureVisibleScreen())
        #expect(model.detailRoute == .endedScreen(sessionID: session.id))

        intents.terminal = NSView()
        #expect(model.detailRoute == .terminal(sessionID: session.id), "a live terminal outranks a kept screen")

        let run = UUID()
        let record = SubagentRecord(id: "a1", agentType: "implementer", description: "map",
                                    startedAt: Date(timeIntervalSince1970: 1_000_000))
        await hub.publish(sessionID: session.id, change: .runStarted(run))
        await hub.publish(sessionID: session.id, change: .subagents([record]))
        #expect(await waitUntil { model.liveStates[session.id]?.subagents == [record] })
        model.openSubagent("a1", in: session.id)
        #expect(model.detailRoute == .terminal(sessionID: session.id), "the terminal stays on screen")
        #expect(model.viewedSubagent?.agentID == "a1")
        model.closeSubagent()
        #expect(model.detailRoute == .terminal(sessionID: session.id))

        model.showDevTerminal(DevTerminal(panel: NSView()))
        #expect(model.detailRoute == .devTerminal)
    }

    @Test func everyRouteIsDrawnOnThePanelColourToday() {
        for route in [DetailRoute.startupError("x"), .devTerminal,
                      .terminal(sessionID: UUID()), .endedScreen(sessionID: UUID()), .record(sessionID: UUID()),
                      .addProject, .noSelection, .chat(sessionID: UUID()), .home, .draft(projectID: nil),
                      .projectPage(projectID: UUID())] {
            #expect(route.surface == LoomTheme.Surface.panel)
        }
    }

    // MARK: Inspector container

    /// The colour of the detail panel at a point a little inside its right edge, drawn offscreen.
    private func rightEdgeColor(of model: CatalogModel) throws -> NSColor {
        let host = NSHostingView(rootView: DetailView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.colorAt(x: bitmap.pixelsWide - 60, y: bitmap.pixelsHigh / 2)).usingColorSpace(.sRGB) ?? .clear
    }

    @Test func theInspectorColumnAppearsOnlyForASessionWhoseInspectorIsOpen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .claude, providerConversationID: "conv", workingDirectory: root.path)
        try await catalog.insertSession(
            session, title: "One", createdAt: Date(timeIntervalSince1970: 1_000),
            lastUsedAt: Date(timeIntervalSince1970: 10_000), lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        defer { model.stop() }
        await model.start()
        model.select(session.id)
        #expect(await waitUntil { model.selectedRow != nil })

        // An offscreen draw is colour-managed, so compare the two draws with each other: the inspector
        // surface is darker than the panel by the same ratio as the tokens.
        func red(_ color: NSColor) -> Double { Double(color.redComponent) }
        let closed = try rightEdgeColor(of: model)
        model.setInspectorOpen(true, for: session.id)
        let open = try rightEdgeColor(of: model)
        let expected = LoomTheme.Surface.inspectorRGB.red / LoomTheme.Surface.terminalRGB.red
        #expect(abs(red(open) / red(closed) - expected) < 0.05, "closed \(closed), open \(open)")
    }
}
