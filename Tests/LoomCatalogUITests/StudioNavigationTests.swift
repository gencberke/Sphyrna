import AppKit
import Foundation
import LoomCore
import LoomTerminal
import Testing
@testable import LoomCatalogUI

/// V02b: the destination, the detail route for each destination with the read-only Chat flag off and on, the
/// destination's persistence (including a file 0.4.4 wrote), and the Studio menu commands. Files live in
/// temporary folders that each test removes.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct StudioNavigationTests {
    /// Per-session terminals and kept screens, and the starts the menu asked for.
    @MainActor
    final class FaceIntents: ConversationIntents {
        var terminals: [UUID: NSView] = [:]
        var screens: [UUID: TerminalScreenSnapshot] = [:]
        var starts: [(provider: ManagedSession.Provider, projectID: UUID?)] = []
        func start(provider: ManagedSession.Provider, projectID: UUID?) { starts.append((provider, projectID)) }
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { terminals[sessionID] }
        func endedScreen(sessionID: UUID) -> TerminalScreenSnapshot? { screens[sessionID] }
    }

    /// A catalog with one project and three sessions: two Claude, one Codex.
    private struct Rig {
        let root: URL
        let hub: SessionEventHub
        let intents: FaceIntents
        let model: CatalogModel
        let projectID: UUID
        let claude: UUID
        let otherClaude: UUID
        let codex: UUID
        var preferencesURL: URL { root.appendingPathComponent("ui-preferences.json") }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-studio-nav-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func rig(root: URL, launchView: LaunchView? = nil, started: Bool = true) async throws -> Rig {
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projectID = try await catalog.addProject(path: folder.path).project.id
        func insert(_ provider: ManagedSession.Provider, _ title: String, _ used: Double) async throws -> UUID {
            let session = ManagedSession(provider: provider, providerConversationID: title, workingDirectory: folder.path)
            try await catalog.insertSession(
                session, title: title, createdAt: Date(timeIntervalSince1970: 1_000),
                lastUsedAt: Date(timeIntervalSince1970: used), lifecycle: .idle, projectID: projectID)
            return session.id
        }
        let claude = try await insert(.claude, "claude", 10_000)
        let otherClaude = try await insert(.claude, "other", 9_000)
        let codex = try await insert(.codex, "codex", 8_000)
        let store = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        if let launchView { try store.update { $0.launchView = launchView } }
        let hub = SessionEventHub()
        let intents = FaceIntents()
        let model = CatalogModel(catalog: catalog, events: hub, preferences: store)
        model.intents = intents
        if started { await model.start() }
        return Rig(root: root, hub: hub, intents: intents, model: model, projectID: projectID,
                   claude: claude, otherClaude: otherClaude, codex: codex)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    private func select(_ id: UUID, in model: CatalogModel) async {
        model.select(id)
        #expect(await waitUntil { model.selectedRow?.id == id })
    }

    private func keptScreen() throws -> TerminalScreenSnapshot {
        let surface = TerminalSurface()
        surface.view.feed(text: "last screen")
        return try #require(surface.captureVisibleScreen())
    }

    // MARK: Destinations and their routes

    @Test func everyDestinationHasItsRouteAndOnlySessionRoutesShowTheSessionHeader() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        #expect(model.destination == nil && model.detailRoute == .noSelection)

        model.showHome()
        #expect(model.destination == .home && model.detailRoute == .home)
        #expect(model.selectedSessionID == nil && model.selectedRow == nil)
        #expect(!model.detailRoute.showsSessionHeader)

        model.showDraft(projectID: rig.projectID)
        #expect(model.detailRoute == .draft(projectID: rig.projectID) && !model.detailRoute.showsSessionHeader)
        model.showDraft(projectID: nil)
        #expect(model.detailRoute == .draft(projectID: nil))

        model.showProjectPage(rig.projectID)
        #expect(model.detailRoute == .projectPage(projectID: rig.projectID) && !model.detailRoute.showsSessionHeader)

        await select(rig.claude, in: model)
        #expect(model.destination == .session(rig.claude) && model.selectedSessionID == rig.claude)
        #expect(model.detailRoute == .record(sessionID: rig.claude) && model.detailRoute.showsSessionHeader)

        // Leaving a session for another place deselects its row, and the context project follows the place.
        model.showHome()
        #expect(model.selectedRow == nil && model.selectedSessionID == nil)
        #expect(model.contextProjectID == nil)
        model.showProjectPage(rig.projectID)
        #expect(model.contextProjectID == rig.projectID)
        model.select(nil)
        #expect(model.destination == nil && model.detailRoute == .noSelection)
    }

    @Test func aDestinationOutranksTheDevelopmentTerminalOnlyByClearingIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        defer { rig.model.stop() }
        rig.model.showDevTerminal(DevTerminal(panel: NSView()))
        #expect(rig.model.detailRoute == .devTerminal)
        rig.model.showHome()
        #expect(rig.model.detailRoute == .home, "navigating leaves the development terminal")
    }

    // MARK: The session face rule

    @Test func withTheFlagOffNoRouteIsTheChatWhateverWasPicked() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        #expect(!model.readOnlyChatEnabled, "off by default")
        await select(rig.claude, in: model)
        #expect(model.detailRoute == .record(sessionID: rig.claude))

        model.showFace(.chat)
        #expect(model.faces.choice(for: rig.claude) == nil, "nothing to choose between yet")
        model.faces.choose(.chat, for: rig.claude)
        #expect(model.detailRoute == .record(sessionID: rig.claude))
        rig.intents.screens[rig.claude] = try keptScreen()
        #expect(model.detailRoute == .endedScreen(sessionID: rig.claude))
        rig.intents.terminals[rig.claude] = NSView()
        #expect(model.detailRoute == .terminal(sessionID: rig.claude))
    }

    @Test func withTheFlagOnAStoppedClaudeSessionRoutesToTheChat() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.readOnlyChatEnabled = true

        await select(rig.claude, in: model)
        #expect(model.detailRoute == .chat(sessionID: rig.claude) && model.detailRoute.showsSessionHeader)
        // The kept screen is V13's fallback, not a route of its own.
        rig.intents.screens[rig.claude] = try keptScreen()
        #expect(model.detailRoute == .chat(sessionID: rig.claude))

        // Codex keeps today's routes.
        await select(rig.codex, in: model)
        #expect(model.detailRoute == .record(sessionID: rig.codex))
        rig.intents.screens[rig.codex] = try keptScreen()
        #expect(model.detailRoute == .endedScreen(sessionID: rig.codex))
        rig.intents.terminals[rig.codex] = NSView()
        #expect(model.detailRoute == .terminal(sessionID: rig.codex))
        model.showFace(.chat)
        #expect(model.detailRoute == .terminal(sessionID: rig.codex), "Codex has no face to choose")
        #expect(!ShellCommand.showChat.isEnabled(on: model))
    }

    @Test func aStartUnderWayIsNotStopped() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.readOnlyChatEnabled = true
        await select(rig.claude, in: model)
        model.setBusy(rig.claude, .resuming)
        #expect(model.detailRoute == .record(sessionID: rig.claude), "no flash of the chat before the terminal arrives")
        rig.intents.terminals[rig.claude] = NSView()
        model.setBusy(rig.claude, nil)
        #expect(model.detailRoute == .terminal(sessionID: rig.claude))
    }

    @Test func aRunningTerminalSessionShowsTheTerminalUnlessChatWasPickedForThatSession() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.readOnlyChatEnabled = true
        rig.intents.terminals[rig.claude] = NSView()
        rig.intents.terminals[rig.otherClaude] = NSView()

        await select(rig.claude, in: model)
        #expect(model.detailRoute == .terminal(sessionID: rig.claude), "the default for a running session")
        model.showFace(.chat)
        #expect(model.detailRoute == .chat(sessionID: rig.claude))

        // The choice belongs to the session and stays in memory while another one is shown.
        await select(rig.otherClaude, in: model)
        #expect(model.detailRoute == .terminal(sessionID: rig.otherClaude))
        await select(rig.claude, in: model)
        #expect(model.detailRoute == .chat(sessionID: rig.claude))

        model.showFace(.terminal)
        #expect(model.detailRoute == .terminal(sessionID: rig.claude))
    }

    @Test func theTerminalFaceOfAStoppedSessionIsItsKeptScreenOrRecord() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.readOnlyChatEnabled = true
        await select(rig.claude, in: model)
        #expect(model.detailRoute == .chat(sessionID: rig.claude))
        model.showFace(.terminal)
        #expect(model.detailRoute == .record(sessionID: rig.claude))
        rig.intents.screens[rig.claude] = try keptScreen()
        #expect(model.detailRoute == .endedScreen(sessionID: rig.claude))
        model.showFace(.chat)
        #expect(model.detailRoute == .chat(sessionID: rig.claude))
    }

    @Test func aSubagentTranscriptStillOutranksTheChat() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.readOnlyChatEnabled = true
        rig.intents.terminals[rig.claude] = NSView()
        await select(rig.claude, in: model)
        model.showFace(.chat)

        let record = SubagentRecord(id: "a1", agentType: "implementer", description: "map",
                                    startedAt: Date(timeIntervalSince1970: 1_000_000))
        await rig.hub.publish(sessionID: rig.claude, change: .runStarted(UUID()))
        await rig.hub.publish(sessionID: rig.claude, change: .subagents([record]))
        #expect(await waitUntil { model.liveStates[rig.claude]?.subagents == [record] })
        model.openSubagent("a1", in: rig.claude)
        #expect(model.detailRoute == .chat(sessionID: rig.claude), "a subagent's transcript no longer replaces the face")
        #expect(model.viewedSubagent?.agentID == "a1" && model.inspector.isOpen(for: rig.claude))
        model.closeSubagent()
        #expect(model.detailRoute == .chat(sessionID: rig.claude), "the choice survived")
    }

    // MARK: Persistence

    private func fileText(_ rig: Rig) throws -> String {
        try String(contentsOf: rig.preferencesURL, encoding: .utf8)
    }

    @Test func eachDestinationIsWrittenAndRestoredOnALastSessionLaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await rig(root: root)
        let project = first.projectID
        let session = first.claude

        func relaunch() async throws -> Rig {
            first.model.flushPreferences()
            return try await rig(root: root)
        }

        first.model.showProjectPage(project)
        let page = try await relaunch()
        #expect(page.model.destination == .projectPage(project) && page.model.detailRoute == .projectPage(projectID: project))
        page.model.stop()

        first.model.showHome()
        let home = try await relaunch()
        #expect(home.model.destination == .home, "Home as the last place comes back as Home")
        home.model.stop()

        await select(session, in: first.model)
        let restored = try await relaunch()
        #expect(restored.model.destination == .session(session) && restored.model.selectedSessionID == session)
        #expect(restored.model.selectedRow?.id == session)
        restored.model.stop()
        #expect(try fileText(first).contains("\"selectedSessionID\""), "an older build still reads the session")

        // A draft is not kept: the file holds the last place that can be restored.
        first.model.showDraft(projectID: project)
        let draft = try await relaunch()
        #expect(draft.model.destination == .session(session))
        draft.model.stop()

        first.model.select(nil)
        let none = try await relaunch()
        #expect(none.model.destination == nil && none.model.detailRoute == .noSelection)
        none.model.stop()
        first.model.stop()
    }

    @Test func aRestoredProjectPageWhoseProjectIsGoneShowsNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig0 = try await rig(root: root)
        rig0.model.stop()
        let store = UIPreferencesStore(url: rig0.preferencesURL)
        try store.update { $0.destination = .projectPage(UUID()) }
        let reopened = try await rig(root: root)
        defer { reopened.model.stop() }
        #expect(reopened.model.destination == nil && reopened.model.detailRoute == .noSelection)
    }

    @Test func removingAProjectLeavesItsPageAndItsDraft() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let folder = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var empty = try #require(await model.addProject(path: folder.path)).project.id
        let other = rig.projectID

        model.showProjectPage(empty)
        await model.removeProject(empty)
        #expect(model.destination == nil && model.detailRoute == .noSelection && model.contextProjectID == nil)

        empty = try #require(await model.addProject(path: folder.path)).project.id
        model.showDraft(projectID: empty)
        await model.removeProject(empty)
        #expect(model.destination == nil)

        // Another project's page, or a project that cannot be removed, stays.
        model.showProjectPage(other)
        await model.removeProject(UUID())
        #expect(model.destination == .projectPage(other))
        await model.removeProject(other) // not empty: refused
        #expect(model.destination == .projectPage(other))
    }

    @Test func aHomeLaunchShowsHomeAndAStoredDestinationNeverOverridesIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try await rig(root: root)
        let project = seed.projectID, session = seed.claude
        seed.model.stop()

        for stored in [Destination.session(session), .projectPage(project)] {
            let store = UIPreferencesStore(url: seed.preferencesURL)
            try store.update { $0.destination = stored; $0.launchView = .home }
            let unstarted = try await rig(root: root, started: false)
            #expect(unstarted.model.destination == .home && unstarted.model.detailRoute == .home, "before the first page is read")
            await unstarted.model.start()
            #expect(unstarted.model.destination == .home && unstarted.model.selectedRow == nil)
            #expect(unstarted.model.detailRoute == .home)
            unstarted.model.stop()
            // The file still holds the place for the next last-session launch.
            #expect(UIPreferencesStore(url: seed.preferencesURL).current.destination == stored)
        }

        // Leaving Home by hand writes the new place, and the next Home launch still opens on Home.
        let store = UIPreferencesStore(url: seed.preferencesURL)
        try store.update { $0.destination = .session(session); $0.launchView = .lastSession }
        let launched = try await rig(root: root)
        #expect(launched.model.destination == .session(session))
        launched.model.showHome()
        launched.model.flushPreferences()
        #expect(UIPreferencesStore(url: seed.preferencesURL).current.destination == .home)
        launched.model.stop()
    }

    @Test func preferencesRoundTripTheDestinationAndReadOlderFiles() throws {
        let id = UUID()
        for destination in [Destination.home, .session(id), .draft(projectID: id), .draft(projectID: nil), .projectPage(id)] {
            let preferences = UIPreferences(destination: destination)
            let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(preferences))
            #expect(again.destination == destination && again == preferences)
        }
        #expect(UIPreferences(selectedSessionID: id).destination == .session(id))
        var preferences = UIPreferences()
        preferences.selectedSessionID = id
        #expect(preferences.destination == .session(id))
        preferences.destination = .home
        #expect(preferences.selectedSessionID == nil)

        // 0.4.4 and batch 1 knew only `selectedSessionID`; it reads as the session destination.
        let old = try JSONDecoder().decode(
            UIPreferences.self, from: Data(#"{"viewMode": "projects", "selectedSessionID": "\#(id)", "sidebarWidth": 340}"#.utf8))
        #expect(old.destination == .session(id) && old.selectedSessionID == id && old.viewMode == .projects)
        let batchOne = try JSONDecoder().decode(
            UIPreferences.self, from: Data(#"{"selectedSessionID": "\#(id)", "launchView": "home", "inspectorOpen": []}"#.utf8))
        #expect(batchOne.destination == .session(id) && batchOne.launchView == .home)
        #expect(try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8)).destination == nil)

        // The newer key wins; one that cannot be read falls back to the older key, or to nothing.
        let both = try JSONDecoder().decode(
            UIPreferences.self, from: Data(#"{"selectedSessionID": "\#(id)", "destination": {"kind": "home"}}"#.utf8))
        #expect(both.destination == .home)
        for odd in [#"{"kind": "wall"}"#, #"{"kind": "project"}"#, #"{"kind": "session", "id": "x"}"#, "7"] {
            let json = #"{"selectedSessionID": "\#(id)", "destination": \#(odd)}"#
            #expect(try JSONDecoder().decode(UIPreferences.self, from: Data(json.utf8)).destination == .session(id))
            let alone = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"destination": \#(odd)}"#.utf8))
            #expect(alone.destination == nil)
        }
    }

    @Test func aFileFrom044OpensOnItsSessionAndAHomeLaunchIgnoresIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try await rig(root: root)
        let session = seed.claude
        seed.model.stop()
        let json = """
        {"viewMode": "projects", "selectedSessionID": "\(session)", "sidebarWidth": 340, "sidebarCollapsed": false,
         "terminalFontSize": 15, "openTabs": ["\(session)"],
         "windowFrame": {"x": 100, "y": 80, "width": 1220, "height": 780},
         "projectColors": false, "showInMenuBar": true, "notifyApprovals": false}
        """
        try Data(json.utf8).write(to: seed.preferencesURL)
        let reopened = try await rig(root: root)
        #expect(reopened.model.destination == .session(session) && reopened.model.selectedRow?.id == session)
        reopened.model.stop()

        let store = UIPreferencesStore(url: seed.preferencesURL)
        try store.update { $0.launchView = .home }
        let home = try await rig(root: root)
        defer { home.model.stop() }
        #expect(home.model.detailRoute == .home)
        #expect(UIPreferencesStore(url: seed.preferencesURL).current.selectedSessionID == session)
    }

    // MARK: Menu commands

    /// The keys of the menus before this slice (UI-MAP → Keyboard shortcuts), as (key, modifiers).
    private let existingKeys: [(String, NSEvent.ModifierFlags)] = [
        (",", [.command]), ("h", [.command]), ("q", [.command]), ("o", [.command]), ("n", [.command]),
        ("n", [.command, .shift]), ("r", [.command]), (".", [.command]), ("\u{8}", [.command]), ("w", [.command, .option]),
        ("w", [.command]), ("c", [.command]), ("v", [.command]), ("a", [.command]), ("f", [.command]),
        ("s", [.control, .command]), ("1", [.command]), ("2", [.command]), ("m", [.command]),
        ("]", [.command, .shift]), ("[", [.command, .shift]), ("j", [.command]), ("j", [.command, .shift]),
    ]

    @Test func theStudioKeysAreTheSpecifiedOnesAndCollideWithNothing() {
        let table = ShellCommand.allCases.map { ($0, $0.title, $0.keyEquivalent, $0.modifiers) }
        #expect(table.map(\.1) == ["Home", "Command Palette…", "New Claude Session", "Show Chat", "Show Terminal", "Toggle Inspector"])
        #expect(ShellCommand.home.keyEquivalent == "h" && ShellCommand.home.modifiers == [.control, .command])
        #expect(ShellCommand.commandPalette.keyEquivalent == "k" && ShellCommand.commandPalette.modifiers == [.command])
        #expect(ShellCommand.newSession.keyEquivalent == "n" && ShellCommand.newSession.modifiers == [.command])
        #expect(ShellCommand.showChat.keyEquivalent == "c" && ShellCommand.showChat.modifiers == [.option, .command])
        #expect(ShellCommand.showTerminal.keyEquivalent == "t" && ShellCommand.showTerminal.modifiers == [.option, .command])
        #expect(ShellCommand.toggleInspector.keyEquivalent == "b" && ShellCommand.toggleInspector.modifiers == [.option, .command])

        // The raw values are the menu items' tags.
        #expect(ShellCommand.allCases.map(\.rawValue) == Array(0..<ShellCommand.allCases.count))
        // No two Studio items share a key, and none repeats a key of the old menus; ⌘N is the one old key
        // the new-session command takes over from "New Claude Session".
        for (index, entry) in table.enumerated() {
            for other in table[(index + 1)...] { #expect(entry.2 != other.2 || entry.3 != other.3, "\(entry.1) and \(other.1)") }
            if entry.0 == .newSession { continue }
            for (key, modifiers) in existingKeys { #expect(entry.2 != key || entry.3 != modifiers, "\(entry.1)") }
            // A letter that an older item takes with other modifiers would be fired ambiguously by AppKit
            // when one of the two differs only by Shift.
            for (key, modifiers) in existingKeys where key == entry.2 {
                #expect(modifiers.symmetricDifference(entry.3) != [.shift], "\(entry.1) differs from an old key by Shift only")
            }
        }
    }

    @Test func theMenuCommandsActThroughTheirHolders() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        func run(_ command: ShellCommand) { command.run(on: model) }
        func enabled(_ command: ShellCommand) -> Bool { command.isEnabled(on: model) }

        // Nothing selected: Home and the palette work, the rest wait for a session.
        #expect(enabled(.home) && enabled(.commandPalette) && enabled(.newSession))
        #expect(!enabled(.toggleInspector) && !enabled(.showChat) && !enabled(.showTerminal))

        run(.commandPalette)
        #expect(model.destination == nil, "the palette is a no-op until its slice")
        run(.home)
        #expect(model.destination == .home && model.detailRoute == .home)

        // New Session (V07): opens the draft of the place the user is on; nothing starts until its first send.
        run(.newSession)
        #expect(model.destination == .draft(projectID: nil) && model.detailRoute == .draft(projectID: nil))
        model.showProjectPage(rig.projectID)
        run(.newSession)
        #expect(model.destination == .draft(projectID: rig.projectID))
        await select(rig.claude, in: model)
        run(.newSession)
        #expect(model.destination == .draft(projectID: rig.projectID), "a session's context is its project")
        #expect(rig.intents.starts.isEmpty, "opening a draft starts no session")
        // The draft's own place is the draft of that project: ⌘N again reuses it.
        run(.newSession)
        #expect(model.destination == .draft(projectID: rig.projectID) && model.newSession.drafts.count == 2)
        await select(rig.claude, in: model)

        // The inspector toggles the selected session's inspector and remembers it.
        #expect(enabled(.toggleInspector) && !model.inspector.isOpen(for: rig.claude))
        run(.toggleInspector)
        #expect(model.inspector.isOpen(for: rig.claude))
        run(.toggleInspector)
        #expect(!model.inspector.isOpen(for: rig.claude))

        // The faces wait for the flag.
        #expect(!enabled(.showChat) && !enabled(.showTerminal))
        run(.showChat)
        #expect(model.faces.choice(for: rig.claude) == nil)
        model.readOnlyChatEnabled = true
        #expect(enabled(.showChat) && enabled(.showTerminal))
        run(.showTerminal)
        #expect(model.faces.choice(for: rig.claude) == .terminal)
        run(.showChat)
        #expect(model.faces.choice(for: rig.claude) == .chat)

        // Starting is refused like the buttons: no actions, no new session.
        model.intents = nil
        #expect(!enabled(.newSession))
    }

    @Test func toggleInspectorDoesNothingOutsideASession() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        defer { rig.model.stop() }
        rig.model.showHome()
        rig.model.toggleInspector()
        #expect(rig.model.inspector.openSessions.isEmpty)
    }
}
