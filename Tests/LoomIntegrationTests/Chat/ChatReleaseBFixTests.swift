import Foundation
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

// Release B fix round 1 (from the real-Claude acceptance), driver side: each test fails without the fix it names.

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct ChatReleaseBFixTests {
    // MARK: F3. A failed capability probe is tried once more

    private func probeEvents(_ rig: Rig) -> [[String: Any]] {
        let journal = DiagnosticJournal.forDataRoot(rig.catalog.dataRoot)
        let text = (try? String(contentsOf: journal.currentURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["event"] as? String == "toolchain_probe_failed" }
    }

    /// F3. One probe failure in six app launches ended the start with `capabilityProbeFailed`, no retry, no journal detail.
    /// A toolchain that fails once and then answers starts; the failure is journaled by its kind, never by output.
    @Test func aProbeThatFailsOnceIsRetriedAndTheStartGoesThrough() async throws {
        let rig = try await Rig.make(probeFailures: 1)
        let driver = rig.driver(UUID())
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        #expect(await driver.currentPhase == .ready)
        let events = probeEvents(rig)
        #expect(events.count == 1)
        #expect(events.first?["kind"] as? String == "timeout")
        #expect(events.first?["attempt"] as? Int == 1 && events.first?["retrying"] as? Bool == true)
        // Nothing but the category: no command, no output.
        #expect(Set(events.first?.keys.map { $0 } ?? []) == ["event", "time", "provider", "kind", "attempt", "retrying"])
        _ = try await driver.stop()
        await rig.finish()
    }

    /// F3. A probe that fails twice fails the start, as before (the draft keeps its text above this layer), after two journal
    /// lines, and the next start resolves again.
    @Test func aProbeThatFailsTwiceFailsTheStartAndTheNextStartResolvesAgain() async throws {
        let rig = try await Rig.make(probeFailures: 2)
        let driver = rig.driver(UUID())
        await #expect(throws: ProviderToolchainError.self) {
            try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        }
        let events = probeEvents(rig)
        #expect(events.compactMap { $0["attempt"] as? Int } == [1, 2])
        #expect(events.last?["retrying"] as? Bool == false)
        let again = rig.driver(UUID())
        try await again.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        #expect(await again.currentPhase == .ready)
        _ = try await again.stop()
        await rig.finish()
    }
}
