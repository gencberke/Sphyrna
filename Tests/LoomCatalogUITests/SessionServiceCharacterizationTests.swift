import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// Characterization of the decisions the session-service refactor moves (SESSION-SERVICE.md, R0): the face of a start, a
// resume, a stopped session's view and an approved open request, and what each harness may do in the production identity
// (`startableProviders == [.claude]`, D-28, D-69 (5)) and the development one (`[.claude, .codex]`). They pass on the code
// as it was written before the refactor and must keep passing, unchanged, through R3 (the gates move to capabilities),
// R4 (the face decision moves to a policy) and R5 (the orchestration moves).

// MARK: The face table

/// The face is the run's endpoint (`pipe`: the Chat face, `terminal`: the terminal face), read from the event hub once the
/// run shows one. Real starts and resumes on the fake provider, the fewest that pin each cell.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(10)))
struct SessionServiceFaceTableTests {
    struct Fixture {
        let rig: LiveRig
        let model: CatalogModel
        let controller: ConversationController
        let projectID: UUID

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            await rig.finish()
        }
    }

    private func makeFixture() async throws -> Fixture {
        let rig = try await LiveRig.make()
        let folder = rig.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await rig.runtime.catalog.addProject(path: folder.path).project
        let model = CatalogModel(
            catalog: await rig.runtime.catalog, events: await rig.runtime.supervisor.events,
            preferences: UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: rig.runtime, model: model)
        await controller.begin()
        await model.start()
        model.installChatSessions(runtime: rig.runtime, dataRoot: rig.root)
        model.setClaudeConfigDirectory(rig.profile)
        return Fixture(rig: rig, model: model, controller: controller, projectID: project.id)
    }

    private func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func hub(_ fixture: Fixture, _ id: UUID) async -> SessionViewState? {
        await fixture.rig.runtime.supervisor.events.snapshot().sessions[id]
    }

    /// The endpoint of the run the session has now: waits for a run that shows one (`.runStarted` resets it and
    /// `.runEndpoint` sets it, two frames), so an earlier run's endpoint is never read for this one.
    private func liveEndpoint(_ fixture: Fixture, _ id: UUID) async -> RunEndpointKind? {
        var found: RunEndpointKind?
        _ = await waitUntil {
            let state = await hub(fixture, id)
            guard state?.runID != nil, let endpoint = state?.runEndpoint else { return false }
            found = endpoint
            return true
        }
        return found
    }

    /// A new Claude session as the draft's send asks for it, in the project.
    private func start(_ fixture: Fixture, text: String) async throws -> UUID {
        var started: UUID?
        var failed = false
        fixture.controller.startSession(projectID: fixture.projectID, launch: NewSessionLaunch(firstMessage: text), focus: .session) {
            switch $0 {
            case let .started(id): started = id
            case .failed: failed = true
            }
        }
        #expect(await waitUntil { started != nil || failed })
        return try #require(started)
    }

    private func stop(_ fixture: Fixture, _ id: UUID) async {
        fixture.model.stopConversation(id)
        let stopped = await waitUntil {
            await hub(fixture, id)?.runID == nil && fixture.model.busy[id] == nil
                && fixture.model.rowModels[id].map { !fixture.model.isRunning($0) } == true
        }
        #expect(stopped, "the session should have stopped")
    }

    private func resume(_ fixture: Fixture, _ id: UUID) async -> RunEndpointKind? {
        fixture.controller.resume(sessionID: id)
        return await liveEndpoint(fixture, id)
    }

    /// An agent's request to open a session, asked as `loom-hook open` does, approved in the model; returns the opened
    /// session's id.
    private func approvedOpening(_ fixture: Fixture, requester: UUID) async throws -> UUID {
        let run = try #require(await hub(fixture, requester)?.runID)
        let hooks = try #require(await fixture.rig.runtime.hookConfiguration)
        let control = try #require(hooks.controlSocketPath)
        let request = OpenSessionWireRequest(
            authenticationToken: hooks.authenticationToken, sessionID: requester, managedRunID: run,
            title: "Opened by an agent", project: nil, message: "Do the next thing.")
        let reply = Task.detached { try OpenSessionClient.exchange(request, socketPath: control) }
        #expect(await waitUntil { fixture.model.openRequests.count == 1 })
        let asked = try #require(fixture.model.openRequests.first)
        fixture.model.approveOpenRequest(asked.id)
        let answer = try await reply.value
        #expect(answer.status == .started)
        #expect(await waitUntil { fixture.model.openRequests.isEmpty })
        return try #require(answer.sessionID)
    }

    @Test func theFaceOfAStartAResumeAStoppedViewAndAnApprovedOpeningFollowsTheSwitchToday() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        var cells: [String: String] = [:]
        func note(_ cell: String, _ endpoint: RunEndpointKind?) { cells[cell] = endpoint?.rawValue ?? "none" }
        func note(_ cell: String, _ flag: Bool?) { cells[cell] = flag.map(String.init) ?? "none" }
        func note(_ cell: String, _ word: String) { cells[cell] = word }

        // Starts from a draft's send: the switch decides.
        model.setNewSessionFace(.chat)
        let chatStart = try await start(fixture, text: "first")
        note("start, Sessions run in Chat", await liveEndpoint(fixture, chatStart))
        model.setNewSessionFace(.terminal)
        let terminalStart = try await start(fixture, text: "second")
        note("start, Sessions run in Terminal", await liveEndpoint(fixture, terminalStart))

        // An approved open request: the terminal whatever the switch says. (D-69 (1) says every start follows the switch;
        // C5 changes this cell to follow it.)
        note("approved open request, Sessions run in Terminal",
             await liveEndpoint(fixture, try await approvedOpening(fixture, requester: terminalStart)))
        model.setNewSessionFace(.chat)
        note("approved open request, Sessions run in Chat",
             await liveEndpoint(fixture, try await approvedOpening(fixture, requester: terminalStart)))

        // A stopped session's view and its resume, from the session the Chat face ran last.
        await stop(fixture, chatStart)
        let stopped = try #require(model.rowModels[chatStart])
        model.setNewSessionFace(.chat)
        model.select(chatStart)
        #expect(await waitUntil { model.selectedRow?.id == chatStart && model.selectedRow?.live?.runID == nil })
        note("stopped session shows its live chat, Sessions run in Chat", model.showsStoppedLiveChat(stopped))
        note("stopped session's route, Sessions run in Chat", model.detailRouteKind)
        note("stopped session can choose its face, Sessions run in Chat", model.canChooseFace)
        model.setNewSessionFace(.terminal)
        note("stopped session shows its live chat, Sessions run in Terminal", model.showsStoppedLiveChat(stopped))
        note("stopped session's route, Sessions run in Terminal", model.detailRouteKind)
        note("stopped session can choose its face, Sessions run in Terminal", model.canChooseFace)

        note("resume, Sessions run in Terminal", await resume(fixture, chatStart))
        await stop(fixture, chatStart)
        model.setNewSessionFace(.chat)
        note("resume, Sessions run in Chat", await resume(fixture, chatStart))
        await stop(fixture, chatStart)

        // Without the app's Chat host there is no Chat face: a start and a resume are the terminal's.
        let host = model.chatSessions
        model.chatSessions = nil
        note("start, Sessions run in Chat, no Chat host", await liveEndpoint(fixture, try await start(fixture, text: "third")))
        note("resume, Sessions run in Chat, no Chat host", await resume(fixture, chatStart))
        note("stopped session shows its live chat, Sessions run in Chat, no Chat host",
             model.rowModels[chatStart].map { model.showsStoppedLiveChat($0) })
        model.chatSessions = host

        let expected: [String: String] = [
            "start, Sessions run in Chat": "pipe",
            "start, Sessions run in Terminal": "terminal",
            "approved open request, Sessions run in Terminal": "terminal",
            "approved open request, Sessions run in Chat": "terminal",
            "stopped session shows its live chat, Sessions run in Chat": "true",
            "stopped session shows its live chat, Sessions run in Terminal": "false",
            "stopped session's route, Sessions run in Chat": "chat",
            "stopped session's route, Sessions run in Terminal": "chat",
            "stopped session can choose its face, Sessions run in Chat": "false",
            "stopped session can choose its face, Sessions run in Terminal": "true",
            "resume, Sessions run in Terminal": "terminal",
            "resume, Sessions run in Chat": "pipe",
            "start, Sessions run in Chat, no Chat host": "terminal",
            "resume, Sessions run in Chat, no Chat host": "terminal",
            "stopped session shows its live chat, Sessions run in Chat, no Chat host": "false",
        ]
        for (cell, value) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(cells[cell] == value, "\(cell): \(cells[cell] ?? "not observed")")
        }
        #expect(Set(cells.keys) == Set(expected.keys))
        await fixture.cleanup()
    }
}

