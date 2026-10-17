import Foundation
import LoomCore
import Observation

/// The part of `ClaudeUsageIndex` the UI uses; a fake stands in for it in tests.
public protocol UsageIndexing: Sendable {
    /// Brings the index up to date with the transcripts on disk.
    func refreshAll() async throws -> UsageScanReport
    /// Brings just these transcripts up to date (the ones a file-system event named).
    func refreshChanged(_ paths: [URL]) async throws -> UsageScanReport
    /// Reads aggregates from the index's own database; never opens a transcript.
    func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot
    /// The same numbers as `snapshot` without the activity window (a scan of the last week).
    func summary(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot
    /// Totals of `count` consecutive local hours or days, the last containing `now`.
    func buckets(size: UsageBucketSize, count: Int, endingAt now: Date, timeZone: TimeZone) async throws -> [UsageBucket]
    /// Whether any usage is indexed at all.
    func hasUsage() async throws -> Bool
    /// What the scans report about themselves (lines they could not understand).
    func diagnostics() async -> UsageDiagnostics
    /// The latest main-thread message of each session, from the index's own database (the context ring).
    func latestMainMessages(sessions: [String]) async throws -> [String: SessionContextSample]
}

/// What a stand-in without its own bucket query gets: the same answers from per-interval snapshots.
extension UsageIndexing {
    public func refreshChanged(_ paths: [URL]) async throws -> UsageScanReport {
        try await refreshAll()
    }

    public func summary(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot {
        try await snapshot(range: range, now: now, timeZone: timeZone)
    }

    public func hasUsage() async throws -> Bool {
        try await snapshot(range: .all, now: Date(), timeZone: .current).messageCount > 0
    }

    public func diagnostics() async -> UsageDiagnostics { UsageDiagnostics() }

    public func latestMainMessages(sessions: [String]) async throws -> [String: SessionContextSample] { [:] }

    public func buckets(size: UsageBucketSize, count: Int, endingAt now: Date, timeZone: TimeZone) async throws -> [UsageBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let edges = size.edges(count: count, endingAt: now, calendar: calendar)
        var result: [UsageBucket] = []
        for (start, end) in zip(edges, edges.dropFirst()) {
            let part = try await snapshot(range: .interval(start: start, end: end), now: now, timeZone: timeZone)
            result.append(UsageBucket(start: start, end: end, tokens: part.tokens, messageCount: part.messageCount))
        }
        return result
    }
}

extension ClaudeUsageIndex: UsageIndexing {
    public func refreshAll() async throws -> UsageScanReport { try await refresh(paths: nil) }
    public func refreshChanged(_ paths: [URL]) async throws -> UsageScanReport { try await refresh(paths: paths) }
}

public enum UsageState: Equatable, Sendable {
    /// Nothing has been read yet (or there is no index at all).
    case idle
    /// The first scan is running and there is no data to show.
    case indexing
    case ready
    /// The first scan failed; a failure after data exists is `UsageModel.lastFailure`.
    case failed(String)
}

public enum UsagePeriod: CaseIterable, Sendable {
    case hours24, days7, days30, days90

    public var title: String {
        switch self {
        case .hours24: "24 h"
        case .days7: "7 d"
        case .days30: "30 d"
        case .days90: "90 d"
        }
    }

    /// Headline wording: "tokens, last 7 days".
    var phrase: String {
        switch self {
        case .hours24: "last 24 hours"
        case .days7: "last 7 days"
        case .days30: "last 30 days"
        case .days90: "last 90 days"
        }
    }

    var range: UsageRange {
        switch self {
        case .hours24: .last24Hours
        case .days7: .days(7)
        case .days30: .days(30)
        case .days90: .days(90)
        }
    }

