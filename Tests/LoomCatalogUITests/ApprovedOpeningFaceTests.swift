import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// C5b: an approved opening follows "Sessions run in" like every other start (D-69 (1)). An agent's open request, approved
// through the model, starts the new session in the Chat face when the switch says Chat and the app has its Chat host; in the
// terminal otherwise. Real runs on the fake provider (its chat engine; `LOOM_FAKE_CHAT_REQUEST_LOG` records its control
// requests).

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(5)))
struct ApprovedOpeningFaceTests {
    private static let title = "Opened by an agent"
    private static let message = "Do the next thing, and tell me when it is done."

    private struct Fixture {
        let rig: LiveRig
        let model: CatalogModel
        let controller: ConversationController
        let projectID: UUID
        let requester: UUID
        let requestLog: URL

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            await rig.finish()
            try? FileManager.default.removeItem(at: requestLog)
        }
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

    /// The endpoint of the run the session has now (`.runStarted` resets it and `.runEndpoint` sets it: wait for both).
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

    /// A requesting session in the terminal (the switch on Terminal for its start), selected.
    private func makeFixture() async throws -> Fixture {
        let requestLog = FileManager.default.temporaryDirectory.appendingPathComponent("loom-requests-\(UUID()).log")
        let rig = try await LiveRig.make(environment: ["LOOM_FAKE_CHAT_REQUEST_LOG": requestLog.path])
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
        model.setNewSessionFace(.terminal)
        var started: UUID?
        controller.startSession(projectID: project.id, launch: NewSessionLaunch(firstMessage: "ask"), focus: .session) {
            if case let .started(id) = $0 { started = id }
        }
        #expect(await waitUntil { started != nil })
        let requester = try #require(started)
        #expect(await liveEndpoint(Fixture(rig: rig, model: model, controller: controller, projectID: project.id,
                                           requester: requester, requestLog: requestLog), requester) == .terminal)
        return Fixture(rig: rig, model: model, controller: controller, projectID: project.id,
                       requester: requester, requestLog: requestLog)
    }

    /// An agent's request to open a session, asked as `loom-hook open` does, approved in the model; returns the opened
    /// session's id.
    private func approvedOpening(_ fixture: Fixture) async throws -> UUID {
        let run = try #require(await hub(fixture, fixture.requester)?.runID)
        let hooks = try #require(await fixture.rig.runtime.hookConfiguration)
        let control = try #require(hooks.controlSocketPath)
        let request = OpenSessionWireRequest(
            authenticationToken: hooks.authenticationToken, sessionID: fixture.requester, managedRunID: run,
            title: Self.title, project: nil, message: Self.message)
        let reply = Task.detached { try OpenSessionClient.exchange(request, socketPath: control) }
        #expect(await waitUntil { fixture.model.openRequests.count == 1 })
        fixture.model.approveOpenRequest(try #require(fixture.model.openRequests.first).id)
        let answer = try await reply.value
        #expect(answer.status == .started)
        #expect(await waitUntil { fixture.model.openRequests.isEmpty })
        return try #require(answer.sessionID)
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The text of the first user record in the fake engine's transcript of the session (what its engine received), once
    /// it is there.
    private func firstUserMessage(_ fixture: Fixture, of id: UUID) async -> String? {
        var found: String?
        _ = await waitUntil(30) {
            let projects = fixture.rig.profile.appendingPathComponent("projects", isDirectory: true)
            let files = (try? FileManager.default.subpathsOfDirectory(atPath: projects.path)) ?? []
            guard let name = files.first(where: { $0.lowercased().hasSuffix("/\(id.uuidString.lowercased()).jsonl") }),
                  let text = try? String(contentsOf: projects.appendingPathComponent(name), encoding: .utf8) else { return false }
            for line in text.split(separator: "\n") {
                guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      record["type"] as? String == "user", let message = record["message"] as? [String: Any] else { continue }
                if let content = message["content"] as? String { found = content }
                else if let blocks = message["content"] as? [[String: Any]] {
                    found = blocks.compactMap { $0["text"] as? String }.joined()
                }
                return found != nil
            }
            return false
        }
        return found
    }

    @Test func withTheSwitchOnChatAnApprovedOpeningStartsInTheChatFaceWithItsTitleItsLinkAndItsFirstMessage() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        model.setNewSessionFace(.chat)
        let selected = model.selectedSessionID

        let opened = try await approvedOpening(fixture)

        #expect(await liveEndpoint(fixture, opened) == .pipe)
        let row = try #require(try await fixture.rig.runtime.catalog.session(id: opened))
        #expect(row.title == Self.title)
        #expect(row.openedBy == fixture.requester)
        // The fake engine got the request's message, as the first user message, over stdin.
        #expect(await firstUserMessage(fixture, of: opened) == Self.message)
        // The selection does not move, and the new session has a Chat driver and no terminal.
        #expect(model.selectedSessionID == selected)
        #expect(model.chatSessions?.existingDriver(for: opened) != nil)
        #expect(model.terminalView(for: opened) == nil)
        // The card has its title, so Sphyrna asks no model to name it: no title request, in a session that ran a turn.
        let driver = try #require(model.chatSessions?.existingDriver(for: opened))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        try await Task.sleep(for: .milliseconds(600))
        let requests = lines(fixture.requestLog)
        #expect(requests.contains("initialize"), "the log saw the session: \(requests)")
        #expect(!requests.contains("generate_session_title"), "\(requests)")
        await fixture.cleanup()
    }

    @Test func withTheSwitchOnTerminalOrWithoutAChatHostAnApprovedOpeningStartsInTheTerminal() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model

        model.setNewSessionFace(.terminal)
        let terminalOpened = try await approvedOpening(fixture)
        #expect(await liveEndpoint(fixture, terminalOpened) == .terminal)
        #expect(await waitUntil { model.terminalView(for: terminalOpened) != nil })

        model.setNewSessionFace(.chat)
        let host = model.chatSessions
        model.chatSessions = nil
        let hostless = try await approvedOpening(fixture)
        #expect(await liveEndpoint(fixture, hostless) == .terminal)
        #expect(await waitUntil { model.terminalView(for: hostless) != nil })
        model.chatSessions = host

        for id in [terminalOpened, hostless] {
            let row = try #require(try await fixture.rig.runtime.catalog.session(id: id))
            #expect(row.title == Self.title && row.openedBy == fixture.requester)
        }
        #expect(!lines(fixture.requestLog).contains("generate_session_title"))
        await fixture.cleanup()
    }
}
