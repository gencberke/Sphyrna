import Foundation
import Testing
@testable import LoomCore

struct SessionTaskCodexInitialStatusTests {
    @Test func initialThreadStatusIsPreservedAndUnknownNeverBecomesReady() async throws {
        let event = CodexAppServerClient.decodeEvent(method: "thread/started", params: .object([
            "thread": .object(["id": .string("native"), "status": .object(["type": .string("idle")])])
        ]))
        guard case let .threadStarted(identity) = event else { Issue.record("missing thread identity"); return }
        #expect(identity.initialStatus == .idle)
        let runID = UUID()
        let idle = CodexEventStateTracker(threadID: "native", managedRunID: runID, after: 5, initialStatus: identity.initialStatus)
        #expect(await idle.status().activity == .atPrompt, "an empty idle thread did not finish a turn")
        #expect(await idle.receive(.event(sequence: 6, .turnStarted(threadID: "native", turnID: "turn")), for: runID) == .applied)
        #expect(await idle.receive(.event(sequence: 5, .threadStatusChanged(threadID: "native", status: .idle)), for: runID) == .staleSequence)
        #expect(await idle.status().activity == .working)

        let unknowns: [CodexThreadStatus?] = [nil, .notLoaded, .unknown("future")]
        for status in unknowns {
            let tracker = CodexEventStateTracker(threadID: "native", managedRunID: runID, after: 5, initialStatus: status)
            #expect(await tracker.status().activity == .unknown)
        }
        let approval = CodexEventStateTracker(threadID: "native", managedRunID: runID, after: 5,
                                              initialStatus: .active([.waitingOnApproval]))
        #expect(await approval.status().activity == .waitingForApproval)
        let question = CodexEventStateTracker(threadID: "native", managedRunID: runID, after: 5,
                                              initialStatus: .active([.waitingOnUserInput]))
        #expect(await question.status().activity == .waitingForInput)
    }
}
