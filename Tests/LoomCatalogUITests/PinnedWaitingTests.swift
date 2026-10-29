import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// A request that waits for the user reaches every place that says so (V18): Home's Needs you, the sidebar's reason line and
/// Active section, the Dock badge, the menu bar and the notifications, for the Chat face's requests and for Codex's, through
/// `SessionViewState.waitingRequests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PinnedWaitingTests {
    private func approval(_ id: String = "r1") -> ProviderPendingRequest {
        ProviderPendingRequest(requestID: id, toolUseID: "t-" + id, kind: .approval, toolName: "Bash", summary: "rm -rf build",
                               note: "Remove the build folder", arrivedAt: Date())
    }

    private func question() -> ProviderPendingRequest {
        ProviderPendingRequest(requestID: "q1", toolUseID: "t-q1", kind: .question, toolName: "AskUserQuestion",
                               summary: "Database", arrivedAt: Date())
    }

    private func plan() -> ProviderPendingRequest {
        ProviderPendingRequest(requestID: "p1", toolUseID: "t-p1", kind: .plan, toolName: "ExitPlanMode",
                               summary: "Plan ready", arrivedAt: Date())
    }

    @Test func aChatFaceRequestReachesHomeTheSidebarTheDockTheMenuBarAndTheNotifier() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let id = try #require(rig.ids[rig.projects[0].id]?.first)
        var badge = 0
        model.onAttentionCountChange = { badge = $0 }
        try await rig.feed(.runStarted(UUID()), for: id)
        try await rig.feed(.runEndpoint(try #require(model.liveStates[id]?.runID), .pipe), for: id)
        // The driver publishes the request, then the work state that explains it.
        try await rig.feed(.pendingRequests([approval()]), for: id)
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: id)

        #expect(model.rowModels[id]?.indicator == .waitingForApproval)
        // Home's Needs you, with what it waits for.
        let entry = try #require(model.homeBoard().needsYou.first { $0.id == id })
        #expect(entry.line == "Asks to run: rm -rf build")
        #expect(model.homeBoard().finished.isEmpty)
        // The sidebar's Active section and its reason line.
        #expect(model.activeIDs.contains(id))
        let line = try #require(SessionReasonLine(model.rowModels[id]?.reason))
        #expect(line.text == "Asks to run: rm -rf build" && line.note == "Remove the build folder")
        // The Dock badge, the same number as the lists.
        #expect(model.attentionCount == 1 && badge == 1)
        #expect(DockBadge.label(count: badge) == "1")
        #expect(model.sessionsNeedingAttention() == [id])
        // The menu bar and the banner: the session is at Needs approval, and the banner says what it is.
        #expect(model.menuBarSummary.approvals == [id])
        #expect(model.firstWaitingRequestKind(of: id) == .approval)
        let post = ApprovalNotificationPlanner.plan(previous: [], current: model.menuBarSummary.approvals, appIsActive: false, enabled: true)
        #expect(post.post == [id])
        #expect(ApprovalNotificationPlanner.body(project: "api", kind: .approval) == "api · Claude is waiting for your approval.")

        // A turn that ended with the request still open does not hide it from any of them.
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete)), for: id)
        #expect(model.rowModels[id]?.indicator == .waitingForApproval)
        #expect(model.homeBoard().needsYou.map(\.id) == [id] && model.attentionCount == 1)
        #expect(model.menuBarSummary.approvals == [id])

        // Answered: out of every one of them together.
        try await rig.feed(.pendingRequests([]), for: id)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: id)
        #expect(model.homeBoard().count == 0 && model.attentionCount == 0 && badge == 0)
        #expect(DockBadge.label(count: badge) == nil)
        #expect(model.menuBarSummary.approvals.isEmpty)
        #expect(ApprovalNotificationPlanner.plan(previous: [id], current: model.menuBarSummary.approvals, appIsActive: false,
                                                 enabled: true).remove == [id])
        #expect(model.rowModels[id]?.reason == nil)
    }

    @Test func theFirstOfSeveralRequestsIsTheReasonAndAQuestionAndAPlanSayWhatTheyAre() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 3, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let ids = try #require(rig.ids[rig.projects[0].id])
        for id in ids { try await rig.feed(.runStarted(UUID()), for: id) }
        try await rig.feed(.pendingRequests([approval("a"), approval("b")]), for: ids[0])
        try await rig.feed(.pendingRequests([question()]), for: ids[1])
        try await rig.feed(.pendingRequests([plan()]), for: ids[2])
        for id in ids { try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: id) }
        func line(_ id: UUID) -> String? { model.homeBoard().needsYou.first { $0.id == id }?.line }
        #expect(line(ids[0]) == "Asks to run: rm -rf build")
        #expect(line(ids[1]) == "Asks: Database")
        #expect(line(ids[2]) == "Plan ready for review")
        #expect(model.attentionCount == 3, "a session counts once, however many requests wait")
        #expect(model.firstWaitingRequestKind(of: ids[1]) == .question)
        #expect(model.firstWaitingRequestKind(of: ids[2]) == .plan)
        #expect(ApprovalNotificationPlanner.body(project: nil, kind: .question) == "Claude has a question for you.")
        #expect(ApprovalNotificationPlanner.body(project: "api", kind: .plan) == "api · Claude has a plan ready for your review.")
        // One answered, one still waits: the session stays at Needs you.
        try await rig.feed(.pendingRequests([approval("b")]), for: ids[0])
        #expect(model.rowModels[ids[0]]?.indicator == .waitingForApproval && model.attentionCount == 3)
    }

    @Test func aCodexRequestAndAChatFaceRequestShowTogetherAndEachLeavesOnItsOwn() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let ids = try #require(rig.ids[rig.projects[0].id])
        let (chat, codex) = (ids[0], ids[1])
        for id in ids { try await rig.feed(.runStarted(UUID()), for: id) }
        try await rig.feed(.pendingRequests([approval()]), for: chat)
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: chat)
        try await rig.feed(.userRequests([ProviderUserRequest(id: "c1", kind: .command, summary: "rm -rf build")]), for: codex)
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: codex)

        #expect(Set(model.homeBoard().needsYou.map(\.id)) == [chat, codex])
        #expect(model.attentionCount == 2 && model.menuBarSummary.approvals == [chat, codex])
        #expect(model.liveStates[chat]?.waitingRequests.map(\.requestID) == ["r1"])
        #expect(model.liveStates[codex]?.waitingRequests.map(\.requestID) == ["c1"])
        #expect(model.homeBoard().needsYou.first { $0.id == codex }?.line == "Asks to run: rm -rf build", "a Codex command reads as a Bash request does")

        // A Codex request that cannot be answered here is not a card and is not counted as one.
        let state = SessionViewState(userRequests: [ProviderUserRequest(id: "u", kind: .unsupported("userInput"), summary: "x")])
        #expect(state.waitingRequests.isEmpty && state.displayReason == nil)

        // Each leaves on its own.
        try await rig.feed(.userRequests([]), for: codex)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: codex)
        #expect(model.homeBoard().needsYou.map(\.id) == [chat] && model.attentionCount == 1)
        try await rig.feed(.pendingRequests([]), for: chat)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: chat)
        #expect(model.homeBoard().count == 0 && model.attentionCount == 0)
    }

    @Test func aRequestOfARunThatEndedLeavesNothingBehind() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 1, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let id = try #require(rig.ids[rig.projects[0].id]?.first)
        let run = UUID()
        try await rig.feed(.runStarted(run), for: id)
        try await rig.feed(.pendingRequests([approval()]), for: id)
        #expect(rig.model.liveStates[id]?.waitingRequests.count == 1)
        try await rig.feed(.runEnded(run, .processExited), for: id)
        #expect(rig.model.liveStates[id]?.waitingRequests.isEmpty != false)
        #expect(rig.model.attentionCount == 0)
        // A late list must not bring the request back to a session whose run is over (the hub drops it, so no frame follows).
        await rig.hub.publish(sessionID: id, change: .pendingRequests([approval()]))
        #expect(rig.model.liveStates[id]?.waitingRequests.isEmpty != false)
        #expect(rig.model.homeBoard().count == 0)
    }

    /// Fix 10: a Codex request reads in the words of Claude's own tools ("Asks to run: <command>", "Asks to edit: <file>"), never
    /// the raw kind ("Allow fileChange: ...").
    @Test func aCodexFileChangeReadsAsAnEditAndNeverAsItsRawKind() {
        let edit = SessionViewState(userRequests: [ProviderUserRequest(id: "f1", kind: .fileChange, summary: "src/App.swift")])
        let reason = edit.displayReason
        #expect(reason?.kind == .approval(tool: "Edit") && reason?.detail == "src/App.swift")
        #expect(edit.waitingRequests.first?.toolName == "Edit")
        let command = SessionViewState(userRequests: [ProviderUserRequest(id: "c1", kind: .command, summary: "make test")])
        #expect(command.displayReason?.kind == .approval(tool: "Bash") && command.displayReason?.detail == "make test")
        #expect(reason.flatMap(InspectorReasonText.line) == "Asks to edit: src/App.swift")
        #expect(command.displayReason.flatMap(InspectorReasonText.line) == "Asks to run: make test")
    }
}
