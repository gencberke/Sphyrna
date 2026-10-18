import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// The Usage page as cards (FB3-1, U1): the pure rules of the card texts and their order, the contrast of the
/// text on the card surface, and an offscreen render of the report at the Settings page width.
@MainActor
struct UsageCardsTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let zone = TimeZone(identifier: "UTC")!

    // MARK: Ranking

    @Test func tokenKindsAreRankedLargestFirst() {
        let tokens = UsageTokens(input: 1_900_000, output: 800_000, cacheWrite5m: 6_100_000, cacheRead: 39_400_000)
        let rows = UsageCardText.rankedKinds(tokens)
        #expect(rows.map(\.title) == ["Cache read", "Cache write", "Input", "Output"])
        #expect(rows.map(\.value) == ["39.4M", "6.1M", "1.9M", "800K"])
        #expect(abs(rows.reduce(0) { $0 + $1.fraction } - 1) < 1e-9)
        #expect(abs(rows[0].fraction - 39_400_000.0 / 48_200_000.0) < 1e-9)
        // Not the listed order when the sizes say otherwise.
        let other = UsageCardText.rankedKinds(UsageTokens(input: 3_000_000, output: 2_000_000, cacheWrite5m: 1_000_000, cacheRead: 500_000))
        #expect(other.map(\.title) == ["Input", "Output", "Cache write", "Cache read"])
    }

    @Test func tokenKindsOfTheSameSizeKeepTheListedOrder() {
        let equal = UsageCardText.rankedKinds(UsageTokens(input: 5, output: 5, cacheWrite5m: 5, cacheRead: 5))
        #expect(equal.map(\.title) == ["Cache read", "Cache write", "Input", "Output"])
        let partial = UsageCardText.rankedKinds(UsageTokens(input: 5, output: 5, cacheWrite5m: 9, cacheRead: 1))
        #expect(partial.map(\.title) == ["Cache write", "Input", "Output", "Cache read"])
    }

    @Test func aZeroTotalGivesZeroSharesAndNoDivision() {
        let rows = UsageCardText.rankedKinds(UsageTokens())
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.fraction == 0 && !$0.fraction.isNaN })
        #expect(rows.map(\.title) == ["Cache read", "Cache write", "Input", "Output"])
        #expect(UsageCardText.servedFromCache(UsageTokens()) == "—")
    }

    @Test func theKindTooltipsKeepTheGroupedNumbersAndTheCacheWriteSplit() {
        let tokens = UsageTokens(input: 41_200, output: 118_900, cacheWrite5m: 200_000, cacheWrite1h: 2_010, cacheRead: 842_200)
        let byTitle = Dictionary(uniqueKeysWithValues: UsageCardText.rankedKinds(tokens).map { ($0.title, $0.tooltip) })
        #expect(byTitle["Input"] == "41,200")
        #expect(byTitle["Output"] == "118,900")
        #expect(byTitle["Cache read"] == "842,200")
        #expect(byTitle["Cache write"] == "5 min 200,000, 1 h 2,010")
        #expect(UsageCardText.servedFromCache(tokens) == "78%")
    }

    // MARK: Texts

    @Test func thePeriodTitleIsTheCapitalisedPhrase() {
        #expect(UsagePeriod.allCases.map(UsageCardText.periodTitle)
            == ["Last 24 hours", "Last 7 days", "Last 30 days", "Last 90 days"])
    }

    @Test func countsAreSingularForOne() {
        #expect(UsageCardText.sessions(1) == "1 session with usage")
        #expect(UsageCardText.sessions(41) == "41 sessions with usage")
        #expect(UsageCardText.models(1) == "1 model")
        #expect(UsageCardText.models(3) == "3 models")
    }

    /// Fix round 2, item 2: every plan meter fills the share still left, from the leading edge, with "N% left", as Home's line
    /// and the footer chip do. The used share is the tooltip now.
    @Test func aPlanLimitRowShowsTheRemainingShareAndKeepsTheUsedShareInItsTooltip() {
        let window = PlanLimitWindow(usedPercent: 62, resetsAt: Self.now.addingTimeInterval(3_600))
        let row = UsageCardText.planLimitRow(.fiveHour, window, now: Self.now, timeZone: Self.zone, measuredAt: Self.now)
        #expect(row.title == "5-hour")
        #expect(row.left == "38% left")
        #expect(row.used == "62% used", "the tooltip")
        #expect(row.remainingFraction == 0.38, "the fill is what is left, not what is used")
        #expect(!row.isLow)
        let reset = UsageText.time(Self.now.addingTimeInterval(3_600), Self.zone)
        #expect(row.reset == "Resets \(reset)")
        #expect(row.accessibilityLabel == "5-hour limit, 62 percent used, 38 percent remaining, resets \(reset)")
        let weekly = UsageCardText.planLimitRow(.weekly, PlanLimitWindow(usedPercent: 31, resetsAt: nil),
                                                now: Self.now, timeZone: Self.zone)
        #expect(weekly.title == "Weekly" && weekly.reset == nil)
        #expect(weekly.left == "69% left" && weekly.remainingFraction == 0.69)
        #expect(weekly.accessibilityLabel == "Weekly limit, 31 percent used, 69 percent remaining")
    }

    /// The colour rules are Home's (`PlanPaceLine.isLow`): neutral, orange under 20 % left or when the window runs out before it
    /// resets; nothing is green.
    @Test func aPlanMeterTurnsOrangeUnderTwentyPercentLeftOrOverPaceAndIsNeutralOtherwise() {
        func row(_ kind: PlanLimitKind, used: Int, resetsIn: TimeInterval?) -> UsagePlanLimitRowText {
            UsageCardText.planLimitRow(kind, PlanLimitWindow(usedPercent: used, resetsAt: resetsIn.map { Self.now.addingTimeInterval($0) }),
                                       now: Self.now, timeZone: Self.zone, measuredAt: Self.now)
        }
        // 38 % left, 80 % of the window gone: under pace.
        #expect(!row(.fiveHour, used: 62, resetsIn: 3_600).isLow)
        // 15 % left.
        #expect(row(.fiveHour, used: 85, resetsIn: 600).isLow)
        // Exactly 20 % left is not under 20.
        #expect(!row(.fiveHour, used: 80, resetsIn: 600).isLow)
        // 30 % left but 70 % used a tenth into the window: it runs out first.
        #expect(row(.fiveHour, used: 70, resetsIn: 4.5 * 3_600).isLow)
        // No reset time: only the share left says anything.
        #expect(row(.weekly, used: 85, resetsIn: nil).isLow)
        #expect(!row(.weekly, used: 50, resetsIn: nil).isLow)
        // The meter and the Home line agree on every one of these.
        for (used, resetsIn) in [(62, 3_600.0), (85, 600.0), (70, 4.5 * 3_600)] {
            let window = PlanLimitWindow(usedPercent: used, resetsAt: Self.now.addingTimeInterval(resetsIn))
            let pace = PlanPace(kind: .fiveHour, window: window, at: Self.now, measuredAt: Self.now)!
            #expect(row(.fiveHour, used: used, resetsIn: resetsIn).isLow == PlanPaceLine.isLow(pace))
        }
    }

    @Test func theCostIsHiddenOnlyWhenItIsZeroBecauseAModelHasNoPrice() {
        func snapshot(cost: Double, unknown: [String]) -> UsageSnapshot {
            UsageSnapshotFactory.snapshot(output: 1_000, cost: cost, unknownModels: unknown)
        }
        #expect(UsageCardText.cost(snapshot(cost: 3.1, unknown: [])) == "~$3.10")
        #expect(UsageCardText.cost(snapshot(cost: 0, unknown: [])) != nil)
        #expect(UsageCardText.cost(snapshot(cost: 3.1, unknown: ["claude-x"])) == "~$3.10")
        #expect(UsageCardText.cost(snapshot(cost: 0, unknown: ["claude-x"])) == nil)
    }

    @Test func theLocalHoursRowCarriesTheCaveatInItsTooltipAndTheFullSentenceForVoiceOver() {
        var cells: [UsageBar] = []
        for index in 0..<5 {
            let start = Self.now.addingTimeInterval(Double(index - 4) * 3_600)
            cells.append(UsageBar(start: start, tokens: Int64(index + 1) * 1_000_000, isCurrent: index == 4))
        }
        let text = UsageCardText.localHours(cells)
        #expect(text.label == "Last 5 hours, local")
        #expect(text.total == "15M")
        #expect(text.tooltip == "15M tokens, approximate. Local activity, not your plan limit.")
        #expect(text.accessibilityLabel == "Last 5 hours, approximate. 15 million tokens. Local activity, not your plan limit.")
    }

    @Test func thePeakIsTheLargestBarAndAbsentWithoutTokens() {
        let bars = [UsageBar(start: Self.now, tokens: 5, isCurrent: false),
                    UsageBar(start: Self.now.addingTimeInterval(86_400), tokens: 13_200_000, isCurrent: true)]
        #expect(UsageCardText.peak(bars, period: .days7, timeZone: Self.zone) == "Peak 13.2M, \(UsageText.bucket(Self.now.addingTimeInterval(86_400), .days7, Self.zone))")
        #expect(UsageCardText.peak([UsageBar(start: Self.now, tokens: 0, isCurrent: true)],
                                   period: .days7, timeZone: Self.zone) == nil)
        #expect(UsageCardText.activityTitle(.hours24) == "Tokens per hour")
        #expect(UsageCardText.activityTitle(.days90) == "Tokens per day")
    }

    // MARK: Card order and plan-limit states

    @Test func thePlanLimitsComeFirstAndOnlyWhenThereIsSomethingToSay() {
        let live = PlanLimits(fiveHour: PlanLimitWindow(usedPercent: 10, resetsAt: Self.now.addingTimeInterval(60)),
                              weekly: nil, fetchedAt: Self.now)
        let past = PlanLimits(fiveHour: PlanLimitWindow(usedPercent: 10, resetsAt: Self.now.addingTimeInterval(-60)),
                              weekly: nil, fetchedAt: Self.now)
        let withLimits = UsageCardText.planLimitsCard(limits: live, failureReason: nil, now: Self.now)
        #expect(withLimits == .limits(notRefreshed: false))
        #expect(UsageCardText.cards(for: withLimits) == [.planLimits, .period, .activity, .models])
        // An earlier answer stays when the last ask failed, with a note.
        #expect(UsageCardText.planLimitsCard(limits: live, failureReason: "x", now: Self.now) == .limits(notRefreshed: true))
        // Nothing current and a failure: the unavailable text, still the first card.
        let unavailable = UsageCardText.planLimitsCard(limits: past, failureReason: "Claude did not answer in time.", now: Self.now)
        #expect(unavailable == .unavailable("Claude did not answer in time."))
        #expect(UsageCardText.cards(for: unavailable).first == .planLimits)
        // Neither: no card.
        let none = UsageCardText.planLimitsCard(limits: nil, failureReason: nil, now: Self.now)
        #expect(none == .none)
        #expect(UsageCardText.cards(for: none) == [.period, .activity, .models])
        #expect(UsageCardText.planLimitsCard(limits: past, failureReason: nil, now: Self.now) == .none)
    }

    // MARK: Contrast

    @Test func secondaryTextOnTheCardSurfaceKeepsAA() {
        let card = LoomTheme.RGB(red: 1, green: 1, blue: 1)
            .composited(over: LoomTheme.Surface.panelRGB, opacity: LoomTheme.Surface.controlOpacity)
        #expect(LoomTheme.Text.secondaryOnCardRGB.contrast(with: card) >= 4.5)
        #expect(LoomTheme.Text.secondaryIncreasedRGB.contrast(with: card) >= 4.5)
        // Night Fleece 2: plain secondary holds AA on the 6 % tone too, so the card tone is secondary.
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: card) >= 4.5)
    }

    // MARK: Render

    private func snapshot(_ period: UsagePeriod, tokens: UsageTokens, sessions: Int, cost: Double,
                          unknown: [String] = [], models: [UsageModelTotal]) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, asOf: Self.now, priceTableAsOf: "2026-10-07", range: period.range,
                      tokens: tokens, estimatedCostUSD: cost, unknownModels: unknown, messageCount: sessions * 10,
                      sessionCount: sessions, days: [], models: models, activityWindow: nil)
    }

    private func model(_ name: String, _ tokens: Int64, cost: Double?) -> UsageModelTotal {
        UsageModelTotal(model: name.lowercased(), displayName: name, tokens: UsageTokens(output: tokens),
                        estimatedCostUSD: cost, messageCount: 1)
    }

    private func report(_ period: UsagePeriod, _ snapshot: UsageSnapshot) -> UsageReport {
        let hourly = period == .hours24
        let count = hourly ? 24 : (period.dayCount ?? 7)
        let step: TimeInterval = hourly ? 3_600 : 86_400
        var bars: [UsageBar] = []
        for index in 0..<count {
            let start = Self.now.addingTimeInterval(Double(index - count + 1) * step)
            let tokens = Int64(1 + (index * 37) % 11) * 1_000_000
            bars.append(UsageBar(start: start, tokens: tokens, isCurrent: index == count - 1))
        }
        let hourTokens: [Int64] = [200_000, 900_000, 3_100_000, 2_400_000, 1_200_000]
        var cells: [UsageBar] = []
        for index in 0..<5 {
            let start = Self.now.addingTimeInterval(Double(index - 4) * 3_600)
            cells.append(UsageBar(start: start, tokens: hourTokens[index], isCurrent: index == 4))
        }
        return UsageReport(period: period, snapshot: snapshot, bars: bars, cells: cells)
    }

    private var limits: PlanLimits {
        PlanLimits(fiveHour: PlanLimitWindow(usedPercent: 62, resetsAt: Self.now.addingTimeInterval(9_000)),
                   weekly: PlanLimitWindow(usedPercent: 31, resetsAt: Self.now.addingTimeInterval(4 * 86_400)),
                   fetchedAt: Self.now)
    }

    private func view(_ report: UsageReport, limits: PlanLimits?, failure: PlanLimitsFailure? = nil,
                      skipped: Int = 0) -> UsageReportView {
        UsageReportView(report: report, limits: limits, limitsFailure: failure, linesNotUnderstood: skipped,
                        timeZone: Self.zone, now: Self.now)
    }

    private var pageWidth: CGFloat { LoomTheme.Layout.settingsWidth - 2 * LoomTheme.Space.settingsInset }

    /// The report at the Settings page width on the panel colour, to a PNG when `LOOM_USAGE_RENDER_DIR` is set.
    @discardableResult
    private func render(_ report: UsageReportView, name: String) throws -> CGSize {
        let page = report
            .padding(.horizontal, LoomTheme.Space.settingsInset)
            .padding(.bottom, LoomTheme.Space.settingsSectionGap)
            .frame(width: LoomTheme.Layout.settingsWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(LoomTheme.Surface.panel)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let directory = ProcessInfo.processInfo.environment["LOOM_USAGE_RENDER_DIR"], !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("usage-\(name).png"))
        }
        return CGSize(width: image.width / 2, height: image.height / 2)
    }

    /// The width the report asks for when offered the page width: more than that would overflow the cards.
    private func askedSize(_ report: UsageReportView) -> CGSize {
        NSHostingController(rootView: report)
            .sizeThatFits(in: CGSize(width: pageWidth, height: .greatestFiniteMagnitude))
    }

    @Test func sevenDaysWithPlanLimitsRendersAtThePageWidthWithoutOverflow() throws {
        let tokens = UsageTokens(input: 1_900_000, output: 800_000, cacheWrite5m: 5_000_000, cacheWrite1h: 1_100_000,
                                 cacheRead: 39_400_000)
        let snap = snapshot(.days7, tokens: tokens, sessions: 41, cost: 312.4, models: [
            model("Opus 5.5", 38_100_000, cost: 281.2), model("Sonnet 5.5", 8_900_000, cost: 29.9),
            model("Haiku 5.5", 1_200_000, cost: 1.3)])
        let page = view(report(.days7, snap), limits: limits, skipped: 3)
        let size = try render(page, name: "7d-limits")
        #expect(size.width == LoomTheme.Layout.settingsWidth)
        #expect(size.height > 400)
        let asked = askedSize(page)
        #expect(asked.width <= pageWidth + 0.5, "the report asked for \(asked.width) pt of \(pageWidth)")
    }

    @Test func twentyFourHoursWithoutPlanLimitsStartsWithThePeriodCard() throws {
        let snap = snapshot(.hours24, tokens: UsageTokens(input: 12_000, output: 90_000, cacheRead: 2_400_000), sessions: 1,
                            cost: 4.2, models: [model("Sonnet 5.5", 2_502_000, cost: 4.2)])
        let page = view(report(.hours24, snap), limits: nil)
        try render(page, name: "24h")
        #expect(UsageCardText.cards(for: UsageCardText.planLimitsCard(limits: nil, failureReason: nil, now: Self.now))
            .first == .period)
        #expect(askedSize(page).width <= pageWidth + 0.5)
    }

    @Test func unavailablePlanLimitsRenderTheirOwnCard() throws {
        let snap = snapshot(.days7, tokens: UsageTokens(output: 4_000_000), sessions: 6, cost: 20,
                            models: [model("Opus 5.5", 4_000_000, cost: 20)])
        let failure = PlanLimitsFailure(category: .timedOut, at: Self.now)
        let page = view(report(.days7, snap), limits: nil, failure: failure)
        try render(page, name: "7d-limits-unavailable")
        #expect(askedSize(page).width <= pageWidth + 0.5)
        // An earlier answer stays with a note when the ask failed.
        let kept = view(report(.days7, snap), limits: limits, failure: failure)
        try render(kept, name: "7d-limits-not-refreshed")
        #expect(askedSize(kept).width <= pageWidth + 0.5)
    }

    @Test func ninetyDaysWithFourModelsAndAnUnknownCostRenders() throws {
        let tokens = UsageTokens(input: 9_000_000, output: 6_000_000, cacheWrite5m: 60_000_000, cacheRead: 410_000_000)
        let snap = snapshot(.days90, tokens: tokens, sessions: 312, cost: 1_840.5, unknown: ["claude-future"], models: [
            model("Opus 5.5", 380_000_000, cost: 1_600.2), model("Sonnet 5.5", 80_000_000, cost: 220.1),
            model("Haiku 5.5", 15_000_000, cost: 20.2), model("Claude Future", 10_000_000, cost: nil)])
        let page = view(report(.days90, snap), limits: limits)
        try render(page, name: "90d-four-models")
        #expect(askedSize(page).width <= pageWidth + 0.5)
    }

    @Test func anEmptyPeriodRendersItsCardsWithZeros() throws {
        let snap = snapshot(.days30, tokens: UsageTokens(), sessions: 0, cost: 0, models: [])
        let full = report(.days30, snap)
        let bars = full.bars.map { UsageBar(start: $0.start, tokens: 0, isCurrent: $0.isCurrent) }
        let cells = full.cells.map { UsageBar(start: $0.start, tokens: 0, isCurrent: $0.isCurrent) }
        let empty = UsageReport(period: .days30, snapshot: snap, bars: bars, cells: cells)
        let page = view(empty, limits: nil)
        try render(page, name: "30d-empty")
        #expect(askedSize(page).width <= pageWidth + 0.5)
    }
}
