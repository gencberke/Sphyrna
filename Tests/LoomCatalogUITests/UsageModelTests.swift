import Foundation
import Darwin
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UsageModelTests {
    private func model(
        _ index: FakeUsageIndex, debounce: Duration = .milliseconds(40), cooldown: Duration = .zero,
        limits: (any PlanLimitsFetching)? = nil, clock: TestClock? = nil
    ) -> UsageModel {
        UsageModel(index: index, limits: limits, clock: { clock?.now ?? Date() },
                   timeZone: TimeZone(identifier: "UTC")!, debounce: debounce, activationCooldown: cooldown)
    }

    @Test func firstRefreshIsIndexingThenReadyAndLaterOnesStayReady() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        #expect(usage.state == .idle)
        #expect(usage.chip == nil)
        index.setBlocking(true)
        usage.refresh(reason: .launch)
        while index.refreshCalls == 0 { await Task.yield() }
        #expect(usage.state == .indexing) // nothing indexed yet: the very first scan
        index.setTokens(1_200_000)
        #expect(usage.chip?.kind == .indexing)
        index.release()
        await usage.settle()
        #expect(usage.state == .ready)
        #expect(usage.chip?.full == "1.2M today")
        #expect(usage.updatedAt != nil)
        index.setBlocking(true)
        usage.refresh(reason: .manual)
        await Task.yield()
        #expect(usage.state == .ready) // a warm refresh never flips the footer back to indexing
        #expect(usage.isRefreshing)
        index.release()
        await usage.settle()
        #expect(!usage.isRefreshing)
    }

    @Test func turnCompletionBurstIsDebouncedIntoOneRefresh() async throws {
        let index = FakeUsageIndex()
        let usage = model(index, debounce: .milliseconds(250))
        for _ in 0..<3 {
            usage.refresh(reason: .turnComplete)
            try await Task.sleep(for: .milliseconds(30))
            #expect(index.refreshCalls == 0) // still waiting out the debounce
        }
        await usage.settle()
        #expect(index.refreshCalls == 1)
        usage.refresh(reason: .turnComplete)
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func requestsDuringARunningRefreshCoalesceIntoOneMoreRun() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        index.setBlocking(true)
        usage.refresh(reason: .manual)
        while index.refreshCalls == 0 { await Task.yield() } // the scan is running
        for _ in 0..<5 { usage.refresh(reason: .manual) }
        index.release()
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func activationDuringARunningRefreshAddsNoRun() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        index.setBlocking(true)
        usage.refresh(reason: .launch)
        await Task.yield()
        usage.refresh(reason: .activation)
        index.release()
        await usage.settle()
        #expect(index.refreshCalls == 1)
    }

    @Test func activationInsideTheCooldownReadsNothing() async {
        let index = FakeUsageIndex()
        let usage = model(index, cooldown: .seconds(60))
        usage.refresh(reason: .launch)
        await usage.settle()
        usage.refresh(reason: .activation)
        await usage.settle()
        #expect(index.refreshCalls == 1)
        usage.refresh(reason: .settingsOpened)
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func turnCompleteFramesRefreshAndOtherChangesDoNot() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        usage.observeTurnCompletions(3) // the first frame only sets the baseline
        usage.observeTurnCompletions(3)
        await usage.settle()
        #expect(index.refreshCalls == 0)
        usage.observeTurnCompletions(4) // a frame that skipped three turns still counts once
        await usage.settle()
        #expect(index.refreshCalls == 1)
    }

    @Test func switchingPeriodsReadsTheIndexButNeverRescansFiles() async {
        let index = FakeUsageIndex()
        index.setTokens(5_000)
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        #expect(usage.report?.period == .days7)
        #expect(index.refreshCalls == 1)
        usage.select(.days30)
        await usage.settle()
        #expect(usage.period == .days30)
        #expect(usage.report?.period == .days30)
        usage.select(.hours24)
        await usage.settle()
        #expect(usage.report?.period == .hours24)
        #expect(usage.report?.bars.count == 24)
        usage.select(.days7) // cached: no further index traffic
        let calls = index.snapshotRanges.count
        #expect(usage.report?.period == .days7)
        #expect(index.snapshotRanges.count == calls)
        #expect(index.refreshCalls == 1)
    }

    @Test func aFailedFirstScanIsFailedAndALaterFailureKeepsTheData() async {
        let index = FakeUsageIndex()
        index.setTokens(900)
        index.setFailing(true)
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        guard case .failed = usage.state else { Issue.record("expected failed, got \(usage.state)"); return }
        #expect(usage.chip == nil)
        index.setFailing(false)
        await usage.refreshNow(reason: .manual)
        #expect(usage.state == .ready)
        index.setFailing(true)
        await usage.refreshNow(reason: .manual)
        #expect(usage.state == .ready)
        #expect(usage.lastFailure == "index unavailable")
        #expect(usage.chip?.kind == .today)
    }

    @Test func indexWorkNeverRunsOnTheMainThread() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        usage.select(.hours24)
        await usage.settle()
        #expect(index.refreshCalls == 1)
        #expect(!index.ranOnMainThread)
    }

    @Test func aRefreshWithUnchangedNumbersDoesNotInvalidateTheChipReaders() async {
        let index = FakeUsageIndex()
        index.setTokens(2_500_000)
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        let invalidated = Mutex(false)
        withObservationTracking { _ = usage.chip } onChange: { invalidated.withLock { $0 = true } }
        await usage.refreshNow(reason: .manual) // new asOf, same figures
        usage.select(.days90)
        await usage.settle()
        #expect(!invalidated.withLock { $0 })
        index.setTokens(2_600_000)
        await usage.refreshNow(reason: .manual)
        #expect(invalidated.withLock { $0 })
    }

    @Test func dayPeriodsFillEmptyDaysAndMarkToday() async {
        let index = FakeUsageIndex()
        index.setTokens(10)
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        let bars = usage.report?.bars ?? []
        #expect(bars.count == 7)
        #expect(bars.last?.isCurrent == true)
        #expect(bars.dropLast().allSatisfy { !$0.isCurrent })
        #expect(usage.report?.cells.count == 5)
    }
}

