import Foundation
import Testing
@testable import LoomCore
@testable import LoomCoreTestRigs

private final class OpenCodeFeedWaitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var finished: Bool { lock.withLock { value } }
    func finish() { lock.withLock { value = true } }
}

@Suite struct OpenCodeLiveFeedTests {
    private func event(_ type: String, session: String, seq: Int64, input: String? = nil, version: Int = 1) -> OpenCodeEvent {
        .init(id: "evt_\(seq)", type: type, sessionID: session, sequence: seq, inboxID: input, version: version)
    }

    @Test func creationBeforeResponseBindsTheExactAppRunAndNativeSession() throws {
        let appID = UUID(), runID = UUID()
        let feed = OpenCodeLiveFeed(appSessionID: appID, runID: runID)
        feed.didConnect()
        #expect(feed.receive(event("session.created", session: "ses_other", seq: 1)))
        #expect(feed.receive(event("session.created", session: "ses_one", seq: 3)))
        try feed.bind(nativeSessionID: "ses_one")
        let value = try #require(feed.snapshot)
        #expect(value.appSessionID == appID)
        #expect(value.runID == runID)
        #expect(value.nativeSessionID == "ses_one")
        #expect(value.creationSequence == 3)
        #expect(value.execution == .unknown)
        feed.didDisconnect()
        #expect(feed.snapshot?.creationSequence == nil)
        #expect(feed.snapshot?.execution == .unknown)
        #expect(!feed.isConnected)
    }

    @Test func boundedEarlyEventsAndUnrecognizedVersionsFailClosed() throws {
        let feed = OpenCodeLiveFeed(appSessionID: UUID(), runID: UUID())
        feed.didConnect()
        for seq in 0..<128 {
            #expect(feed.receive(event("session.created", session: "ses_\(seq)", seq: Int64(seq))))
        }
        #expect(!feed.receive(event("session.created", session: "ses_overflow", seq: 128)))
        #expect(throws: OpenCodeError.unavailable) { try feed.bind(nativeSessionID: "ses_1") }
        #expect(!feed.isConnected)
        feed.didConnect()
        #expect(!feed.isConnected)

        let second = OpenCodeLiveFeed(appSessionID: UUID(), runID: UUID())
        second.didConnect()
        try second.bind(nativeSessionID: "ses_one")
        #expect(!second.receive(event("session.execution.started", session: "ses_one", seq: 1, version: 2)))
        #expect(!second.isConnected)
        second.didDisconnect()
        #expect(second.snapshot?.execution == .unknown)
    }
    @Test func disconnectFinishesUnboundAndLateObservers() async throws {
        let feed = OpenCodeLiveFeed(appSessionID: UUID(), runID: UUID())
        feed.didConnect()
        let updates = feed.updates()
        let signal = OpenCodeFeedWaitResult()
        let pending = Task {
            var iterator = updates.makeAsyncIterator()
            let value = await iterator.next()
            if value == nil { signal.finish() }
        }
        feed.didDisconnect()
        // The finish is synchronous; only the observer's task resuming takes time, and under the full gate's parallel load
        // that took longer than half a second (both waits failed in `150456-76010`). The wait returns as soon as it holds.
        #expect(await SessionRuntimeRig.waitUntil(5) { signal.finished })
        pending.cancel()
        _ = await pending.value

        let late = feed.updates()
        let lateSignal = OpenCodeFeedWaitResult()
        let waiting = Task {
            var iterator = late.makeAsyncIterator()
            let value = await iterator.next()
            if value == nil { lateSignal.finish() }
        }
        #expect(await SessionRuntimeRig.waitUntil(5) { lateSignal.finished })
        waiting.cancel()
        _ = await waiting.value
    }

}
