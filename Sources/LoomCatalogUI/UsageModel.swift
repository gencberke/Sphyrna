import Foundation
import LoomCore
import Observation

/// The part of `ClaudeUsageIndex` the UI uses; a fake stands in for it in tests.
public protocol UsageIndexing: Sendable {
    /// Brings the index up to date with the transcripts on disk.
    func refreshAll() async throws -> UsageScanReport
    /// Reads aggregates from the index's own database; never opens a transcript.
    func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot
}

extension ClaudeUsageIndex: UsageIndexing {
    public func refreshAll() async throws -> UsageScanReport { try await refresh(paths: nil) }
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

/// Why a refresh was asked for. Every one is an event that already happens; nothing polls.
public enum UsageRefreshReason: Sendable {
    case launch, activation, settingsOpened, turnComplete, manual
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

/// The one observable usage state both the footer chip and the Settings page read. Index work
/// runs on the index's own queue, never on the main actor, and only on events: launch, window
/// activation, Settings opening, a finished Claude turn (debounced) and the refresh button.
/// Requests while a refresh runs coalesce into one more run.
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

    @ObservationIgnored private let index: any UsageIndexing
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
    /// Any usage at all in the index (decides between an empty Today and "No usage yet").
    public private(set) var hasHistory = false

    public init(
        index: any UsageIndexing, clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current, debounce: Duration = .seconds(2),
        activationCooldown: Duration = .seconds(10)
    ) {
        self.index = index
        self.clock = clock
        self.timeZone = timeZone
        self.debounce = debounce
        self.activationCooldown = activationCooldown
    }

    // MARK: Events

    /// Asks for a refresh. Returns at once; `turnComplete` waits `debounce` (the first request
    /// of a burst sets the time, later ones join it) and `activation` is skipped right after a refresh.
    public func refresh(reason: UsageRefreshReason) {
        switch reason {
        case .turnComplete:
            guard debounceTask == nil else { return }
            debounceTask = Task { [weak self, debounce] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled, let self else { return }
                self.debounceTask = nil
                self.start()
            }
        case .activation:
            // A running refresh already covers an activation.
            if isRefreshing { return }
            if let last = lastRefreshEnd, ContinuousClock.now - last < activationCooldown { return }
            start()
        case .launch, .settingsOpened, .manual:
            start()
        }
    }

    /// Starts a refresh now and returns when it (and any run it absorbed) has finished.
    public func refreshNow(reason: UsageRefreshReason) async {
        start()
        await refreshTask?.value
    }

    /// The Claude Stop hook's turn boundary, as the catalog model sees it on the event stream.
    public func observe(_ change: SessionEventChange) {
        if case let .status(status) = change, status?.activity == .turnComplete { refresh(reason: .turnComplete) }
    }

    public func windowActivityChanged(_ active: Bool) {
        if active { refresh(reason: .activation) }
    }

    /// Waits for a pending debounce and a running refresh (tests, evidence).
    public func settle() async {
        await debounceTask?.value
        await refreshTask?.value
        await loadingPeriod?.value
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

    private func start() {
        if isRefreshing { rerun = true; return }
        isRefreshing = true
        if report == nil, state != .ready { setState(.indexing) }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    private func run() async {
        repeat {
            rerun = false
            do {
                _ = try await index.refreshAll()
                try await loadAfterScan()
                lastFailure = nil
                updatedAt = clock()
                setState(.ready)
            } catch is CancellationError {
                break
            } catch {
                let message = String(describing: error)
                if report == nil { setState(.failed(message)) } else { lastFailure = message }
            }
        } while rerun
        isRefreshing = false
        refreshTask = nil
        lastRefreshEnd = .now
    }

    private func loadAfterScan() async throws {
        let now = clock()
        let day = try await index.snapshot(range: .days(1), now: now, timeZone: timeZone)
        today = day
        hasHistory = day.messageCount > 0
        if !hasHistory {
            hasHistory = try await index.snapshot(range: .all, now: now, timeZone: timeZone).messageCount > 0
        }
        reports = [:]
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
        let content = UsageChipContent.make(state: next, today: today, hasHistory: hasHistory)
        if content != chip { chip = content }
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

    /// One query per hour: the index keeps quarter-hour buckets and no hourly API of its own.
    private func hourlyBars(count: Int, now: Date) async throws -> [UsageBar] {
        let calendar = calendar
        let current = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var bars: [UsageBar] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            let start = calendar.date(byAdding: .hour, value: -offset, to: current) ?? current
            let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
            let hour = try await index.snapshot(range: .interval(start: start, end: end), now: now, timeZone: timeZone)
            bars.append(UsageBar(start: start, tokens: hour.tokens.total, isCurrent: offset == 0))
        }
        return bars
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
