import Foundation
import SystemConfiguration
import Testing
import LoomCore
@testable import LoomChat
@testable import LoomRemora
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// L3b, Home's Remora as plain values: the state chosen from the preferences and the last calls, the texts, the tiles, the field's
/// keys, the automatic brief's `homeShown` rule and the one reachability read. No view, no process.
@MainActor
struct RemoraHomeStateTests {
    // MARK: Fixtures

    private let zone = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = locale
        return calendar
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func session(_ id: UUID = UUID(), project: UUID? = UUID(), name: String? = "loom", title: String = "Port the sidebar",
                         activity: Date = Date(timeIntervalSince1970: 1_000), indicator: SessionIndicator = .idle) -> HomeRemoraSession {
        HomeRemoraSession(id: id, projectID: project, projectName: name, tone: nil, provider: .claude, title: title,
                          lastActivityAt: activity, indicator: indicator)
    }

    // MARK: The state

    @Test func theStateIsChosenFromThePreferencesAndTheLastCalls() {
        typealias Inputs = HomeRemoraState.Inputs
        func choose(_ change: (inout Inputs) -> Void) -> HomeRemoraState {
            var inputs = Inputs()
            change(&inputs)
            return HomeRemoraState.choose(inputs)
        }
        #expect(choose { $0.isOn = false } == .off, "Remora off: Home is the band and Needs you")
        #expect(choose { $0.hasHost = false } == .off, "no host, as a window with no runtime")
        #expect(choose { $0.isOn = false; $0.hasSessions = false } == .off, "off wins over an empty catalog")
        #expect(choose { $0.hasSessions = false } == .beforeAnySession)
        #expect(choose { _ in } == .whenIAsk, "no brief and none running: the catalog's tiles")
        #expect(choose { $0.hasBrief = true } == .brief)
        #expect(choose { $0.phase = .briefing } == .reading)
        #expect(choose { $0.phase = .briefing; $0.hasBrief = true } == .reading, "Catch Me Up replaces the brief while it is written")
        #expect(choose { $0.phase = .asking; $0.hasBrief = true } == .brief, "a question leaves the brief where it is")
        #expect(choose { $0.hasBrief = true; $0.pickedUp = 1 } == .folded)
        #expect(choose { $0.hasBrief = true; $0.pickedUp = 2; $0.expanded = true } == .brief, "Show Brief brings it back")
        #expect(choose { $0.briefFailure = .notLoggedIn } == .cannotAnswer(.login))
        for kind: RemoraFailure.Kind in [.rateLimited, .refused, .apiError, .timedOut, .endedWithoutAnswer, .outputTooLarge, .couldNotStart] {
            #expect(choose { $0.briefFailure = kind } == .cannotAnswer(.generic(kind)))
        }
        #expect(choose { $0.briefFailure = .apiError; $0.hasBrief = true } == .cannotAnswer(.generic(.apiError)), "a failed Catch Me Up says so")
        #expect(choose { $0.decision = .wait(.windowLow(remaining: 0.05)) } == .cannotAnswer(.wait))
        #expect(choose { $0.decision = .wait(.windowLow(remaining: 0.05)); $0.hasBrief = true } == .brief, "a wait does not hide a brief")
        #expect(choose { $0.decision = .skip(.whenIAsk) } == .whenIAsk)
        #expect(choose { $0.decision = .skip(.nothingMoved) } == .whenIAsk)
        #expect(choose { $0.stopped = .brief } == .stoppedBrief)
        #expect(choose { $0.stopped = .question; $0.hasBrief = true } == .brief, "a stopped question is the answer's, not the brief's")
        #expect(HomeRemoraState.off.replacesBand == false && HomeRemoraState.beforeAnySession.replacesBand == false)
        for state: HomeRemoraState in [.reading, .brief, .folded, .whenIAsk, .stoppedBrief, .cannotAnswer(.login)] {
            #expect(state.replacesBand, "\(state)")
        }
    }

    @Test func theDefaultsAreOnAndAutomatic() {
        let defaults = RemoraPreferences()
        #expect(defaults.isOn && defaults.briefMode == .automatic)
        #expect(HomeRemoraShow.asksForBrief(isOn: defaults.isOn, hasHost: true, mode: defaults.briefMode))
        #expect(!HomeRemoraShow.asksForBrief(isOn: false, hasHost: true, mode: .automatic))
        #expect(!HomeRemoraShow.asksForBrief(isOn: true, hasHost: false, mode: .automatic))
        #expect(!HomeRemoraShow.asksForBrief(isOn: true, hasHost: true, mode: .whenIAsk))
    }

