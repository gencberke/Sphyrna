import Foundation
import Testing
@testable import LoomCore

/// Timing record for the usage refresh (OPT1 item 4), off unless `LOOM_USAGE_TIMING_OUT` names the
/// JSON file to write. It builds a generated profile of 50,000 messages in the last week, then
/// times what the usage model asked the index for before (one snapshot per hour bar, each with the
/// week-long activity-window scan) against what it asks now (one summary, one snapshot, one
/// bucketed query). Debug build timings: compare the two columns, not the absolute figures.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct ClaudeUsageTimingTests {
    private static let outputPath = ProcessInfo.processInfo.environment["LOOM_USAGE_TIMING_OUT"]

    @Test(.enabled(if: ClaudeUsageTimingTests.outputPath != nil))
    func recordRefreshQueryTimings() async throws {
        let fixture = try UsageFixture()
        let messages = 50_000, files = 50
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for file in 0..<files {
            let lines = (0..<messages / files).map { step -> String in
                let number = file * (messages / files) + step
                // Spread evenly over the last 7 days, newest messages last.
                let age = 7 * 86_400 - Double(number) * (7 * 86_400 - 60) / Double(messages)
                return UsageLine(
                    id: "m\(number)", request: "r\(number)", session: "s\(file)",
                    model: number % 4 == 0 ? "claude-sonnet-4-6" : "claude-haiku-4-5-20251001",
                    ts: formatter.string(from: now.addingTimeInterval(-age)),
                    input: 100 + number % 300, output: number % 70, cacheRead: number % 5_000).json
            }
            try fixture.write(lines, to: fixture.transcript(session: "s\(file)"))
        }
        let index = fixture.makeIndex(clock: { now })
        let started = ContinuousClock.now
        try await index.refresh()
        let indexingSeconds = Self.seconds(ContinuousClock.now - started)
        let zone = TimeZone.current

        func milliseconds(_ body: () async throws -> Void) async throws -> Double {
            try await body()   // warm-up
            var samples: [Double] = []
            for _ in 0..<7 {
                let start = ContinuousClock.now
                try await body()
                samples.append(Self.seconds(ContinuousClock.now - start) * 1_000)
            }
            return samples.sorted()[samples.count / 2]
        }
        func before(days: Int?, hours: Int) async throws {
            _ = try await index.snapshot(range: .days(1), now: now, timeZone: zone)
            _ = try await index.snapshot(range: days.map { .days($0) } ?? .last24Hours, now: now, timeZone: zone)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let current = calendar.dateInterval(of: .hour, for: now)!.start
            for offset in 0..<hours {
                let start = calendar.date(byAdding: .hour, value: -offset, to: current)!
                let end = calendar.date(byAdding: .hour, value: 1, to: start)!
                _ = try await index.snapshot(range: .interval(start: start, end: end), now: now, timeZone: zone)
            }
        }
        func after(days: Int?, hours: Int) async throws {
            _ = try await index.summary(range: .days(1), now: now, timeZone: zone)
            _ = try await index.snapshot(range: days.map { .days($0) } ?? .last24Hours, now: now, timeZone: zone)
            _ = try await index.buckets(size: .hour, count: hours, endingAt: now, timeZone: zone)
        }
        func cell(days: Int?, hours: Int, snapshots: Int) async throws -> [String: Any] {
            let old = try await milliseconds { try await before(days: days, hours: hours) }
            let new = try await milliseconds { try await after(days: days, hours: hours) }
            return ["index_calls_before": snapshots, "index_calls_after": 3,
                    "before_ms_median": Int(old.rounded()), "after_ms_median": Int(new.rounded())]
        }
        let record: [String: Any] = [
            "what": "usage model index traffic per refresh, generated profile",
            "build": "debug swift test (SQLite is the same C code in release; compare columns)",
            "messages": messages, "transcript_files": files, "window": "all messages in the last 7 days",
            "indexing_ms_once": Int((indexingSeconds * 1_000).rounded()),
            "samples": "median of 7 after one warm-up",
            "view_7d": try await cell(days: 7, hours: 5, snapshots: 7),
            "view_24h": try await cell(days: nil, hours: 24, snapshots: 26),
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: try #require(Self.outputPath)))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
