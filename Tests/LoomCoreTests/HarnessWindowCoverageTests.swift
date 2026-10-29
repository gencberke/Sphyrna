import Foundation
import Testing
@testable import LoomCore

@Suite struct HarnessWindowCoverageTests {
    @Test func completenessFollowsTheWindowPartAndNeverSurvivesAnAccountChangeAsStaleWindows() {
        let now = Date(timeIntervalSince1970: 1_791_600_000)
        let first = HarnessAccount.subscription(email: "one@example.invalid", plan: "max")
        let second = HarnessAccount.subscription(email: "two@example.invalid", plan: "max")
        let window = HarnessLimitWindow(id: "five_hour", name: "5-hour", durationMinutes: 300,
                                        usedPercent: 40, resetsAt: now.addingTimeInterval(3_600))
        let old = HarnessReading(provider: .claude, account: first, windows: [window], readAt: now, windowsComplete: false)
        let retained = old.updated(by: HarnessProbeAnswer(models: [HarnessModel(id: "m", displayName: "M", isDefault: false,
                                                                                 efforts: [])]), at: now)
        #expect(retained.windows == [window] && !retained.windowsComplete)
        let refreshed = retained.updated(by: HarnessProbeAnswer(windows: [window], windowsComplete: true), at: now)
        #expect(refreshed.windows == [window] && refreshed.windowsComplete)
        let changed = old.updated(by: HarnessProbeAnswer(account: second), at: now)
        #expect(changed.account == second && changed.windows.isEmpty)
        let partial = changed.updated(by: HarnessProbeAnswer(windows: [window], windowsComplete: false), at: now)
        #expect(partial.windows == [window] && !partial.windowsComplete)
    }
}
