import Foundation
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// N2 (r9 closing optimizer): a window uncovered without being activated shows the status bar's limits as of now, not as
/// of the last minute tick or activation.
@MainActor
@Suite struct StatusBarUncoverTests {
    private final class Clock: Sendable {
        private let date: Mutex<Date>
        init(_ date: Date) { self.date = Mutex(date) }
        var now: Date { date.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    @Test func uncoveringTheWindowRebuildsTheLimitSegmentsAtOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-status-uncover-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = Clock(start)
        let fiveHour = PlanLimitWindow(usedPercent: 40, resetsAt: start.addingTimeInterval(3 * 3_600))
        let weekly = PlanLimitWindow(usedPercent: 10, resetsAt: start.addingTimeInterval(4 * 86_400))
        let fetcher = UsageHarnessTests.AccountFetcher()
        fetcher.set(PlanLimitsReading(limits: PlanLimits(fiveHour: fiveHour, weekly: weekly, fetchedAt: start),
                                      account: .subscription(email: "fixture@example.invalid", plan: "max")))
        let usage = UsageModel(index: FakeUsageIndex(), limits: fetcher, clock: { clock.now })
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        model.currentDate = { clock.now }
        model.usage = usage
        defer { model.setWindowVisible(false) }
        await usage.checkStatusLimits(of: .claude)
        let before = try #require(usage.statusSegments.first { $0.harness == .claude })
        #expect(before.windows.count == 2, "both windows are current: \(before)")

        // Covered, the five-hour window ends; the bar is uncovered without the window becoming active.
        clock.advance(3 * 3_600 + 30)
        model.setWindowVisible(true)
        let after = try #require(usage.statusSegments.first { $0.harness == .claude })
        let reading = try #require(usage.readings[.claude])
        #expect(after == StatusBarUsage.make(harness: .claude, reading: reading, now: clock.now),
                "the segments are rebuilt against the uncovered moment")
        #expect(after.windows.count == 1 && after != before, "the ended window is gone at once: \(after)")
    }
}
