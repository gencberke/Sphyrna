import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// H1 item 4: the notice above a live terminal shows the state's issue while it has one.
struct SessionIssueNoticeTests {
    private let watchdog = "Loom is not receiving events from Claude, so this session's status may be wrong. The session itself is not affected."

    @Test func theNoticeTextIsTheStatesIssueAndGoneWhenTheIssueClears() {
        var live = SessionViewState(runID: UUID(), issue: watchdog)
        #expect(SessionIssueNotice.message(for: live) == watchdog)
        live.issue = nil
        #expect(SessionIssueNotice.message(for: live) == nil)
        #expect(SessionIssueNotice.message(for: nil) == nil)
        #expect(SessionIssueNotice.message(for: SessionViewState(runID: UUID(), issue: "")) == nil)
    }

    @Test func unrelatedChangesToTheStateDoNotChangeTheNotice() {
        var live = SessionViewState(runID: UUID(), issue: watchdog)
        let before = SessionIssueNotice.message(for: live)
        live.waitingAcknowledged.toggle()
        live.unviewedCompletion.toggle()
        live.status = ProviderWorkState(activity: .working, pendingProviderWorkCount: 2)
        #expect(SessionIssueNotice.message(for: live) == before)
    }
}
