import Foundation
import Darwin
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// MARK: Freshness and plan limits

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
        _ = await exitStatus(of: writer)

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
