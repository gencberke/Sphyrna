import Foundation
import Synchronization
@testable import LoomCore
@testable import LoomCatalogUI

/// Builds snapshots without an index (the memberwise initializers are internal to LoomCore).
enum UsageSnapshotFactory {
    static func snapshot(
        range: UsageRange = .days(1), now: Date = Date(timeIntervalSince1970: 1_790_000_000),
        input: Int64 = 0, output: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0,
        cost: Double = 0, unknownModels: [String] = [], messages: Int? = nil, days: [UsageDay] = [],
        models: [UsageModelTotal] = []
    ) -> UsageSnapshot {
        let tokens = UsageTokens(input: input, output: output, cacheWrite5m: cacheWrite, cacheRead: cacheRead)
        return UsageSnapshot(
            provider: .claude, asOf: now, priceTableAsOf: "2026-10-07", range: range, tokens: tokens,
            estimatedCostUSD: cost, unknownModels: unknownModels,
            messageCount: messages ?? (tokens.total > 0 ? 1 : 0), sessionCount: tokens.total > 0 ? 1 : 0,
            days: days, models: models, activityWindow: nil)
    }
}

/// A scripted `UsageIndexing`: counts calls, records the thread each ran on, can block a refresh.
final class FakeUsageIndex: UsageIndexing, @unchecked Sendable {
    struct State {
        var refreshCalls = 0
        /// The paths of every `refreshChanged` call (they are not counted in `refreshCalls`).
        var changedCalls: [[URL]] = []
        var snapshotRanges: [UsageRange] = []
        var ranOnMainThread = false
        var failRefresh = false
        var blockRefresh = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    /// Tokens (total) the next snapshots report for every range.
    private let tokens = Mutex<Int64>(0)
    /// Overrides `hasUsage` (nil: decided by the snapshot like the protocol's default).
    private let historyOverride = Mutex<Bool?>(nil)
    /// What `diagnostics()` reports as lines the scans could not understand.
    private let skippedLines = Mutex(0)

    var refreshCalls: Int { state.withLock { $0.refreshCalls } }
    var changedCalls: [[URL]] { state.withLock { $0.changedCalls } }
    var snapshotRanges: [UsageRange] { state.withLock { $0.snapshotRanges } }
    var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }
    func setTokens(_ value: Int64) { tokens.withLock { $0 = value } }
    func setHasUsage(_ value: Bool?) { historyOverride.withLock { $0 = value } }
    func setLinesNotUnderstood(_ value: Int) { skippedLines.withLock { $0 = value } }
    func setFailing(_ value: Bool) { state.withLock { $0.failRefresh = value } }
    func setBlocking(_ value: Bool) { state.withLock { $0.blockRefresh = value } }
    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.blockRefresh = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    struct Failure: Error, CustomStringConvertible { var description: String { "index unavailable" } }

    func refreshAll() async throws -> UsageScanReport {
        let (fail, block) = state.withLock { state -> (Bool, Bool) in
            state.refreshCalls += 1
            if Thread.isMainThread { state.ranOnMainThread = true }
            return (state.failRefresh, state.blockRefresh)
        }
        if block {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.blockRefresh else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if fail { throw Failure() }
        return UsageScanReport()
    }

    func refreshChanged(_ paths: [URL]) async throws -> UsageScanReport {
        state.withLock { $0.changedCalls.append(paths) }
        return UsageScanReport()
    }

    func diagnostics() async -> UsageDiagnostics {
        UsageDiagnostics(linesNotUnderstood: skippedLines.withLock { $0 })
    }

    func hasUsage() async throws -> Bool {
        if let value = historyOverride.withLock({ $0 }) { return value }
        return try await snapshot(range: .all, now: Date(), timeZone: .current).messageCount > 0
    }

    func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot {
        state.withLock { state in
            state.snapshotRanges.append(range)
            if Thread.isMainThread { state.ranOnMainThread = true }
        }
        let total = tokens.withLock { $0 }
        return UsageSnapshotFactory.snapshot(range: range, now: now, output: total, cost: Double(total) / 1_000_000)
    }
}


/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 1_791_374_400)) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// A scripted `PlanLimitsFetching`: counts asks, can block one, answers what it was given.
final class FakeLimits: PlanLimitsFetching, @unchecked Sendable {
    private struct State {
        var asks = 0
        var answer: PlanLimits?
        var failure: PlanLimitsFailure?
        var blocking = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    var asks: Int { state.withLock { $0.asks } }
    func setAnswer(_ value: PlanLimits?) { state.withLock { $0.answer = value } }
    /// What `lastFailure` reports (a real fetcher sets it when an ask fails and clears it on success).
    func setFailure(_ value: PlanLimitsFailure?) { state.withLock { $0.failure = value } }
    var lastFailure: PlanLimitsFailure? { state.withLock { $0.failure } }
    func setBlocking(_ value: Bool) { state.withLock { $0.blocking = value } }
    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.blocking = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func fetch() async -> PlanLimits? {
        let block = state.withLock { state -> Bool in
            state.asks += 1
            return state.blocking
        }
        if block {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.blocking else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return state.withLock { $0.answer }
    }
}
