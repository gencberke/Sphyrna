import Foundation
import Observation
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI
import LoomTestSupport

/// L3b: what Home does each time it shows, over a real host and the fake provider's Remora mode (no real Claude, profile or vault):
/// the day's kept brief is read again every time, and the automatic brief is asked once, for a Home that is on screen, with one
/// reachability read.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraHomeShowTests {
    private let visible = HomeWindowFacts(hasWindow: true, isMiniaturized: false, occlusionVisible: true)

    private func whenIAsk() -> RemoraPreferences { RemoraPreferences(briefMode: .whenIAsk) }

    @Test func theKeptBriefIsReadAgainEachTimeHomeShowsSoADeletionsRemovalReachesTheScreen() async throws {
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 3_600)], preferences: whenIAsk())
        defer { Task { await rig.finish() } }
        let remora = rig.model.remora
        #expect(remora.keptBrief == nil, "nothing reads it at launch")
        try rig.keepBrief(text: "Billing moved.", chips: [(0, "Waits for review")])
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible)
        #expect(remora.keptBrief?.text == "Billing moved." && remora.keptBrief?.chips.count == 1)
        // Core removes the file when a session it names is deleted: the next Home shows no brief, with nothing else touched.
        try FileManager.default.removeItem(at: rig.remoraDirectory.appendingPathComponent("day-brief.json"))
        #expect(remora.keptBrief != nil, "the state stands until Home shows again")
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible)
        #expect(remora.keptBrief == nil, "each Home show reads it again")
        try rig.keepBrief(text: "Second.", chips: [])
        await HomeRemoraCalls.homeShown(model: rig.model, window: .none)
        #expect(remora.keptBrief?.text == "Second.", "also when the window is not known yet")
        #expect(!rig.ranAProcess && !remora.isBusy, "a brief set to When I ask starts nothing")
    }

    @Test func theAutomaticBriefAsksOnlyForAHomeOnScreenWhenOnlineAndOnlyOnceADay() async throws {
        let rig = try await RemoraHomeRig.make(
            seeds: [.init(title: "Billing", project: 0, ago: 3_600)],
            script: ["LOOM_FAKE_REMORA_ANSWER": "You left off in loom, where billing waits."])
        defer { Task { await rig.finish() } }
        let remora = rig.model.remora
        var reads = 0

        await HomeRemoraCalls.homeShown(model: rig.model, window: .none, isOnline: { reads += 1; return true })
        #expect(reads == 0 && !rig.ranAProcess && !remora.isBusy, "no window, no ask and no reachability read")
        await HomeRemoraCalls.homeShown(model: rig.model, window: HomeWindowFacts(hasWindow: true, isMiniaturized: true, occlusionVisible: true),
                                        isOnline: { reads += 1; return true })
        await HomeRemoraCalls.homeShown(model: rig.model, window: HomeWindowFacts(hasWindow: true, isMiniaturized: false, occlusionVisible: false),
                                        isOnline: { reads += 1; return true })
        #expect(reads == 0 && !rig.ranAProcess, "a miniaturized or covered window asks nothing")
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { reads += 1; return false })
        await remora.settle()
        #expect(reads == 1, "one read for one show")
        #expect(!rig.ranAProcess && remora.lastAnswer == nil && remora.lastBriefDecision == nil, "offline starts nothing and records nothing")

        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { reads += 1; return true })
        await remora.settle()
        #expect(reads == 2)
        #expect(rig.ranAProcess)
        #expect(remora.lastAnswer?.kind == .brief && remora.lastAnswer?.answer.text.hasPrefix("You left off in loom") == true)
        #expect(remora.keptBrief?.text.hasPrefix("You left off in loom") == true, "the day's brief is kept for a relaunch")
        #expect(remora.usage?.today.briefs == 1)

        // The next Home of the same day asks again and is told no: one brief a day.
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { true })
        await remora.settle()
        #expect(remora.usage?.today.briefs == 1)
    }

    @Test func aWaitingBriefLeavesItsReasonForHomeAndCatchMeUpAnywayRunsIt() async throws {
        // The plan's 5-hour window has 5 % left, under the 10 % threshold: the morning brief waits.
        let rig = try await RemoraHomeRig.make(
            seeds: [.init(title: "Billing", project: 0, ago: 3_600)],
            script: ["LOOM_FAKE_REMORA_ANSWER": "A brief anyway."])
        defer { Task { await rig.finish() } }
        let remora = rig.model.remora
        let limits = FakeLimits()
        limits.setAnswer(PlanLimits(fiveHour: PlanLimitWindow(usedPercent: 95, resetsAt: Date().addingTimeInterval(2 * 3_600)), weekly: nil,
                                    fetchedAt: Date()))
        let usage = UsageModel(index: FakeUsageIndex(), limits: limits, timeZone: TimeZone(identifier: "UTC")!)
        rig.model.usage = usage
        usage.refresh(reason: .launch)
        await usage.settle()
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { true })
        await remora.settle()
        guard case .wait(.windowLow)? = remora.lastBriefDecision else {
            Issue.record("the decision was \(String(describing: remora.lastBriefDecision))")
            return
        }
        #expect(!rig.ranAProcess)
        let ui = HomeRemoraUI()
        #expect(HomeRemoraCalls.catchMeUp(rig.model, ui: ui), "Catch Me Up Anyway asks whatever the schedule says")
        await remora.settle()
        #expect(remora.lastAnswer?.answer.text == "A brief anyway." && remora.lastBriefDecision == nil)
    }

    // MARK: The closing review (1.6.0)

    @Test func aHostInstalledAfterHomeShowedAsksHomeAgainAndTheBriefIsAsked() async throws {
        // The app shows its window (and a restored Home) before the runtime installs Remora's host.
        let seeds: [RemoraHomeRig.Seed] = [.init(title: "Billing", project: 0, ago: 3_600)]
        let script = ["LOOM_FAKE_REMORA_ANSWER": "You left off in loom, where billing waits."]
        let rig = try await RemoraHomeRig.make(seeds: seeds, script: script, withHost: false)
        defer { Task { await rig.finish() } }
        let remora = rig.model.remora
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { true })
        #expect(!rig.ranAProcess && remora.keptBrief == nil, "nothing to ask without the host")
        // Home's show task is keyed on what it observes: the host's arrival must change it, and be seen.
        let before = HomeRemoraShowKey(windowAttached: true, hasHost: rig.model.hasRemora)
        let changed = ObservedFlag()
        withObservationTracking { _ = rig.model.hasRemora } onChange: { changed.set() }
        rig.makeHost(seeds: seeds, preferences: RemoraPreferences(), script: script, now: rig.base)
        #expect(changed.value, "installing the host was not observable: Home would not ask again")
        #expect(HomeRemoraShowKey(windowAttached: true, hasHost: rig.model.hasRemora) != before)
        // What Home's task then runs: the brief is asked once the host is there.
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { true })
        await remora.settle()
        #expect(rig.ranAProcess, "the brief was not asked once the host arrived")
        #expect(remora.keptBrief?.text.hasPrefix("You left off in loom") == true, "the day's brief was not kept and read back")
    }

    @Test func aKeptBriefLoadsOnceTheHostArrives() async throws {
        let seeds: [RemoraHomeRig.Seed] = [.init(title: "Billing", project: 0, ago: 3_600)]
        let rig = try await RemoraHomeRig.make(seeds: seeds, preferences: whenIAsk(), withHost: false)
        defer { Task { await rig.finish() } }
        try rig.keepBrief(text: "Kept from this morning.", chips: [(0, "Waits for review")])
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { true })
        #expect(rig.model.remora.keptBrief == nil)
        rig.makeHost(seeds: seeds, preferences: whenIAsk(), script: [:], now: rig.base)
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { true })
        #expect(rig.model.remora.keptBrief?.text == "Kept from this morning.")
        #expect(!rig.ranAProcess)
    }

    @Test func aFailedPaletteQuestionLeavesHomesBriefAndAHomeQuestionsFailureStaysUnderItsField() async throws {
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 3_600)], preferences: whenIAsk(),
                                               script: ["LOOM_FAKE_REMORA": "error"])
        defer { Task { await rig.finish() } }
        let remora = rig.model.remora
        try rig.keepBrief(text: "Billing moved.", chips: [(0, "Waits for review")])
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible)
        let reads = HomeRemoraReads(baselineUndo: nil)
        await reads.read(model: rig.model)
        #expect(HomeRemoraContext.make(model: rig.model, reads: reads, ui: HomeRemoraUI()).state == .brief)

        // ⌘K's question fails: Home still shows the day's brief.
        #expect(PaletteRemoraCalls.ask(rig.model, "What moved in billing?", scope: .allProjects))
        await remora.settle()
        #expect(remora.lastFailure == .apiError)
        #expect(HomeRemoraContext.make(model: rig.model, reads: reads, ui: HomeRemoraUI()).state == .brief,
                "a ⌘K failure took the brief's place on Home")

        // Home's own question fails, and the user leaves Home and comes back (a new HomeRemoraUI): the brief, not the failure.
        let ui = HomeRemoraUI()
        #expect(HomeRemoraCalls.ask(rig.model, ui: ui, "What moved in billing?"))
        await remora.settle()
        #expect(HomeRemoraAnswerContent.make(model: rig.model, asked: try #require(ui.asked), baselineUndo: nil)?.body == .failed(.apiError))
        #expect(HomeRemoraContext.make(model: rig.model, reads: reads, ui: HomeRemoraUI()).state == .brief,
                "a question's failure took the brief's place after Home came back")

        // A brief's failure does take its place, and Try Again is a brief.
        #expect(HomeRemoraCalls.catchMeUp(rig.model, ui: ui))
        await remora.settle()
        #expect(HomeRemoraContext.make(model: rig.model, reads: reads, ui: HomeRemoraUI()).state == .cannotAnswer(.generic(.apiError)))
    }

    @Test func homesAnswerCardDoesNotStreamAPaletteQuestion() async throws {
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 3_600)], preferences: whenIAsk(),
                                               script: ["LOOM_FAKE_REMORA": "slow", "LOOM_FAKE_REMORA_ANSWER": "Billing waits for review."])
        defer { Task { await rig.finish() } }
        let remora = rig.model.remora
        let ui = HomeRemoraUI()
        #expect(HomeRemoraCalls.ask(rig.model, ui: ui, "What moved in billing?"))
        let asked = try #require(ui.asked)
        #expect(HomeRemoraAnswerContent.make(model: rig.model, asked: asked, baselineUndo: nil)?.body
                    == .working(reading: remora.reading, text: remora.streamedText), "Home's own question streams into its card")
        await remora.settle()
        // ⌘K asks while Home's answer is open: its words stream elsewhere, never under Home's question.
        #expect(PaletteRemoraCalls.ask(rig.model, "Anything else waiting?", scope: .allProjects))
        for _ in 0..<300 where remora.streamedText.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(remora.phase == .asking && !remora.streamedText.isEmpty)
        if case .working? = HomeRemoraAnswerContent.make(model: rig.model, asked: asked, baselineUndo: nil)?.body {
            Issue.record("a ⌘K question streamed into Home's card")
        }
        rig.model.stopRemora()
        await remora.settle()
        if case .stopped? = HomeRemoraAnswerContent.make(model: rig.model, asked: asked, baselineUndo: nil)?.body {
            Issue.record("a stopped ⌘K question showed as Home's")
        }
    }

    @Test func withRemoraOffHomesReadsOpenNoMemoryAndMakeNoFolder() async throws {
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 3_600)],
                                               preferences: RemoraPreferences(isOn: false))
        defer { Task { await rig.finish() } }
        try rig.keepBrief(text: "Kept from this morning.", chips: [(0, "Waits for review")])
        await HomeRemoraCalls.homeShown(model: rig.model, window: visible, isOnline: { true })
        let reads = HomeRemoraReads(baselineUndo: nil)
        await reads.read(model: rig.model)
        let host = try #require(rig.host)
        #expect(!host.memoryIsOpen, "Home opened Remora's memory with Remora off")
        for folder in ["journal", "projects"] {
            #expect(!FileManager.default.fileExists(atPath: rig.remoraDirectory.appendingPathComponent(folder).path),
                    "Home made remora/\(folder) with Remora off")
        }
        #expect(rig.model.remora.keptBrief == nil && !reads.hasRead && !rig.ranAProcess)
        // Turning Remora on is a new read key: Home reads then.
        let off = rig.model.homeRemoraReadKey
        rig.model.setRemoraOn(true)
        #expect(rig.model.homeRemoraReadKey != off)
    }
}

/// A flag an observation's `onChange` sets (it may run off the main actor).
private final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
