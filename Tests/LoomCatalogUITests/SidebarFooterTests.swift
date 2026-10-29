import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

struct SidebarFooterTests {
    private func today(_ tokens: Int64, cost: Double, unknown: [String] = []) -> UsageSnapshot {
        UsageSnapshotFactory.snapshot(output: tokens, cost: cost, unknownModels: unknown)
    }

    @Test func idleAndFailedStatesHideTheChip() {
        #expect(UsageChipContent.make(state: .idle, today: nil, hasHistory: false) == nil)
        #expect(UsageChipContent.make(state: .failed("x"), today: nil, hasHistory: false) == nil)
    }

    @Test func indexingAndEmptyStatesHaveTheirOwnText() throws {
        let indexing = try #require(UsageChipContent.make(state: .indexing, today: nil, hasHistory: false))
        #expect(indexing.kind == .indexing)
        #expect(indexing.full == "Indexing…" && indexing.short == "Indexing…")
        #expect(indexing.accessibilityLabel == "Claude usage, indexing")
        let empty = try #require(UsageChipContent.make(state: .ready, today: today(0, cost: 0), hasHistory: false))
        #expect(empty.kind == .empty)
        #expect(empty.full == "No usage yet")
        #expect(empty.tooltip.contains("No Claude usage found in this profile yet"))
    }

    // 2026-10-07T12:00:00Z, a Wednesday.
    private static let now = Date(timeIntervalSince1970: 1_791_374_400)
    private static let utc = TimeZone(identifier: "UTC")!

    private func window(used: Int, resetsInSeconds: TimeInterval?) -> PlanLimitWindow {
        PlanLimitWindow(usedPercent: used, resetsAt: resetsInSeconds.map { Self.now.addingTimeInterval($0) })
    }

    private func limits(five: PlanLimitWindow?, week: PlanLimitWindow?) -> PlanLimits {
        PlanLimits(fiveHour: five, weekly: week, fetchedAt: Self.now.addingTimeInterval(-60))
    }