// MARK: The capability table

/// What each harness may do, per build identity: model-level answers on a catalog fixture, no process. The production
/// identity shows a Codex record and starts nothing of it (D-28, D-69 (5)).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionServiceCapabilityTableTests {
    private final class Intents: ConversationIntents {
        func start(provider: ManagedSession.Provider, projectID: UUID?) {}
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
    }

    private struct Fixture {
        let root: URL
        let model: CatalogModel
        let runtime: SessionRuntime
        /// The model holds its intents weakly.
        let intents: Intents
        let claude: UUID
        let codex: UUID

        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A model over a catalog of one stopped Claude session and one stopped Codex session, both with a provider
    /// conversation id. The runtime exists for the Chat host only: it is never started, nothing runs.
    private func makeFixture(startable: Set<ManagedSession.Provider>) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-capability-table-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        func add(_ provider: ManagedSession.Provider, at second: Double) async throws -> UUID {
            let session = ManagedSession(provider: provider, providerConversationID: "conversation-\(provider.rawValue)",
                                         workingDirectory: root.path)
            try await catalog.insertSession(session, title: "\(provider.rawValue) session",
                                            createdAt: Date(timeIntervalSince1970: 1_000 + second),
                                            lastUsedAt: Date(timeIntervalSince1970: 10_000 + second), lifecycle: .idle)
            return session.id
        }
        let claude = try await add(.claude, at: 0)
        let codex = try await add(.codex, at: 1)
        let hub = SessionEventHub()
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog, events: hub, scopeLauncher: nil)
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { provider in
                    ProviderToolchain(
                        provider: provider, executable: "/usr/bin/false",
                        capabilities: ProviderCapabilities(version: "none", help: "", serverHelp: ""),
                        environment: [:], profileDirectory: root.appendingPathComponent("profile"))
                },
                hookHelperPath: "/usr/bin/false", socketDirectory: URL(fileURLWithPath: "/tmp/cap-\(UUID().uuidString.prefix(8))", isDirectory: true),
                homeDirectory: root.path, idlePolicy: SessionIdlePolicy(), codexIdentityTimeout: 0.2))
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")),
                                 startableProviders: startable)
        let intents = Intents()
        model.intents = intents
        await model.start()
        model.installChatSessions(runtime: runtime, dataRoot: root)
        return Fixture(root: root, model: model, runtime: runtime, intents: intents, claude: claude, codex: codex)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// Today's answers for the session of `provider`, keyed "<identity>, <harness>, <question>".
    private func answers(_ identity: String, _ startable: Set<ManagedSession.Provider>,
                         _ provider: ManagedSession.Provider) async throws -> [String: String] {
        let fixture = try await makeFixture(startable: startable)
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = provider == .claude ? fixture.claude : fixture.codex
        #expect(await waitUntil { model.rowModels[id] != nil })
        let row = try #require(model.rowModels[id])
        var out: [String: String] = [:]
        func note(_ question: String, _ value: String) { out["\(identity), \(provider.rawValue), \(question)"] = value }
        func note(_ question: String, _ flag: Bool) { note(question, String(flag)) }
        func note(_ question: String, _ reason: String?) { note(question, reason ?? "nil") }
        func note(_ question: String, _ send: CatalogModel.ChangesSendAvailability) { note(question, send == .ready ? "ready" : "notChat") }

        note("can start", model.canStart(provider, projectID: nil))
        note("new-session entry's unavailable reason", model.newSessionUnavailableReason(provider))
        note("can resume", model.canResume(row))
        note("resume unavailable reason", model.resumeUnavailableReason(row))
        note("can resume from Home", model.canResumeFromHome(row.record))
        note("Side tab offered", model.sideTabIsOffered(for: row))
        model.setNewSessionFace(.chat)
        note("Chat face for a resume, Sessions run in Chat", model.showsStoppedLiveChat(row))
        note("Changes send, Sessions run in Chat", model.changesSendAvailability(for: id))
        model.setNewSessionFace(.terminal)
        note("Chat face for a resume, Sessions run in Terminal", model.showsStoppedLiveChat(row))
        note("Changes send, Sessions run in Terminal", model.changesSendAvailability(for: id))
        note("deletion refusal", model.deletionDisabledReason(for: row))
        return out
    }

    @Test func eachHarnessMayDoTodayWhatTheBuildIdentitySaysItMay() async throws {
        let production: Set<ManagedSession.Provider> = [.claude]
        let development: Set<ManagedSession.Provider> = [.claude, .codex]
        var observed: [String: String] = [:]
        for (identity, startable) in [("production", production), ("development", development)] {
            for provider in [ManagedSession.Provider.claude, .codex] {
                observed.merge(try await answers(identity, startable, provider)) { first, _ in first }
            }
        }

        let codexLater = "Codex comes in a later version"
        let codexNoResume = "Codex sessions can't be resumed in this version."
        let codexNoDelete = "Codex sessions can't be deleted from Loom yet."
        var expected: [String: String] = [:]
        for identity in ["production", "development"] {
            // Claude is the same in both identities.
            for (question, value) in [
                ("can start", "true"), ("new-session entry's unavailable reason", "nil"), ("can resume", "true"),
                ("resume unavailable reason", "nil"), ("can resume from Home", "true"), ("Side tab offered", "true"),
                ("Chat face for a resume, Sessions run in Chat", "true"), ("Changes send, Sessions run in Chat", "ready"),
                ("Chat face for a resume, Sessions run in Terminal", "false"), ("Changes send, Sessions run in Terminal", "notChat"),
                ("deletion refusal", "nil"),
            ] { expected["\(identity), claude, \(question)"] = value }
            // Codex is never offered a Side tab, a Chat face or a Changes send, and cannot be deleted from Loom.
            let startsCodex = identity == "development"
            for (question, value) in [
                ("can start", String(startsCodex)), ("new-session entry's unavailable reason", startsCodex ? "nil" : codexLater),
                ("can resume", String(startsCodex)), ("resume unavailable reason", startsCodex ? "nil" : codexNoResume),
                ("can resume from Home", String(startsCodex)), ("Side tab offered", "false"),
                ("Chat face for a resume, Sessions run in Chat", "false"), ("Changes send, Sessions run in Chat", "notChat"),
                ("Chat face for a resume, Sessions run in Terminal", "false"), ("Changes send, Sessions run in Terminal", "notChat"),
                ("deletion refusal", codexNoDelete),
            ] { expected["\(identity), codex, \(question)"] = value }
        }
        for (cell, value) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(observed[cell] == value, "\(cell): \(observed[cell] ?? "not observed")")
        }
        #expect(Set(observed.keys) == Set(expected.keys))
    }
}
