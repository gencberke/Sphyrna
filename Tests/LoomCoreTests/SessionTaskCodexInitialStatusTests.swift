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

    @Test func nativeIdleRemainsDistinctFromTheInterruptedTurnOutcome() async throws {
        let run = UUID()
        let tracker = CodexEventStateTracker(threadID: "native", managedRunID: run, after: 0, initialStatus: .idle)
        #expect(await tracker.receive(.event(sequence: 1, .turnStarted(threadID: "native", turnID: "turn")), for: run) == .applied)
        #expect(await tracker.status().nativeThreadStatus == .active([]))
        #expect(await tracker.receive(.event(sequence: 2, .turnCompleted(threadID: "native", turnID: "turn",
                                                                         outcome: .interrupted, lastAssistantMessage: nil)), for: run) == .applied)
        #expect(await tracker.status().activity == .failed("interrupted"))
        #expect(await tracker.status().nativeThreadStatus == .active([]))
        let snapshot = CodexThreadSnapshot(threadID: "native", lastTurnID: "turn", lastTurnStartedAt: nil,
            lastTurnOutcome: .interrupted, lastAssistantMessage: nil, isIdle: true, status: .idle)
        #expect(await tracker.refresh(snapshot, after: 3) == .applied)
        #expect(await tracker.status().activity == .failed("interrupted"))
        #expect(await tracker.status().nativeThreadStatus == .idle)
        #expect(await tracker.status().lastTurnOutcome == .interrupted)
        let withoutOutcome = CodexThreadSnapshot(threadID: "native", lastTurnID: nil, lastTurnStartedAt: nil,
            lastTurnOutcome: nil, lastAssistantMessage: nil, isActive: true, status: .active([]))
        #expect(await tracker.refresh(withoutOutcome, after: 4) == .applied)
        let retained = await tracker.status()
        #expect(retained.activity == .working && retained.lastTurnOutcome == .interrupted)
        let active = CodexThreadSnapshot(threadID: "native", lastTurnID: "turn", lastTurnStartedAt: nil,
            lastTurnOutcome: .failed("earlier failure"), lastAssistantMessage: nil,
            isActive: true, status: .active([]))
        #expect(await tracker.refresh(active, after: 5) == .applied)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.status().lastTurnOutcome == .failed("earlier failure"))
    }

}
