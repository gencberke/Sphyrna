import Foundation
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// The Usage page with Codex beside Claude (D-99): the Limits section's cards and states, which harness is shown and asked,
/// the asking rules (Codex when the page opens and when the app turns active, with the probe's floor; Claude through its
/// own cadence and one child), and the section choice. Fake probe sources only: no real Claude or Codex.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UsageHarnessTests {
    static let start = Date(timeIntervalSince1970: 1_791_374_400)
    static let zone = TimeZone(identifier: "UTC")!

    // MARK: Rigs

    /// A probe source that answers a script, the last answer for ever; counts its asks.
    final class Scripted: HarnessProbeSource, @unchecked Sendable {
        private let state: Mutex<(answers: [HarnessProbeAnswer?], asks: Int)>
        init(_ answers: [HarnessProbeAnswer?]) { state = Mutex((answers, 0)) }
        var asks: Int { state.withLock { $0.asks } }
        func set(_ answers: [HarnessProbeAnswer?]) { state.withLock { $0.answers = answers; $0.asks = 0 } }
        func read() async -> HarnessProbeAnswer? {
            state.withLock { state in
                defer { state.asks += 1 }
                guard !state.answers.isEmpty else { return nil }
                return state.answers[min(state.asks, state.answers.count - 1)]
            }
        }
    }

    /// A plan-limits fetcher that names an account beside the windows, counting every ask of either kind.
    final class AccountFetcher: PlanLimitsFetching, @unchecked Sendable {
        private let state = Mutex((asks: 0, reading: PlanLimitsReading(limits: nil, account: nil), failure: PlanLimitsFailure?.none))
        var asks: Int { state.withLock { $0.asks } }
        func set(_ reading: PlanLimitsReading, failure: PlanLimitsFailure? = nil) {
            state.withLock { $0.reading = reading; $0.failure = failure }
        }
        var lastFailure: PlanLimitsFailure? { state.withLock { $0.failure } }
        func fetchReading() async -> PlanLimitsReading { state.withLock { $0.asks += 1; return $0.reading } }
        func fetch() async -> PlanLimits? { await fetchReading().limits }
    }

    static func window(_ id: String, _ name: String, minutes: Int?, used: Int, resetsIn: TimeInterval?, at now: Date = start)
        -> HarnessLimitWindow {
        HarnessLimitWindow(id: id, name: name, durationMinutes: minutes, usedPercent: used,
                           resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    static let pro = HarnessAccount.subscription(email: "someone@example.invalid", plan: "pro")

    static func codexAnswer(
        account: HarnessAccount? = pro, five: Int = 23, week: Int = 61, days: [HarnessTokenDay]? = nil, lifetime: Int64? = nil
    ) -> HarnessProbeAnswer {
        HarnessProbeAnswer(
            account: account,
            windows: account == HarnessAccount.apiKey || account == HarnessAccount.none ? [] : [
                window("codex.primary", "5-hour", minutes: 300, used: five, resetsIn: 3 * 3_600),
                window("codex.secondary", "Weekly", minutes: 10_080, used: week, resetsIn: 4 * 86_400)],
            lifetimeTokens: lifetime, tokenDays: days)
    }

    static func claudeLimits(five: Int = 38, week: Int = 20, at now: Date = start) -> PlanLimits {
        PlanLimits(
            fiveHour: PlanLimitWindow(usedPercent: five, resetsAt: now.addingTimeInterval(3 * 3_600)),
            weekly: PlanLimitWindow(usedPercent: week, resetsAt: now.addingTimeInterval(4 * 86_400)), fetchedAt: now)
    }

    /// The sections the model told its owner about.
    final class SectionLog: @unchecked Sendable {
        private let state = Mutex<[UsageSection]>([])
        func add(_ section: UsageSection) { state.withLock { $0.append(section) } }
        var all: [UsageSection] { state.withLock { $0 } }
    }

    struct Rig {
        let usage: UsageModel
        let probe: HarnessProbe
        let connections: HarnessConnections
        let clock: TestClock
        let claude: AccountFetcher
        let codex: Scripted
        let sections: SectionLog
    }

    /// A usage model with the probe attached, Claude through a fetcher and Codex through a script.
    func rig(codex answers: [HarnessProbeAnswer?] = [UsageHarnessTests.codexAnswer()], claudeAccount: HarnessAccount? = .subscription(email: nil, plan: "max"),
             connections: HarnessConnections = HarnessConnections(), section: UsageSection = .limits) -> Rig {
        let clock = TestClock(Self.start)
        let claude = AccountFetcher()
        claude.set(PlanLimitsReading(limits: Self.claudeLimits(), account: claudeAccount))
        let codex = Scripted(answers)
        let probe = HarnessProbe(
            connections: connections, sources: [.claude: ClaudeProbeSource(fetcher: claude), .codex: codex],
            clock: { clock.now })
        let usage = UsageModel(index: FakeUsageIndex(), limits: claude, clock: { clock.now }, timeZone: Self.zone,
                               debounce: .milliseconds(40), activationCooldown: .zero)
        let sections = SectionLog()
        usage.attachHarness(probe: probe, connections: connections, section: section) { sections.add($0) }
        return Rig(usage: usage, probe: probe, connections: connections, clock: clock, claude: claude, codex: codex,
                   sections: sections)
    }

    /// The Usage page opens: the Settings window shows and the Usage section appears.
    func openPage(_ rig: Rig) async {
        rig.usage.setSettingsWindowVisible(true)
        rig.usage.setUsageSectionSelected(true)
        await rig.usage.settle()
    }

    func groups(_ rig: Rig, _ filter: UsageHarnessFilter = .all) -> [UsageLimitsGroup] {
        rig.usage.limitGroups(shown: filter.shown(among: rig.usage.connectedHarnesses), now: rig.clock.now)
    }

    // MARK: The cards

    @Test func claudeAndCodexEachGetOneCardPerWindowWithLeftPaceAndReset() async {
        let rig = rig()
        await openPage(rig)
        let both = groups(rig)
        #expect(both.map(\.heading) == ["Claude", "Codex"])
        #expect(both.map(\.plan) == ["Max", "Pro"], "the plan only: the email never reaches the page")

        let claude = both[0]
        #expect(claude.cards.map(\.content.title) == ["5-hour", "Weekly"])
        #expect(claude.cards.map(\.content.left) == ["62% left", "80% left"])
        #expect(claude.cards[0].content.sentence == "Resets in 3h · at this pace it lasts")
        #expect(claude.cards[0].content.tickFraction != nil, "the pace tick is PlanPace's")
        let read = "Read \(UsageText.time(rig.clock.now, Self.zone))"
        #expect(claude.cards.allSatisfy { $0.read == read })

        let codex = both[1]
        #expect(codex.cards.map(\.content.title) == ["5-hour", "Weekly"], "Codex's windows are named by their length")
        #expect(codex.cards.map(\.content.left) == ["77% left", "39% left"])
        #expect(codex.cards[1].content.sentence.hasPrefix("Resets in 4d"))
        #expect(codex.cards[0].accessibilityLabel == "Codex 5-hour, 77% left")
        #expect(codex.cards[0].accessibilityValue == "Resets in 3h · at this pace it lasts. \(read)")
    }

    @Test func codexAloneAndClaudeAloneEachShowOnlyTheirGroup() async {
        let codexOnly = rig(connections: HarnessConnections(disconnected: [.claude]))
        await openPage(codexOnly)
        #expect(groups(codexOnly).map(\.heading) == ["Codex"])
        #expect(codexOnly.claude.asks == 0, "Claude is switched off: not asked")

        let claudeOnly = rig(connections: HarnessConnections(disconnected: [.codex]))
        await openPage(claudeOnly)
        #expect(groups(claudeOnly).map(\.heading) == ["Claude"])
        #expect(UsageHarnessFilter.offered(among: claudeOnly.usage.connectedHarnesses).isEmpty, "one harness: no filter")
    }

    @Test func theFilterHidesTheOtherHarnessAndFallsBackToAllWhenItsOwnIsOff() async {
        let rig = rig()
        await openPage(rig)
        #expect(UsageHarnessFilter.offered(among: rig.usage.connectedHarnesses) == [.all, .claude, .codex])
        #expect(groups(rig, .claude).map(\.heading) == ["Claude"])
        #expect(groups(rig, .codex).map(\.heading) == ["Codex"])
        #expect(groups(rig, .all).map(\.heading) == ["Claude", "Codex"])
        rig.connections.setConnected(.codex, false)
        #expect(groups(rig, .codex).map(\.heading) == ["Claude"], "a filter on a harness that is off shows what is connected")
    }

    @Test func aSwitchedOffHarnessIsAbsentAndNeverAskedAndItsReadingGoes() async {
        let rig = rig()
        await openPage(rig)
        #expect(rig.codex.asks == 1 && rig.usage.readings[.codex] != nil)
        rig.connections.setConnected(.codex, false)
        rig.clock.advance(400)
        rig.usage.setUsageSectionSelected(false)
        rig.usage.setUsageSectionSelected(true)
        await rig.usage.settle()
        #expect(rig.codex.asks == 1, "switched off: not asked again")
        #expect(rig.usage.readings[.codex] == nil)
        #expect(groups(rig).map(\.heading) == ["Claude"])
        rig.usage.refresh(reason: .manual)
        await rig.usage.settle()
        #expect(rig.codex.asks == 1, "not even by Update")
    }

    @Test func anApiKeyAccountSaysItHasNoSubscriptionLimits() async {
        let rig = rig(codex: [Self.codexAnswer(account: .apiKey)], claudeAccount: .apiKey)
        await openPage(rig)
        for group in groups(rig) {
            #expect(group.cards.isEmpty && group.failure == nil)
            #expect(group.message?.title == "No subscription limits")
            #expect(group.plan == nil)
        }
    }

    @Test func nobodySignedInPointsToConnections() async {
        let rig = rig(codex: [Self.codexAnswer(account: HarnessAccount.none)])
        await openPage(rig)
        let codex = groups(rig)[1]
        #expect(codex.cards.isEmpty)
        #expect(codex.message?.title == "Not signed in")
        #expect(codex.message?.detail == "Sign in with the Codex CLI, then check Settings → Connections.")
    }

    @Test func aFailedReadKeepsTheLastWindowsAndSaysWhyUntilAReadWorks() async {
        let rig = rig(codex: [Self.codexAnswer(), nil, Self.codexAnswer(five: 40)])
        await openPage(rig)
        #expect(groups(rig)[1].failure == nil)

        rig.clock.advance(301)
        rig.usage.windowActivityChanged(false)
        rig.usage.windowActivityChanged(true)
        await rig.usage.settle()
        let failed = groups(rig)[1]
        #expect(rig.codex.asks == 2)
        #expect(failed.failure == "Could not read: Codex did not answer.")
        #expect(failed.cards.map(\.content.left) == ["77% left", "39% left"], "the last good windows stay")

        rig.usage.refresh(reason: .manual)
        await rig.usage.settle()
        let recovered = groups(rig)[1]
        #expect(recovered.failure == nil)
        #expect(recovered.cards.map(\.content.left) == ["60% left", "39% left"])
    }

    @Test func aFirstReadThatFailsHasNoCardsAndOnlyTheReason() async {
        let rig = rig(codex: [nil])
        await openPage(rig)
        let codex = groups(rig)[1]
        #expect(codex.cards.isEmpty && codex.message == nil)
        #expect(codex.failure == "Could not read: Codex did not answer.")
        // Before any ask there is nothing to say yet but that it is being read.
        let unasked = UsageLimitsPage.group(harness: .codex, reading: nil, failure: nil, now: Self.start, timeZone: Self.zone)
        #expect(unasked.message?.title == "Reading limits…")
    }

    @Test func aWindowOfAnotherLengthHasNoTickAndAnEndedWindowDropsOut() {
        let reading = HarnessReading(provider: .codex, account: Self.pro, windows: [
            Self.window("a.primary", "Spark 3-day", minutes: 4_320, used: 90, resetsIn: 86_400),
            Self.window("b.primary", "5-hour", minutes: 300, used: 10, resetsIn: -60)], readAt: Self.start)
        let group = UsageLimitsPage.group(harness: .codex, reading: reading, failure: nil, now: Self.start, timeZone: Self.zone)
        #expect(group.cards.map(\.content.title) == ["Spark 3-day"], "the ended window is gone")
        #expect(group.cards[0].content.tickFraction == nil)
        #expect(group.cards[0].content.left == "10% left" && group.cards[0].content.isLow)
        #expect(group.cards[0].content.sentence == "Resets in 1d")
        let ended = HarnessReading(provider: .codex, account: Self.pro, windows: [reading.windows[1]], readAt: Self.start)
        #expect(UsageLimitsPage.group(harness: .codex, reading: ended, failure: nil, now: Self.start, timeZone: Self.zone)
            .message?.title == "No limit window is running")
    }

    // MARK: Asking

    @Test func codexIsAskedWhenThePageOpensAndWhenTheAppTurnsActiveWithTheProbesFloor() async {
        let rig = rig()
        rig.usage.windowActivityChanged(false)
        rig.usage.windowActivityChanged(true)
        await rig.usage.settle()
        #expect(rig.codex.asks == 0, "the page is not showing: Codex is not asked")

        await openPage(rig)
        #expect(rig.codex.asks == 1)

        rig.clock.advance(100)
        rig.usage.windowActivityChanged(false)
        rig.usage.windowActivityChanged(true)
        await rig.usage.settle()
        #expect(rig.codex.asks == 1, "inside the five-minute floor")

        rig.clock.advance(250)
        rig.usage.windowActivityChanged(false)
        rig.usage.windowActivityChanged(true)
        await rig.usage.settle()
        #expect(rig.codex.asks == 2, "past the floor, with the page showing")

        rig.usage.setUsageSectionSelected(false)
        rig.clock.advance(400)
        rig.usage.windowActivityChanged(false)
        rig.usage.windowActivityChanged(true)
        await rig.usage.settle()
        #expect(rig.codex.asks == 2, "the page is away again")
    }

    @Test func updateForcesCodexAndNothingAsksOnATimer() async {
        let rig = rig()
        await openPage(rig)
        rig.clock.advance(5)
        rig.usage.refresh(reason: .manual)
        await rig.usage.settle()
        #expect(rig.codex.asks == 2, "Update forces the read inside the floor")
        // Home's Check Again is a manual refresh with no page showing: it does not read Codex.
        rig.usage.setUsageSectionSelected(false)
        rig.usage.refresh(reason: .manual)
        await rig.usage.settle()
        #expect(rig.codex.asks == 2)
    }

    @Test func aClaudeAskThroughTheCadenceRunsOneChildForTheAccountAndTheWindows() async {
        let rig = rig()
        await openPage(rig)
        #expect(rig.claude.asks == 1, "one get_usage child for the one ask")
        #expect(rig.usage.limits == Self.claudeLimits())
        let reading = await rig.probe.lastReading(of: .claude)
        #expect(reading?.account == .subscription(email: nil, plan: "max"), "the same ask named the account")
        #expect(reading?.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(rig.usage.readings[.claude] == reading)
        // Connections reads the probe's reading with no ask of its own.
        #expect(rig.claude.asks == 1)
    }

    @Test func aFailedClaudeAskKeepsItsWindowsAndAddsTheReason() async {
        let rig = rig()
        await openPage(rig)
        rig.clock.advance(400)
        rig.claude.set(PlanLimitsReading(limits: nil, account: nil), failure: PlanLimitsFailure(category: .timedOut, at: rig.clock.now))
        rig.usage.windowActivityChanged(false)
        rig.usage.windowActivityChanged(true)
        await rig.usage.settle()
        let claude = groups(rig)[0]
        #expect(claude.failure == "Could not read: Claude did not answer in time.")
        #expect(claude.cards.map(\.content.left) == ["62% left", "80% left"])
        #expect(rig.usage.limits == Self.claudeLimits(), "the chip and Home keep the last good windows too")
    }

    @Test func claudeIsNotAskedOnceItIsSwitchedOff() async {
        let rig = rig()
        await openPage(rig)
        rig.connections.setConnected(.claude, false)
        rig.clock.advance(400)
        rig.usage.windowActivityChanged(false)
        rig.usage.windowActivityChanged(true)
        await rig.usage.settle()
        #expect(rig.claude.asks == 1)
        #expect(rig.usage.limits == nil && rig.usage.readings[.claude] == nil)
        #expect(rig.usage.paces(at: rig.clock.now).isEmpty)
    }

    // MARK: The section

    @Test func theSectionChoiceIsToldToItsOwnerAndSurvivesAReloadOfThePreferences() throws {
        let rig = rig(section: .tokens)
        #expect(rig.usage.section == .tokens, "the page opens on the stored choice")
        rig.usage.selectSection(.limits)
        rig.usage.selectSection(.limits)
        #expect(rig.sections.all == [.limits], "each change once")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-r6-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ui-preferences.json")
        let store = UIPreferencesStore(url: url)
        #expect(store.current.usageSection == .limits, "Limits by default")
        try store.update { $0.usageSection = .tokens }
        #expect(UIPreferencesStore(url: url).current.usageSection == .tokens)
        // A file from before the choice existed, or with a choice that is not one, reads as Limits.
        try Data("{\"sidebarWidth\": 300}".utf8).write(to: url)
        #expect(UIPreferencesStore(url: url).current.usageSection == .limits)
        try Data("{\"usageSection\": \"nonsense\"}".utf8).write(to: url)
        #expect(UIPreferencesStore(url: url).current.usageSection == .limits)
    }

    @Test func untilResetCountsInTwoUnitsAtMost() {
        let now = Self.start
        #expect(UsageFormat.untilReset(now.addingTimeInterval(30), from: now) == "1m")
        #expect(UsageFormat.untilReset(now.addingTimeInterval(12 * 60), from: now) == "12m")
        #expect(UsageFormat.untilReset(now.addingTimeInterval(3 * 3_600), from: now) == "3h")
        #expect(UsageFormat.untilReset(now.addingTimeInterval(3 * 3_600 + 14 * 60 + 10), from: now) == "3h 15m")
        #expect(UsageFormat.untilReset(now.addingTimeInterval(2 * 86_400 + 4 * 3_600), from: now) == "2d 4h")
        #expect(UsageFormat.untilReset(now.addingTimeInterval(-5), from: now) == "1m")
    }
}
