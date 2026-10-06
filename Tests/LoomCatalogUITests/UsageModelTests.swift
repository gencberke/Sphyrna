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
        _ index: FakeUsageIndex, debounce: Duration = .milliseconds(40), cooldown: Duration = .zero
    ) -> UsageModel {
        UsageModel(index: index, timeZone: TimeZone(identifier: "UTC")!, debounce: debounce,
                   activationCooldown: cooldown)
    }

    @Test func firstRefreshIsIndexingThenReadyAndLaterOnesStayReady() async {
        let index = FakeUsageIndex()
        index.setTokens(1_200_000)
        let usage = model(index)
        #expect(usage.state == .idle)
        #expect(usage.chip == nil)
        index.setBlocking(true)
        usage.refresh(reason: .launch)
        await Task.yield()
        #expect(usage.state == .indexing)
        #expect(usage.chip?.kind == .indexing)
        index.release()
        await usage.settle()
        #expect(usage.state == .ready)
        #expect(usage.chip?.full == "Today 1.2M tok · ~$1.20")
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
        await Task.yield()
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
        usage.observe(.status(ProviderWorkState(activity: .working)))
        usage.observe(.runStarted(UUID()))
        await usage.settle()
        #expect(index.refreshCalls == 0)
        usage.observe(.status(ProviderWorkState(activity: .turnComplete)))
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
        #expect(chip.figure == "1.85M tok")
        #expect(chip.cost == "~$2.40")
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
        // A second refresh with no file growth keeps the figures and reads nothing new.
        await usage.refreshNow(reason: .manual)
        #expect(usage.report?.snapshot.tokens.total == 1_865_000)
    }
}