    private func makeChip(_ tokens: Int64 = 1_204_310, cost: Double = 3.1, limits: PlanLimits? = nil) throws -> UsageChipContent {
        try #require(UsageChipContent.make(
            state: .ready, today: today(tokens, cost: cost), hasHistory: true, limits: limits,
            now: Self.now, timeZone: Self.utc))
    }

    @Test func todayShowsTokensAloneWithoutLimitsAndNeverMoney() throws {
        let chip = try makeChip()
        #expect(chip.kind == .today)
        #expect(chip.full == "1.2M today")
        #expect(chip.short == "1.2M today")
        #expect(chip.limit == nil)
        #expect(chip.accessibilityLabel == "Claude usage today, 1.2 million tokens")
        #expect(chip.tooltip.hasPrefix("Claude usage today, this Claude profile"))
        #expect(chip.tooltip.contains("1,204,310 tokens"))
        for text in [chip.full, chip.tooltip, chip.accessibilityLabel] {
            #expect(!text.contains("$") && !text.contains("~") && !text.lowercased().contains("estimate"))
        }
    }

    @Test func theChipSaysTheBottleneckLimitNextToTheTokens() throws {
        // 38 % of the five hours used, the week far from full.
        let chip = try makeChip(limits: limits(
            five: window(used: 38, resetsInSeconds: 3.5 * 3_600), week: window(used: 20, resetsInSeconds: 5 * 86_400)))
        #expect(chip.full == "1.2M today · 5h 62%")
        #expect(chip.short == "1.2M today")
        #expect(chip.limit == UsageChipContent.Limit(name: "5h", remainingPercent: 62))
        #expect(chip.limit?.text == "5h 62%" && chip.limit?.isLow == false)
        #expect(chip.accessibilityLabel == "Claude usage today, 1.2 million tokens, five-hour limit 62 percent remaining")
        // The times are the system locale's (`UsageText`): 11:59, 15:30 and Monday 12:00 in a 24 hour locale.
        func at(_ seconds: TimeInterval) -> String { UsageText.time(Self.now.addingTimeInterval(seconds), Self.utc) }
        let monday = UsageText.weekday(Self.now.addingTimeInterval(5 * 86_400), Self.utc)
        #expect(chip.tooltip.contains("Plan limits, updated \(at(-60))"))
        #expect(chip.tooltip.contains("5-hour: 62% left, resets \(at(3.5 * 3_600))"))
        #expect(chip.tooltip.contains("Weekly: 80% left, resets \(monday) \(at(5 * 86_400))"))
        #expect(chip.tooltip.contains("1,204,310 tokens: input 0, output 1,204,310"))
        for text in [chip.full, chip.tooltip, chip.accessibilityLabel] {
            #expect(!text.contains("$") && !text.contains("~"))
        }
    }

    @Test func theWindowWithTheLeastLeftIsTheBottleneckAndATieGoesToTheEarlierReset() throws {
        let weekly = try makeChip(limits: limits(
            five: window(used: 38, resetsInSeconds: 3_600), week: window(used: 82, resetsInSeconds: 86_400)))
        #expect(weekly.limit == .init(name: "Wk", remainingPercent: 18))
        #expect(weekly.accessibilityLabel.hasSuffix("weekly limit 18 percent remaining"))
        let tieWeek = try makeChip(limits: limits(
            five: window(used: 40, resetsInSeconds: 7_200), week: window(used: 40, resetsInSeconds: 3_600)))
        #expect(tieWeek.limit == .init(name: "Wk", remainingPercent: 60))
        let tieFive = try makeChip(limits: limits(
            five: window(used: 40, resetsInSeconds: 3_600), week: window(used: 40, resetsInSeconds: 7_200)))
        #expect(tieFive.limit == .init(name: "5h", remainingPercent: 60))
    }

    @Test func aWindowThatAlreadyResetIsIgnoredEverywhere() throws {
        let expiredFive = try makeChip(limits: limits(
            five: window(used: 99, resetsInSeconds: -1), week: window(used: 30, resetsInSeconds: 86_400)))
        #expect(expiredFive.limit == .init(name: "Wk", remainingPercent: 70))
        #expect(!expiredFive.tooltip.contains("5-hour"))
        let allExpired = try makeChip(limits: limits(
            five: window(used: 99, resetsInSeconds: -60), week: window(used: 99, resetsInSeconds: -1)))
        #expect(allExpired.limit == nil)
        #expect(allExpired.full == "1.2M today")
        #expect(!allExpired.tooltip.contains("Plan limits"))
    }

    @Test func aWindowWithoutAResetTimeCountsAndPartialLimitsShowTheOneWindow() throws {
        let weekOnly = try makeChip(limits: limits(five: nil, week: window(used: 10, resetsInSeconds: nil)))
        #expect(weekOnly.limit == .init(name: "Wk", remainingPercent: 90))
        #expect(weekOnly.tooltip.contains("Weekly: 90% left\n"))
    }

    @Test func theLimitIsLowOnlyBelowTwentyPercentRemaining() throws {
        func chip(used: Int) throws -> UsageChipContent {
            try makeChip(limits: limits(five: window(used: used, resetsInSeconds: 3_600), week: nil))
        }
        let at20 = try #require(chip(used: 80).limit)
        let at19 = try #require(chip(used: 81).limit)
        #expect(at20.remainingPercent == 20 && !at20.isLow)
        #expect(at19.remainingPercent == 19 && at19.isLow)
        #expect(try #require(chip(used: 100).limit).isLow)
        #expect(try #require(chip(used: 0).limit).isLow == false)
        // The spoken label keeps saying the window and what is left, low or not.
        #expect(try chip(used: 81).accessibilityLabel.hasSuffix("five-hour limit 19 percent remaining"))
    }

    @Test func withoutPlanLimitsTheChipIsTokensOnly() throws {
        for limits in [nil, limits(five: nil, week: nil)] {
            let chip = try makeChip(limits: limits)
            #expect(chip.limit == nil)
            #expect(chip.full == chip.short)
        }
    }

    @Test func aDayWithNothingButAnEarlierHistoryReadsZeroTokens() {
        let chip = UsageChipContent.make(state: .ready, today: today(0, cost: 0), hasHistory: true)
        #expect(chip?.kind == .today)
        #expect(chip?.short == "0 today")
    }

    @Test func unknownModelsAddNothingToTheChip() {
        let chip = UsageChipContent.make(
            state: .ready, today: today(500, cost: 0, unknown: ["claude-x"]), hasHistory: true)
        #expect(chip?.full == "500 today")
        #expect(chip?.accessibilityLabel == "Claude usage today, 500 tokens")
        #expect(chip?.tooltip.contains("price") == false)
    }

    @Test func tooltipBreaksTheTokensDownByType() throws {
        let snapshot = UsageSnapshotFactory.snapshot(
            input: 41_200, output: 118_900, cacheWrite: 202_010, cacheRead: 842_200, cost: 3.1)
        let chip = try #require(UsageChipContent.make(state: .ready, today: snapshot, hasHistory: true))
        #expect(chip.tooltip.contains(
            "1,204,310 tokens: input 41,200, output 118,900, cache write 202,010, cache read 842,200."))
    }

}
