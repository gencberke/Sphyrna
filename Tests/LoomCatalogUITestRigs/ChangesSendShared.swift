import AppKit
import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
import LoomTestSupport

/// What both halves of `ChangesSendTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ChangesSendShared {
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

/// `ChangesSendTests`'s fixtures, for both halves of the suite.
@MainActor protocol ChangesSendFixtures {}

extension ChangesSendFixtures {
    typealias Fixture = ChangesSendShared.Fixture

    func make() async throws -> Fixture {
        let rig = try await LiveRig.make()
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

    func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func startFromDraft(_ model: CatalogModel, text: String) async throws -> UUID {
        model.showDraft(projectID: nil)
        model.setDraftText(text, projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.destination?.sessionID != nil })
        return try #require(model.destination?.sessionID)
    }

    func comment(_ model: CatalogModel, _ id: UUID, line: Int, _ text: String) {
        model.changes.session(for: id).saveComment(
            text, at: ChangeAnchor(fileID: "/w/src/a.swift", line: line, removed: false, text: "let value = \(line)"),
            displayPath: "src/a.swift", in: .lastTurn)
    }
}