    var dayCount: Int? {
        switch self {
        case .hours24: nil
        case .days7: 7
        case .days30: 30
        case .days90: 90
        }
    }
}

/// Why a refresh was asked for. Every one is an event; nothing polls.
public enum UsageRefreshReason: Sendable {
    case launch, activation, settingsOpened, turnComplete, manual, dayChanged
}

/// One bar of the per-period chart (an hour for 24 h, a calendar day otherwise).
public struct UsageBar: Equatable, Sendable {
    public let start: Date
    public let tokens: Int64
    public let isCurrent: Bool
}

/// Everything the Usage page shows for one period.
public struct UsageReport: Equatable, Sendable {
    public let period: UsagePeriod
    public let snapshot: UsageSnapshot
    /// Oldest first, empty buckets included.
    public let bars: [UsageBar]
    /// The last five clock hours, oldest first; the final cell is the current hour.
    public let cells: [UsageBar]
}

/// When plan limits are asked for again. The Claude CLI answers each ask in a short process, so the
/// asks stay few: never when no Loom window is showing, never two at once, no timer.
public struct PlanLimitsCadence: Equatable, Sendable {
    /// A window became visible again: ask when the last ask is at least this old (seconds).
    public var afterShown: TimeInterval = 300
    /// A Claude turn finished: ask when the last ask is at least this old.
    public var afterTurn: TimeInterval = 120
    /// The Usage page was opened: ask unless the last ask is this fresh.
    public var afterPageOpened: TimeInterval = 10

    public init() {}
}

/// The one observable usage state both the footer chip and the Settings page read. Index work
/// runs on the index's own queue, never on the main actor, and only on events: launch, window
/// activation, the Usage page showing, a change under the profile's `projects` folder (reported by
/// `UsageTranscriptWatcher`, debounced and read for just the changed files), a finished Claude turn
/// (debounced; a full walk only while no watcher runs, otherwise the watcher's file is read), a new day and the refresh button. Requests while a refresh runs coalesce into one
/// more run. While no Loom window or Usage page is showing, the running watcher's changes are only
/// collected (the changed files, or a full-scan flag after an overflow); coming back reads just those
/// files, a full scan only after an overflow or on a new local day, and nothing when nothing changed.
/// Without a watcher, changes mark the numbers stale and the next time one shows walks everything.
/// Plan limits come from `limitsSource` on `PlanLimitsCadence`.
@MainActor @Observable
public final class UsageModel {
    public private(set) var state: UsageState = .idle
    public private(set) var period: UsagePeriod = .days7
    public private(set) var report: UsageReport?
    public private(set) var updatedAt: Date?
    public private(set) var isRefreshing = false
    /// A refresh failed while earlier data is still shown.
    public private(set) var lastFailure: String?
    /// The footer's text; replaced only when it changes, so its readers redraw only then.
    public private(set) var chip: UsageChipContent?
    /// The Claude plan limits, nil while unknown or unavailable.
    public private(set) var limits: PlanLimits?
    /// Why the last plan-limits ask failed; nil after a success or before any ask. The page says
    /// "Plan limits unavailable" while it is set.
    public private(set) var limitsFailure: PlanLimitsFailure?
    /// Transcript lines the scans could not understand since Loom started: the totals may be low.
    public private(set) var linesNotUnderstood = 0
    /// The context of each tracked session (`trackContext`), by session id. A session the index holds
    /// no main-thread message of has no entry.
    public private(set) var contexts: [String: ContextUsage] = [:]

    @ObservationIgnored private let index: any UsageIndexing
    @ObservationIgnored private let limitsSource: (any PlanLimitsFetching)?
    @ObservationIgnored private let cadence: PlanLimitsCadence
    @ObservationIgnored private var limitsTask: Task<Void, Never>?
    @ObservationIgnored private var lastLimitsAsk: Date?
    /// The sessions whose context is kept current, the model windows known so far (`windowKey`)
    /// and the pass that reads them.
    @ObservationIgnored private var trackedSessions: [String] = []
    @ObservationIgnored private var contextWindows: [String: Int64] = [:]
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    /// The latest samples behind `contexts`, kept so a newly known window applies without a read.
    @ObservationIgnored private var samples: [String: SessionContextSample] = [:]
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored public let timeZone: TimeZone
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let activationCooldown: Duration
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var lastRefreshEnd: ContinuousClock.Instant?
    @ObservationIgnored private var reports: [UsagePeriod: UsageReport] = [:]
    @ObservationIgnored private var loadingPeriod: Task<Void, Never>?
    @ObservationIgnored private var today: UsageSnapshot?
    /// The last window activity the model was told about; only a change counts. Assumed active
    /// until told otherwise (the app reports the real state as soon as its window exists).
    @ObservationIgnored private var windowIsActive = true
    /// Something changed while nobody could see the numbers.
    @ObservationIgnored private var stale = false
    /// The Settings window is showing, and its Usage section; together they make the page visible.
    @ObservationIgnored private var settingsWindowVisible = false
    @ObservationIgnored private var usageSectionSelected = false
    /// Transcripts reported changed and not read yet, and whether a full scan is wanted instead.
    @ObservationIgnored private var changedPaths: Set<URL> = []
    @ObservationIgnored private var wantsFullScan = false
    /// `UsageTranscriptWatcher` is running over the profile's `projects` folder, so file changes
    /// reach `transcriptsChanged` and a finished turn needs no full walk of its own.
    @ObservationIgnored private var transcriptWatcherRunning = false
    /// The period report is older than the index: a refresh for the chip alone skipped it.
    @ObservationIgnored private var reportOutdated = false
    /// A full scan has finished: file-system events before that are covered by the launch scan.
    @ObservationIgnored private var fullScanDone = false
    /// The last turn-completion count seen on the event stream (nil until the first frame).
    @ObservationIgnored private var turnCompletions: UInt64?
    /// The local day of the latest refresh request (the chip says "Today").
    @ObservationIgnored private var requestedDay: Date?
    /// Any usage at all in the index (decides between an empty Today and "No usage yet").
    public private(set) var hasHistory = false

