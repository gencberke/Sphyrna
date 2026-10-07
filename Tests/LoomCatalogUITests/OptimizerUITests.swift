import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import LoomCore
@testable import LoomCatalogUI

@MainActor
private final class ResumeRecordingIntents: ConversationIntents {
    var resumes: [UUID] = []
    func start(provider: ManagedSession.Provider, projectID: UUID?) {}
    func resume(sessionID: UUID) { resumes.append(sessionID) }
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { nil }
}

/// OPT2: the optimizer fixes for the UI layer, one regression test per item.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct OptimizerUITests {
    // MARK: Item 1 - Codex cannot be resumed where it cannot be started

    private func makeModel(startable: Set<ManagedSession.Provider>) async throws
        -> (model: CatalogModel, intents: ResumeRecordingIntents, claude: UUID, codex: UUID, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-opt2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let claude = ManagedSession(provider: .claude, workingDirectory: root.path)
        let codex = ManagedSession(provider: .codex, workingDirectory: root.path)
        try await catalog.insertSession(claude, title: "Claude one", lifecycle: .idle)
        try await catalog.insertSession(codex, title: "Codex one", lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")),
                                 startableProviders: startable)
        let intents = ResumeRecordingIntents()
        model.intents = intents
        await model.start()
        return (model, intents, claude.id, codex.id, root)
    }

    private func row(_ model: CatalogModel, _ id: UUID) throws -> SessionRowModel {
        try #require(model.list(for: .activity).rows.first { $0.id == id })
    }

    @Test func productionDoesNotOfferOrPerformResumeOfACodexRecord() async throws {
        let fixture = try await makeModel(startable: [.claude])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let codexRow = try row(fixture.model, fixture.codex)
        #expect(!fixture.model.canResume(codexRow))
        #expect(fixture.model.resumeUnavailableReason(codexRow) == "Codex conversations can't be resumed in this version.")
        fixture.model.resumeConversation(fixture.codex)
        #expect(fixture.intents.resumes.isEmpty, "a stale menu or Cmd+R must not reach the runtime")
        // Claude is unaffected.
        let claudeRow = try row(fixture.model, fixture.claude)
        #expect(fixture.model.canResume(claudeRow))
        #expect(fixture.model.resumeUnavailableReason(claudeRow) == nil)
        fixture.model.resumeConversation(fixture.claude)
        #expect(fixture.intents.resumes == [fixture.claude])
    }

    @Test func developmentStillResumesACodexRecord() async throws {
        let fixture = try await makeModel(startable: [.claude, .codex])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let codexRow = try row(fixture.model, fixture.codex)
        #expect(fixture.model.canResume(codexRow))
        #expect(fixture.model.resumeUnavailableReason(codexRow) == nil)
        fixture.model.resumeConversation(fixture.codex)
        #expect(fixture.intents.resumes == [fixture.codex])
    }

    // MARK: Item 2 - the preparing notice takes no layout space above the terminal

    @Test func thePreparingNoticeIsNotPartOfTheBannerStack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-opt2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        #expect(Banners.isEmpty(for: model))
        let key = StartKey(provider: .claude, projectID: nil)
        #expect(model.beginStart(key))
        #expect(model.preparingNotice == "Preparing Claude…")
        // The banner stack sits above the tab strip and the terminal: a row there resizes the PTY.
        #expect(Banners.isEmpty(for: model), "a preparing notice must not add a row above the terminal")
        model.endStart(key)
        #expect(model.preparingNotice == nil)
        // Real messages still take their row.
        model.reportFailure("failed")
        #expect(!Banners.isEmpty(for: model))
    }

    // MARK: Item 3 - usage work while hidden, edges only, one launch pass

    private func usageModel(_ index: FakeUsageIndex, cooldown: Duration = .zero,
                            clock: @escaping @Sendable () -> Date = { Date() }) -> UsageModel {
        UsageModel(index: index, clock: clock, timeZone: TimeZone(identifier: "UTC")!,
                   debounce: .milliseconds(20), activationCooldown: cooldown)
    }

    @Test func turnsFinishedWhileHiddenReadNothingUntilTheNextActivation() async {
        let index = FakeUsageIndex()
        let usage = usageModel(index, cooldown: .seconds(600))
        await usage.refreshNow(reason: .launch)
        #expect(index.refreshCalls == 1)
        usage.windowActivityChanged(false)
        for _ in 0..<3 {
            usage.refresh(reason: .turnComplete)
            await usage.settle()
        }
        #expect(index.refreshCalls == 1, "hidden turn completions only mark usage stale")
        // Activation reads at once even inside the cooldown, because the data is stale.
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2)
        // Nothing is stale now: a second activation inside the cooldown reads nothing.
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func aTurnThatFinishesWhileTheDebounceRunsAndTheWindowHidesIsNotRead() async throws {
        let index = FakeUsageIndex()
        let usage = usageModel(index)
        usage.refresh(reason: .turnComplete)
        usage.windowActivityChanged(false)
        await usage.settle()
        #expect(index.refreshCalls == 0)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 1)
    }

    @Test func repeatedIdenticalActivityNotificationsAreOneEdge() async {
        let index = FakeUsageIndex()
        let usage = usageModel(index)
        usage.windowActivityChanged(false)
        for _ in 0..<4 {
            usage.windowActivityChanged(true)
            await usage.settle()
        }
        #expect(index.refreshCalls == 1)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func theLaunchRefreshJoinsAnActivationPassInsteadOfRunningAgain() async {
        let index = FakeUsageIndex()
        let usage = usageModel(index)
        index.setBlocking(true)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true) // the window came up while the first page was still loading
        while index.refreshCalls == 0 { await Task.yield() }
        usage.refresh(reason: .launch)    // the first page finished
        index.release()
        await usage.settle()
        #expect(index.refreshCalls == 1)
        usage.refresh(reason: .launch)    // a launch after a finished pass has nothing to add either
        await usage.settle()
        #expect(index.refreshCalls == 1)
    }

    // MARK: Item 4 - the usage view does not flash the empty notice

    @Test func hasHistoryIsAssignedOnceWithTheFinalValue() async {
        let index = FakeUsageIndex()
        index.setTokens(0)
        index.setHasUsage(true) // nothing today, history before
        let usage = usageModel(index)
        await usage.refreshNow(reason: .launch)
        #expect(usage.hasHistory)
        let invalidated = Mutex(false)
        withObservationTracking { _ = usage.hasHistory } onChange: { invalidated.withLock { $0 = true } }
        await usage.refreshNow(reason: .manual)
        #expect(usage.hasHistory)
        #expect(!invalidated.withLock { $0 }, "a refresh must not write false before it writes true again")
    }

    // MARK: Item 5 - labels

    @Test func theTabLabelStatesTitleStatusAndPinning() {
        #expect(ConversationTabItem.accessibilityLabel(title: "Fix bug", status: nil, transient: false) == "Fix bug")
        #expect(ConversationTabItem.accessibilityLabel(title: "Fix bug", status: "Waiting for approval", transient: true)
                == "Fix bug, Waiting for approval, not pinned")
    }

    // MARK: Item 6 - chip state edges

    @Test func theChipRefreshesWhenTheDayChangesAndNotBefore() async {
        let index = FakeUsageIndex()
        let day = Mutex(Date(timeIntervalSince1970: 1_791_374_400)) // 2026-10-07T12:00:00Z
        let usage = usageModel(index, clock: { day.withLock { $0 } })
        await usage.refreshNow(reason: .launch)
        #expect(index.refreshCalls == 1)
        day.withLock { $0 = Date(timeIntervalSince1970: 1_791_374_400 + 11 * 3_600 + 3_540) } // 22:59
        usage.minuteTick()
        await usage.settle()
        #expect(index.refreshCalls == 1)
        day.withLock { $0 = Date(timeIntervalSince1970: 1_791_374_400 + 12 * 3_600) } // 2026-10-08T00:00:00Z
        usage.minuteTick()
        await usage.settle()
        #expect(index.refreshCalls == 2)
        usage.minuteTick() // the same new day: once
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func aFailingDayChangeRefreshIsNotRetriedEveryMinute() async {
        let index = FakeUsageIndex()
        let day = Mutex(Date(timeIntervalSince1970: 1_791_374_400))
        let usage = usageModel(index, clock: { day.withLock { $0 } })
        await usage.refreshNow(reason: .launch)
        index.setFailing(true)
        day.withLock { $0 = Date(timeIntervalSince1970: 1_791_374_400 + 12 * 3_600) }
        for _ in 0..<3 {
            usage.minuteTick()
            await usage.settle()
        }
        #expect(index.refreshCalls == 2)
    }

    @Test func aPopulatedIndexNeverShowsTheFirstScanState() async {
        let index = FakeUsageIndex()
        index.setTokens(1_000) // an earlier launch already indexed usage
        let usage = usageModel(index)
        index.setBlocking(true)
        usage.refresh(reason: .launch)
        while index.refreshCalls == 0 { await Task.yield() }
        #expect(usage.state == .idle)
        #expect(usage.chip == nil, "a warm launch keeps the chip hidden until the scan ends")
        index.release()
        await usage.settle()
        #expect(usage.state == .ready)
    }

    @Test func anIndexThatNeverScannedShowsTheFirstScanState() async {
        let index = FakeUsageIndex()
        let usage = usageModel(index)
        index.setBlocking(true)
        usage.refresh(reason: .launch)
        while index.refreshCalls == 0 { await Task.yield() }
        #expect(usage.state == .indexing)
        #expect(usage.chip?.kind == .indexing)
        index.release()
        await usage.settle()
    }

    @Test func aPersistentFailureStaysFailedAcrossActivations() async {
        let index = FakeUsageIndex()
        index.setFailing(true)
        let usage = usageModel(index)
        await usage.refreshNow(reason: .launch)
        guard case .failed = usage.state else { Issue.record("expected failed"); return }
        index.setBlocking(true)
        usage.windowActivityChanged(false)
        usage.windowActivityChanged(true)
        while index.refreshCalls < 2 { await Task.yield() }
        guard case .failed = usage.state else { Issue.record("a retry must not flip to \(usage.state)"); return }
        #expect(usage.chip == nil)
        index.release()
        await usage.settle()
        guard case .failed = usage.state else { Issue.record("expected failed"); return }
    }

    // MARK: Item 7 - formatter churn

    @Test func usageDatesReuseTheirFormatters() {
        let zone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_791_374_400)
        let before = UsageText.formattersCreated
        var lines: Set<String> = []
        for step in 0..<60 {
            let moment = date.addingTimeInterval(Double(step) * 3_600)
            lines.insert(UsageText.hour(moment, zone))
            lines.insert(UsageText.date(moment, zone))
            lines.insert(UsageText.weekday(moment, zone))
            lines.insert(UsageText.time(moment, zone))
        }
        #expect(UsageText.formattersCreated - before <= 4, "one formatter per pattern and zone")
        #expect(UsageText.date(date, zone) == "Wed 7 Oct")
        #expect(UsageText.hour(date, zone) == "12 PM")
        #expect(UsageText.time(date, zone) == "12:00")
        #expect(UsageText.priceDate("2026-10-07") == "7 Oct 2026")
        #expect(UsageText.hour(date, TimeZone(secondsFromGMT: 19_800)!) == "5:30 PM")
        #expect(UsageText.date(date, TimeZone(secondsFromGMT: 12 * 3_600 + 3_600 * 3)!) == "Thu 8 Oct")
    }

    @Test func dayHeadingsReuseTheirFormatters() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        let before = DayGrouping.formattersCreated
        var titles: [String] = []
        for days in 2..<40 {
            let day = calendar.startOfDay(for: now.addingTimeInterval(-Double(days) * 86_400))
            titles.append(DayGrouping.title(for: day, now: now, calendar: calendar))
        }
        #expect(DayGrouping.formattersCreated - before <= 3, "one formatter per heading pattern")
        #expect(titles.first == "Monday")
        #expect(DayGrouping.title(for: calendar.startOfDay(for: now), now: now, calendar: calendar) == "Today")
        #expect(titles.contains("Sep 20"))
        let lastYear = calendar.startOfDay(for: now.addingTimeInterval(-400 * 86_400))
        #expect(DayGrouping.title(for: lastYear, now: now, calendar: calendar) == "Sep 2, 2025")
    }

    @Test func keyboardNavigationWritesOnlyOnAChange() {
        let navigation = KeyboardNavigation()
        navigation.refresh(false)
        let invalidated = Mutex(false)
        withObservationTracking { _ = navigation.isEnabled } onChange: { invalidated.withLock { $0 = true } }
        navigation.refresh(false)
        #expect(!invalidated.withLock { $0 }, "every key-window change must not re-render the chrome buttons")
        navigation.refresh(true)
        #expect(invalidated.withLock { $0 })
        #expect(navigation.isEnabled)
    }
}
