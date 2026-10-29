import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `MergeSeamTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum MergeSeamShared {
    struct Fixture {
        let rig: LiveRig
        let model: CatalogModel
        let controller: ConversationController

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            await rig.finish()
        }

        var home: URL { rig.root.appendingPathComponent("home", isDirectory: true) }
    }
}

/// `MergeSeamTests`'s fixtures, for both halves of the suite.
@MainActor protocol MergeSeamFixtures {}

extension MergeSeamFixtures {
    typealias Fixture = MergeSeamShared.Fixture

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

    func waitUntil(_ seconds: Double = 15, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// A start from the draft's send with `mode` chosen, as the controller gets it.
    func start(_ fixture: Fixture, mode: String?, text: String = "hello") async throws -> UUID {
        var started: UUID?
        var failed = false
        fixture.controller.startSession(
            projectID: nil, launch: NewSessionLaunch(firstMessage: text, choices: ClaudeLaunchChoices(permissionMode: mode)),
            focus: .session
        ) { outcome in
            switch outcome {
            case let .started(id): started = id
            case .failed: failed = true
            }
        }
        #expect(await waitUntil { started != nil || failed })
        return try #require(started)
    }

    func endpoint(_ fixture: Fixture, _ id: UUID) async -> RunEndpointKind? {
        try? await fixture.rig.runtime.catalog.session(id: id)?.runEndpoint
    }

    func notice(_ fixture: Fixture, _ id: UUID) async -> String? {
        await fixture.rig.runtime.supervisor.events.snapshot().sessions[id]?.issue
    }

    func chatDriver(_ fixture: Fixture, _ id: UUID) async throws -> ChatSessionDriver {
        #expect(await waitUntil { fixture.model.chatSessions?.existingDriver(for: id) != nil })
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        return driver
    }
}