    public init(
        index: any UsageIndexing, limits limitsSource: (any PlanLimitsFetching)? = nil,
        cadence: PlanLimitsCadence = PlanLimitsCadence(), clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current, debounce: Duration = .seconds(2),
        activationCooldown: Duration = .seconds(10)
    ) {
        self.index = index
        self.limitsSource = limitsSource
        self.cadence = cadence
        self.clock = clock
        self.timeZone = timeZone
        self.debounce = debounce
        self.activationCooldown = activationCooldown
    }

    // MARK: Events

    /// Someone can see the numbers: the active main window, or the Usage page.
    private var observing: Bool { windowIsActive || usagePageVisible }
    private var usagePageVisible: Bool { settingsWindowVisible && usageSectionSelected }
    /// The watcher has reported every change since the launch scan, so what happened while nobody
    /// looked is known exactly and is collected instead of marking everything stale.
    private var watcherKeepsTrack: Bool { transcriptWatcherRunning && fullScanDone }
    /// The local day now is not the day of the latest refresh request (the chip says "Today").
    private var dayChanged: Bool {
        guard let requestedDay else { return false }
        return calendar.startOfDay(for: clock()) != requestedDay
    }

    /// Asks for a refresh. Returns at once; `turnComplete` waits `debounce` (the first request
    /// of a burst sets the time, later ones join it) and `activation` is skipped right after a refresh.
    public func refresh(reason: UsageRefreshReason) {
        switch reason {
        case .turnComplete:
            guard observing else {
                // With the watcher keeping track, the turn's own transcript write is collected.
                if !watcherKeepsTrack { stale = true }
                return
            }
            // The watcher reports the turn's own transcript write and `transcriptsChanged` reads just
            // that file; only without a watcher does a finished turn walk every transcript.
            if !transcriptWatcherRunning { wantsFullScan = true }
            scheduleDebounced()
            fetchLimitsIfDue(after: cadence.afterTurn)
        case .activation:
            if watcherKeepsTrack {
                // What happened while hidden is known: a full scan only for an overflow or a new
                // day, else just the changed files (inside the cooldown too), else nothing.
                if stale || wantsFullScan || dayChanged { start() } else { startChanged() }
                return
            }
            if stale {
                // Something changed while hidden: read now, inside the cooldown too, and again if
                // the running refresh began before that change.
                start()
                return
            }
            // A running refresh already covers an activation.
            if isRefreshing { return }
            if let last = lastRefreshEnd, ContinuousClock.now - last < activationCooldown { return }
            start()
        case .launch:
            fetchLimitsIfDue(after: cadence.afterShown)
            // The first pass already ran (or is running): an activation that came up while the
            // first page loaded covers it. A second pass would only rerun the first.
            guard !isRefreshing, lastRefreshEnd == nil else { return }
            start()
        case .manual:
            start()
            fetchLimitsIfDue(after: cadence.afterPageOpened)
        case .settingsOpened, .dayChanged:
            start()
        }
    }

    /// Starts a refresh now and returns when it (and any run it absorbed) has finished.
    public func refreshNow(reason: UsageRefreshReason) async {
        start()
        await refreshTask?.value
    }