// MARK: Freshness and plan limits

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UsageFreshnessTests {
    private func model(
        _ index: FakeUsageIndex, limits: (any PlanLimitsFetching)? = nil, clock: TestClock? = nil,
        debounce: Duration = .milliseconds(40), cooldown: Duration = .zero
    ) -> UsageModel {
        UsageModel(index: index, limits: limits, clock: { clock?.now ?? Date() },
                   timeZone: TimeZone(identifier: "UTC")!, debounce: debounce, activationCooldown: cooldown)
    }

    private let transcript = URL(fileURLWithPath: "/tmp/profile/projects/-p/session.jsonl")

    /// The Settings window is key: the main window is not active, the Usage page is visible.
    private func showUsagePageOnly(_ usage: UsageModel) {
        usage.windowActivityChanged(false)
        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
    }

    @Test func aTranscriptChangeRefreshesWhileOnlyTheUsagePageIsVisible() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        showUsagePageOnly(usage)
        await usage.settle()
        let before = index.refreshCalls
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        await usage.settle()
        #expect(index.changedCalls == [[transcript]])
        #expect(index.refreshCalls == before) // only the changed file, no full walk
    }

    @Test func aFinishedTurnRefreshesWhileOnlyTheUsagePageIsVisible() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        usage.observeTurnCompletions(0)
        await usage.refreshNow(reason: .launch)
        showUsagePageOnly(usage)
        await usage.settle()
        let before = index.refreshCalls
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(index.refreshCalls == before + 1) // before the page counted as a reader this only marked stale
    }

    @Test func nothingIsReadWhileNoWindowIsVisibleAndTheNextActivationReadsOnce() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        usage.windowActivityChanged(false)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        usage.transcriptsChanged(UsageTranscriptChange(paths: [], needsFullScan: true))
        usage.observeTurnCompletions(0)
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(index.refreshCalls == 1 && index.changedCalls.isEmpty)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2) // one full read covers everything that happened
        #expect(index.changedCalls.isEmpty)
    }

    @Test func aBurstOfTranscriptChangesIsOneReadOfTheUnionOfTheFiles() async {
        let index = FakeUsageIndex()
        let usage = model(index, debounce: .milliseconds(150))
        await usage.refreshNow(reason: .launch)
        let other = URL(fileURLWithPath: "/tmp/profile/projects/-p/other.jsonl")
        for path in [transcript, other, transcript] {
            usage.transcriptsChanged(UsageTranscriptChange(paths: [path], needsFullScan: false))
        }
        #expect(index.changedCalls.isEmpty) // still inside the debounce
        await usage.settle()
        #expect(index.changedCalls.count == 1)
        #expect(Set(index.changedCalls[0]) == [transcript, other])
    }

    @Test func changesBeforeTheFirstFullScanAreLeftToIt() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        await usage.settle()
        #expect(index.refreshCalls == 0 && index.changedCalls.isEmpty)
        usage.refresh(reason: .launch) // still starts: no partial read took its place
        await usage.settle()
        #expect(index.refreshCalls == 1)
    }

    @Test func lostEventsAskForAFullScan() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: true))
        await usage.settle()
        #expect(index.refreshCalls == 2 && index.changedCalls.isEmpty)
    }

    @Test func aChipOnlyReadSkipsThePeriodReportUntilThePageShows() async {
        let index = FakeUsageIndex()
        index.setTokens(1_000)
        let usage = model(index)
        await usage.refreshNow(reason: .launch) // main window active, page closed
        let ranges = index.snapshotRanges.count
        index.setTokens(5_000)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        await usage.settle()
        #expect(index.snapshotRanges.dropFirst(ranges).allSatisfy { $0 == .days(1) }) // today's summary only
        #expect(usage.chip?.full == "5K today")
        #expect(usage.report?.snapshot.tokens.total == 1_000) // the page's report waits for the page
        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
        await usage.settle()
        #expect(usage.report?.snapshot.tokens.total == 5_000)
    }

    // MARK: A finished turn with the transcript watcher running

    @Test func aFinishedTurnWithTheWatcherRunningWalksNoTranscripts() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        usage.setTranscriptWatcherRunning(true)
        usage.observeTurnCompletions(0)
        await usage.refreshNow(reason: .launch)
        #expect(index.refreshCalls == 1) // the launch walk
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(index.refreshCalls == 1 && index.changedCalls.isEmpty) // the watcher reads the file; the turn does not
    }

    @Test func withoutAWatcherAFinishedTurnStillWalksEveryTranscript() async {
        let index = FakeUsageIndex()
        let usage = model(index) // the watcher never started, or the profile has no projects folder
        usage.observeTurnCompletions(0)
        await usage.refreshNow(reason: .launch)
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(index.refreshCalls == 2 && index.changedCalls.isEmpty)
    }

    @Test func aTranscriptEventAfterTheTurnDebounceStillUpdatesTheNumbers() async {
        let index = FakeUsageIndex()
        index.setTokens(1_000)
        let usage = model(index)
        usage.setTranscriptWatcherRunning(true)
        usage.observeTurnCompletions(0)
        await usage.refreshNow(reason: .launch)
        #expect(usage.chip?.full == "1K today")
        usage.observeTurnCompletions(1)
        await usage.settle() // the turn's debounce has run out and read nothing
        #expect(index.changedCalls.isEmpty)
        index.setTokens(5_000)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false)) // the late write
        await usage.settle()
        #expect(index.changedCalls == [[transcript]])
        #expect(index.refreshCalls == 1)
        #expect(usage.chip?.full == "5K today")
    }

    @Test func aTranscriptEventBeforeTheTurnEndsIsReadOnceForJustThatFile() async {
        let index = FakeUsageIndex()
        let usage = model(index, debounce: .milliseconds(150))
        usage.setTranscriptWatcherRunning(true)
        usage.observeTurnCompletions(0)
        await usage.refreshNow(reason: .launch)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        usage.observeTurnCompletions(1) // joins the same debounce
        await usage.settle()
        #expect(index.changedCalls == [[transcript]] && index.refreshCalls == 1)
    }

    @Test func lostEventsStillWalkEverythingWhileTheWatcherRuns() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        usage.setTranscriptWatcherRunning(true)
        usage.observeTurnCompletions(0)
        await usage.refreshNow(reason: .launch)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [], needsFullScan: true))
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(index.refreshCalls == 2 && index.changedCalls.isEmpty) // one walk covers both
    }

    @Test func theLimitsAskAfterATurnIsUnchangedWhileTheWatcherRuns() async {
        let clock = TestClock()
        let source = FakeLimits()
        let usage = model(FakeUsageIndex(), limits: source, clock: clock)
        usage.setTranscriptWatcherRunning(true)
        usage.observeTurnCompletions(0)
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(source.asks == 1)
        clock.advance(121)
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(source.asks == 2)
    }

    // MARK: Coming back with the watcher running

    /// The watcher runs and the launch scan is done: the state the release app is in.
    private func watched(
        _ index: FakeUsageIndex, clock: TestClock? = nil, cooldown: Duration = .zero
    ) async -> UsageModel {
        let usage = model(index, clock: clock, cooldown: cooldown)
        usage.setTranscriptWatcherRunning(true)
        await usage.refreshNow(reason: .launch)
        return usage
    }

    @Test func comingBackReadsOnlyTheTranscriptsThatChangedWhileHidden() async {
        let index = FakeUsageIndex()
        let usage = await watched(index)
        usage.windowActivityChanged(false)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        await usage.settle()
        #expect(index.changedCalls.isEmpty) // nobody is looking: collected, not read
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.changedCalls == [[transcript]])
        #expect(index.refreshCalls == 1)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.changedCalls.count == 1 && index.refreshCalls == 1) // collected once, read once
    }

    @Test func changedTranscriptsAreReadInsideTheActivationCooldownToo() async {
        let index = FakeUsageIndex()
        let usage = await watched(index, cooldown: .seconds(60))
        usage.windowActivityChanged(false)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.changedCalls == [[transcript]] && index.refreshCalls == 1)
    }

    @Test func comingBackAfterTheDebounceRanOutKeepsWhatWasCollected() async throws {
        let index = FakeUsageIndex()
        let usage = await watched(index)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false)) // debounce starts
        usage.windowActivityChanged(false)
        await usage.settle() // the debounce ends with everyone looking away
        #expect(index.changedCalls.isEmpty)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.changedCalls == [[transcript]] && index.refreshCalls == 1)
    }

    @Test func aFinishedTurnWhileHiddenIsCoveredByTheTranscriptWrite() async {
        let index = FakeUsageIndex()
        let usage = await watched(index)
        usage.observeTurnCompletions(0)
        usage.windowActivityChanged(false)
        usage.observeTurnCompletions(1)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        await usage.settle()
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.changedCalls == [[transcript]] && index.refreshCalls == 1)
    }

    @Test func comingBackWithNothingChangedReadsNothing() async {
        let index = FakeUsageIndex()
        let usage = await watched(index, clock: TestClock())
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true) // the cooldown is zero: it has passed
        await usage.settle()
        #expect(index.refreshCalls == 1 && index.changedCalls.isEmpty)
    }

    @Test func anOverflowWhileHiddenGivesOneFullScanWhenComingBack() async {
        let index = FakeUsageIndex()
        let usage = await watched(index)
        usage.windowActivityChanged(false)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        usage.transcriptsChanged(UsageTranscriptChange(paths: [], needsFullScan: true))
        await usage.settle()
        #expect(index.refreshCalls == 1)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2 && index.changedCalls.isEmpty) // the walk covers the named file
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func aNewDayWhileHiddenGivesOneFullScanWhenComingBack() async {
        let clock = TestClock()
        let index = FakeUsageIndex()
        let usage = await watched(index, clock: clock)
        usage.windowActivityChanged(false)
        clock.advance(86_400)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2 && index.changedCalls.isEmpty)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true) // the same day again
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func aChangeReadOnComingBackStillFillsThePageWhenItOpens() async {
        let index = FakeUsageIndex()
        index.setTokens(1_000)
        let usage = await watched(index)
        usage.windowActivityChanged(false)
        index.setTokens(5_000)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(usage.chip?.full == "5K today")
        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
        await usage.settle()
        #expect(usage.report?.snapshot.tokens.total == 5_000)
    }

    @Test func withoutAWatcherComingBackStillWalksEverythingAfterAChange() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        await usage.refreshNow(reason: .launch)
        usage.windowActivityChanged(false)
        usage.transcriptsChanged(UsageTranscriptChange(paths: [transcript], needsFullScan: false))
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2 && index.changedCalls.isEmpty)
    }

    // MARK: Plan limits

    private func limits(
        five: Int? = 38, week: Int? = 20, fetchedAt: Date = Date(timeIntervalSince1970: 1_791_374_400)
    ) -> PlanLimits {
        PlanLimits(
            fiveHour: five.map { PlanLimitWindow(usedPercent: $0, resetsAt: fetchedAt.addingTimeInterval(3 * 3_600)) },
            weekly: week.map { PlanLimitWindow(usedPercent: $0, resetsAt: fetchedAt.addingTimeInterval(4 * 86_400)) },
            fetchedAt: fetchedAt)
    }

    @Test func limitsAreAskedWhenTheFirstWindowShowsAndReachTheChip() async {
        let index = FakeUsageIndex()
        index.setTokens(1_200_000)
        let source = FakeLimits()
        source.setAnswer(limits())
        let usage = model(index, limits: source, clock: TestClock())
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(source.asks == 1)
        #expect(usage.limits == limits())
        #expect(usage.chip?.full == "1.2M today · 5h 62%")
    }

    @Test func aFailedAskIsShownUntilANewAskSucceeds() async {
        let clock = TestClock()
        let source = FakeLimits()
        let failure = PlanLimitsFailure(category: .timedOut, at: clock.now)
        source.setFailure(failure)
        let usage = model(FakeUsageIndex(), limits: source, clock: clock)
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(usage.limits == nil)
        #expect(usage.limitsFailure == failure)

        // The next ask answers: the failure is gone, whatever the source still remembers.
        clock.advance(400)
        source.setAnswer(limits())
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(source.asks == 2)
        #expect(usage.limits == limits())
        #expect(usage.limitsFailure == nil)

        // A later failure keeps the earlier answer and records why it was not refreshed.
        clock.advance(400)
        source.setAnswer(nil)
        source.setFailure(PlanLimitsFailure(category: .notAvailable, at: clock.now))
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(usage.limits == limits())
        #expect(usage.limitsFailure?.category == .notAvailable)
    }

    @Test func aCancelledAskIsNotAFailure() async {
        let source = FakeLimits()
        source.setFailure(PlanLimitsFailure(category: .cancelled, at: Date()))
        let usage = model(FakeUsageIndex(), limits: source, clock: TestClock())
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(source.asks == 1)
        #expect(usage.limitsFailure == nil)
    }

    @Test func linesTheScansDidNotUnderstandReachThePage() async {
        let index = FakeUsageIndex()
        let usage = model(index, clock: TestClock())
        await usage.refreshNow(reason: .launch)
        #expect(usage.linesNotUnderstood == 0)
        index.setLinesNotUnderstood(3)
        await usage.refreshNow(reason: .manual)
        #expect(usage.linesNotUnderstood == 3)
        #expect(UsageText.skippedLines(3) == "3 usage records could not be understood, so totals may be low.")
        #expect(UsageText.skippedLines(1) == "1 usage record could not be understood, so totals may be low.")
        #expect(UsageText.skippedLines(0) == nil)
        #expect(await usage.diagnosticsSnapshot().usage.linesNotUnderstood == 3)
    }

    @Test func everyFailureCategoryHasAShortReasonExceptCancellation() {
        let categories: [PlanLimitsFailure.Category] = [
            .noToolchain, .spawnFailed, .writeFailed, .timedOut, .endedWithoutAnswer, .outputTooLarge, .notAvailable,
        ]
        for category in categories { #expect(!(category.reason ?? "").isEmpty, "\(category)") }
        #expect(PlanLimitsFailure.Category.cancelled.reason == nil)
    }

    @Test func aWindowShowingAgainAsksOnlyWhenTheLastAskIsFiveMinutesOld() async {
        let clock = TestClock()
        let source = FakeLimits()
        source.setAnswer(limits())
        let usage = model(FakeUsageIndex(), limits: source, clock: clock)
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(source.asks == 1)
        clock.advance(299)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(source.asks == 1)
        clock.advance(2)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(source.asks == 2)
    }

    @Test func aFinishedTurnAsksOnlyWhenTheLastAskIsTwoMinutesOld() async {
        let clock = TestClock()
        let source = FakeLimits()
        let usage = model(FakeUsageIndex(), limits: source, clock: clock)
        usage.observeTurnCompletions(0)
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(source.asks == 1)
        clock.advance(119)
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(source.asks == 1)
        clock.advance(2)
        usage.observeTurnCompletions(2)
        await usage.settle()
        #expect(source.asks == 2)
    }

    @Test func openingTheUsagePageAsksUnlessTheLastAskIsTenSecondsFresh() async {
        let clock = TestClock()
        let source = FakeLimits()
        let usage = model(FakeUsageIndex(), limits: source, clock: clock)
        usage.refresh(reason: .launch)
        await usage.settle()
        clock.advance(5)
        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
        await usage.settle()
        #expect(source.asks == 1)
        usage.setUsageSectionSelected(false)
        clock.advance(6)
        usage.setUsageSectionSelected(true)
        await usage.settle()
        #expect(source.asks == 2)
    }

    @Test func limitsAreNeverAskedWhileNoWindowIsVisible() async {
        let clock = TestClock()
        let source = FakeLimits()
        let usage = model(FakeUsageIndex(), limits: source, clock: clock)
        usage.observeTurnCompletions(0)
        usage.windowActivityChanged(false)
        usage.refresh(reason: .launch)
        await usage.settle()
        clock.advance(3_600)
        usage.observeTurnCompletions(1)
        await usage.settle()
        #expect(source.asks == 0)
        usage.windowActivityChanged(true) // the first window to show asks
        await usage.settle()
        #expect(source.asks == 1)
    }

    @Test func twoAsksNeverRunAtOnce() async {
        let clock = TestClock()
        let source = FakeLimits()
        source.setBlocking(true)
        let usage = model(FakeUsageIndex(), limits: source, clock: clock)
        usage.observeTurnCompletions(0)
        usage.refresh(reason: .launch)
        while source.asks == 0 { await Task.yield() }
        clock.advance(3_600)
        usage.observeTurnCompletions(1)
        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
        #expect(source.asks == 1)
        source.release()
        await usage.settle()
        #expect(source.asks == 1)
    }

    @Test func aFailedAskKeepsTheLastLimitsAndALimitsChangeNeedsNoRead() async {
        let clock = TestClock()
        let index = FakeUsageIndex()
        index.setTokens(1_200_000)
        let source = FakeLimits()
        source.setAnswer(limits())
        let usage = model(index, limits: source, clock: clock)
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(usage.chip?.limit == .init(name: "5h", remainingPercent: 62))
        let reads = index.refreshCalls
        source.setAnswer(limits(five: 90))
        clock.advance(400)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(usage.chip?.limit == .init(name: "5h", remainingPercent: 10))
        source.setAnswer(nil) // a failed ask (offline after wake, a timeout): keep the last answer, no banner
        clock.advance(400)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(usage.limits?.fiveHour?.usedPercent == 90)
        #expect(usage.chip?.limit == .init(name: "5h", remainingPercent: 10))
        #expect(usage.lastFailure == nil)
        #expect(index.refreshCalls >= reads) // the activations may read; the limits themselves never do
    }

    @Test func theMinuteTickDropsAWindowThatEndedWithoutAnyRead() async {
        let clock = TestClock()
        let index = FakeUsageIndex()
        index.setTokens(1_200_000)
        let source = FakeLimits()
        source.setAnswer(limits(five: 90, week: 20)) // the five-hour window resets in 3 h
        let usage = model(index, limits: source, clock: clock)
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(usage.chip?.limit == .init(name: "5h", remainingPercent: 10))
        let reads = index.refreshCalls
        // The window stays visible but another app is in front: the tick still drops the ended window.
        usage.windowActivityChanged(false)
        clock.advance(3 * 3_600 + 60)
        usage.minuteTick()
        #expect(usage.chip?.limit == .init(name: "Wk", remainingPercent: 80))
        #expect(index.refreshCalls == reads)
        #expect(source.asks == 1)
    }
}

