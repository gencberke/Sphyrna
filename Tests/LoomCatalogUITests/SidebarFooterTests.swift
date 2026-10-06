import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

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

    @Test func todayShowsTokensFirstAndTheCostOnlyInTheFullForm() throws {
        let chip = try #require(UsageChipContent.make(
            state: .ready, today: today(1_204_310, cost: 3.1), hasHistory: true))
        #expect(chip.kind == .today)
        #expect(chip.full == "Today 1.2M tok · ~$3.10")
        #expect(chip.short == "Today 1.2M tok")
        #expect(chip.accessibilityLabel == "Claude usage today, 1.2 million tokens")
        #expect(chip.tooltip.hasPrefix("Claude usage today, this Claude profile"))
        #expect(chip.tooltip.contains("1,204,310 tokens"))
        #expect(chip.tooltip.contains("API-equivalent estimate about $3.10"))
    }

    @Test func aDayWithNothingButAnEarlierHistoryReadsZeroTokens() throws {
        let chip = try #require(UsageChipContent.make(state: .ready, today: today(0, cost: 0), hasHistory: true))
        #expect(chip.kind == .today)
        #expect(chip.short == "Today 0 tok")
    }

    @Test func costIsLeftOutWhollyWhenOnlyUnknownModelsRanToday() throws {
        let chip = try #require(UsageChipContent.make(
            state: .ready, today: today(500, cost: 0, unknown: ["claude-x"]), hasHistory: true))
        #expect(chip.full == chip.short)
        #expect(chip.tooltip.contains("no known price"))
    }

    @Test func tooltipBreaksTheTokensDownByType() throws {
        let snapshot = UsageSnapshotFactory.snapshot(
            input: 41_200, output: 118_900, cacheWrite: 202_010, cacheRead: 842_200, cost: 3.1)
        let chip = try #require(UsageChipContent.make(state: .ready, today: snapshot, hasHistory: true))
        #expect(chip.tooltip.contains(
            "1,204,310 tokens: input 41,200, output 118,900, cache write 202,010, cache read 842,200."))
    }
}
