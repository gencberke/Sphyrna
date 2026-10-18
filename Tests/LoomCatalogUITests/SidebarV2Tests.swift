import Foundation
import Observation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// V04, the parts that need no window: the words of a reason line, the row's own reason property, the Home
/// row's count and its label. What the views evaluate is in `SidebarRenderTests`; what they expose to
/// VoiceOver is in `SidebarAccessibilityTests`.
/// Whether an observed read saw a write. `onChange` is `@Sendable`, so the flag is a class; the tests use it on
/// the main actor only.
final class ObservedWrite: @unchecked Sendable {
    private(set) var wrote = false

    /// Starts watching what `read` reads; the first write to any of it sets `wrote`.
    @MainActor init(_ read: @MainActor () -> Void) {
        withObservationTracking { read() } onChange: { [self] in wrote = true }
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SidebarV2Tests {
    private func approval(_ command: String = "git push origin fix/webhook-sig") -> StatusReason {
        StatusReason(.approval(tool: "Bash"), detail: command, note: "Push the branch")
    }

    // MARK: The words of a reason line

    @Test func aReasonLineSaysWhatTheSessionWaitsForOrDidLast() {
        func text(_ reason: StatusReason) -> String? { SessionReasonLine(reason)?.text }
        #expect(text(approval()) == "Allow: git push origin fix/webhook-sig")
        #expect(text(StatusReason(.approval(tool: "Write"), detail: "/tmp/ws/hello.txt")) == "Allow Write: /tmp/ws/hello.txt")
        #expect(text(StatusReason(.approval(tool: "Edit"))) == "Allow Edit")
        #expect(text(StatusReason(.approval(tool: "Bash"))) == "Asks to run a command")
        #expect(text(StatusReason(.question, detail: "PDF library")) == "Asks: PDF library")
        #expect(text(StatusReason(.question)) == "Asks a question")
        #expect(text(StatusReason(.planReady)) == "Plan ready for review")
        #expect(text(StatusReason(.input)) == "Waiting for your input")
        #expect(text(StatusReason(.turnDone, detail: "12 tests added, all pass")) == "12 tests added, all pass")
        #expect(text(StatusReason(.turnDone)) == "Turn done")
        #expect(text(StatusReason(.failure(category: "rate_limit"), detail: "Too many requests")) == "Failed: Too many requests")
        #expect(text(StatusReason(.failure(category: "rate_limit"))) == "Failed: rate limit")
        #expect(text(StatusReason(.failure(category: nil))) == "Turn failed")
        #expect(text(StatusReason(.automaticTurn, detail: "Background command finished")) == "Background command finished")
        #expect(text(StatusReason(.automaticTurn)) == "Continuing after a background task")
        #expect(SessionReasonLine(nil) == nil)
    }

    @Test func workThatStillRunsComesBeforeTheLastWords() {
        let one = StatusReason(.turnDone, detail: "Started the import", work: BackgroundWork(shells: 1))
        #expect(SessionReasonLine(one)?.text == "1 background task running · Started the import")
        let two = StatusReason(.turnDone, work: BackgroundWork(shells: 1, subagents: 1))
        #expect(SessionReasonLine(two)?.text == "2 background tasks running")
        // A schedule is not running work.
        let scheduled = StatusReason(.turnDone, detail: "Done", work: BackgroundWork(scheduled: 2))
        #expect(SessionReasonLine(scheduled)?.text == "Done")
    }

    @Test func theTooltipAddsTheCommandsOwnDescription() {
        let line = SessionReasonLine(approval())
        #expect(line?.help == "Allow: git push origin fix/webhook-sig\nPush the branch")
        #expect(SessionReasonLine(StatusReason(.planReady))?.help == "Plan ready for review")
    }

    @Test func theAccessibilityLabelNamesTheReasonAfterTheState() {
        let label = SessionCardView.accessibilityLabel(
            title: "Webhook", provider: .claude, status: "Needs approval", reason: "Allow: git push",
            origin: nil, pinned: true)
        #expect(label == "Webhook, Claude, Needs approval, Allow: git push, pinned")
        // Without a reason the label is what it was.
        #expect(SessionCardView.accessibilityLabel(
            title: "Webhook", provider: .claude, status: "Working", origin: nil, pinned: false) == "Webhook, Claude, Working")
    }

