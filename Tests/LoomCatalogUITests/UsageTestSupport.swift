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

    var refreshCalls: Int { state.withLock { $0.refreshCalls } }
    var snapshotRanges: [UsageRange] { state.withLock { $0.snapshotRanges } }
    var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }
    func setTokens(_ value: Int64) { tokens.withLock { $0 = value } }
    func setHasUsage(_ value: Bool?) { historyOverride.withLock { $0 = value } }
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
