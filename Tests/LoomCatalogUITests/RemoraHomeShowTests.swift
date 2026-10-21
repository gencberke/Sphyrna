import Foundation
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

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
}
