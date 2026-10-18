import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// An index that answers context lookups from a table and counts them; its scans do nothing.
final class ContextFakeIndex: UsageIndexing, @unchecked Sendable {
    private struct State {
        var samples: [String: SessionContextSample] = [:]
        var lookups: [[String]] = []
        var refreshes = 0
    }
    private let state = Mutex(State())
    var lookups: [[String]] { state.withLock { $0.lookups } }
    var refreshes: Int { state.withLock { $0.refreshes } }
    func set(_ samples: [String: SessionContextSample]) { state.withLock { $0.samples = samples } }

    func refreshAll() async throws -> UsageScanReport {
        state.withLock { $0.refreshes += 1 }
        return UsageScanReport()
    }

    func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot {
        UsageSnapshotFactory.snapshot(range: range, now: now)
    }

    func latestMainMessages(sessions: [String]) async throws -> [String: SessionContextSample] {
        state.withLock { state in
            state.lookups.append(sessions)
            return state.samples.filter { sessions.contains($0.key) }
        }
    }
}

/// The data side of V10: which sessions' context the model reads, when, and what it makes of it; the
/// pace of the plan windows; and the words and pictures of the ring and the pace line.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ContextPaceTests {
    private static let zone = TimeZone(identifier: "UTC")!
    private static let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07T12:00:00Z

    private func sample(_ model: String = "claude-opus-5-5-20261001", cacheRead: Int64 = 80_000, input: Int64 = 4_000,
                        cacheWrite: Int64 = 200, output: Int64 = 1_500) -> SessionContextSample {
        SessionContextSample(model: model, timestamp: Self.now,
                             tokens: UsageTokens(input: input, output: output, cacheWrite5m: cacheWrite, cacheRead: cacheRead))
    }

    private func model(_ index: ContextFakeIndex, limits: (any PlanLimitsFetching)? = nil) -> UsageModel {
        let now = Self.now
        return UsageModel(index: index, limits: limits, clock: { now }, timeZone: Self.zone,
                   debounce: .milliseconds(20), activationCooldown: .zero)
    }

    // MARK: Model

    @Test func aTrackedSessionGetsItsTokensWithoutAPercentageUntilItsWindowIsKnown() async {
        let index = ContextFakeIndex()
        index.set(["s1": sample()])
        let usage = model(index)
        usage.trackContext(sessions: ["s1"])
        await usage.settle()
        #expect(usage.contexts["s1"] == ContextUsage(tokens: 84_200, window: nil, model: "claude-opus-5-5-20261001"))
        #expect(usage.contexts["s1"]?.percent == nil)

        // The window arrives (the chat wire's `modelUsage`); no read is needed to apply it.
        usage.setContextWindow(200_000, forModel: "claude-opus-5-5")
        #expect(usage.contexts["s1"]?.window == 200_000)
        #expect(usage.contexts["s1"]?.percent == 42)
        #expect(index.lookups.count == 1)

        usage.setContextWindow(nil, forModel: "claude-opus-5-5")
        #expect(usage.contexts["s1"]?.percent == nil)
    }

    @Test func aWindowMeetsTheModelIdWhateverItsDatedDecoration() async {
        let index = ContextFakeIndex()
        index.set(["s1": sample("claude-sonnet-5-20261001")])
        let usage = model(index)
        usage.setContextWindow(200_000, forModel: "anthropic/claude-sonnet-5")
        usage.trackContext(sessions: ["s1"])
        await usage.settle()
        #expect(usage.contexts["s1"]?.window == 200_000)
    }

    @Test func theMillionContextVariantKeepsItsOwnWindow() async {
        let index = ContextFakeIndex()
        // Transcripts write the model without `[1m]`: one session fits the plain window, one has outgrown it.
        index.set(["small": sample("claude-sonnet-5", cacheRead: 150_000, input: 0, cacheWrite: 0),
                   "big": sample("claude-sonnet-5", cacheRead: 400_000, input: 0, cacheWrite: 0)])
        let usage = model(index)
        usage.setContextWindow(200_000, forModel: "claude-sonnet-5")
        usage.setContextWindow(1_000_000, forModel: "claude-sonnet-5[1m]")
        usage.trackContext(sessions: ["small", "big"])
        await usage.settle()
        #expect(usage.contexts["small"]?.window == 200_000)   // the second window did not replace the first
        #expect(usage.contexts["small"]?.percent == 75)
        #expect(usage.contexts["big"]?.window == 1_000_000)   // past 200K it can only be the extended one
        #expect(usage.contexts["big"]?.percent == 40)

        // Only the extended window is known: a session that fits 200K is not guessed to be on 1M.
        usage.setContextWindow(nil, forModel: "claude-sonnet-5")
        #expect(usage.contexts["small"]?.percent == nil)
        // Only the plain window is known and the context is past it: no share rather than a wrong one.
        usage.setContextWindow(nil, forModel: "claude-sonnet-5[1m]")
        usage.setContextWindow(200_000, forModel: "claude-sonnet-5")
        #expect(usage.contexts["big"]?.percent == nil)
        #expect(usage.contexts["big"]?.tokens == 400_000)
    }

    @Test func aSessionWithoutAMainMessageHasNoEntryAndLeavingTheSetDropsOne() async {
        let index = ContextFakeIndex()
        index.set(["s1": sample()])
        let usage = model(index)
        usage.trackContext(sessions: ["s1", "s2"])
        await usage.settle()
        #expect(Set(usage.contexts.keys) == ["s1"])
        usage.trackContext(sessions: ["s2"])
        await usage.settle()
        #expect(usage.contexts.isEmpty)
        usage.trackContext(sessions: [])
        await usage.settle()
        #expect(usage.contexts.isEmpty)
    }

    @Test func aRefreshReadsTheTrackedSessionsAgainAndNothingElse() async {
        let index = ContextFakeIndex()
        index.set(["s1": sample(cacheRead: 10_000)])
        let usage = model(index)
        usage.trackContext(sessions: ["s1"])
        await usage.settle()
        #expect(usage.contexts["s1"]?.tokens == 14_200)

        index.set(["s1": sample(cacheRead: 30_000)])
        await usage.refreshNow(reason: .manual)
        await usage.settle()
        #expect(usage.contexts["s1"]?.tokens == 34_200)
        #expect(index.lookups == [["s1"], ["s1"]])
    }

    @Test func withNothingTrackedARefreshMakesNoContextLookup() async {
        let index = ContextFakeIndex()
        let usage = model(index)
        await usage.refreshNow(reason: .manual)
        await usage.settle()
        #expect(index.refreshes == 1)
        #expect(index.lookups.isEmpty)
        // Naming the same sessions again is not a new read.
        usage.trackContext(sessions: ["s1"])
        usage.trackContext(sessions: ["s1"])
        await usage.settle()
        #expect(index.lookups.count == 1)
    }

    @Test func thePaceOfEachWindowComesFromTheLastAnswerAtTheTimeGiven() async {
        let limits = FakeLimits()
        limits.setAnswer(PlanLimits(
            fiveHour: PlanLimitWindow(usedPercent: 60, resetsAt: Self.now.addingTimeInterval(3 * 3_600)),
            weekly: PlanLimitWindow(usedPercent: 20, resetsAt: Self.now.addingTimeInterval(86_400)), fetchedAt: Self.now))
        let index = ContextFakeIndex()
        let usage = model(index, limits: limits)
        #expect(usage.paces(at: Self.now).isEmpty)       // nothing asked yet
        usage.refresh(reason: .launch)
        await usage.settle()
        let paces = usage.paces(at: Self.now)
        #expect(paces.map(\.kind) == [.fiveHour, .weekly])
        #expect(paces[0].status == .overPace)              // 60 % after 2 of 5 hours
        #expect(paces[1].status == .underPace)             // 20 % after 6 of 7 days
        // Later the five-hour window has ended and drops out without another ask.
        #expect(usage.paces(at: Self.now.addingTimeInterval(4 * 3_600)).map(\.kind) == [.weekly])
        #expect(limits.asks == 1)
    }

    // MARK: Words

    @Test func theLabelAndTooltipLeadWithTokensAndAddAShareOnlyForAKnownWindow() {
        let known = ContextUsage(tokens: 84_200, window: 200_000, model: "m")
        let unknown = ContextUsage(tokens: 84_200, window: nil, model: "m")
        #expect(ContextRingText.label(known) == "84.2K · 42%")
        #expect(ContextRingText.label(unknown) == "84.2K")
        #expect(ContextRingText.detail(known) == "Context: 84,200 of 200,000 tokens (42%)")
        #expect(ContextRingText.detail(unknown) == "Context: 84,200 tokens")
        #expect(!ContextRingText.spoken(unknown).contains("percent"))
        // The inspector's line under the ring adds to the label instead of repeating it.
        #expect(ContextRingText.caption(known) == "84,200 of 200,000 tokens")
        #expect(ContextRingText.caption(unknown) == "Window unknown")
        #expect(ContextRingText.spoken(known).hasSuffix("42 percent"))
    }

    private func pace(_ kind: PlanLimitKind, used: Int, resetsIn: TimeInterval) -> PlanPace {
        PlanPace(kind: kind, window: PlanLimitWindow(usedPercent: used, resetsAt: Self.now.addingTimeInterval(resetsIn)), at: Self.now)!
    }

    @Test func thePaceSentenceNamesTheResetAndWhetherTheLimitLasts() {
        let lasts = pace(.fiveHour, used: 38, resetsIn: 4_800)   // 12:00 + 1 h 20 = 13:20
        func at(_ seconds: TimeInterval) -> String { UsageText.time(Self.now.addingTimeInterval(seconds), Self.zone) }
        func day(_ seconds: TimeInterval) -> String { UsageText.weekday(Self.now.addingTimeInterval(seconds), Self.zone) }
        #expect(PlanPaceText.sentence(lasts, now: Self.now, timeZone: Self.zone) == "Resets \(at(4_800)) · at this pace it lasts")
        #expect(PlanPaceText.remaining(lasts) == "62% left")
        #expect(PlanPaceText.title(.fiveHour) == "5-hour window")

        let over = pace(.fiveHour, used: 60, resetsIn: 3 * 3_600)  // 2 h gone, 60 %: runs out 1 h 20 from now
        #expect(PlanPaceText.sentence(over, now: Self.now, timeZone: Self.zone) == "Resets \(at(3 * 3_600)) · at this pace it runs out \(at(4_800))")

        // Early in the week there is no verdict, only the reset time.
        let early = pace(.weekly, used: 40, resetsIn: 7 * 86_400 - 6 * 3_600)  // 6 h of 168 h gone
        #expect(early.status == .tooEarly)
        #expect(PlanPaceText.verdict(early, now: Self.now, timeZone: Self.zone) == nil)
        #expect(PlanPaceText.sentence(early, now: Self.now, timeZone: Self.zone) == "Resets \(day(86_400 * 7 - 6 * 3_600)) \(at(86_400 * 7 - 6 * 3_600))")
        #expect(PlanPaceText.remaining(early) == "60% left")

        let usedUp = pace(.weekly, used: 100, resetsIn: 2 * 86_400)
        #expect(PlanPaceText.sentence(usedUp, now: Self.now, timeZone: Self.zone) == "Resets \(day(2 * 86_400)) \(at(2 * 86_400)) · limit reached")
        #expect(PlanPaceText.title(.weekly) == "Weekly")
    }

    // MARK: Home's compact plan-limits line (V25)

    @Test func theCompactLineReadsFromFixtureNumbersLikeKsExample() {
        func at(_ seconds: TimeInterval) -> String { UsageText.time(Self.now.addingTimeInterval(seconds), Self.zone) }
        // 38 % of the five hours used after 3 h 40 of 5 (lasts), 26 % of the week used after 3 of 7 days (lasts): both left,
        // the verdict once.
        let five = pace(.fiveHour, used: 38, resetsIn: 4_800)
        let week = pace(.weekly, used: 26, resetsIn: 4 * 86_400)
        let line = PlanLimitsLine(paces: [five, week], now: Self.now, timeZone: Self.zone)
        #expect(line.text == "5h 62% left \u{00B7} Wk 74% left \u{00B7} on pace")
        #expect(line.verdict == .onPace && !(line.verdict?.isWarning ?? true))
        #expect(line.windows.map(\.isLow) == [false, false])
        #expect(line.spoken == "Plan limits, 5-hour window 62% left, Weekly 74% left, on pace")
        // One window alone, and none early in a window (no verdict at all).
        #expect(PlanLimitsLine(paces: [week], now: Self.now, timeZone: Self.zone).text == "Wk 74% left \u{00B7} on pace")
        let early = pace(.weekly, used: 40, resetsIn: 7 * 86_400 - 6 * 3_600)
        #expect(PlanLimitsLine(paces: [early], now: Self.now, timeZone: Self.zone).text == "Wk 60% left")
        // A window that runs out names itself and when; a used-up one says so; under 20 % left is marked low.
        let over = pace(.fiveHour, used: 60, resetsIn: 3 * 3_600)
        let runsOut = PlanLimitsLine(paces: [over, week], now: Self.now, timeZone: Self.zone)
        #expect(runsOut.text == "5h 40% left \u{00B7} Wk 74% left \u{00B7} 5h runs out \(at(4_800))")
        #expect(runsOut.verdict?.isWarning == true)
        let usedUp = pace(.weekly, used: 100, resetsIn: 2 * 86_400)
        let reached = PlanLimitsLine(paces: [five, usedUp], now: Self.now, timeZone: Self.zone)
        #expect(reached.text == "5h 62% left \u{00B7} Wk 0% left \u{00B7} Wk limit reached" && reached.windows.map(\.isLow) == [false, true])
        #expect(PlanLimitsLine(paces: [], now: Self.now, timeZone: Self.zone).text == "")
    }

    @Test func everyPlanMeterFillsWhatIsLeftAndTheTickIsWhereAnEvenPaceLeavesIt() {
        // The footer chip fills the share left; Home's meters now do too, with the tick at the share left at an even pace.
        let lasts = pace(.fiveHour, used: 38, resetsIn: 4_800)      // 3 h 40 of 5 h gone
        #expect(abs(PlanPaceLine.remainingFraction(lasts) - 0.62) < 0.001)
        #expect(abs(PlanPaceLine.tickFraction(lasts) - (1 - lasts.elapsedFraction)) < 0.001)
        #expect(PlanPaceLine.remainingFraction(lasts) > PlanPaceLine.tickFraction(lasts), "the fill beyond the tick: it lasts")
        let over = pace(.fiveHour, used: 60, resetsIn: 3 * 3_600)
        #expect(PlanPaceLine.remainingFraction(over) < PlanPaceLine.tickFraction(over), "the fill short of the tick: it runs out")
        #expect(PlanPaceLine.isLow(over) && !PlanPaceLine.isLow(lasts))
        #expect(PlanPaceLine.isLow(pace(.weekly, used: 85, resetsIn: 86_400)), "under 20 % left is low, as on the chip")
        #expect(UsageChipContent.Limit.lowBelowPercent == Int(LoomTheme.PlanPaceLine.lowBelow * 100))
    }

    @Test func theMetersUseNoSuccessGreenAndTheFooterChipsFillTone() {
        // One neutral fill and one warning colour for every plan meter; success is a content colour (DESIGN §4).
        #expect(LoomTheme.PlanPaceLine.fill == LoomTheme.Text.secondary)
        #expect(LoomTheme.PlanPaceLine.lasts == LoomTheme.Text.secondary, "a limit that lasts is not green")
        #expect(LoomTheme.PlanPaceLine.fillOver == LoomTheme.Status.attention)
        #expect(LoomTheme.PlanPaceLine.runsOut == LoomTheme.Status.attentionLight)
        #expect(LoomTheme.PlanPaceLine.lasts != LoomTheme.Success.light)
    }

    // MARK: Pictures

    /// A view on the card colour at 2x, to a PNG when `LOOM_CONTEXT_RENDER_DIR` is set; the size it came out.
    @discardableResult
    private func render<V: View>(_ view: V, width: CGFloat, name: String) throws -> NSBitmapImageRep {
        let page = view
            .padding(16)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(LoomTheme.Surface.card)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let directory = ProcessInfo.processInfo.environment["LOOM_CONTEXT_RENDER_DIR"], !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("v10-\(name).png"))
        }
        return bitmap
    }

    /// How far the picture is from bare card colour, summed over its pixels: a ring or a meter that drew
    /// nothing leaves none, and a longer arc leaves more than a shorter one.
    private func inked(_ bitmap: NSBitmapImageRep) -> Double {
        let card = LoomTheme.Surface.cardRGB
        var total = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += abs(Double(color.redComponent) - card.red) + abs(Double(color.greenComponent) - card.green)
                    + abs(Double(color.blueComponent) - card.blue)
            }
        }
        return total
    }

    @Test func theRingDrawsMoreArcAsTheContextFills() throws {
        func ring(_ tokens: Int64, window: Int64?) -> some View {
            ContextRing(usage: ContextUsage(tokens: tokens, window: window, model: "m"))
        }
        let unknown = inked(try render(ring(84_200, window: nil), width: 60, name: "ring-unknown"))
        let quarter = inked(try render(ring(50_000, window: 200_000), width: 60, name: "ring-25"))
        let most = inked(try render(ring(150_000, window: 200_000), width: 60, name: "ring-75"))
        let full = inked(try render(ring(195_000, window: 200_000), width: 60, name: "ring-full"))
        #expect(unknown > 0)            // the track is there without a window, and no arc
        #expect(unknown < quarter)
        #expect(quarter > unknown)
        #expect(most > quarter)
        #expect(full >= most)
    }

    @Test func theRingWithItsLabelRendersAtTheComposersHeight() throws {
        let view = VStack(alignment: .leading, spacing: 8) {
            ContextRing(usage: ContextUsage(tokens: 76_000, window: 200_000, model: "m"), showsLabel: true)
            ContextRing(usage: ContextUsage(tokens: 190_000, window: 200_000, model: "m"), showsLabel: true)
            ContextRing(usage: ContextUsage(tokens: 84_200, window: nil, model: "m"), showsLabel: true)
        }
        let bitmap = try render(view, width: 180, name: "ring-states")
        #expect(bitmap.pixelsWide == 360)
        #expect(inked(bitmap) > 0)
        let one = NSHostingController(rootView: ContextRing(usage: ContextUsage(tokens: 1, window: 2, model: "m")))
            .sizeThatFits(in: CGSize(width: 200, height: 200))
        #expect(one.width == LoomTheme.ContextRing.hitSide && one.height == LoomTheme.ContextRing.hitSide)
    }

    @Test func thePaceLineRendersTheThreeVerdictsWithoutOverflow() throws {
        let lines = VStack(alignment: .leading, spacing: 16) {
            PlanPaceLine(pace: pace(.fiveHour, used: 38, resetsIn: 4_800), now: Self.now, timeZone: Self.zone)
            PlanPaceLine(pace: pace(.fiveHour, used: 60, resetsIn: 3 * 3_600), now: Self.now, timeZone: Self.zone)
            PlanPaceLine(pace: pace(.weekly, used: 100, resetsIn: 2 * 86_400), now: Self.now, timeZone: Self.zone)
        }
        let bitmap = try render(lines, width: 280, name: "pace-lines")
        #expect(bitmap.pixelsWide == 560)
        #expect(inked(bitmap) > 0)
        let asked = NSHostingController(rootView: PlanPaceLine(
            pace: pace(.weekly, used: 82, resetsIn: 4 * 86_400), now: Self.now, timeZone: Self.zone))
            .sizeThatFits(in: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        #expect(asked.width <= 280)
    }
}
