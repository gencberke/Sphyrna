import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat

// V23, Agents live, on the catalog side: which subagent the Agents tab and the sidebar tree mark as waiting, what the open
// subagent's notice says in each face, how "Show the request" reaches the pinned card, and a stopped session's list read from
// its folder. Counting seams stand in for the folder read; nothing here opens a window or runs a program.

private let agentsT0 = Date(timeIntervalSince1970: 1_000_000)

private func hubRequest(_ id: String, agent: ProviderRequestAgent?) -> ProviderPendingRequest {
    ProviderPendingRequest(requestID: id, toolUseID: "t-" + id, kind: .approval, toolName: "Bash", summary: "ls", arrivedAt: nil, agent: agent)
}

private func liveState(_ requests: [ProviderPendingRequest] = []) -> SessionViewState {
    SessionViewState(runID: UUID(), pendingRequests: requests)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SubagentWaitingMarkTests {
    private let reviewer = ProviderRequestAgent(id: "a-reviewer", name: "reviewer", description: "Review auth")

    private func records() -> [SubagentRecord] {
        [inspectorRecord("a-explorer", type: "Explore", description: "Find the login flow", started: agentsT0),
         inspectorRecord("a-reviewer", type: "reviewer", description: "Review auth", started: agentsT0.addingTimeInterval(5))]
    }

    @Test func theSubagentWhoseRequestWaitsIsMarkedAndNoOtherIs() {
        let state = liveState([hubRequest("r1", agent: reviewer)])
        #expect(SubagentWaiting.ids(in: state) == ["a-reviewer"])

        let list = InspectorAgentsContent(records: records(), now: agentsT0, waiting: SubagentWaiting.ids(in: state))
        #expect(list.running.map(\.isWaiting) == [false, true])
        #expect(list.running[1].accessibilityLabel.hasSuffix("waiting for you"))
        #expect(list.running[0].accessibilityLabel.contains("waiting") == false)

        let tree = SubagentTreeContent(records: records(), now: agentsT0, finishedExpanded: false, runningExpanded: false,
                                       waiting: SubagentWaiting.ids(in: state))
        #expect(tree.rows.map(\.isWaiting) == [false, true])
        #expect(tree.rows[1].accessibilityLabel.contains("waiting for you"))
    }

    /// The rule: a main-thread request names no agent, so it marks none, whichever subagents run.
    @Test func aMainThreadRequestMarksNoSubagent() {
        let state = liveState([hubRequest("r1", agent: nil)])
        #expect(SubagentWaiting.ids(in: state).isEmpty)
        #expect(SubagentWaiting.ids(in: nil).isEmpty)
        let list = InspectorAgentsContent(records: records(), now: agentsT0, waiting: SubagentWaiting.ids(in: state))
        #expect(list.running.allSatisfy { !$0.isWaiting })
        let tree = SubagentTreeContent(records: records(), now: agentsT0, finishedExpanded: false, runningExpanded: false,
                                       waiting: SubagentWaiting.ids(in: state))
        #expect(tree.rows.allSatisfy { !$0.isWaiting })
        // And the notice: the Chat face knows the asker, so a main-thread request puts no notice on any subagent.
        for record in records() {
            #expect(SubagentWaiting.notice(agentID: record.id, record: record, state: state, indicator: .waitingForApproval, endpoint: .pipe) == nil)
        }
    }

    @Test func aWaitingSubagentStaysAmongTheShownRowsPastTheCapWithoutReorderingThem() {
        let many = (0..<6).map { inspectorRecord("a\($0)", description: "task \($0)", started: agentsT0.addingTimeInterval(Double($0))) }
        let plain = SubagentTreeContent(records: many, now: agentsT0, finishedExpanded: false, runningExpanded: false)
        #expect(plain.rows.map(\.id) == ["a0", "a1", "a2", "more"])
        let waiting = SubagentTreeContent(records: many, now: agentsT0, finishedExpanded: false, runningExpanded: false, waiting: ["a5"])
        #expect(waiting.rows.map(\.id) == ["a0", "a1", "a5", "more"])
        #expect(waiting.rows.first { $0.id == "a5" }?.isWaiting == true)
        #expect(waiting.rows.last?.title == "+3 more")
    }

    /// The terminal face has no hub request: the hook names the subagent, and the ledger carries the mark. The Chat face ignores
    /// that mark (its driver says when a card ends), and a main-thread prompt on the terminal marks none.
    @Test func theTerminalFacesMarkComesFromTheHooksAndTheChatFacesFromTheHub() {
        var marked = records()
        marked[0].awaitsApproval = true
        let terminal = SessionViewState(runID: UUID(), subagents: marked, reason: StatusReason(.approval(tool: "Bash")), runEndpoint: .terminal)
        #expect(SubagentWaiting.ids(in: terminal) == ["a-explorer"])
        let list = InspectorAgentsContent(records: marked, now: agentsT0, waiting: SubagentWaiting.ids(in: terminal))
        #expect(list.running.map(\.isWaiting) == [true, false])
        // The notice is on the marked subagent only, in the terminal's words; not on the other one that runs.
        #expect(SubagentWaiting.notice(agentID: "a-explorer", record: marked[0], state: terminal, indicator: .waitingForApproval, endpoint: .terminal) == .terminal)
        #expect(SubagentWaiting.notice(agentID: "a-reviewer", record: marked[1], state: terminal, indicator: .waitingForApproval, endpoint: .terminal) == nil)
        // A main-thread prompt (a hook-reported request, no subagent marked) is tied to the main thread: no notice on a running subagent.
        let main = SessionViewState(runID: UUID(), subagents: records(), reason: StatusReason(.approval(tool: "Bash")), runEndpoint: .terminal)
        #expect(SubagentWaiting.ids(in: main).isEmpty)
        #expect(SubagentWaiting.notice(agentID: "a-explorer", record: records()[0], state: main, indicator: .waitingForApproval, endpoint: .terminal) == nil)
        // The Chat face: the hook's mark is not the truth there.
        let chat = SessionViewState(runID: UUID(), subagents: marked, runEndpoint: .pipe)
        #expect(SubagentWaiting.ids(in: chat).isEmpty)
        #expect(SubagentWaiting.notice(agentID: "a-explorer", record: marked[0], state: chat, indicator: .waitingForApproval, endpoint: .pipe) == nil)
    }

    @Test func theNoticeSaysWhereToAnswerInTheFaceTheSessionRunsIn() {
        let state = liveState([hubRequest("r1", agent: reviewer)])
        let reviewing = records()[1], exploring = records()[0]
        // Chat face: on the subagent that asked, and on no other.
        let chat = SubagentWaiting.notice(agentID: reviewing.id, record: reviewing, state: state, indicator: .waitingForApproval, endpoint: .pipe)
        #expect(chat == .chat && chat?.text == "Waiting for you: answer it in the chat")
        #expect(SubagentWaiting.notice(agentID: exploring.id, record: exploring, state: state, indicator: .waitingForApproval, endpoint: .pipe) == nil)

        // Terminal face, no hook named the asker (only Claude's registry says the session waits): the request cannot be tied to a
        // main-thread one, so the running open subagent gets the notice.
        let terminal = liveState()
        let notice = SubagentWaiting.notice(agentID: exploring.id, record: exploring, state: terminal, indicator: .waitingForApproval, endpoint: .terminal)
        #expect(notice == .terminal && notice?.text == "Waiting for approval: answer it in the session's terminal")
        // Not when the session does not wait, the subagent is done, or the run is no terminal run.
        #expect(SubagentWaiting.notice(agentID: exploring.id, record: exploring, state: terminal, indicator: .working, endpoint: .terminal) == nil)
        let done = inspectorRecord("a-done", running: false)
        #expect(SubagentWaiting.notice(agentID: done.id, record: done, state: terminal, indicator: .waitingForApproval, endpoint: .terminal) == nil)
        #expect(SubagentWaiting.notice(agentID: exploring.id, record: exploring, state: terminal, indicator: .waitingForApproval, endpoint: nil) == nil)
    }

    @Test func aStoppedSessionsListSaysInterruptedAndFinishedWithoutAnyMark() {
        var cut = inspectorRecord("a-cut", running: false)
        cut.wasInterrupted = true
        let list = InspectorAgentsContent(records: [cut, inspectorRecord("a-done", running: false)], now: agentsT0)
        #expect(list.running.isEmpty && list.finished.map(\.note) == ["Interrupted", nil])
        #expect(list.finished[0].accessibilityLabel.hasSuffix("Interrupted"))
        #expect(SubagentPillContent(record: cut, now: agentsT0).label == "Interrupted")
        #expect(SubagentPillContent(record: inspectorRecord("a-done", running: false), now: agentsT0).label == "Finished 41s")
    }

    @Test func theEmptyListSaysWhatIsTrueOfTheSession() {
        #expect(InspectorAgents.emptyText(isRunning: true).hasPrefix("No subagents."))
        #expect(InspectorAgents.emptyText(isRunning: false, readsFolder: true) == "No subagents in this session.")
        #expect(InspectorAgents.emptyText(isRunning: false) == "Agents show while the session runs.")
    }
}

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

private actor NoSource: ChatLiveSource {
    func modelChanges() -> ChatModelChanges { ChatModelChanges(changes: AsyncStream { $0.finish() }) }
    func snapshotChange() -> ModelChange { TurnModel(source: .live).snapshot(sequence: 0, hasOlder: false) }
    func liveState() -> ChatLiveState { ChatLiveState(sessionID: UUID()) }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func answer(requestID: String, _ answer: ChatRequestAnswer) async throws {}
    func resume() async throws {}
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ShowTheRequestTests {
    private func request(_ id: String, agent: ChatRequestAgent?) -> ChatPendingRequest {
        let fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"],
                                           "tool_use_id": .string("toolu_" + id)]
        return ChatPendingRequest(requestID: id, request: ToolPermissionRequest(json: .object(fields))!,
                                  arrivedAt: Date(timeIntervalSince1970: 1), agent: agent)
    }

    @Test func showTheRequestMakesTheSubagentsCardTheOneShownAndMovesTheStacksScrollTarget() {
        let cards = PinnedCardsModel(source: NoSource())
        let main = request("r-main", agent: nil)
        let asked = request("r-agent", agent: ChatRequestAgent(id: "a-reviewer", type: "reviewer", description: "Review auth"))
        cards.apply(ChatLiveState(sessionID: UUID(), phase: .needsYou, requests: [main, asked], settled: []))
        #expect(cards.current?.requestID == "r-main" && cards.revealCount == 0)

        // The counting seam: the stack scrolls to `revealedRequestID` each time the count moves.
        #expect(cards.reveal(agentID: "a-reviewer"))
        #expect(cards.current?.requestID == "r-agent" && cards.revealedRequestID == "r-agent" && cards.revealCount == 1)
        // Nothing was answered.
        #expect(cards.requests.count == 2)
        // The same again scrolls again (the card may have been scrolled away since).
        #expect(cards.reveal(agentID: "a-reviewer") && cards.revealCount == 2)
    }

    @Test func aSubagentWithoutAWaitingRequestRevealsNothing() {
        let cards = PinnedCardsModel(source: NoSource())
        cards.apply(ChatLiveState(sessionID: UUID(), phase: .needsYou, requests: [request("r-main", agent: nil)], settled: []))
        #expect(cards.reveal(agentID: "a-reviewer") == false)
        #expect(cards.revealCount == 0 && cards.revealedRequestID == nil && cards.current?.requestID == "r-main")
    }
}

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
