import Foundation
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

// Release B fix round 1 (from the real-Claude acceptance), driver side: each test fails without the fix it names.

private final class Moves: Sendable {
    let list = Mutex<[(from: UUID, to: UUID)]>([])
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct ChatReleaseBFixTests {
    /// F1. The real CLI 2.1.300 writes `/clear` as `conversation_reset` (its `new_conversation_id` is the record's own uuid,
    /// not a session), the SessionStart hook with source `clear`, and `system/init`, the last two under the session the
    /// transcript is written under. Taking the reset's id made two moves 26 ms apart: an empty middle card and the real one.
    /// One `/clear` is one move, whichever of the hook and the init Loom reads first.
    @Test(arguments: ["hook-first", "init-first"])
    func oneClearMovesTheRunOnceToTheCardTheTranscriptIsWrittenUnder(order: String) async throws {
        let rig = try await Rig.make(environment: order == "init-first" ? ["LOOM_FAKE_CHAT_RESET_ORDER": "init-first"] : [:])
        let id = UUID()
        let moves = Moves()
        let queues = ChatQueueStore(directory: rig.root.appendingPathComponent("chat-queues"))
        let driver = ChatSessionDriver(
            sessionID: id, runtime: rig.runtime, queueStore: queues, readyTimeout: .seconds(20),
            onMoved: { from, to in moves.list.withLock { $0.append((from, to)) } })
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        try await driver.send("hello before the clear")
        #expect(await idle(driver))
        let original = try #require(await driver.liveState().conversationID)
        // A paused queue item, to see it move once (an interrupt pauses the queue).
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        _ = try await driver.enqueue("queued across the clear")
        await driver.interrupt()
        #expect(await idle(driver))

        try await driver.send("/clear")
        #expect(await waitUntil { await driver.sessionID != id })
        #expect(await idle(driver))
        // A second move would come within milliseconds; wait well past that.
        try await Task.sleep(for: .milliseconds(800))
        let card = await driver.sessionID
        #expect(moves.list.withLock { $0.map(\.to) } == [card])
        #expect(moves.list.withLock { $0.first?.from } == id)

        // The conversation id the driver and the catalog name is the one the transcript is written under.
        try await driver.send("after the clear")
        #expect(await idle(driver))
        let conversation = try #require(await driver.liveState().conversationID)
        #expect(conversation != original)
        let projects = rig.profile.appendingPathComponent("projects", isDirectory: true)
        let transcripts = ((try? FileManager.default.subpathsOfDirectory(atPath: projects.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && !$0.contains("/subagents/") }
            .map { ($0 as NSString).lastPathComponent }
        #expect(transcripts.contains(conversation + ".jsonl"), "\(transcripts)")
        #expect(try await rig.catalog.session(id: card)?.session.providerConversationID == conversation)

        // Two cards, not three: no conversation id without a transcript is left as a card.
        let cards = try await rig.catalog.sessions().compactMap(\.session.providerConversationID)
        #expect(cards.count == 2, "\(cards)")
        #expect(Set(cards) == Set([original, conversation]))
        for card in cards { #expect(transcripts.contains(card + ".jsonl"), "\(card) has no transcript") }

        // The queue and the marker followed once.
        let snapshot = await driver.snapshot()
        #expect(snapshot.markers.filter { $0 == .reset(trigger: "clear") }.count == 1)
        #expect(snapshot.queue.items.map(\.text) == ["queued across the clear"])
        #expect(FileManager.default.fileExists(atPath: queues.url(for: card).path))
        #expect(!FileManager.default.fileExists(atPath: queues.url(for: id).path))
        _ = await driver.clearQueue()
        _ = try await driver.stop()
        await rig.finish()
    }

    // MARK: F2. A denied tool reads as denied

    /// F2. The result text of a deny with a note is the note alone (CLI 2.1.300), so the text-prefix rule called it failed.
    /// The wire says it: `tool_result_meta[].non_execution_kind` (`toolDenialKind` in a transcript). A call that really
    /// failed stays failed.
    @Test func aToolTheUserRefusedWithANoteIsDeniedAndAFailedToolIsNot() {
        func record(id: String, text: String, extra: [String: JSONValue]) -> StreamMessage {
            var fields: [String: JSONValue] = [
                "type": "user", "uuid": .string("r-" + id), "session_id": "s1", "parent_tool_use_id": .null,
                "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": .string(text),
                                                        "is_error": true]]],
            ]
            fields.merge(extra) { _, new in new }
            return Fixture.message(Fixture.line(.object(fields)))
        }
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "go", at: Date(timeIntervalSince1970: 1_800_000_000))
        for id in ["noted", "rule", "plain", "failed", "transcript"] {
            _ = model.apply(Fixture.message(Fixture.assistant(
                messageID: "m-" + id, uuid: "a-" + id, blocks: [Fixture.toolUse(id, "Bash", ["command": "touch x"])])))
        }
        // Live: a note with no known prefix, a deny rule, and the user's plain reject.
        _ = model.apply(record(id: "noted", text: "do not create files here, use the Write tool next time", extra: [
            "tool_use_result": "Error: do not create files here",
            "tool_result_meta": [["id": "noted", "non_execution_kind": "permission-rule",
                                  "permission_decision": ["decision": "reject", "source": "user_reject"]]]]))
        _ = model.apply(record(id: "rule", text: "Edits are off here.", extra: [
            "tool_result_meta": [["id": "rule", "non_execution_kind": "permission-rule"]]]))
        _ = model.apply(record(id: "plain", text: "User rejected tool use", extra: [
            "tool_result_meta": [["id": "plain", "non_execution_kind": "user-rejected"]]]))
        // A tool that ran and failed: no refusal in its meta.
        _ = model.apply(record(id: "failed", text: "Exit code 1\nboom", extra: [
            "tool_result_meta": [["id": "failed", "permission_decision": ["decision": "accept", "source": "user_temporary"]]]]))
        // A transcript record carries the same fact as `toolDenialKind`.
        _ = model.apply(record(id: "transcript", text: "a note", extra: ["toolDenialKind": "permission-rule"]))
        let status = Dictionary(uniqueKeysWithValues: model.tools.map { ($0.id, $0.status) })
        #expect(status["noted"] == .denied)
        #expect(status["rule"] == .denied)
        #expect(status["plain"] == .denied)
        #expect(status["failed"] == .failed)
        #expect(status["transcript"] == .denied)
        #expect(model.tools.first { $0.id == "failed" }?.exitCode == 1)
    }

    /// F2, end to end on the fake: a live deny with a note (and one without) leaves the Bash row denied, as the card's
    /// "Denied" line says; an allowed one succeeds.
    @Test func aLiveDenyWithANoteLeavesTheToolRowDenied() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver(UUID())
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        for note in ["use make clean instead", nil] as [String?] {
            try await driver.send("/scenario approval")
            #expect(await waitUntil { await driver.currentPhase == .needsYou })
            let request = try #require(await driver.snapshot().requests.first)
            try await driver.answer(requestID: request.requestID, .deny(note: note))
            #expect(await idle(driver))
        }
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        let allowed = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: allowed.requestID, .allowOnce)
        #expect(await idle(driver))
        let statuses = await driver.snapshot().model.tools.map(\.status)
        #expect(statuses == [.denied, .denied, .succeeded], "\(statuses)")
        _ = try await driver.stop()
        await rig.finish()
    }

    // MARK: F3. A failed capability probe is tried once more
}
