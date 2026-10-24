import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// Settings → General → Notify when a long turn finishes: which finished turns get a banner (`LongTurnWatch`), what it says, and
/// that the switch is kept.
@MainActor
@Suite struct LongTurnNotificationTests {
    private let id = UUID()
    private let start = Date(timeIntervalSince1970: 1_791_374_400)

    private func candidate(_ indicator: SessionIndicator, _ session: UUID? = nil) -> AttentionCandidate {
        AttentionCandidate(id: session ?? id, indicator: indicator, lastActivityAt: start)
    }

    /// A turn of `seconds` that ends at `end`, followed as the menu bar changes would follow it; what each step posts.
    private func turn(seconds: TimeInterval, end: SessionIndicator = .ready, enabled: Bool = true, appIsActive: Bool = false,
                      shown: UUID? = nil, watch: LongTurnWatch = LongTurnWatch()) -> (started: [UUID], ended: [UUID]) {
        let started = watch.finishedTurns([candidate(.working)], enabled: enabled, appIsActive: appIsActive, shown: shown, now: start)
        let ended = watch.finishedTurns([candidate(end)], enabled: enabled, appIsActive: appIsActive, shown: shown,
                                        now: start.addingTimeInterval(seconds))
        return (started, ended)
    }

    @Test func withTheSwitchOffNothingIsPosted() {
        #expect(turn(seconds: 120, enabled: false).ended.isEmpty)
    }

    @Test func aThirtySecondTurnThatEndsOffScreenPostsOneBannerWithOpen() {
        let result = turn(seconds: 30)
        #expect(result.started.isEmpty, "nothing while the turn runs")
        #expect(result.ended == [id], "one banner as it ends")
        #expect(turn(seconds: 45, end: .unviewedCompletion).ended == [id], "an unseen finish counts too")
        #expect(LongTurnWatch.title(session: "Fix the sidebar") == "Fix the sidebar finished")
        #expect(LongTurnWatch.openActionTitle == "Open")
        #expect(LongTurnWatch.openActionIdentifier != LongTurnWatch.categoryIdentifier)
    }

    @Test func aTenSecondTurnPostsNothing() {
        #expect(turn(seconds: 10).ended.isEmpty)
        #expect(turn(seconds: 29.9).ended.isEmpty)
    }

    @Test func aSessionOnScreenInTheActiveAppPostsNothing() {
        #expect(turn(seconds: 60, appIsActive: true, shown: id).ended.isEmpty, "the user is looking at it")
        #expect(turn(seconds: 60, appIsActive: false, shown: id).ended == [id], "shown, but Sphyrna is in the background")
        #expect(turn(seconds: 60, appIsActive: true, shown: UUID()).ended == [id], "Sphyrna is active on another session")
    }

    @Test func aTurnEndingInARequestThatWaitsPostsNothing() {
        #expect(turn(seconds: 60, end: .waitingForApproval).ended.isEmpty, "the needs-approval banner speaks for it")
        let watch = LongTurnWatch()
        #expect(turn(seconds: 60, end: .waitingForInput, watch: watch).ended.isEmpty, "a question or an elicitation waits")
        let later = watch.finishedTurns([candidate(.ready)], enabled: true, appIsActive: false, shown: nil,
                                        now: start.addingTimeInterval(90))
        #expect(later.isEmpty, "answering it later is not a finished turn")
        #expect(turn(seconds: 60, end: .failed("boom")).ended.isEmpty, "a failed turn is not a finished one")
    }

    @Test func anApprovalInTheMiddleOfATurnKeepsItsStart() {
        let watch = LongTurnWatch()
        _ = watch.finishedTurns([candidate(.working)], enabled: true, appIsActive: false, shown: nil, now: start)
        _ = watch.finishedTurns([candidate(.waitingForApproval)], enabled: true, appIsActive: false, shown: nil,
                                now: start.addingTimeInterval(20))
        _ = watch.finishedTurns([candidate(.working)], enabled: true, appIsActive: false, shown: nil, now: start.addingTimeInterval(25))
        let ended = watch.finishedTurns([candidate(.ready)], enabled: true, appIsActive: false, shown: nil,
                                        now: start.addingTimeInterval(35))
        #expect(ended == [id], "35 s from the first working state")
    }

    @Test func theSwitchIsOffByDefaultAndKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-long-turns-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("p.json"))
        let integration = SystemIntegration()
        integration.attach(preferences: preferences)
        #expect(!integration.notifyLongTurns)
        var changes = 0
        integration.onNotifyLongTurnsChange = { changes += 1 }
        integration.setNotifyLongTurns(true)
        #expect(changes == 1)
        let relaunched = SystemIntegration()
        relaunched.attach(preferences: UIPreferencesStore(url: preferences.url))
        #expect(relaunched.notifyLongTurns)
    }
}