    @Test func theProjectViewListsOneLineRowsAndTheActivityViewKeepsTheCard() {
        #expect(SessionCardView.isOneLine(mode: .projects))
        #expect(!SessionCardView.isOneLine(mode: .activity))
    }

    // MARK: The row's own reason

    @Test func aRowHoldsItsReasonAndWritesItOnlyWhenItDiffers() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 4, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let ids = try #require(rig.ids[rig.projects[0].id])
        let target = try #require(model.list(for: .activity).rows.first { $0.id == ids[0] })
        let other = try #require(model.list(for: .activity).rows.first { $0.id == ids[1] })
        #expect(target.reason == nil)

        try await rig.feed(.runStarted(UUID()), for: ids[0])
        try await rig.feed(.runStarted(UUID()), for: ids[1])
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: ids[0])
        // Only a row of the Active section carries the reason line; the flag follows the section, per row.
        #expect(target.inActiveSection && !other.inActiveSection)

        // The reason arrives before the status it explains; only the row it belongs to changes.
        let targetWrite = ObservedWrite { _ = target.reason }
        let otherWrite = ObservedWrite { _ = other.reason }
        try await rig.feed(.reason(approval()), for: ids[0])
        #expect(targetWrite.wrote && !otherWrite.wrote)
        #expect(target.reason == approval() && other.reason == nil)

        // The status it explains, then frames that carry the same reason: nothing is written.
        let rewrite = ObservedWrite { _ = target.reason }
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: ids[0])
        try await rig.feed(.blockers([.ambiguousIdentity]), for: ids[0])
        #expect(!rewrite.wrote, "an equal reason is not a write")

        // A new reason replaces it; the end of the run drops an approval that can no longer be answered.
        try await rig.feed(.reason(StatusReason(.question, detail: "Color")), for: ids[0])
        #expect(target.reason == StatusReason(.question, detail: "Color"))
        try await rig.feed(.runEnded(try #require(target.live?.runID), .processExited), for: ids[0])
        #expect(target.reason == nil && !target.inActiveSection)
    }

    @Test func aFinishedTurnsLastLineOutlivesItsRun() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let id = try #require(rig.ids[rig.projects[0].id]?.first)
        let row = try #require(rig.model.list(for: .activity).rows.first { $0.id == id })
        let run = UUID()
        try await rig.feed(.runStarted(run), for: id)
        try await rig.feed(.reason(StatusReason(.turnDone, detail: "12 tests added")), for: id)
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete)), for: id)
        try await rig.feed(.runEnded(run, .processExited), for: id)
        #expect(row.reason == StatusReason(.turnDone, detail: "12 tests added"))
        #expect(SessionReasonLine(row.reason)?.text == "12 tests added")
    }

    // MARK: The Home row

    @Test func theHomeRowLabelNamesTheCountOfWhatNeedsYou() {
        #expect(HomeRow.accessibilityLabel(count: 0) == "Home")
        #expect(HomeRow.accessibilityLabel(count: 1) == "Home, 1 session needs you")
        #expect(HomeRow.accessibilityLabel(count: 3) == "Home, 3 sessions need you")
    }

    @Test func theHomeCountIsObservedAndWrittenOnlyWhenItChanges() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 4, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let ids = try #require(rig.ids[rig.projects[0].id])
        #expect(model.attentionCount == 0)

        let working = ObservedWrite { _ = model.attentionCount }
        try await rig.feed(.runStarted(UUID()), for: ids[0])
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: ids[0])
        #expect(!working.wrote, "a working session does not need you")

        let first = ObservedWrite { _ = model.attentionCount }
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: ids[0])
        #expect(model.attentionCount == 1 && first.wrote)

        // Another kind of need for the same session, and a reason: the count is the same, nothing is written.
        let same = ObservedWrite { _ = model.attentionCount }
        try await rig.feed(.reason(approval()), for: ids[0])
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForInput)), for: ids[0])
        #expect(model.attentionCount == 1 && !same.wrote)

        let second = ObservedWrite { _ = model.attentionCount }
        try await rig.feed(.runStarted(UUID()), for: ids[1])
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: ids[1])
        #expect(model.attentionCount == 2 && second.wrote)

        // Marking one read and answering the other bring it back to nothing.
        rig.model.markRead(ids[0])
        await rig.model.settle()
        try await rig.applyNextFrame()
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: ids[1])
        #expect(model.attentionCount == 0)
    }
}
