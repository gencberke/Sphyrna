import Foundation
import Testing
@testable import LoomCore

struct SessionEventHubTests {
    @Test func fastConsumerSeesTypedChangesInOrder() async throws {
        let hub = SessionEventHub()
        let sessionID = UUID(), runID = UUID()
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.sequence == 0)
        let changes: [SessionEventChange] = [
            .conversationIdentity("provider-thread"),
            .runStarted(runID),
            .status(ProviderWorkState(activity: .working)),
            .identityState(.ambiguous),
            .blockers([.ambiguousIdentity]),
            .lifecycle(.idle),
            .runEnded(runID, .idle),
        ]
        for (offset, change) in changes.enumerated() {
            await hub.publish(sessionID: sessionID, change: change)
            let frame = try #require(await iterator.next())
            #expect(frame.sequence == offset + 1)
            #expect(frame.sessionID == sessionID)
            #expect(frame.change == change)
        }
        let final = await hub.snapshot()
        #expect(final.sessions[sessionID]?.runID == nil)
        #expect(final.sessions[sessionID]?.identity == .ambiguous)
        #expect(final.sessions[sessionID]?.blockers == [.ambiguousIdentity])
        #expect(final.sessions[sessionID]?.lifecycle == .idle)
    }

    @Test func slowConsumerGetsLatestStateAfterCoalescing() async throws {
        let hub = SessionEventHub()
        let first = UUID(), second = UUID()
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        for index in 0..<100 {
            await hub.publish(
                sessionID: first,
                change: .conversationIdentity("thread-\(index)")
            )
            await hub.publish(
                sessionID: second,
                change: .status(ProviderWorkState(activity: .turnComplete))
            )
        }
        let frame = try #require(await iterator.next())
        #expect(frame.sequence == 200)
        #expect(frame.sessions[first]?.conversationID == "thread-99")
        #expect(frame.sessions[second]?.status?.activity == .turnComplete)
    }
}
