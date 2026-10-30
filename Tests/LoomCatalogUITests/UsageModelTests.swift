import Foundation
import Darwin
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UsageModelTests {
    private func model(
        _ index: FakeUsageIndex, debounce: Duration = .milliseconds(40), cooldown: Duration = .zero,
        limits: (any PlanLimitsFetching)? = nil, clock: TestClock? = nil, gate: DebounceGate? = nil
    ) -> UsageModel {
        if let gate {
            return UsageModel(index: index, limits: limits, clock: { clock?.now ?? Date() },
                              timeZone: TimeZone(identifier: "UTC")!, debounce: debounce, activationCooldown: cooldown,
                              sleep: { _ in await gate.wait() })
        }
        return UsageModel(index: index, limits: limits, clock: { clock?.now ?? Date() },
                          timeZone: TimeZone(identifier: "UTC")!, debounce: debounce, activationCooldown: cooldown)
    }

    /// The debounce's wait, held until the test opens it: a burst is judged against the debounce itself, not
    /// against how long the machine takes between two lines of the test.
    final class DebounceGate: Sendable {
        private struct State {
            var opened = false
            var waiting: [CheckedContinuation<Void, Never>] = []
            var waits = 0
        }
        private let state = Mutex(State())
        /// How many debounce windows have started.
        var waits: Int { state.withLock { $0.waits } }

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    state.waits += 1
                    if state.opened { return true }
                    state.waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.opened = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }
    }

    @Test func firstRefreshIsIndexingThenReadyAndLaterOnesStayReady() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        #expect(usage.state == .idle)
        #expect(usage.chip == nil)
        index.setBlocking(true)
        usage.refresh(reason: .launch)
        await waitFor("the first scan") { index.refreshCalls > 0 }
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

    @Test func todayUsageHoldsTodaysTokensByKindFromTheReadTheChipIsMadeFrom() async {
        let index = KindsUsageIndex(input: 1_000, output: 200, cacheWrite: 300, cacheRead: 9_000)
        let usage = UsageModel(index: index, clock: { Date() }, timeZone: TimeZone(identifier: "UTC")!)
        #expect(usage.todayUsage == nil)
        await usage.refreshNow(reason: .launch)
        let today = usage.todayUsage
        #expect(today?.input == 1_000 && today?.output == 200 && today?.cacheWrite == 300 && today?.cacheRead == 9_000)
        #expect(today?.total == 10_500)
        #expect(today.flatMap(\.cacheShare).map { (0.87...0.88).contains($0) } == true, "9,000 of 10,300 prompt tokens")
        // No read of its own: the one day summary the chip is made from.
        #expect(index.snapshotRanges.filter { $0 == .days(1) }.count == 1)

        // A read that finds the same figures writes nothing.
        let write = ObservedWrite { _ = usage.todayUsage }
        await usage.refreshNow(reason: .manual)
        #expect(!write.wrote)
        index.set(input: 1_000, output: 250, cacheWrite: 300, cacheRead: 9_000)
        await usage.refreshNow(reason: .manual)
        #expect(usage.todayUsage?.output == 250)
    }

    @Test func turnCompletionBurstIsDebouncedIntoOneRefresh() async throws {
        let index = FakeUsageIndex()
        let gate = DebounceGate()
        let usage = model(index, debounce: .milliseconds(250), gate: gate)
        for _ in 0..<3 {
            usage.refresh(reason: .turnComplete)
            await Task.yield()
            #expect(index.refreshCalls == 0) // still waiting out the debounce
        }
        #expect(gate.waits == 1, "the later requests of the burst join the first one's wait")
        gate.open() // the debounce ends
        await usage.settle()
        #expect(index.refreshCalls == 1)
        usage.refresh(reason: .turnComplete)
        await usage.settle()
        #expect(index.refreshCalls == 2)
        #expect(gate.waits == 2, "a request after the burst starts a debounce of its own")
    }

    @Test func requestsDuringARunningRefreshCoalesceIntoOneMoreRun() async {
        let index = FakeUsageIndex()
        let usage = model(index)
        index.setBlocking(true)
        usage.refresh(reason: .manual)
        await waitFor("the scan") { index.refreshCalls > 0 } // the scan is running
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

        // The next ask answers: the failure is gone, whatever the source still remembers. The limits are as of the probe's
        // read (the time the Usage page says it read them), not the fake's own stamp.
        clock.advance(400)
        source.setAnswer(limits(fetchedAt: clock.now))
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(source.asks == 2)
        #expect(usage.limits == limits(fetchedAt: clock.now))
        #expect(usage.limitsFailure == nil)

        // A later failure keeps the earlier answer and records why it was not refreshed.
        let answered = clock.now
        clock.advance(400)
        source.setAnswer(nil)
        source.setFailure(PlanLimitsFailure(category: .notAvailable, at: clock.now))
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(usage.limits == limits(fetchedAt: answered))
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
        await waitFor("the limits source to be asked") { source.asks > 0 }
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
