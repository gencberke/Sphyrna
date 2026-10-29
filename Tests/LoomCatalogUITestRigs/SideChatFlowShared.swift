import AppKit
import CryptoKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
import LoomTestSupport

/// What both halves of `SideChatFlowTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum SideChatFlowShared {
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

    /// The parent's CLI took its first message and answered it. A turn in the model is no proof: the message's own row makes one
    /// while the message is still on its way (ready, no turn running), and a fork made then copies a transcript that does not
    /// hold it yet. The fake writes the message to the transcript before it streams the answer.
    @MainActor
    static func hasAnswered(_ driver: ChatSessionDriver) async -> Bool {
        let snapshot = await driver.snapshot()
        return snapshot.phase == .ready && !snapshot.turnRunning && !answers(snapshot).isEmpty
    }

    @MainActor
    static func answers(_ snapshot: ChatDriverSnapshot) -> [String] {
        snapshot.model.entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } }
    }
}

/// `SideChatFlowTests`'s fixtures, for both halves of the suite.
@MainActor protocol SideChatFlowFixtures {}

extension SideChatFlowFixtures {
    typealias Fixture = SideChatFlowShared.Fixture

    func make(forkable: Bool = true) async throws -> Fixture {
        let rig = try await LiveRig.make(forkable: forkable)
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

    /// A parent that has answered once, with its driver.
    func parent(_ fixture: Fixture, text: String = "hello") async throws -> (id: UUID, driver: ChatSessionDriver) {
        let id = try await startFromDraft(fixture.model, text: text)
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { await SideChatFlowShared.hasAnswered(driver) })
        return (id, driver)
    }

    func ask(_ model: CatalogModel, _ session: SideSession, _ parent: UUID, _ text: String) async {
        session.composerText = text
        await model.submitSideQuestion(in: parent)
    }

    func transcript(named conversation: String, under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "\(conversation).jsonl" { return url }
        }
        return nil
    }

    func phase(_ driver: ChatSessionDriver) async -> ChatDriverPhase { await driver.currentPhase }
}
