import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
import LoomTerminal
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

@MainActor
struct OpenRequestEvidenceTests {
    @Test func theSnapshotListsEachRequestWithItsPhaseAndRedactsTheTextForRealProviders() throws {
        let requester = UUID()
        let waiting = OpenRequestShared.openRequest(requester: requester)
        let failed = OpenRequestShared.openRequest(requester: requester, phase: .failed("Claude could not be started"))
        let rows = OpenRequestEvidence.rows([waiting, failed], redacted: false)
        #expect(rows.map { $0["phase"] as? String } == ["waiting", "failed"])
        #expect(rows[0]["id"] as? String == waiting.id.uuidString && rows[0]["requester"] as? String == requester.uuidString)
        #expect(rows[0]["title"] as? String == "EDDP-412 Fix login")
        #expect(rows[1]["failure"] as? String == "Claude could not be started")
        // D-69: no tracker key, no kind, no existing session in the snapshot.
        #expect(rows.allSatisfy { $0["ticket"] == nil && $0["kind"] == nil && $0["existingSession"] == nil })

        let redacted = OpenRequestEvidence.rows([waiting, failed], redacted: true)
        #expect(redacted.allSatisfy { $0["title"] as? String == "" && $0["failure"] as? String == "" })
        #expect(redacted.map { $0["phase"] as? String } == ["waiting", "failed"], "state stays visible")
        #expect(OpenRequestEvidence.rows([], redacted: false).isEmpty)
    }
}