    @Test func theKeptBriefStandsForTheBriefUntilTheAnswerIsWritten() {
        let kept = RemoraKeptBrief(startedAt: Date(timeIntervalSince1970: 500), text: "Kept sentence.", chips: [RemoraChip(sessionID: "x", why: "w")],
                                   footer: "read 2 sessions")
        let answer = RemoraHostAnswer(
            kind: .brief, question: nil,
            answer: RemoraAnswer(text: "Kept sentence.", cited: [], chips: [], drafts: [], proposedFacts: [], block: .valid, model: nil,
                                 usage: RemoraTokenUsage(input: 2, cacheCreation: 1_200, cacheRead: 0, output: 64), costUSD: nil,
                                 duration: .milliseconds(4_600)),
            proposedFacts: [], readSessionIDs: [], footer: "read 2 sessions", journaled: true)
        #expect(HomeRemoraBrief.current(kept: nil, lastAnswer: nil) == nil)
        let fromKept = HomeRemoraBrief.current(kept: kept, lastAnswer: nil)
        #expect(fromKept?.text == "Kept sentence." && fromKept?.startedAt == kept.startedAt && fromKept?.duration == nil)
        let both = HomeRemoraBrief.current(kept: kept, lastAnswer: answer)
        #expect(both?.duration == 4.6 && both?.tokens == 1_266, "the numbers belong to the answer while it is the same brief")
        let ownOnly = HomeRemoraBrief.current(kept: nil, lastAnswer: answer)
        #expect(ownOnly?.text == "Kept sentence." && ownOnly?.startedAt == nil)
        var question = answer
        question.kind = .question
        #expect(HomeRemoraBrief.current(kept: nil, lastAnswer: question) == nil, "a question's answer is not a brief")
    }

    // MARK: Texts

