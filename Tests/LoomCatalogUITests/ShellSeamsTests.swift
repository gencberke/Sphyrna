import AppKit
import Foundation
import LoomCore
import SwiftUI
import LoomTerminal
import Testing
@testable import LoomCatalogUI

/// V01/V02: the sidebar's fill and opacity (FB6-6), the launch-view preferences, the per-session inspector, and the detail
/// route. Files live in temporary folders that each test removes.
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

    // MARK: Settings → Theme → Sidebar (FB6-6, D-57)

    /// The segments' order and words, and what a 1.6.x or 1.7.0 `sidebarStyle` word reads as: `solid` is Canvas at Solid,
    /// `transparent` and `glass` are Canvas at 80 %, and a missing or unknown word is Solid (nobody is moved by the new pair).
    @Test func theSidebarSegmentsReadTheirStepsAndAnOldStyleReadsAsThePairItHad() {
        #expect(SidebarFill.allCases.map(\.rawValue) == ["canvas", "raised", "deep"])
        #expect(SidebarFill.allCases.map(\.title) == ["Canvas", "Raised", "Deep"])
        #expect(SidebarOpacity.allCases.map(\.rawValue) == ["solid", "90", "80", "65"])
        #expect(SidebarOpacity.allCases.map(\.title) == ["Solid", "90 %", "80 %", "65 %"])
        #expect(SidebarAppearance.legacy("solid") == .standard)
        #expect(SidebarAppearance.legacy("transparent") == SidebarAppearance(fill: .canvas, opacity: .eighty))
        #expect(SidebarAppearance.legacy("glass") == SidebarAppearance(fill: .canvas, opacity: .eighty))
        #expect(SidebarAppearance.legacy(nil) == .standard && SidebarAppearance.legacy("frosted") == .standard)
        // The one word the evidence scripts read: `solid` for the opaque step, `transparent` for any see-through step.
        #expect(SidebarAppearance.standard.legacyStyle == "solid")
        #expect(SidebarAppearance(fill: .deep, opacity: .eighty).legacyStyle == "transparent")
        #expect(SidebarAppearance(opacity: .sixtyFive).legacyStyle == "transparent")
    }

    @Test func theSidebarFillAndOpacityPersistAndApplyLive() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        #expect(model.sidebarAppearance == .standard, "the canvas, opaque (D-81)")

        model.setSidebarFill(.raised)
        model.setSidebarOpacity(.sixtyFive)
        #expect(model.sidebarAppearance == SidebarAppearance(fill: .raised, opacity: .sixtyFive))
        let kept = try stored(root)
        #expect(kept.sidebarFill == .raised && kept.sidebarOpacity == .sixtyFive)
        #expect(model.preferencesSnapshot.projectColors, "nothing else changed")

        model.setSidebarFill(.canvas)
        model.setSidebarOpacity(.solid)
        #expect(model.sidebarAppearance == .standard)
        let written = String(decoding: try Data(contentsOf: root.appendingPathComponent("ui-preferences.json")), as: UTF8.self)
        #expect(written.contains("\"sidebarFill\"") && written.contains("\"sidebarOpacity\""))
        #expect(!written.contains("\"sidebarStyle\""), "a file written now carries the pair, not the old word")

        // A new window reads what was saved.
        model.setSidebarOpacity(.eighty)
        let again = self.model(at: root)
        #expect(again.sidebarAppearance == SidebarAppearance(fill: .canvas, opacity: .eighty))
    }

    /// DESIGN §2 item 2 (FB6-6, D-81): the sidebar is Canvas at Solid for a fresh or missing preference, and a stored choice
    /// is kept. A user who chose Glass or Transparent keeps the look they had, as Canvas at 80 %; the two newer keys win.
    @Test func aFreshOrMissingSidebarPreferenceIsCanvasAtSolidAndAStoredChoiceIsKept() throws {
        #expect(UIPreferences().sidebarFill == .canvas && UIPreferences().sidebarOpacity == .solid)
        let freshPreferences = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(freshPreferences.sidebarFill == .canvas && freshPreferences.sidebarOpacity == .solid)
        let oddPreferences = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"sidebarStyle": "frosted"}"#.utf8))
        #expect(oddPreferences.sidebarFill == .canvas && oddPreferences.sidebarOpacity == .solid)

        let stored = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: stored) }
        #expect(model(at: stored).sidebarAppearance == .standard, "no file at all")
        try Data(#"{"sidebarStyle": "glass"}"#.utf8).write(to: stored.appendingPathComponent("ui-preferences.json"))
        #expect(model(at: stored).sidebarAppearance == SidebarAppearance(opacity: .eighty),
                "a stored Glass reads as Canvas at 80 %")
        try Data(#"{"sidebarStyle": "transparent"}"#.utf8).write(to: stored.appendingPathComponent("ui-preferences.json"))
        #expect(model(at: stored).sidebarAppearance == SidebarAppearance(opacity: .eighty))
        try Data(#"{"sidebarStyle": "solid"}"#.utf8).write(to: stored.appendingPathComponent("ui-preferences.json"))
        #expect(model(at: stored).sidebarAppearance == .standard)
        try Data(#"{"sidebarStyle": "transparent", "sidebarFill": "deep", "sidebarOpacity": "65"}"#.utf8)
            .write(to: stored.appendingPathComponent("ui-preferences.json"))
        #expect(model(at: stored).sidebarAppearance == SidebarAppearance(fill: .deep, opacity: .sixtyFive))
    }

    @Test func theBackgroundDrawsTheFillAtItsStepAndReduceTransparencyForcesSolid() {
        typealias Background = SidebarBackground
        #expect(Background.effectiveOpacity(.standard, reduceTransparency: false) == 1)
        #expect(Background.effectiveOpacity(SidebarAppearance(opacity: .ninety), reduceTransparency: false) == 0.9)
        #expect(Background.effectiveOpacity(SidebarAppearance(opacity: .eighty), reduceTransparency: false)
                == LoomTheme.Surface.sidebarTintOpacity && LoomTheme.Surface.sidebarTintOpacity == 0.8,
                "80 % is the step 1.7.0 called Transparent")
        #expect(Background.effectiveOpacity(SidebarAppearance(opacity: .sixtyFive), reduceTransparency: false)
                == LoomTheme.Surface.sidebarTintSixtyFive && LoomTheme.Surface.sidebarTintSixtyFive == 0.65)
        for fill in SidebarFill.allCases {
            // The fill changes what the step is drawn with, never the step.
            #expect(Background.effectiveOpacity(SidebarAppearance(fill: fill, opacity: .eighty), reduceTransparency: false) == 0.8)
            for opacity in SidebarOpacity.allCases {
                #expect(Background.effectiveOpacity(SidebarAppearance(fill: fill, opacity: opacity), reduceTransparency: true) == 1)
            }
        }
    }

    @Test func preferencesRoundTripAndAnOldOrOddFileReadsAsTheDefaults() throws {
        let preferences = UIPreferences(sidebarFill: .raised, sidebarOpacity: .sixtyFive, launchView: .home)
        let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(again.sidebarFill == .raised && again.sidebarOpacity == .sixtyFive && again.launchView == .home
                && again == preferences)

        let old = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(old.sidebarFill == .canvas && old.sidebarOpacity == .solid && old.launchView == .lastSession
                && old.inspectorOpen.isEmpty)
        let odd = try JSONDecoder().decode(
            UIPreferences.self,
            from: Data(#"{"sidebarStyle": "frosted", "sidebarFill": "sepia", "sidebarOpacity": 3, "launchView": 3, "inspectorOpen": ["x", 4]}"#.utf8))
        #expect(odd.sidebarFill == .canvas && odd.sidebarOpacity == .solid && odd.launchView == .lastSession
                && odd.inspectorOpen.isEmpty)
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

        model.readOnlyChatEnabled = true // the frozen Chat face's read-only chat (D-100)
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
