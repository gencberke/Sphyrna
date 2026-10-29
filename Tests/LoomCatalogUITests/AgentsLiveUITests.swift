import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCatalogUITestRigs

// V23, Agents live, on the catalog side: which subagent the Agents tab and the sidebar tree mark as waiting, what the open
// subagent's notice says in each face, how "Show the request" reaches the pinned card, and a stopped session's list read from
// its folder. Counting seams stand in for the folder read; nothing here opens a window or runs a program.

// MARK: The card's line

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SubagentCardLineTests {
    private func run(_ status: SubagentRun.Status, progress: String? = nil, result: String? = nil) -> SubagentRun {
        SubagentRun(toolUseID: "agent_1", description: "Review auth", subagentType: "reviewer", prompt: "Look", status: status,
                    result: result.map { ClippedText($0) }, latestProgress: progress, agentID: "a-reviewer", startedAt: nil, endedAt: nil)
    }

    /// The line is the newest words, whatever the previous ones were like: two blocks of one length that start alike are two lines.
    @Test func theLineFollowsTheNewestWordsEvenWhenTwoBlocksShareTheirLengthAndStart() {
        let first = "Reading the login handler and the session store: checks token A"
        let second = "Reading the login handler and the session store: checks token B"
        #expect(first.utf8.count == second.utf8.count && first.prefix(24) == second.prefix(24))
        #expect(ChatWork.subagentDetail(run(.running, progress: first)) == first)
        #expect(ChatWork.subagentDetail(run(.running, progress: second)) == second)
        // While it runs only its words show; before it has said any, nothing.
        #expect(ChatWork.subagentDetail(run(.running)) == nil)
        #expect(ChatWork.subagentDetail(run(.running, progress: "Looking", result: "Early result")) == "Looking")
    }

    /// Where the stream has no words (the terminal face, a stopped session: `latestProgress` is live streams only) the card is as it was.
    @Test func withoutTheStreamsWordsTheCardShowsItsResultWhenDoneAndNothingWhileRunning() {
        #expect(ChatWork.subagentDetail(run(.succeeded, result: "Auth looks fine")) == "Auth looks fine")
        #expect(ChatWork.subagentDetail(run(.succeeded, progress: "Reading auth.py", result: "Auth looks fine")) == "Auth looks fine")
        #expect(ChatWork.subagentDetail(run(.running)) == nil)
        #expect(ChatWork.subagentDetail(run(.running, result: "Async agent launched in the background")) == nil)
    }
}

// MARK: Show the request