/// The model over the real index and a throwaway Claude profile: the numbers on screen are the
/// fixture's deduplicated truth.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UsageModelRealIndexTests {
    private func line(id: String, ts: String, input: Int, output: Int, cacheRead: Int) -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"requestId\":\"req_\(id)\",\"sessionId\":\"sess-1\","
            + "\"isSidechain\":false,\"message\":{\"id\":\"\(id)\",\"model\":\"claude-haiku-4-5-20251001\","
            + "\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\"input_tokens\":\(input),"
            + "\"cache_read_input_tokens\":\(cacheRead),\"output_tokens\":\(output)}}}"
    }

    @Test func todayAndSevenDayTotalsEqualTheDeduplicatedFixture() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-usage-ui-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config", isDirectory: true)
        let project = config.appendingPathComponent("projects/-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(config.path, 0o700)
        let first = line(id: "msg_a", ts: "2026-10-07T09:00:00.000Z", input: 1_000_000, output: 200_000, cacheRead: 500_000)
        let second = line(id: "msg_b", ts: "2026-10-07T11:00:00.000Z", input: 100_000, output: 50_000, cacheRead: 0)
        let yesterday = line(id: "msg_c", ts: "2026-10-06T12:00:00.000Z", input: 10_000, output: 5_000, cacheRead: 0)
        // msg_a is written twice (Claude writes one message once per content block).
        try [first, first, second, yesterday].joined(separator: "\n").appending("\n")
            .write(to: project.appendingPathComponent("sess-1.jsonl"), atomically: true, encoding: .utf8)

        let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07T12:00:00Z
        let profile = ClaudeProfileLayout(profileDirectory: config, environment: [:], home: root)
        let index = ClaudeUsageIndex(databaseURL: root.appendingPathComponent("usage-index.sqlite3"),
                                     profile: profile, clock: { now })
        let usage = UsageModel(index: index, clock: { now }, timeZone: TimeZone(identifier: "UTC")!)
        await usage.refreshNow(reason: .launch)

        #expect(usage.state == .ready)
        // Today: msg_a + msg_b once each. Tokens 1,700,000 + 150,000; cost 2.05 + 0.35 = $2.40.
        let chip = try #require(usage.chip)
        #expect(chip.full == "1.85M today")
        #expect(!chip.tooltip.contains("$") && !chip.accessibilityLabel.contains("$"))
        #expect(chip.tooltip.contains("1,850,000 tokens: input 1,100,000, output 250,000, cache write 0, cache read 500,000."))
        // Seven days add yesterday: 15,000 tokens, $0.035.
        let report = try #require(usage.report)
        #expect(report.snapshot.tokens.total == 1_865_000)
        #expect(report.bars.count == 7)
        #expect(report.bars.last?.tokens == 1_850_000)
        #expect(report.bars.dropLast().last?.tokens == 15_000)
        #expect(abs(report.snapshot.estimatedCostUSD - 2.435) < 1e-9)
        // The five hourly cells are 08:00 to 12:00: msg_a sits in 09:00, msg_b in 11:00.
        #expect(report.cells.map(\.tokens) == [0, 1_700_000, 0, 150_000, 0])
        // The real index answers with its own scan report, not the protocol's empty default.
        #expect(await usage.diagnosticsSnapshot().usage.lastScanAt != nil)
        // A second refresh with no file growth keeps the figures and reads nothing new.
        await usage.refreshNow(reason: .manual)
        #expect(usage.report?.snapshot.tokens.total == 1_865_000)
    }


    /// The app's wiring without the app: a file-system stream over the profile's `projects` folder
    /// feeding the model, the Settings window the only visible one, no hook and no event.
    @Test func aTranscriptAppendedByAnotherProcessMovesTheChipWithNoHook() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-usage-live-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config", isDirectory: true)
        let project = config.appendingPathComponent("projects/-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(config.path, 0o700)
        let file = project.appendingPathComponent("sess-1.jsonl")
        try (line(id: "msg_a", ts: "2026-10-07T09:00:00.000Z", input: 1_000, output: 0, cacheRead: 0) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07T12:00:00Z
        let profile = ClaudeProfileLayout(profileDirectory: config, environment: [:], home: root)
        let index = ClaudeUsageIndex(databaseURL: root.appendingPathComponent("usage-index.sqlite3"),
                                     profile: profile, clock: { now })
        let usage = UsageModel(index: index, clock: { now }, timeZone: TimeZone(identifier: "UTC")!,
                               debounce: .milliseconds(100), activationCooldown: .zero)
        await usage.refreshNow(reason: .launch)
        #expect(usage.chip?.full == "1K today")
        usage.windowActivityChanged(false) // Settings is key, the main window is not
        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
        await usage.settle()

        let watcher = UsageTranscriptWatcher(directory: profile.projectsDirectory, latency: 0.1) { [weak usage] change in
            Task { @MainActor in usage?.transcriptsChanged(change) }
        }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(500))
        let appended = line(id: "msg_b", ts: "2026-10-07T11:00:00.000Z", input: 2_000_000, output: 0, cacheRead: 0)
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "printf '%s\\n' \"$1\" >> \"$2\"", "sh", appended, file.path]
        try writer.run()
        writer.waitUntilExit()

        let deadline = ContinuousClock.now + .seconds(15)
        while usage.chip?.full != "2M today", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(usage.chip?.full == "2M today")
        #expect(usage.report?.snapshot.tokens.total == 2_001_000) // the page is visible, so its report followed too
    }


    // MARK: OPT1 - what a refresh asks of the index

    /// The real index behind a counter: which index calls one refresh makes.
    private final class CountingIndex: UsageIndexing, @unchecked Sendable {
        let base: ClaudeUsageIndex
        private let counts = Mutex<[String: Int]>([:])
        /// The report of every scan, in order (whole walks and changed-file reads alike).
        private let reports = Mutex<[UsageScanReport]>([])
        var scanReports: [UsageScanReport] { reports.withLock { $0 } }
        init(_ base: ClaudeUsageIndex) { self.base = base }
        func count(_ name: String) -> Int { counts.withLock { $0[name] ?? 0 } }
        private func bump(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }

        func refreshAll() async throws -> UsageScanReport { try await record(base.refresh(paths: nil)) }
        func refreshChanged(_ paths: [URL]) async throws -> UsageScanReport { try await record(base.refresh(paths: paths)) }
        private func record(_ report: UsageScanReport) -> UsageScanReport {
            reports.withLock { $0.append(report) }
            return report
        }
        func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot {
            bump("snapshot")
            return try await base.snapshot(range: range, now: now, timeZone: timeZone)
        }
        func summary(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot {
            bump("summary")
            return try await base.summary(range: range, now: now, timeZone: timeZone)
        }
        func buckets(size: UsageBucketSize, count: Int, endingAt now: Date, timeZone: TimeZone) async throws -> [UsageBucket] {
            bump("buckets")
            return try await base.buckets(size: size, count: count, endingAt: now, timeZone: timeZone)
        }
        func hasUsage() async throws -> Bool {
            bump("hasUsage")
            return try await base.hasUsage()
        }
    }

    private func makeProfile(lines: [String]) throws -> (root: URL, config: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-usage-ui-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let config = root.appendingPathComponent("config", isDirectory: true)
        let project = config.appendingPathComponent("projects/-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(config.path, 0o700)
        if !lines.isEmpty {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: project.appendingPathComponent("sess-1.jsonl"), atomically: true, encoding: .utf8)
        }
        return (root, config)
    }

    @Test(arguments: [UsagePeriod.days7, .hours24])
    func oneRefreshMakesOneSnapshotOneSummaryAndOneBucketQuery(period: UsagePeriod) async throws {
        let (root, config) = try makeProfile(lines: [
            line(id: "a", ts: "2026-10-07T09:00:00.000Z", input: 1_000, output: 200, cacheRead: 500),
            line(id: "b", ts: "2026-10-06T11:00:00.000Z", input: 100, output: 50, cacheRead: 0),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07T12:00:00Z
        let profile = ClaudeProfileLayout(profileDirectory: config, environment: [:], home: root)
        let counting = CountingIndex(ClaudeUsageIndex(
            databaseURL: root.appendingPathComponent("usage-index.sqlite3"), profile: profile, clock: { now }))
        let usage = UsageModel(index: counting, clock: { now }, timeZone: TimeZone(identifier: "UTC")!)
        usage.select(period)
        await usage.refreshNow(reason: .launch)

        // Before: 7 snapshots in the 7-day view and 26 in the 24-hour view, each with a week-long scan.
        #expect(counting.count("summary") == 1)    // today, for the footer chip
        #expect(counting.count("snapshot") == 1)   // the selected period, the only one with the activity window
        #expect(counting.count("buckets") == 1)    // every hour bar at once
        // Only the first refresh asks, once, before the scan whether "Indexing…" is the right state
        // (nothing is indexed yet); after the scan today already has messages.
        #expect(counting.count("hasUsage") == 1)
        #expect(usage.report?.snapshot.activityWindow != nil)
        #expect(usage.report?.snapshot.tokens.total == (period == .days7 ? 1_850 : 1_700))
        #expect(usage.report?.cells.map(\.tokens) == [0, 1_700, 0, 0, 0])
    }

    @Test func anEmptyIndexIsDecidedByAnExistenceCheckNotASnapshot() async throws {
        let (root, config) = try makeProfile(lines: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ClaudeProfileLayout(profileDirectory: config, environment: [:], home: root)
        let counting = CountingIndex(ClaudeUsageIndex(
            databaseURL: root.appendingPathComponent("usage-index.sqlite3"), profile: profile))
        let usage = UsageModel(index: counting, timeZone: TimeZone(identifier: "UTC")!)
        await usage.refreshNow(reason: .launch)
        #expect(usage.hasHistory == false)
        #expect(counting.count("hasUsage") == 2)   // before the scan (first-scan state) and after it (history)
        #expect(counting.count("snapshot") == 1)   // the selected period only; no `.all` snapshot
    }

    /// Item 1 of hardening round 1: the files the index examines for one finished turn.
    @Test(arguments: [true, false])
    func aFinishedTurnExaminesOnlyTheChangedTranscriptWhenTheWatcherRuns(watcherRuns: Bool) async throws {
        let (root, config) = try makeProfile(lines: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        var files: [URL] = []
        for number in 0..<200 {
            let directory = projects.appendingPathComponent("-tmp-proj-\(number)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("sess-\(number).jsonl")
            try (line(id: "m\(number)", ts: "2026-10-07T09:00:00.000Z", input: 1_000, output: 0, cacheRead: 0) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            files.append(file)
        }
        let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07T12:00:00Z
        let profile = ClaudeProfileLayout(profileDirectory: config, environment: [:], home: root)
        let counting = CountingIndex(ClaudeUsageIndex(
            databaseURL: root.appendingPathComponent("usage-index.sqlite3"), profile: profile, clock: { now }))
        let usage = UsageModel(index: counting, clock: { now }, timeZone: TimeZone(identifier: "UTC")!,
                               debounce: .milliseconds(40), activationCooldown: .zero)
        usage.setTranscriptWatcherRunning(watcherRuns)
        usage.observeTurnCompletions(0)
        await usage.refreshNow(reason: .launch)
        #expect(counting.scanReports.map(\.filesSeen) == [200]) // the launch walk
        #expect(usage.chip?.full == "200K today")

        // A turn finishes: Claude appended to one transcript, the watcher reports that file.
        let handle = try FileHandle(forWritingTo: files[17])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(id: "late", ts: "2026-10-07T11:00:00.000Z", input: 2_000, output: 0, cacheRead: 0) + "\n").utf8))
        try handle.close()
        usage.observeTurnCompletions(1)
        if watcherRuns { usage.transcriptsChanged(UsageTranscriptChange(paths: [files[17]], needsFullScan: false)) }
        await usage.settle()

        let examined = counting.scanReports.dropFirst().map(\.filesSeen).reduce(0, +)
        #expect(examined == (watcherRuns ? 1 : 200)) // before the change: all 200 on every turn
        if watcherRuns {
            #expect(counting.scanReports.last?.filesParsed == 1)
            #expect(usage.chip?.full == "202K today") // the late line is counted all the same
        }
    }
}
