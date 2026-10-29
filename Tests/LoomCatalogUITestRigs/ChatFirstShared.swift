import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `ChatFirstTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ChatFirstShared {
    struct Fixture {
        let rig: LiveRig
        let model: CatalogModel
        let controller: ConversationController

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            await rig.finish()
        }
    }
}

/// `ChatFirstTests`'s fixtures, for both halves of the suite.
@MainActor protocol ChatFirstFixtures {}

extension ChatFirstFixtures {
    typealias Fixture = ChatFirstShared.Fixture

    func makeFixture(environment: [String: String] = [:]) async throws -> Fixture {
        let rig = try await LiveRig.make(environment: environment)
        let model = CatalogModel(
            catalog: await rig.runtime.catalog, events: await rig.runtime.supervisor.events,
            preferences: UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: rig.runtime, model: model)
        await controller.begin()
        await model.start()
        model.installChatSessions(runtime: rig.runtime, dataRoot: rig.root)
        model.useFrozenChatFace()
        model.setClaudeConfigDirectory(rig.profile)
        return Fixture(rig: rig, model: model, controller: controller)
    }

    /// A start in a fresh rig captures the environment and opens a run scope first; under a full run's load that took more
    /// than 15 s once. The deadline only bounds a failure, so it is one that load does not cross.
    func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// Sends the project-less draft and returns the session it started.
    func startFromDraft(_ fixture: Fixture, text: String) async throws -> UUID {
        let model = fixture.model
        model.showDraft(projectID: nil)
        model.setDraftText(text, projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.destination?.sessionID != nil })
        return try #require(model.destination?.sessionID)
    }

    func endpoint(_ fixture: Fixture, _ id: UUID) async -> RunEndpointKind? {
        try? await fixture.rig.runtime.catalog.session(id: id)?.runEndpoint
    }

    func title(_ fixture: Fixture, _ id: UUID) async -> String? {
        try? await fixture.rig.runtime.catalog.session(id: id)?.title
    }

    /// A Chat session that has answered once and then moved to the terminal, which has resumed it and rests at its prompt.
    func terminalSession(_ fixture: Fixture) async throws -> UUID {
        let model = fixture.model
        let id = try await startFromDraft(fixture, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await waitUntil { model.selectedRow?.record.runEndpoint == .pipe })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { await endpoint(fixture, id) == .terminal && model.handovers[id] == nil })
        #expect(await waitUntil {
            fixture.controller.terminalEvidence(tokens: ["RESUMED"]).first?.tokenPresence["RESUMED"] == true
        })
        return id
    }

    func hub(_ fixture: Fixture, _ id: UUID) async -> SessionViewState? {
        await fixture.rig.runtime.supervisor.events.snapshot().sessions[id]
    }

    func chatSession(_ fixture: Fixture) async throws -> (UUID, ChatSessionDriver) {
        let id = try await startFromDraft(fixture, text: "hello")
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await waitUntil { fixture.model.selectedRow?.record.runEndpoint == .pipe })
        return (id, driver)
    }
}
