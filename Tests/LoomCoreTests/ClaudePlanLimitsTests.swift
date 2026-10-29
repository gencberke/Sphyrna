import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore
import LoomTestSupport

struct PlanLimitsRuleTests {
    private let now = Date(timeIntervalSince1970: 1_791_374_400)

    private func window(_ used: Int, _ seconds: TimeInterval?) -> PlanLimitWindow {
        PlanLimitWindow(usedPercent: used, resetsAt: seconds.map { now.addingTimeInterval($0) })
    }

    @Test func theBottleneckIsTheLeastRemainingThenTheEarlierResetAndExpiredWindowsAreIgnored() {
        func limits(_ five: PlanLimitWindow?, _ week: PlanLimitWindow?) -> PlanLimits {
            PlanLimits(fiveHour: five, weekly: week, fetchedAt: now)
        }
        #expect(limits(window(38, 3_600), window(82, 86_400)).bottleneck(at: now)?.kind == .weekly)
        #expect(limits(window(90, 3_600), window(82, 86_400)).bottleneck(at: now)?.kind == .fiveHour)
        #expect(limits(window(50, 7_200), window(50, 3_600)).bottleneck(at: now)?.kind == .weekly)
        #expect(limits(window(50, 3_600), window(50, 7_200)).bottleneck(at: now)?.kind == .fiveHour)
        #expect(limits(window(99, -1), window(10, 86_400)).bottleneck(at: now)?.kind == .weekly)
        #expect(limits(window(99, -1), window(10, 0)).bottleneck(at: now) == nil)
        #expect(limits(nil, window(10, nil)).bottleneck(at: now)?.kind == .weekly)
    }
}

/// The plan pace line's arithmetic: used share against the share of the window that has passed.
struct PlanPaceTests {
    private let now = Date(timeIntervalSince1970: 1_791_374_400)

    private func pace(_ kind: PlanLimitKind = .fiveHour, used: Int, elapsed: Double, resetsIn: TimeInterval? = nil) -> PlanPace? {
        let remaining = resetsIn ?? kind.duration * (1 - elapsed)
        return PlanPace(kind: kind, window: PlanLimitWindow(usedPercent: used, resetsAt: now.addingTimeInterval(remaining)), at: now)
    }

    @Test func theWindowsAreFiveHoursAndSevenDays() {
        #expect(PlanLimitKind.fiveHour.duration == 18_000)
        #expect(PlanLimitKind.weekly.duration == 604_800)
    }

    @Test func halfwayThroughWithAFifthUsedIsUnderPaceAndNeverRunsOut() throws {
        let pace = try #require(pace(used: 20, elapsed: 0.5))
        #expect(pace.status == .underPace)
        #expect(abs(pace.elapsedFraction - 0.5) < 1e-9)
        #expect(pace.usedFraction == 0.2)
        #expect(pace.runsOutAt == nil)
    }

    @Test func theToleranceIsFivePointsEitherSide() throws {
        #expect(try #require(pace(used: 55, elapsed: 0.5)).status == .onPace)   // exactly +5
        #expect(try #require(pace(used: 45, elapsed: 0.5)).status == .onPace)   // exactly -5
        #expect(try #require(pace(used: 56, elapsed: 0.5)).status == .overPace)
        #expect(try #require(pace(used: 44, elapsed: 0.5)).status == .underPace)
    }

    @Test func overPaceProjectsWhenTheWindowRunsOutAtTheRateSoFar() throws {
        // 60 % used after 2 of 5 hours: 100 % at 3 h 20 min in, 1 h 20 min from now, before the reset.
        let pace = try #require(pace(used: 60, elapsed: 0.4))
        #expect(pace.status == .overPace)
        let runsOut = try #require(pace.runsOutAt)
        #expect(abs(runsOut.timeIntervalSince(now) - 4_800) < 1e-6)
        #expect(runsOut < pace.resetsAt)
    }

    @Test func aUsedUpWindowIsOverPaceAndRunsOutNowAnywhereInTheWindow() throws {
        for elapsed in [0.0, 0.01, 0.5, 0.99] {
            let pace = try #require(pace(used: 100, elapsed: elapsed))
            #expect(pace.status == .overPace, "elapsed \(elapsed)")
            #expect(pace.runsOutAt == now, "elapsed \(elapsed)")
        }
    }

    // The edges of the window.