    @Test func theTextsAreTheOnesDESIGNGives() {
        let when = date("2026-10-20T09:12:00Z")
        #expect(HomeRemoraText.heading == "Where you left off")
        #expect(HomeRemoraText.whenLine(when, zone: zone, locale: locale, calendar: calendar) == "tuesday 20 october \u{00B7} 09:12")
        #expect(HomeRemoraText.youAskedAt(date("2026-10-20T11:20:00Z"), zone: zone, locale: locale, calendar: calendar) == "You asked at 11:20")
        #expect(HomeRemoraText.earlierTime(date("2026-10-20T11:20:00Z"), zone: zone, locale: locale, calendar: calendar) == "11:20")
        #expect(HomeRemoraText.footer("read 6 sessions and 3 project notes", duration: 4.6) == "Remora read 6 sessions and 3 project notes \u{00B7} 4.6 s")
        #expect(HomeRemoraText.footer("read 6 sessions", duration: nil) == "Remora read 6 sessions", "a relaunched brief has no time")
        #expect(HomeRemoraText.sourcesFoot(sessions: 6, notes: 3, tokens: 28_000, duration: 4.6) == "6 sessions \u{00B7} 3 notes \u{00B7} 28K tokens \u{00B7} 4.6 s")
        #expect(HomeRemoraText.sourcesFoot(sessions: 1, notes: 1, tokens: nil, duration: nil) == "1 session \u{00B7} 1 note")
        #expect(HomeRemoraText.sourcesLabel(brief: true) == "Read for this brief" && HomeRemoraText.sourcesLabel(brief: false) == "Read for this answer")
        #expect(HomeRemoraText.foldTail(startedAt: when, pickedUp: 2, of: 3, zone: zone, locale: locale, calendar: calendar)
            == "morning brief 09:12 \u{00B7} 2 of 3 picked up")
        #expect(HomeRemoraText.foldTail(startedAt: nil, pickedUp: 1, of: 3) == "morning brief \u{00B7} 1 of 3 picked up")
        #expect(HomeRemoraText.whenIAsk == "Your latest sessions, newest first.")
        #expect(HomeRemoraText.beforeAnySession == "Remora reads your sessions and tells you where you left off. It answers once you have a session.")
        #expect(HomeRemoraText.stoppedQuestion == "Stopped. Ask again for the whole answer.")
        #expect(HomeRemoraText.hoverKey == "The composer's own \u{21B5} sends it. Sphyrna never does.")
    }

    @Test func theReadingLineUsesTheCountsOfTheCall() {
        #expect(HomeRemoraText.readingLine(RemoraReading(sessions: 6, projectNotes: 3)) == "Reading 6 sessions and 3 project notes…")
        #expect(HomeRemoraText.readingLine(RemoraReading(sessions: 1, projectNotes: 1)) == "Reading 1 session and 1 project note…")
        #expect(HomeRemoraText.readingLine(RemoraReading(sessions: 4, projectNotes: 0)) == "Reading 4 sessions…")
        let scoped = RemoraReading(sessions: 3, projectNotes: 1, project: .init(id: UUID(), name: "loom"))
        #expect(HomeRemoraText.readingLine(scoped) == "Reading 3 sessions in loom and its note…")
        #expect(HomeRemoraText.readingLine(nil) == "Reading your sessions…", "before the pack is built")
    }

    @Test func theFailureSentencesAreDESIGNsTwoAndTheWaitIsComputed() {
        #expect(HomeRemoraText.failure(.notLoggedIn) == "Remora uses your Claude Code login. Log in with claude in a terminal.")
        for kind: RemoraFailure.Kind in [.rateLimited, .refused, .apiError, .timedOut, .endedWithoutAnswer, .outputTooLarge, .couldNotStart] {
            #expect(HomeRemoraText.failure(kind) == "Remora could not get an answer from Claude.", "\(kind)")
        }
        let reset = date("2026-10-20T13:40:00Z")
        #expect(HomeRemoraText.waitSentence(threshold: 0.10, resetsAt: reset, timeZone: zone, locale: locale)
            == "Less than a tenth of your 5-hour limit is left until 13:40, so the morning brief waits. Questions still run.")
        #expect(HomeRemoraText.waitSentence(threshold: 0.25, resetsAt: reset, timeZone: zone, locale: locale)
            == "Less than 25% of your 5-hour limit is left until 13:40, so the morning brief waits. Questions still run.")
        #expect(HomeRemoraText.waitSentence(threshold: 0.10, resetsAt: nil, timeZone: zone, locale: locale)
            == "Less than a tenth of your 5-hour limit is left, so the morning brief waits. Questions still run.")
    }

    @Test func quietProjectsReadAsWordsAndPutInDraftSaysWhereTheLineGoes() {
        let now = date("2026-10-21T10:00:00Z")
        #expect(HomeRemoraText.quietSince(date("2026-10-16T08:00:00Z"), now: now, zone: zone, locale: locale, calendar: calendar) == "quiet since Friday")
        #expect(HomeRemoraText.quietSince(date("2026-10-02T08:00:00Z"), now: now, zone: zone, locale: locale, calendar: calendar) == "quiet since 2 october")
        #expect(HomeRemoraText.hoverWhere(.place) == "Goes below its composer's text, not sent, and the session opens")
        #expect(HomeRemoraText.hoverWhere(.copy(.terminal)) == "It runs in the terminal, so this is copied")
    }

    // MARK: Tiles

    @Test func tilesFollowTheChipsOrderNextAndDraftComeFromTheChipAndAtMostThreeShow() {
        let ids = (0..<5).map { _ in UUID() }
        let projects = (0..<5).map { _ in UUID() }
        var sessions: [UUID: HomeRemoraSession] = [:]
        for (index, id) in ids.enumerated() { sessions[id] = session(id, project: projects[index], name: "p\(index)", title: "Session \(index)") }
        // Remora ranks: 3, 1, 4, 0; session 2 is not named.
        let order = [3, 1, 4, 0]
        let nexts = ["The next step.", "Another step.", "", "Far step."]
        let chips = order.enumerated().map { RemoraChip(sessionID: ids[$0.element].uuidString, why: "why \($0.element)", next: nexts[$0.offset]) }
        let drafts = [RemoraDraft(sessionID: ids[1].uuidString, text: "Run the checks.")]
        let plan = HomeRemoraTiles.brief(chips: chips, drafts: drafts, sessions: sessions, excluded: [])
        #expect(plan.tiles.map(\.id) == [ids[3], ids[1], ids[4]], "the chips' order, three tiles")
        #expect(plan.further.map(\.id) == [ids[0]], "a fourth project that moved is one line")
        #expect(plan.further.first?.why == "why 0")
        #expect(plan.tiles[0].next == "The next step." && plan.tiles[1].next == "Another step.", "Next is the chip's own line")
        #expect(plan.tiles[2].next == nil && plan.tiles[2].draft == nil, "an empty next is no line")
        #expect(plan.tiles[1].draft == "Run the checks." && plan.tiles[0].draft == nil)
        #expect(plan.tiles.allSatisfy { !$0.isCatalog })
    }

    @Test func oneTileForEachProjectAndSessionsThatAreGoneAreHidden() {
        let project = UUID()
        let first = UUID(), second = UUID(), gone = UUID(), other = UUID()
        let sessions = [first: session(first, project: project), second: session(second, project: project),
                        other: session(other, project: UUID(), name: "site")]
        let chips = [gone, first, second, other].map { RemoraChip(sessionID: $0.uuidString, why: "") }
            + [RemoraChip(sessionID: "not a uuid", why: "")]
        let plan = HomeRemoraTiles.brief(chips: chips, drafts: [], sessions: sessions, excluded: [])
        #expect(plan.tiles.map(\.id) == [first, other], "a deleted session has no tile, a project has one, a bad id is dropped")
        #expect(plan.tiles.allSatisfy { $0.next == nil })
    }

    @Test func anExcludedProjectIsNeverNamedNotInATileNotInALineNotInANote() {
        let secret = UUID(), open = UUID()
        let hidden = UUID(), shown = UUID()
        let sessions = [hidden: session(hidden, project: secret, name: "secret"), shown: session(shown, project: open, name: "open")]
        let chips = [RemoraChip(sessionID: hidden.uuidString, why: "", next: "Secret step."),
                     RemoraChip(sessionID: shown.uuidString, why: "", next: "Open step.")]
        let projects = [HomeRemoraProject(id: secret, name: "secret", tone: nil), HomeRemoraProject(id: open, name: "open", tone: nil),
                        HomeRemoraProject(id: UUID(), name: "quiet one", tone: nil)]
        var latest = [secret: Date(timeIntervalSince1970: 10), open: Date(timeIntervalSince1970: 20)]
        latest[projects[2].id] = Date(timeIntervalSince1970: 5)
        let plan = HomeRemoraTiles.brief(chips: chips, drafts: [], sessions: sessions, excluded: [secret], projects: projects,
                                         latest: latest, before: Date(timeIntervalSince1970: 100))
        #expect(plan.tiles.map(\.id) == [shown])
        #expect(plan.tiles[0].next == "Open step.", "the excluded project's chip is never named")
        #expect(plan.quiet.map(\.project.name) == ["quiet one"], "an excluded project is not a quiet line either; a named one is not quiet")
        let catalog = HomeRemoraTiles.catalog(recent: [sessions[hidden]!, sessions[shown]!], excluded: [secret])
        #expect(catalog.map(\.id) == [shown])
    }

    @Test func theCatalogsTilesAreTheNewestSessionsOneForEachProjectWithOpenOnly() {
        let projects = (0..<4).map { _ in UUID() }
        var recent: [HomeRemoraSession] = []
        for (index, project) in projects.enumerated() {
            recent.append(session(project: project, name: "p\(index)", activity: Date(timeIntervalSince1970: Double(100 - index * 10))))
            recent.append(session(project: project, name: "p\(index)", activity: Date(timeIntervalSince1970: Double(50 - index))))
        }
        let tiles = HomeRemoraTiles.catalog(recent: recent.shuffled(), excluded: [])
        #expect(tiles.count == 3 && tiles.allSatisfy(\.isCatalog))
        #expect(tiles.map(\.session.projectName) == ["p0", "p1", "p2"], "newest first, one for each project")
        #expect(tiles.allSatisfy { $0.draft == nil && $0.next == nil }, "Open only")
    }

    /// While a brief is written the tiles' places hold empty frames, with or without an older brief kept; When I ask keeps the
    /// catalog's tiles (DESIGN §9 Reading and writing, §20). Over a rig's catalog and model; the host is never called.
    @Test(arguments: [false, true])
    func readingGivesNoTilesButFramesAndWhenIAskKeepsTheCatalogs(kept: Bool) async throws {
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 600), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        if kept {
            try rig.keepBrief(text: "You left off in loom and api.", chips: [(0, "Waits for review"), (1, "Needs a test")])
            await rig.model.loadRemoraKeptBrief()
            #expect(rig.model.remora.keptBrief != nil)
        }
        let reads = HomeRemoraReads(baselineUndo: nil)
        await reads.read(model: rig.model)
        let ui = HomeRemoraUI()

        let before = HomeRemoraContext.make(model: rig.model, reads: reads, ui: ui)
        #expect(before.state == (kept ? .brief : .whenIAsk))
        #expect(before.tiles.count == 2 && before.readingFrames == 0)
        #expect(before.tiles.allSatisfy(\.isCatalog) == !kept, "When I ask has the catalog's tiles, the brief its own")

        rig.model.remora.phase = .briefing
        let reading = HomeRemoraContext.make(model: rig.model, reads: reads, ui: ui)
        #expect(reading.state == .reading)
        #expect(reading.tiles.isEmpty, "no tile while a brief is written: \(reading.tiles.map(\.session.title))")
        #expect(reading.readingFrames == HomeRemoraTiles.maxTiles && reading.further.isEmpty && reading.quiet.isEmpty)
        rig.model.remora.phase = .idle
        #expect(!rig.ranAProcess)
    }

    @Test func quietProjectsAreThoseThatDidNotMoveSinceTheBrief() {
        let moved = HomeRemoraProject(id: UUID(), name: "moved", tone: nil)
        let still = HomeRemoraProject(id: UUID(), name: "still", tone: nil)
        let older = HomeRemoraProject(id: UUID(), name: "older", tone: nil)
        let unknown = HomeRemoraProject(id: UUID(), name: "unknown", tone: nil)
        let start = Date(timeIntervalSince1970: 1_000)
        let quiet = HomeRemoraTiles.quiet(
            projects: [moved, still, older, unknown],
            latest: [moved.id: start.addingTimeInterval(60), still.id: start.addingTimeInterval(-600), older.id: start.addingTimeInterval(-6_000)],
            named: [], excluded: [], before: start)
        #expect(quiet.map(\.project.name) == ["still", "older"], "newest first; a project with no known session is not described")
    }

    @Test func anEntryIsPickedUpWhenItsSessionRanAfterTheBriefBegan() {
        let start = Date(timeIntervalSince1970: 1_000)
        func tile(_ activity: Double) -> HomeRemoraTile {
            HomeRemoraTile(session: session(activity: Date(timeIntervalSince1970: activity)), next: nil, draft: nil, isCatalog: false)
        }
        let tiles = [tile(1_500), tile(900), tile(1_000), tile(2_000)]
        #expect(HomeRemoraTiles.pickedUp(tiles, since: start) == 2, "strictly after the start")
        #expect(HomeRemoraTiles.pickedUp(tiles, since: nil) == 0)
    }

    @Test func aTilesStateLineUsesTheCatalogsWords() {
        let now = Date(timeIntervalSince1970: 100_000)
        let ago = now.addingTimeInterval(-25 * 60)
        #expect(HomeRemoraTiles.stateText(.working, lastActivityAt: ago, now: now) == "Working")
        #expect(HomeRemoraTiles.stateText(.unviewedCompletion, lastActivityAt: ago, now: now) == "Finished 25m ago, not read")
        #expect(HomeRemoraTiles.stateText(.failed(nil), lastActivityAt: ago, now: now) == "Failed")
        #expect(HomeRemoraTiles.stateText(.failed("3 token tests"), lastActivityAt: ago, now: now) == "Failed \u{00B7} 3 token tests")
        #expect(HomeRemoraTiles.stateText(.ended, lastActivityAt: ago, now: now) == "Last active 25m ago")
        #expect(HomeRemoraTiles.stateText(.waitingForApproval, lastActivityAt: ago, now: now) == "Needs approval")
    }

    // MARK: The field

    @Test func theFieldTakesReturnEscapeAndUpWithTheirMeaning() {
        typealias Keys = HomeRemoraFieldKeys
        #expect(Keys.resolve(.return, text: "  what moved?  ", busy: false, lastQuestion: nil) == .init(action: .ask("what moved?"), handled: true))
        #expect(Keys.resolve(.return, text: "   ", busy: false, lastQuestion: nil) == .init(action: .nothing, handled: true), "an empty return asks nothing")
        #expect(Keys.resolve(.return, text: "again", busy: true, lastQuestion: nil) == .init(action: .nothing, handled: true), "a call runs")
        #expect(Keys.resolve(.escape, text: "typed", busy: true, lastQuestion: nil) == .init(action: .stop, handled: true))
        #expect(Keys.resolve(.escape, text: "typed", busy: false, lastQuestion: nil) == .init(action: .nothing, handled: false), "Esc is not taken when nothing runs")
        #expect(Keys.resolve(.up, text: "", busy: false, lastQuestion: "which session touched auth?")
            == .init(action: .recall("which session touched auth?"), handled: true))
        #expect(Keys.resolve(.up, text: "x", busy: false, lastQuestion: "q") == .init(action: .nothing, handled: false), "up in text moves the caret")
        #expect(Keys.resolve(.up, text: "", busy: false, lastQuestion: nil) == .init(action: .nothing, handled: false))
        #expect(Keys.resolve(.up, text: "", busy: false, lastQuestion: "") == .init(action: .nothing, handled: false))
    }

    @Test func aMenuMovesWrapsAndUsesTheRowUnderTheCursor() {
        typealias Keys = HomeRemoraMenuKeys
        #expect(Keys.resolve(.down, cursor: nil, count: 3) == .init(cursor: 0, use: nil, handled: true))
        #expect(Keys.resolve(.up, cursor: nil, count: 3) == .init(cursor: 2, use: nil, handled: true))
        #expect(Keys.resolve(.down, cursor: 2, count: 3).cursor == 0)
        #expect(Keys.resolve(.return, cursor: 1, count: 3) == .init(cursor: 1, use: 1, handled: true))
        #expect(Keys.resolve(.space, cursor: nil, count: 3).handled == false)
        #expect(Keys.resolve(.left, cursor: 1, count: 3).handled == false)
    }

    // MARK: Showing Home

    @Test func theAutomaticBriefAsksOnlyForAHomeThatIsOnScreen() {
        let visible = HomeWindowFacts(hasWindow: true, isMiniaturized: false, occlusionVisible: true)
        #expect(HomeRemoraShow.homeShown(routeIsHome: true, window: visible))
        #expect(!HomeRemoraShow.homeShown(routeIsHome: false, window: visible), "another route")
        #expect(!HomeRemoraShow.homeShown(routeIsHome: true, window: .none), "no window yet")
        #expect(!HomeRemoraShow.homeShown(routeIsHome: true, window: HomeWindowFacts(hasWindow: true, isMiniaturized: true, occlusionVisible: true)))
        #expect(!HomeRemoraShow.homeShown(routeIsHome: true, window: HomeWindowFacts(hasWindow: true, isMiniaturized: false, occlusionVisible: false)),
                "covered or hidden")
    }

    // MARK: Reachability

    @Test func aPathIsOnlineOnlyWhenItIsSatisfied() {
        #expect(NetworkReach.isOnline(status: .satisfied))
        #expect(!NetworkReach.isOnline(status: .unsatisfied))
        #expect(!NetworkReach.isOnline(status: .requiresConnection), "a route that still needs a connection is not one")
    }

    @Test func theEvidenceOverrideReplacesTheSystemsReadAndNothingElse() async {
        defer { NetworkReach.evidenceOverride = nil }
        NetworkReach.evidenceOverride = false
        #expect(await !NetworkReach.isOnline())
        NetworkReach.evidenceOverride = true
        #expect(await NetworkReach.isOnline())
    }

    @Test func theSystemReadReturnsWithinItsBoundAndLeavesNothingRunning() async {
        // The first path of a real monitor, or nothing within the bound: either way it returns, and a second read is as good as the first.
        // The limit is generous on purpose: under a full run's load the global queue that starts each read can lag for seconds
        // (pool #1 on 22 Oct took 3.1 s for these two 400 ms reads); a read that never returned would still fail it.
        let started = ContinuousClock.now
        _ = await NetworkReach.firstStatus(bound: .milliseconds(400))
        _ = await NetworkReach.firstStatus(bound: .milliseconds(400))
        #expect(ContinuousClock.now - started < .seconds(30))
    }
}
