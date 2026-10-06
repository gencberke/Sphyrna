import Foundation
import Testing
@testable import LoomCore

/// Sample timelines in days from the conversation's last use (day 0).
struct CleanupPlannerTests {
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private static func day(_ days: Double) -> Date {
        origin.addingTimeInterval(days * 24 * 60 * 60)
    }

    private let policy = CleanupPolicy()

    /// A conversation last used on day 0 that became stale on day 15.
    private func stale(
        lastUsed: Double = 0, staleSince: Double? = 15,
        lifecycle: SessionLifecycle = .stale, pinned: Bool = false,
        running: Bool = false, deleting: Bool = false,
        worktree: CleanupWorktreeVerdict = .clear, task: CleanupTaskLink = .none
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: UUID(), lifecycle: lifecycle, lastUsedAt: Self.day(lastUsed),
            staleSince: staleSince.map(Self.day), pinned: pinned, isRunning: running,
            isDeleting: deleting, worktree: worktree, taskLink: task
        )
    }

    private func plan(
        _ candidates: [CleanupCandidate], now: Double,
        lastRun: Double? = nil, lastLaunch: Double? = nil, policy: CleanupPolicy? = nil
    ) -> CleanupPlan {
        CleanupPlanner.plan(
            candidates: candidates, now: Self.day(now), lastRunAt: lastRun.map(Self.day),
            lastLaunchAt: lastLaunch.map(Self.day), policy: policy ?? self.policy
        )
    }

    // MARK: Per-conversation eligibility

    @Test func staleConversationWaitsUntilDay30ThenIsEligible() {
        let candidate = stale()
        #expect(plan([candidate], now: 15).excluded
            == [CleanupExclusion(id: candidate.id, reason: .waitUntil(Self.day(30)))])
        #expect(plan([candidate], now: 29).excluded
            == [CleanupExclusion(id: candidate.id, reason: .waitUntil(Self.day(30)))])
        let atThirty = plan([candidate], now: 30)
        #expect(atThirty.eligible == [CleanupEligible(id: candidate.id, eligibleSince: Self.day(30))])
        #expect(atThirty.excluded.isEmpty)
    }

    @Test func viewingAStaleRowExtendsTheWait() {
        // Viewed on day 20: last use moves to day 20, staleSince stays day 15.
        let viewed = stale(lastUsed: 20)
        #expect(plan([viewed], now: 30).excluded
            == [CleanupExclusion(id: viewed.id, reason: .waitUntil(Self.day(35)))])
        #expect(plan([viewed], now: 34).eligible.isEmpty)
        #expect(plan([viewed], now: 35).eligible == [CleanupEligible(id: viewed.id, eligibleSince: Self.day(35))])
    }

    @Test func viewingDoesNotCountFlagKeepsDay30() {
        var uncounted = CleanupPolicy()
        uncounted.viewingExtendsWait = false
        let viewed = stale(lastUsed: 20)
        #expect(plan([viewed], now: 30, policy: uncounted).eligible
            == [CleanupEligible(id: viewed.id, eligibleSince: Self.day(30))])
    }

    @Test func missingStaleSinceFallsBackToLastUseAndStaleAfter() {
        // Rows classified before schema v3 have no staleSince: lastUsed + 15 days stands in.
        let legacy = stale(staleSince: nil)
        #expect(plan([legacy], now: 29).excluded
            == [CleanupExclusion(id: legacy.id, reason: .waitUntil(Self.day(30)))])
        #expect(plan([legacy], now: 30).eligible.count == 1)
    }

    @Test func resumedConversationIsNotStale() {
        // Resumed on day 22: lifecycle is active again, even with an old staleSince.
        let resumed = stale(lastUsed: 22, lifecycle: .active)
        #expect(plan([resumed], now: 60).excluded == [CleanupExclusion(id: resumed.id, reason: .notStale)])
        let idle = stale(staleSince: nil, lifecycle: .idle)
        #expect(plan([idle], now: 60).excluded == [CleanupExclusion(id: idle.id, reason: .notStale)])
    }

    @Test func exceptionsAreExcludedWithTheirReasons() {
        let pinned = stale(pinned: true)
        let running = stale(running: true)
        let deleting = stale(deleting: true)
        let worktree = stale(worktree: .protected("3 unpushed commits"))
        let task = stale(task: .unfinished)
        let result = plan([pinned, running, deleting, worktree, task], now: 90)
        #expect(result.eligible.isEmpty)
        #expect(result.excluded == [
            CleanupExclusion(id: pinned.id, reason: .pinned),
            CleanupExclusion(id: running.id, reason: .running),
            CleanupExclusion(id: deleting.id, reason: .deleting),
            CleanupExclusion(id: worktree.id, reason: .worktree("3 unpushed commits")),
            CleanupExclusion(id: task.id, reason: .task),
        ])
    }

    @Test func pinnedIsAlwaysExcludedWhateverElseHolds() {
        let pinned = stale(pinned: true)
        #expect(plan([pinned], now: 400).excluded == [CleanupExclusion(id: pinned.id, reason: .pinned)])
        let pinnedIdle = stale(lifecycle: .idle, pinned: true)
        #expect(plan([pinnedIdle], now: 400).excluded == [CleanupExclusion(id: pinnedIdle.id, reason: .pinned)])
    }

    // MARK: Cadence

    @Test func cadenceIsLastRunPlus30DaysOfElapsedTime() {
        let candidate = stale()
        #expect(plan([candidate], now: 10, lastRun: 0).due == .notDue(until: Self.day(30)))
        #expect(plan([candidate], now: 29.9, lastRun: 0).due == .notDue(until: Self.day(30)))
        #expect(plan([candidate], now: 30, lastRun: 0).due == .due)
        #expect(plan([candidate], now: 31, lastRun: 0).due == .due)
        #expect(plan([candidate], now: 5, lastRun: nil).due == .due)
        // A calendar-month cadence would differ: runs on Jan 31, then "one month later"
        // is Feb 28 (28 days) or Mar 3 (31 days), so the gap between runs is irregular
        // (28 to 31 days). Elapsed time keeps the gap constant at 30 days.
    }

    // MARK: Review mode

    @Test func longAbsenceRequiresReview() {
        let candidate = stale()
        let absent = plan([candidate], now: 100, lastRun: 0, lastLaunch: 40)
        #expect(absent.due == .due)
        #expect(absent.mode == .reviewRequired(.longAbsence))
        // 44 days since the last launch is not yet a long absence.
        #expect(plan([candidate], now: 84, lastRun: 0, lastLaunch: 40).mode == .reviewRequired(.automaticDisabled))
    }

    @Test func bulkEligibleCountRequiresReview() {
        let many = (0..<25).map { _ in stale() }
        let result = plan(many, now: 60, lastRun: 0, lastLaunch: 59)
        #expect(result.eligible.count == 25)
        #expect(result.mode == .reviewRequired(.bulk))
        let ten = Array(many.prefix(10))
        #expect(plan(ten, now: 60, lastRun: 0, lastLaunch: 59).mode == .reviewRequired(.automaticDisabled))
    }

    @Test func defaultPolicyNeverAllowsAutomaticDeletion() {
        #expect(!CleanupPolicy().automaticDeletionEnabled)
        let timelines: [(candidates: [CleanupCandidate], launch: Double?)] = [
            ([], nil), ([stale()], nil), ([stale()], 59), ([stale(), stale()], 0),
        ]
        for timeline in timelines {
            let result = plan(timeline.candidates, now: 60, lastRun: nil, lastLaunch: timeline.launch)
            #expect(result.mode != .automaticAllowed)
        }
    }

    @Test func automaticModeOnlyWhenEnabledAndNothingForcesReview() {
        var automatic = CleanupPolicy()
        automatic.automaticDeletionEnabled = true
        let candidate = stale()
        #expect(plan([candidate], now: 60, lastRun: 0, lastLaunch: 59, policy: automatic).mode == .automaticAllowed)
        #expect(plan([candidate], now: 100, lastRun: 0, lastLaunch: 40, policy: automatic).mode == .reviewRequired(.longAbsence))
        let many = (0..<11).map { _ in stale() }
        #expect(plan(many, now: 60, lastRun: 0, lastLaunch: 59, policy: automatic).mode == .reviewRequired(.bulk))
    }

    @Test func eligibleListIsOrderedByEligibilityThenId() {
        let late = stale(lastUsed: 5, staleSince: 20)
        let early = stale()
        let result = plan([late, early], now: 60)
        #expect(result.eligible.map(\.id) == [early.id, late.id])
    }
}
