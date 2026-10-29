import AppKit
import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
import LoomTestSupport

/// The Side tab's state as development evidence reads it (`side-state`): ids, booleans and the phase word, never a word of a
/// question, an answer or a notice. A real side-chat flow over the fake provider is encoded and every leaf of the JSON is checked.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(8)))
struct SideTabEvidenceTests {
    private static let phaseWords: Set<String> = ["stopped", "starting", "ready", "working", "needsYou", "stopping", "failed", "none"]
    private static let topKeys: Set<String> = ["open", "busy", "notice", "closeFailed", "chats"]
    private static let chatKeys: Set<String> = ["id", "phase", "live", "waiting", "settled", "asked"]

    private func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func encoded(_ state: SideTabState) throws -> [String: Any] {
        let data = try JSONEncoder().encode(state)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every leaf is a UUID string, a Bool or a phase word; every key is one of the shape's.
    private func checkLeaves(_ json: [String: Any]) throws {
        #expect(Set(json.keys) == Self.topKeys)
        for key in ["busy", "notice", "closeFailed"] { #expect(isBool(json[key]), "\(key) is a Bool") }
        if !(json["open"] is NSNull) { #expect(UUID(uuidString: json["open"] as? String ?? "") != nil) }
        let chats = try #require(json["chats"] as? [[String: Any]])
        for chat in chats {
            #expect(Set(chat.keys) == Self.chatKeys)
            #expect(UUID(uuidString: chat["id"] as? String ?? "") != nil)
            #expect(Self.phaseWords.contains(chat["phase"] as? String ?? ""))
            for key in ["live", "waiting", "settled", "asked"] { #expect(isBool(chat[key]), "\(key) is a Bool") }
        }
    }

    private func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    @Test func theTabsStateHoldsIdsAndBooleansAndNoTextOfAQuestionAnAnswerOrANotice() async throws {
        let rig = try await LiveRig.make(forkable: true)
        let model = CatalogModel(
            catalog: await rig.runtime.catalog, events: await rig.runtime.supervisor.events,
            preferences: UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: rig.runtime, model: model)
        await controller.begin()
        await model.start()
        model.installChatSessions(runtime: rig.runtime, dataRoot: rig.root)
        model.useFrozenChatFace()
        model.setClaudeConfigDirectory(rig.profile)

        // A parent that has answered once.
        model.showDraft(projectID: nil)
        model.setDraftText("hello", projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.destination?.sessionID != nil })
        let parent = try #require(model.destination?.sessionID)
        let parentDriver = try #require(model.chatSessions?.existingDriver(for: parent))
        #expect(await waitUntil {
            let snapshot = await parentDriver.snapshot()
            return snapshot.phase == .ready && !snapshot.turnRunning
                && snapshot.model.entries.contains { if case .assistantText = $0.body { true } else { false } }
        })

        // Before the tab was ever used: nothing is made, and the state is empty.
        let empty = await model.sideTabState(for: parent)
        #expect(empty == SideTabState(open: nil, busy: false, notice: false, closeFailed: false, chats: []))
        try checkLeaves(try encoded(empty))
        #expect(try encoded(empty)["open"] is NSNull, "nothing open is written as null")

        // A question and its answer, through the composer's own paths.
        let question = "Which zebra-kiwi marker does the quick question carry?"
        model.setSideComposerText(question, in: parent)
        await model.submitSideQuestion(in: parent)
        #expect(await waitUntil { model.side.existing(for: parent)?.openID != nil })
        let id = try #require(model.side.existing(for: parent)?.openID)
        let side = try #require(model.chatSessions?.existingDriver(for: id))
        func answers() async -> [String] {
            await side.snapshot().model.entries.compactMap { entry -> String? in
                if case let .assistantText(text) = entry.body { text.text } else { nil }
            }
        }
        var state = await model.sideTabState(for: parent)
        #expect(await waitUntil {
            state = await model.sideTabState(for: parent)
            let answered = await !answers().isEmpty
            return answered && state.chats.first?.settled == true && state.chats.first?.phase == .ready
        })
        let chat = try #require(state.chats.first)
        #expect(state.open == chat.id && chat.id == id && chat.asked && chat.live && !state.busy && !state.notice)
        let answer = try #require(await answers().first, "the side chat answered")
        #expect(!answer.isEmpty)

        // A notice: a message that begins with "/" is refused, and the notice's words stay out of the state.
        model.setSideComposerText("/clear", in: parent)
        await model.submitSideQuestion(in: parent)
        let refused = await model.sideTabState(for: parent)
        #expect(refused.notice && !refused.closeFailed)

        for state in [state, refused] {
            let json = try encoded(state)
            try checkLeaves(json)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            #expect(!text.contains("zebra-kiwi") && !text.contains(question))
            #expect(!text.contains(answer))
            #expect(!text.contains(ChatSessionDriver.commandsRefusedText) && !text.contains("/clear"))
        }

        controller.stopObserving()
        model.stop()
        await rig.finish()
    }
}
