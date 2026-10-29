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