    @Test func earlyInTheWindowThereIsNoVerdictButTheUseIsStillThere() throws {
        let fresh = try #require(pace(used: 0, elapsed: 0))
        #expect(fresh.elapsedFraction == 0)
        #expect(fresh.status == .tooEarly)
        #expect(fresh.runsOutAt == nil)
        // A few percent in the first minutes is no rate to project (and does not divide by the elapsed time).
        let early = try #require(pace(used: 9, elapsed: 0.001))
        #expect(early.status == .tooEarly)
        #expect(early.usedFraction == 0.09)
        #expect(early.runsOutAt == nil)
        // Forty percent of a week used after a twentieth of it: not "it lasts" (8.4 hours is too little to say).
        let week = try #require(pace(.weekly, used: 40, elapsed: 0.04))
        #expect(week.status == .tooEarly)
        #expect(week.usedFraction == 0.4)
        // The same use once a twentieth has passed is a rate.
        #expect(try #require(pace(used: 20, elapsed: 0.05)).status == .overPace)
    }

    @Test func theElapsedTimeIsMeasuredWhereTheUseWasRead() throws {
        // Read 30 minutes into a five-hour window with 30 % used: far over pace.
        let readAt = now
        let resets = readAt.addingTimeInterval(4.5 * 3_600)
        let window = PlanLimitWindow(usedPercent: 30, resetsAt: resets)
        // Two and a half hours later the same answer, measured at "now", would read as 30 % after 60 %
        // of the window: under pace, "it lasts". Measured where it was read it is still over pace.
        let later = readAt.addingTimeInterval(2.5 * 3_600)
        let drifting = try #require(PlanPace(kind: .fiveHour, window: window, at: later))
        #expect(drifting.status == .underPace)
        let anchored = try #require(PlanPace(kind: .fiveHour, window: window, at: later, measuredAt: readAt))
        #expect(anchored.status == .overPace)
        #expect(abs(anchored.elapsedFraction - 0.1) < 1e-9)
        #expect((try #require(anchored.runsOutAt)) >= later)
        // Through the limits: `fetchedAt` is that moment.
        let limits = PlanLimits(fiveHour: window, weekly: nil, fetchedAt: readAt)
        #expect(limits.paces(at: later).first?.status == .overPace)
        // A read time in the future is not trusted past `now`.
        #expect(try #require(PlanPace(kind: .fiveHour, window: window, at: readAt, measuredAt: later)).elapsedFraction
                == 0.1)
    }

    @Test func aResetFurtherAwayThanTheWindowIsNotStarted() throws {
        let pace = try #require(pace(used: 3, elapsed: 0, resetsIn: PlanLimitKind.fiveHour.duration + 7_200))
        #expect(pace.elapsedFraction == 0)
        #expect(pace.status == .tooEarly)
    }

    @Test func justBeforeTheResetTheWholeWindowHasPassed() throws {
        let pace = try #require(pace(used: 96, elapsed: 0, resetsIn: 1))
        #expect(pace.elapsedFraction > 0.9999)
        #expect(pace.status == .onPace)           // within five points of an even pace
        #expect(try #require(self.pace(used: 40, elapsed: 0, resetsIn: 1)).status == .underPace)
        #expect(try #require(self.pace(used: 99, elapsed: 0, resetsIn: 1)).status == .onPace)
    }

    @Test func anEndedWindowOrOneWithoutAResetTimeHasNoPace() {
        #expect(pace(used: 50, elapsed: 0, resetsIn: 0) == nil)   // resets exactly now: it is over
        #expect(pace(used: 50, elapsed: 0, resetsIn: -60) == nil)
        let unknown = PlanPace(kind: .weekly, window: PlanLimitWindow(usedPercent: 50, resetsAt: nil), at: now)
        #expect(unknown == nil)
    }

    @Test func theWeeklyWindowUsesItsOwnLength() throws {
        // Half of a week gone, a quarter used.
        let pace = try #require(self.pace(.weekly, used: 25, elapsed: 0.5))
        #expect(pace.kind == .weekly)
        #expect(pace.status == .underPace)
        #expect(abs(pace.elapsedFraction - 0.5) < 1e-9)
    }

    @Test func limitsGiveThePaceOfEachCurrentWindowFiveHourFirst() {
        let limits = PlanLimits(
            fiveHour: PlanLimitWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3_600)),
            weekly: PlanLimitWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(86_400)), fetchedAt: now)
        #expect(limits.paces(at: now).map(\.kind) == [.fiveHour, .weekly])
        // The five-hour window has ended; only the week is left.
        #expect(limits.paces(at: now.addingTimeInterval(7_200)).map(\.kind) == [.weekly])
        #expect(PlanLimits(fiveHour: nil, weekly: nil, fetchedAt: now).paces(at: now).isEmpty)
    }
}
