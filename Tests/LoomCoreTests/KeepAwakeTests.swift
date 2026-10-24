import Foundation
import Testing
@testable import LoomCore

/// Settings → General → Keep Mac awake: one assertion against idle system sleep while any session works, and only then.
@MainActor
@Suite struct KeepAwakeTests {
    @MainActor
    final class RecordingAssertion: IdleSleepAssertion {
        private(set) var holds = 0
        private(set) var releases = 0
        var held: Bool { holds > releases }

        func hold() -> Bool {
            holds += 1
            return true
        }

        func release() { releases += 1 }
    }

    @Test func offNeverHoldsTheAssertion() {
        let assertion = RecordingAssertion()
        let controller = KeepAwakeController(assertion: assertion)
        controller.workingChanged(2)
        controller.settingChanged(.off)
        controller.workingChanged(0)
        controller.workingChanged(1)
        #expect(assertion.holds == 0)
        #expect(!controller.isHeld)
    }

    @Test func workingSessionsHoldOneAssertionUntilTheLastEnds() {
        let assertion = RecordingAssertion()
        let controller = KeepAwakeController(assertion: assertion)
        controller.settingChanged(.whileWorking)
        #expect(assertion.holds == 0, "nothing works yet")
        controller.workingChanged(1)
        #expect(assertion.holds == 1 && controller.isHeld, "one working session holds it")
        controller.workingChanged(2)
        #expect(assertion.holds == 1, "a second working session takes no second assertion")
        controller.workingChanged(1)
        #expect(assertion.held && assertion.releases == 0, "still held while one works")
        controller.workingChanged(0)
        #expect(assertion.releases == 1 && !assertion.held && !controller.isHeld, "released as the last one ends")
    }

    @Test func turningTheSettingOffOrQuittingReleasesIt() {
        let assertion = RecordingAssertion()
        let controller = KeepAwakeController(assertion: assertion)
        controller.workingChanged(1)
        controller.settingChanged(.whileWorking)
        #expect(assertion.holds == 1, "turned on while a session works: held at once")
        controller.settingChanged(.off)
        #expect(assertion.releases == 1 && !controller.isHeld, "Off releases it while the session still works")
        controller.settingChanged(.whileWorking)
        #expect(assertion.holds == 2)
        controller.stop()
        #expect(assertion.releases == 2 && !assertion.held, "quit releases it")
    }

    @Test func theSettingKeepsItsKeyAndTitles() throws {
        #expect(KeepAwakeSetting.allCases.map(\.title) == ["Off", "While a session works"])
        let data = try JSONEncoder().encode(KeepAwakeSetting.whileWorking)
        #expect(String(decoding: data, as: UTF8.self) == "\"whileWorking\"")
    }
}