    /// Transcripts changed under the profile (`UsageTranscriptWatcher`). While someone can see the
    /// numbers they are read after the debounce, only those files; otherwise they are collected
    /// (bounded by the distinct transcripts written) for the next time someone can.
    public func transcriptsChanged(_ change: UsageTranscriptChange) {
        guard fullScanDone else { return } // the launch scan has not run yet and will read everything
        guard observing || watcherKeepsTrack else { stale = true; return }
        if change.needsFullScan { wantsFullScan = true } else { changedPaths.formUnion(change.paths) }
        if observing { scheduleDebounced() }
    }

    /// Tells the model whether the transcript watcher is running (the app sets it after starting
    /// the stream; a stream that failed to start or a profile without a `projects` folder is false).
    public func setTranscriptWatcherRunning(_ running: Bool) {
        transcriptWatcherRunning = running
    }

    /// The running count of finished Claude turns, as the latest event frame carries it. A frame
    /// that was skipped under load does not matter: the count in the next one has still moved.
    public func observeTurnCompletions(_ count: UInt64) {
        defer { turnCompletions = count }
        guard let seen = turnCompletions, count != seen else { return }
        refresh(reason: .turnComplete)
    }

    /// The window became (in)active. Only a change counts: the app reports every occlusion, key
    /// and application notification, most of which repeat the state.
    public func windowActivityChanged(_ active: Bool) {
        guard active != windowIsActive else { return }
        windowIsActive = active
        guard active else { return }
        refresh(reason: .activation)
        fetchLimitsIfDue(after: cadence.afterShown)
    }

    /// The Settings window shows or hides (closed, minimized or covered).
    public func setSettingsWindowVisible(_ visible: Bool) {
        let before = usagePageVisible
        settingsWindowVisible = visible
        pageVisibilityChanged(from: before)
    }

    /// The Settings window's Usage section appears or goes away.
    public func setUsageSectionSelected(_ selected: Bool) {
        let before = usagePageVisible
        usageSectionSelected = selected
        pageVisibilityChanged(from: before)
    }

    private func pageVisibilityChanged(from before: Bool) {
        guard usagePageVisible, !before else { return }
        // The page shows what the last chip-only refresh skipped: read it now.
        if reportOutdated { start() } else { refresh(reason: .activation) }
        fetchLimitsIfDue(after: cadence.afterPageOpened)
    }

    /// The catalog model's minute tick while the window is active: the chip says "Today", so a new
    /// local day reads the index once (a day that failed to read is not retried every minute).
    /// A limit window that has ended drops out of the chip without any read.
    public func minuteTick() {
        // Pure: a plan window that has ended drops out whenever the window ticks (visible, key or not).
        rebuildChip()
        guard windowIsActive, dayChanged else { return }
        refresh(reason: .dayChanged)
    }

    /// Waits for a pending debounce and a running refresh (tests, evidence).
    public func settle() async {
        await debounceTask?.value
        await refreshTask?.value
        await loadingPeriod?.value
        await limitsTask?.value
        await contextTask?.value
    }

    public func select(_ newPeriod: UsagePeriod) {
        guard newPeriod != period else { return }
        period = newPeriod
        report = reports[newPeriod]
        guard report == nil, state == .ready else { return }
        loadingPeriod = Task { [weak self] in
            guard let self else { return }
            await self.loadSelectedPeriod()
        }
    }

    // MARK: Refresh

    /// The first request of a burst sets the time, later ones join it (a streaming turn is read
    /// about every `debounce`, not once at its end and not on every line).
    private func scheduleDebounced() {
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            // Everyone looked away during the debounce: with the watcher keeping track, coming back
            // reads what was collected; without it, one full read.
            guard self.observing else {
                if !self.watcherKeepsTrack {
                    self.changedPaths = []
                    self.wantsFullScan = false
                    self.stale = true
                }
                return
            }
            if self.wantsFullScan { self.start() } else { self.startChanged() }
        }
    }

    private func start() {
        stale = false
        wantsFullScan = true
        launchRefresh()
    }

    /// Reads the transcripts named by file-system events; the report behind the page is rebuilt only
    /// while the page shows (otherwise the chip's day summary alone, which is all anyone sees).
    private func startChanged() {
        guard !changedPaths.isEmpty else { return }
        launchRefresh()
    }

