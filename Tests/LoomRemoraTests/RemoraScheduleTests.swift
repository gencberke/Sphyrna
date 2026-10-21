import Foundation
import Testing
@testable import LoomRemora

/// L1b: whether the morning brief runs now. Pure; a fixed time zone and fixed dates.
struct RemoraScheduleTests {
    private let zone = TimeZone(identifier: "Europe/Istanbul")!  // UTC+3 all year

    private func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Automatic, Home shown, a session active at 21 October 08:00, now 21 October 09:00, never briefed, plenty of window.
    private func input(_ change: (inout RemoraScheduleInput) -> Void = { _ in }) -> RemoraScheduleInput {
        var value = RemoraScheduleInput(
            remoraOn: true, briefMode: .automatic, now: local(21, 9), timeZone: zone, lastBrief: nil,
            newestActivity: local(21, 8), homeShown: true, windowRemainingShare: 0.8)
        change(&value)
        return value
    }

    @Test func aBriefRunsWhenEverythingAllowsIt() {
        #expect(RemoraSchedule.decide(input()) == .run)
        #expect(RemoraSchedule.decide(input { $0.windowRemainingShare = nil }) == .run, "an unknown window never holds it back")
        #expect(RemoraSchedule.decide(input { $0.windowRemainingShare = 0.10 }) == .run, "the threshold itself is enough")
    }

    @Test func eachReasonHolds() {
        typealias Change = (inout RemoraScheduleInput) -> Void
        let table: [(String, Change, RemoraBriefDecision)] = [
            ("Remora off", { $0.remoraOn = false }, .skip(.remoraOff)),
            ("When I ask", { $0.briefMode = .whenIAsk }, .skip(.whenIAsk)),
            ("Home not shown", { $0.homeShown = false }, .skip(.homeNotShown)),
            ("no session at all", { $0.newestActivity = nil }, .skip(.nothingMoved)),
            ("window under the threshold", { $0.windowRemainingShare = 0.05 }, .wait(.windowLow(remaining: 0.05))),
            ("window under a custom threshold", { $0.windowRemainingShare = 0.2; $0.windowThreshold = 0.25 }, .wait(.windowLow(remaining: 0.2))),
            ("window empty", { $0.windowRemainingShare = 0 }, .wait(.windowLow(remaining: 0))),
        ]
        for (name, change, expected) in table {
            #expect(RemoraSchedule.decide(input(change)) == expected, "\(name)")
        }
    }

    @Test func offAndWhenIAskWinOverEverythingElse() {
        let busy = input { $0.homeShown = false; $0.windowRemainingShare = 0; $0.lastBrief = local(21, 5) }
        var off = busy; off.remoraOn = false
        #expect(RemoraSchedule.decide(off) == .skip(.remoraOff))
        var ask = busy; ask.briefMode = .whenIAsk
        #expect(RemoraSchedule.decide(ask) == .skip(.whenIAsk))
    }

    @Test func aBriefAlreadyRunTodayIsSkippedAndTheSecondOfTheDayNeverRuns() {
        var state = input()
        #expect(RemoraSchedule.decide(state) == .run)
        state.lastBrief = state.now  // the caller records the brief that ran
        #expect(RemoraSchedule.decide(state) == .skip(.alreadyBriefedToday))
        for (day, hour) in [(21, 9), (21, 15), (21, 23), (22, 1), (22, 3)] {
            var later = state
            later.now = local(day, hour, 59)
            later.newestActivity = later.now  // plenty moved since
            #expect(RemoraSchedule.decide(later) == .skip(.alreadyBriefedToday), "day \(day) \(hour):59")
        }
    }

    @Test func theDayStartsAtFourSoBeforeFourItIsStillYesterday() {
        // Briefed on the 21st at 09:00. At 03:59 on the 22nd it is still the 21st's day; at 04:00 a new day begins.
        var state = input { $0.lastBrief = local(21, 9); $0.newestActivity = local(22, 3) }
        state.now = local(22, 3, 59)
        #expect(RemoraSchedule.decide(state) == .skip(.alreadyBriefedToday))
        state.now = local(22, 4)
        #expect(RemoraSchedule.decide(state) == .run)
        // A brief at 02:00 belongs to the day that began at 04:00 the day before.
        state.lastBrief = local(22, 2)
        state.now = local(22, 3, 30)
        #expect(RemoraSchedule.decide(state) == .skip(.alreadyBriefedToday))
        state.now = local(22, 4, 1)
        #expect(RemoraSchedule.decide(state) == .run)
        // Without a brief since yesterday's 04:00, 02:00 runs one for the day that is still going.
        var night = input { $0.lastBrief = local(20, 9); $0.now = local(22, 2); $0.newestActivity = local(22, 1) }
        #expect(RemoraSchedule.decide(night) == .run)
        night.lastBrief = local(21, 5)
        #expect(RemoraSchedule.decide(night) == .skip(.alreadyBriefedToday))
        #expect(RemoraSchedule.dayStart(containing: local(22, 3, 59), in: zone) == local(21, 4))
        #expect(RemoraSchedule.dayStart(containing: local(22, 4), in: zone) == local(22, 4))
    }

    @Test func nothingMovedSinceTheLastBriefMeansNoBrief() {
        let yesterday = input { $0.lastBrief = local(20, 10); $0.newestActivity = local(20, 9) }
        #expect(RemoraSchedule.decide(yesterday) == .skip(.nothingMoved))
        let moved = input { $0.lastBrief = local(20, 10); $0.newestActivity = local(20, 11) }
        #expect(RemoraSchedule.decide(moved) == .run)
        // Never briefed: activity from before the day before does not count.
        #expect(RemoraSchedule.decide(input { $0.newestActivity = local(18, 12) }) == .skip(.nothingMoved))
        #expect(RemoraSchedule.decide(input { $0.newestActivity = local(20, 12) }) == .run)
        #expect(RemoraSchedule.briefSince(now: local(21, 9), lastBrief: nil, timeZone: zone) == local(20, 4))
        #expect(RemoraSchedule.briefSince(now: local(21, 9), lastBrief: local(20, 10), timeZone: zone) == local(20, 10))
    }

    @Test func aWaitingBriefRunsWhenTheWindowRecoversAndOnlyOnce() {
        var state = input { $0.windowRemainingShare = 0.04 }
        #expect(RemoraSchedule.decide(state) == .wait(.windowLow(remaining: 0.04)))
        state.windowRemainingShare = 0.6
        #expect(RemoraSchedule.decide(state) == .run)
        state.lastBrief = state.now
        #expect(RemoraSchedule.decide(state) == .skip(.alreadyBriefedToday))
    }
}