// MARK: A stopped session's list

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct StoppedAgentsTests {
    /// Counts the folder reads the tab asked for, and answers from the records a test sets.
    final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [StoppedAgentsReader.Request] = []
        private var _holding = false
        var records: [SubagentRecord] = []

        var requests: [StoppedAgentsReader.Request] { lock.withLock { _requests } }

        /// The next reads wait for `release()` (a read that is slow).
        func hold() { lock.withLock { _holding = true } }
        func release() { lock.withLock { _holding = false } }

        var reader: StoppedAgentsReader {
            StoppedAgentsReader { [self] request in
                lock.withLock { _requests.append(request) }
                while lock.withLock({ _holding }) { try? await Task.sleep(for: .milliseconds(5)) }
                return records
            }
        }
    }

    private func stopped(_ id: String, interrupted: Bool = false) -> SubagentRecord {
        var record = inspectorRecord(id, running: false, type: "Explore", description: "task " + id)
        record.wasInterrupted = interrupted
        return record
    }

    private func fixture() async throws -> (rig: InspectorRig, log: ReadLog) {
        let rig = try await InspectorRig.make()
        let log = ReadLog()
        rig.model.stoppedAgents.reader = log.reader
        // The rig gives every session a terminal view, which counts as a run: these sessions have none.
        rig.intents.terminals.removeAll()
        rig.model.setClaudeConfigDirectory(rig.root)
        rig.model.select(rig.ids[0])
        return (rig, log)
    }

    /// The rule: the folder is read only while the Agents tab is open on a session with no run.
    @Test func nothingReadsWhileTheTabIsClosedAndTheTabOpenedReadsOnceEachTime() async throws {
        let (rig, log) = try await fixture()
        defer { rig.cleanup() }
        let (model, id) = (rig.model, rig.ids[0])
        log.records = [stopped("a1")]
        // Closed, and open on another tab: no trigger, so the inspector's task has nothing to run.
        #expect(model.agentsTrigger == nil)
        await model.runAgentsRead()
        model.setInspector(open: true, for: id)
        #expect(model.agentsTrigger == nil, "the inspector is open on Overview")
        await model.runAgentsRead()
        model.selectInspectorTab(.changes)
        await model.runAgentsRead()
        #expect(log.requests.isEmpty)

        // Opening the tab is the reason to read: once, from the session's own conversation and folder, under the config directory.
        model.selectInspectorTab(.agents)
        #expect(model.agentsTrigger == AgentsTrigger(session: id, conversationID: "conv-0"))
        await model.runAgentsRead()
        #expect(log.requests.count == 1)
        #expect(log.requests.first?.conversationID == "conv-0" && log.requests.first?.configDirectory == rig.root)
        #expect(log.requests.first?.workingDirectory == rig.root.path)
        let row = try #require(model.selectedRow)
        #expect(model.agentRecords(for: row)?.map(\.id) == ["a1"])

        // Closed again: nothing reads, whatever else happens. Opened again: one more read.
        model.selectInspectorTab(.overview)
        #expect(model.agentsTrigger == nil)
        await model.runAgentsRead()
        #expect(log.requests.count == 1)
        model.selectInspectorTab(.agents)
        await model.runAgentsRead()
        #expect(log.requests.count == 2)

        // Another session is another trigger, and so is a session that runs: that one lists its live ledger, no folder.
        model.select(rig.ids[1])
        #expect(model.agentsTrigger == nil, "the inspector is open per session")
        model.setInspector(open: true, for: rig.ids[1])
        #expect(model.agentsTrigger == AgentsTrigger(session: rig.ids[1], conversationID: "conv-1"))
        model.select(id)
        await rig.goLive(0, [])
        #expect(model.agentsTrigger == nil)
        await model.runAgentsRead()
        #expect(log.requests.count == 2)
        let running = try #require(model.selectedRow)
        #expect(model.agentRecords(for: running) == [])
    }

    /// A stopped Claude session whose folder cannot be read (no profile, or no conversation yet) has nothing to wait for: its
    /// list is empty at once, so the tab says that agents show while the session runs instead of staying blank.
    @Test func aStoppedSessionWhoseFolderCannotBeReadIsEmptyNotUnread() async throws {
        let (rig, log) = try await fixture()
        defer { rig.cleanup() }
        let (model, id) = (rig.model, rig.ids[0])
        model.setClaudeConfigDirectory(nil)
        model.setInspector(open: true, for: id)
        model.selectInspectorTab(.agents)
        #expect(model.agentsTrigger == nil)
        await model.runAgentsRead()
        let row = try #require(model.selectedRow)
        #expect(model.agentRecords(for: row) == [], "a list no read can fill is empty, not waiting for a read")
        #expect(InspectorAgents.emptyText(isRunning: false, readsFolder: model.agentsFolderIsReadable(row))
            == "Agents show while the session runs.")
        #expect(log.requests.isEmpty)
        // With the profile back, the folder is the list again: nothing until it was read.
        model.setClaudeConfigDirectory(rig.root)
        #expect(model.agentsFolderIsReadable(row))
        #expect(model.agentRecords(for: row) == nil)
    }

    @Test func aReadThatEndsAfterTheTabClosedStoresNothing() async throws {
        let (rig, log) = try await fixture()
        defer { rig.cleanup() }
        let (model, id) = (rig.model, rig.ids[0])
        log.records = [stopped("a1")]
        model.setInspector(open: true, for: id)
        model.selectInspectorTab(.agents)
        let trigger = try #require(model.agentsTrigger)
        log.hold()
        let read = Task { await model.runAgentsRead() }
        #expect(await inspectorWaitUntil { log.requests.count == 1 })
        // The tab is closed while the folder is read: the answer is not kept.
        model.selectInspectorTab(.overview)
        log.release()
        await read.value
        #expect(model.stoppedAgents.records(for: id, conversationID: trigger.conversationID) == nil)
    }

    /// The folder, the main transcript and the scan together, as the app wires them: types, descriptions, the interrupted call.
    @Test func theLiveReaderListsTheFolderAndMarksTheCallWithNoResult() async throws {
        let (rig, _) = try await fixture()
        defer { rig.cleanup() }
        let model = rig.model
        model.stoppedAgents.reader = .live
        let projects = rig.root.appendingPathComponent("projects/-tmp-ws", isDirectory: true)
        let subagents = projects.appendingPathComponent("conv-0/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        func agent(_ id: String, type: String, toolUseID: String, written: TimeInterval) throws {
            let meta: [String: Any] = ["agentType": type, "description": "task " + id, "toolUseId": toolUseID, "spawnDepth": 1]
            try JSONSerialization.data(withJSONObject: meta).write(to: subagents.appendingPathComponent("agent-\(id).meta.json"))
            let transcript = subagents.appendingPathComponent("agent-\(id).jsonl")
            try Data("{}\n".utf8).write(to: transcript)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: written)], ofItemAtPath: transcript.path)
        }
        try agent("afinished", type: "Explore", toolUseID: "toolu_ok", written: 1_000)
        try agent("acut", type: "general-purpose", toolUseID: "toolu_cut", written: 2_000)
        try Data("not json".utf8).write(to: subagents.appendingPathComponent("agent-abroken.meta.json"))
        func line(_ object: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        }
        func call(_ id: String) -> String {
            line(["type": "assistant", "uuid": "a-" + id, "message": ["id": "m-" + id, "role": "assistant", "content": [
                ["type": "tool_use", "id": id, "name": "Agent", "input": ["description": "d"]]]]])
        }
        let result = line(["type": "user", "uuid": "r1", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_ok", "content": "ok"]]]])
        let transcript = [call("toolu_ok"), result, call("toolu_cut")].joined(separator: "\n") + "\n"
        try transcript.write(to: projects.appendingPathComponent("conv-0.jsonl"), atomically: true, encoding: .utf8)

        model.setInspector(open: true, for: rig.ids[0])
        model.selectInspectorTab(.agents)
        await model.runAgentsRead()
        let selected = try #require(model.selectedRow)
        let listed = try #require(model.agentRecords(for: selected))
        // Newest first by the transcript's last write; the unreadable meta file is skipped.
        #expect(listed.map(\.id) == ["acut", "afinished"])
        #expect(listed.map(\.agentType) == ["general-purpose", "Explore"])
        #expect(listed.map(\.description) == ["task acut", "task afinished"])
        #expect(listed.map(\.wasInterrupted) == [true, false])
        #expect(listed.allSatisfy { !$0.isRunning })
    }

    /// Opening an entry of a stopped session shows its transcript through the subagent panel; it stays through frames that carry
    /// no run, and gives way when a run starts and the live list takes over.
    @Test func anEntryOfAStoppedSessionOpensItsTranscriptAndGivesWayToARun() async throws {
        let (rig, log) = try await fixture()
        defer { rig.cleanup() }
        let (model, id) = (rig.model, rig.ids[0])
        log.records = [stopped("a1", interrupted: true), stopped("a2")]
        model.setInspector(open: true, for: id)
        model.selectInspectorTab(.agents)
        await model.runAgentsRead()

        model.openSubagent("a1", in: id)
        #expect(model.viewedSubagent == ViewedSubagent(sessionID: id, agentID: "a1", fromFolder: true))
        #expect(model.subagentPanel != nil && model.subagentPanelState?.isRunning == false)
        #expect(model.viewedSubagentRecord()?.wasInterrupted == true)
        // An entry the list does not hold opens nothing.
        model.openSubagent("nope", in: id)
        #expect(model.viewedSubagent?.agentID == "a1")

        // A frame for the session that carries no run does not close it.
        await rig.hub.publish(sessionID: id, change: .issue("something"))
        #expect(await inspectorWaitUntil { model.liveStates[id]?.issue == "something" })
        #expect(model.viewedSubagent?.agentID == "a1")

        // A run starts: the live list is the list, and the folder's entry closes.
        await rig.goLive(0, [])
        #expect(await inspectorWaitUntil { model.viewedSubagent == nil })
    }
}