    private func launchRefresh() {
        requestedDay = calendar.startOfDay(for: clock())
        if isRefreshing { rerun = true; return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    private func run() async {
        await announceFirstScan()
        repeat {
            rerun = false
            let full = wantsFullScan
            let paths = Array(changedPaths)
            wantsFullScan = false
            changedPaths = []
            do {
                _ = try await full ? index.refreshAll() : index.refreshChanged(paths)
                if full { fullScanDone = true }
                let skipped = await index.diagnostics().linesNotUnderstood
                if skipped != linesNotUnderstood { linesNotUnderstood = skipped }
                try await loadAfterScan(detail: full || usagePageVisible || report == nil)
                lastFailure = nil
                updatedAt = clock()
                setState(.ready)
                await reloadContexts()
            } catch is CancellationError {
                break
            } catch {
                // What this pass was to read is still unread.
                if full { wantsFullScan = true } else { changedPaths.formUnion(paths) }
                let message = String(describing: error)
                if report == nil { setState(.failed(message)) } else { lastFailure = message }
            }
        } while rerun
        isRefreshing = false
        refreshTask = nil
        lastRefreshEnd = .now
    }

    /// "Indexing…" is the first-ever scan: shown only while there is nothing to show and the index
    /// holds no usage yet. A later launch keeps the chip hidden until its refresh ends, and a
    /// failed state stays failed (no hidden, indexing, hidden cycle on every activation).
    private func announceFirstScan() async {
        guard report == nil, state == .idle else { return }
        guard let populated = try? await index.hasUsage(), !populated else { return }
        if state == .idle { setState(.indexing) }
    }

    /// `detail == false` reads only what the chip shows (today's summary); the period report is
    /// rebuilt when the page next shows.
    private func loadAfterScan(detail: Bool) async throws {
        let now = clock()
        let day = try await index.summary(range: .days(1), now: now, timeZone: timeZone)
        today = day
        // Decided before it is assigned: a false in between would swap the report for the
        // empty notice (and reset its scroll) for the length of the await.
        var history = day.messageCount > 0
        if !history { history = try await index.hasUsage() }
        if hasHistory != history { hasHistory = history }
        reports = [:]
        guard detail else { reportOutdated = true; return }
        reportOutdated = false
        let selected = period
        let built = try await buildReport(selected, now: now)
        reports[selected] = built
        if period == selected { report = built } else { report = reports[period] }
        if report == nil { loadingPeriod = Task { [weak self] in await self?.loadSelectedPeriod() } }
    }

    private func loadSelectedPeriod() async {
        let wanted = period
        guard let built = try? await buildReport(wanted, now: clock()) else { return }
        reports[wanted] = built
        if period == wanted { report = built }
    }

    private func setState(_ next: UsageState) {
        if next != state { state = next }
        rebuildChip()
    }

    /// Replaced only when the text changes, so the footer redraws only then.
    private func rebuildChip() {
        let content = UsageChipContent.make(
            state: state, today: today, hasHistory: hasHistory, limits: limits, now: clock(), timeZone: timeZone)
        if content != chip { chip = content }
    }

    // MARK: Context

    /// Names the sessions whose context the ring shows (the visible ones). Each is one indexed lookup
    /// in the index's database, made now and again after every refresh; nothing is scanned and no
    /// timer runs. Sessions not named lose their entry.
    public func trackContext(sessions: [String]) {
        let wanted = Array(Set(sessions)).sorted()
        guard wanted != trackedSessions else { return }
        trackedSessions = wanted
        contextTask?.cancel()
        contextTask = Task { [weak self] in await self?.reloadContexts() }
    }

    /// The context window of a model, in tokens, when it became known (the Chat wire reports it as
    /// `modelUsage.<model>.contextWindow`). Until then a session on that model shows tokens only.
    /// The 1M-context variant (`claude-opus-5-5[1m]`) is kept apart from the plain model. `nil` forgets it.
    public func setContextWindow(_ window: Int64?, forModel model: String) {
        let key = Self.windowKey(model)
        if let window, window > 0 { contextWindows[key] = window } else { contextWindows[key] = nil }
        applyContextWindows()
    }

    private static let extendedSuffix = "[1m]"

    /// The canonical model id, plus `[1m]` for the extended-context variant: the two have different windows.
    private static func windowKey(_ model: String) -> String {
        UsagePricing.canonicalModelID(model) + (model.lowercased().contains(extendedSuffix) ? extendedSuffix : "")
    }

    /// The window a sample is shown against. Transcripts write the model without `[1m]`, so a session
    /// cannot be told apart from its model id alone: the plain window holds while the context fits in it;
    /// one that has grown past it can only be on the extended window, and without a known extended window
    /// (or with no plain one) no share is shown rather than a wrong one.
    private func window(for sample: SessionContextSample) -> Int64? {
        let base = UsagePricing.canonicalModelID(sample.model)
        let extended = contextWindows[base + Self.extendedSuffix]
        if sample.model.lowercased().contains(Self.extendedSuffix) { return extended }
        guard let plain = contextWindows[base] else { return nil }
        if sample.contextTokens <= plain { return plain }
        if let extended, sample.contextTokens <= extended { return extended }
        return nil
    }

    private func reloadContexts() async {
        let sessions = trackedSessions
        guard !sessions.isEmpty else {
            if !contexts.isEmpty { contexts = [:] }
            samples = [:]
            return
        }
        guard let found = try? await index.latestMainMessages(sessions: sessions), !Task.isCancelled else { return }
        guard sessions == trackedSessions else { return } // the tracked set moved while reading
        samples = found
        applyContextWindows()
    }

    private func applyContextWindows() {
        let next = samples.mapValues { sample in
            ContextUsage(sample: sample, window: window(for: sample))
        }
        if next != contexts { contexts = next }
    }

    // MARK: Plan limits

    /// Asks the Claude CLI for the plan limits when someone can see them, none is being asked for
    /// and the last ask is at least `minimumAge` seconds old.
    private func fetchLimitsIfDue(after minimumAge: TimeInterval) {
        guard let limitsSource, observing, limitsTask == nil else { return }
        if let last = lastLimitsAsk, clock().timeIntervalSince(last) < minimumAge { return }
        lastLimitsAsk = clock()
        limitsTask = Task { [weak self] in
            let fetched = await limitsSource.fetch()
            guard let self, !Task.isCancelled else { return }
            self.limitsTask = nil
            self.lastLimitsAsk = self.clock()
            // A failed ask (offline after wake, a timeout) keeps the last answer; it carries its
            // own "updated" time and ended windows drop out by themselves.
            if let fetched, self.limits != fetched { self.limits = fetched }
            // A success clears the failure; a cancelled ask is neither.
            let failure = fetched == nil ? limitsSource.lastFailure : nil
            if failure?.category != .cancelled, self.limitsFailure != failure { self.limitsFailure = failure }
            self.rebuildChip()
        }
    }

    /// The pace of each plan window at `now` (five-hour first): are you on track for the limit? Pure
    /// arithmetic over the last answer, so it needs no ask; the caller passes the time it draws at.
    public func paces(at now: Date) -> [PlanPace] { limits?.paces(at: now) ?? [] }

    /// The facts the diagnostics export carries from here: the index's scan report and the plan-limits failure.
    public func diagnosticsSnapshot() async -> (usage: UsageDiagnostics, planLimitsFailure: PlanLimitsFailure?) {
        (await index.diagnostics(), limitsSource?.lastFailure)
    }

    // MARK: Report

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func buildReport(_ period: UsagePeriod, now: Date) async throws -> UsageReport {
        let snapshot = try await index.snapshot(range: period.range, now: now, timeZone: timeZone)
        let hours = try await hourlyBars(count: period == .hours24 ? 24 : 5, now: now)
        let bars = period.dayCount.map { dayBars(snapshot, count: $0, now: now) } ?? hours
        return UsageReport(period: period, snapshot: snapshot, bars: bars, cells: Array(hours.suffix(5)))
    }

    /// One bucketed query for every hour bar (the index groups by quarter hour).
    private func hourlyBars(count: Int, now: Date) async throws -> [UsageBar] {
        let hours = try await index.buckets(size: .hour, count: count, endingAt: now, timeZone: timeZone)
        return hours.enumerated().map { offset, hour in
            UsageBar(start: hour.start, tokens: hour.tokens.total, isCurrent: offset == hours.count - 1)
        }
    }

    private func dayBars(_ snapshot: UsageSnapshot, count: Int, now: Date) -> [UsageBar] {
        let calendar = calendar
        let today = calendar.startOfDay(for: now)
        let byStart = Dictionary(snapshot.days.map { ($0.start, $0.tokens.total) }, uniquingKeysWith: +)
        return (0..<count).reversed().map { offset in
            let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return UsageBar(start: start, tokens: byStart[start] ?? 0, isCurrent: offset == 0)
        }
    }
}
