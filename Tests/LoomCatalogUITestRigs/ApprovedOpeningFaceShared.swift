import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `ApprovedOpeningFaceTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ApprovedOpeningFaceShared {
    @MainActor
    static let title = "Opened by an agent"

    @MainActor
    static let message = "Do the next thing, and tell me when it is done."

    struct Fixture {
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
}

/// `ApprovedOpeningFaceTests`'s fixtures, for both halves of the suite.
@MainActor protocol ApprovedOpeningFaceFixtures {}

extension ApprovedOpeningFaceFixtures {
    typealias Fixture = ApprovedOpeningFaceShared.Fixture

    func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func hub(_ fixture: Fixture, _ id: UUID) async -> SessionViewState? {
        await fixture.rig.runtime.supervisor.events.snapshot().sessions[id]
    }

    /// The endpoint of the run the session has now (`.runStarted` resets it and `.runEndpoint` sets it: wait for both).
    func liveEndpoint(_ fixture: Fixture, _ id: UUID) async -> RunEndpointKind? {
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
    func makeFixture() async throws -> Fixture {
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
        model.useFrozenChatFace()
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
    func approvedOpening(_ fixture: Fixture) async throws -> UUID {
        let run = try #require(await hub(fixture, fixture.requester)?.runID)
        let hooks = try #require(await fixture.rig.runtime.hookConfiguration)
        let control = try #require(hooks.controlSocketPath)
        let request = OpenSessionWireRequest(
            authenticationToken: hooks.authenticationToken, sessionID: fixture.requester, managedRunID: run,
            title: ApprovedOpeningFaceShared.title, project: nil, message: ApprovedOpeningFaceShared.message)
        let reply = Task {
            try await onOwnThread("open-session exchange") { try OpenSessionClient.exchange(request, socketPath: control) }
        }
        #expect(await waitUntil { fixture.model.openRequests.count == 1 })
        fixture.model.approveOpenRequest(try #require(fixture.model.openRequests.first).id)
        let answer = try await reply.value
        #expect(answer.status == .started)
        #expect(await waitUntil { fixture.model.openRequests.isEmpty })
        return try #require(answer.sessionID)
    }

    func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
