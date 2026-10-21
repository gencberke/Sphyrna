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
        #expect(model.sidebarStyle == .solid, "Solid is the default (D-81)")

        // The sidebar's background reads the style itself (`SidebarBackground(style:)`); there is no bridge
        // through Reduce Transparency any more.
        model.setSidebarStyle(.glass)
        #expect(model.sidebarStyle == .glass)
        #expect(try stored(root).sidebarStyle == .glass)
        #expect(model.preferencesSnapshot.projectColors, "nothing else changed")

        model.setSidebarStyle(.solid)
        #expect(model.sidebarStyle == .solid)
        #expect(try stored(root).sidebarStyle == .solid)

        // A new window reads what was saved.
        model.setSidebarStyle(.glass)
        let again = self.model(at: root)
        #expect(again.sidebarStyle == .glass)
    }

    /// DESIGN §2 item 2 (D-81): the sidebar is Solid for a fresh or missing preference, and a stored choice is kept. A user who
    /// chose Glass keeps Glass; nobody is moved by the new default.
    @Test func aFreshOrMissingSidebarPreferenceIsSolidAndAStoredChoiceIsKept() throws {
        #expect(UIPreferences().sidebarStyle == .solid)
        #expect(try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8)).sidebarStyle == .solid)
        #expect(try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"sidebarStyle": "frosted"}"#.utf8)).sidebarStyle == .solid)
        #expect(SidebarBackground(reduceTransparency: false).style == .solid, "a bare background draws Solid")

        let fresh = try temporaryRoot()
        let stored = try temporaryRoot()
        defer { for root in [fresh, stored] { try? FileManager.default.removeItem(at: root) } }
        #expect(model(at: fresh).sidebarStyle == .solid, "no file at all")
        try Data(#"{"sidebarStyle": "glass"}"#.utf8).write(to: stored.appendingPathComponent("ui-preferences.json"))
        #expect(model(at: stored).sidebarStyle == .glass, "a stored Glass stays Glass")
        try Data(#"{"sidebarStyle": "solid"}"#.utf8).write(to: stored.appendingPathComponent("ui-preferences.json"))
        #expect(model(at: stored).sidebarStyle == .solid)
    }

    @Test func theBackgroundDrawsTheStyleTheModelHoldsAndReduceTransparencyForcesSolid() {
        // The tint the sidebar draws for each pair of (style, system Reduce Transparency).
        func tint(_ style: SidebarStyle, _ reduce: Bool) -> Double {
            LoomTheme.Surface.sidebarTintOpacity(for: SidebarBackground.effectiveStyle(style, reduceTransparency: reduce))
        }
        #expect(tint(.glass, false) == LoomTheme.Surface.sidebarTintOpacity && LoomTheme.Surface.sidebarTintOpacity == 0.8,
                "Glass is the canvas at 0.8 over the material")
        #expect(tint(.solid, false) == 1)
        #expect(tint(.glass, true) == 1 && tint(.solid, true) == 1)
    }

    @Test func preferencesRoundTripAndAnOldOrOddFileReadsAsTheDefaults() throws {
        let preferences = UIPreferences(sidebarStyle: .solid, launchView: .home)
        let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(again.sidebarStyle == .solid && again.launchView == .home && again == preferences)

        let old = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(old.sidebarStyle == .solid && old.launchView == .lastSession && old.inspectorOpen.isEmpty)
        let odd = try JSONDecoder().decode(
            UIPreferences.self, from: Data(#"{"sidebarStyle": "frosted", "launchView": 3, "inspectorOpen": ["x", 4]}"#.utf8))
        #expect(odd.sidebarStyle == .solid && odd.launchView == .lastSession && odd.inspectorOpen.isEmpty)
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
        #expect(empty.detailRoute == .home, "an empty catalog opens on Home, which carries the first-run states")
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
        #expect(model.detailRoute == .chat(sessionID: session.id), "a stopped Claude session opens as Chat")
        // The routes below are the Terminal face's: what a Claude session showed in 0.4.4, and still shows when the
        // read-only Chat is switched off.
        model.readOnlyChatEnabled = false
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

    @Test func everyRouteIsDrawnOnTheCanvasToday() {
        for route in [DetailRoute.startupError("x"), .devTerminal,
                      .terminal(sessionID: UUID()), .endedScreen(sessionID: UUID()), .record(sessionID: UUID()),
                      .noSelection, .chat(sessionID: UUID()), .home, .draft(projectID: nil),
                      .projectPage(projectID: UUID())] {
            #expect(route.surface == LoomTheme.Surface.panel)
        }
    }

    // MARK: Inspector container

    /// The brightest red along the inspector column's leading edge (the column is 328 pt wide, flush with the window's trailing edge), low in the
    /// pane where no content is drawn, drawn offscreen. The inspector is the canvas like the pane, so an open column shows as
    /// its leading hairline, brighter than the flat canvas.
    private func inspectorEdgeBrightness(of model: CatalogModel) throws -> Double {
        let host = NSHostingView(rootView: DetailView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)   // the tokens compared below are the Dark ones
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / 1000
        let edge = bitmap.pixelsWide - Int((LoomTheme.Rhythm.inspectorWidth * scale).rounded())
        let rows = Int(Double(bitmap.pixelsHigh) * 0.8)..<Int(Double(bitmap.pixelsHigh) * 0.95)
        return rows.flatMap { y in (edge - 3...edge + 3).compactMap { x in
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent
        } }.map(Double.init).max() ?? 0
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

        // An offscreen draw is colour-managed, so compare the two draws with each other.
        let closed = try inspectorEdgeBrightness(of: model)
        model.setInspectorOpen(true, for: session.id)
        let open = try inspectorEdgeBrightness(of: model)
        #expect(open - closed > 0.03, "the hairline of the column; closed \(closed), open \(open)")
    }
}
