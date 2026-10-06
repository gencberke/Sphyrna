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
                change: .status(ProviderWorkState(
                    activity: .turnComplete, pendingProviderWorkCount: index))
            )
        }
        let frame = try #require(await iterator.next())
        #expect(frame.sequence == 200)
        #expect(frame.sessions[first]?.conversationID == "thread-99")
        #expect(frame.sessions[second]?.status?.activity == .turnComplete)
    }

    // MARK: O-2 F5: unchanged state is not a frame

    @Test func equalStateEventsPublishNothingButRunEventsAlwaysDo() async throws {
        let hub = SessionEventHub()
        let id = UUID(), runID = UUID()
        let working = ProviderWorkState(activity: .working)
        await hub.publish(sessionID: id, change: .runStarted(runID))
        await hub.publish(sessionID: id, change: .status(working))
        await hub.publish(sessionID: id, change: .blockers([.activeTurn]))
        let base = await hub.snapshot().sequence
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        // Every pure-state kind, repeated with the value it already has.
        await hub.publish(sessionID: id, change: .status(working))
        await hub.publish(sessionID: id, change: .blockers([.activeTurn]))
        await hub.publish(sessionID: id, change: .issue(nil))
        await hub.publish(sessionID: id, change: .stopFailure(nil))
        await hub.publish(sessionID: id, change: .userRequests([]))
        await hub.publish(sessionID: id, change: .identityState(.known))
        await hub.publish(sessionID: id, change: .unviewedCompletion(false))
        await hub.publish(sessionID: id, change: .conversationIdentity(nil))
        await hub.publish(sessionID: UUID(), change: .blockers([]))
        #expect(await hub.snapshot().sequence == base)
        // Run events carry run identity and always publish, equal state or not.
        await hub.publish(sessionID: id, change: .runStarted(runID))
        var frame = try #require(await iterator.next())
        #expect(frame.sequence == base + 1)
        await hub.publish(sessionID: id, change: .runEnded(runID, .idle))
        frame = try #require(await iterator.next())
        #expect(frame.sequence == base + 2)
        await hub.publish(sessionID: id, change: .runEnded(runID, .idle))
        frame = try #require(await iterator.next())
        #expect(frame.sequence == base + 3)
        // A real change still publishes, and a new turn completion after work does.
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .turnComplete)))
        frame = try #require(await iterator.next())
        #expect(frame.sequence == base + 4)
        #expect(frame.sessions[id]?.unviewedCompletion == true)
    }

    // MARK: CP5 B3: recovery from the latest frame

    @Test func lateEventOfAnEarlierRunCannotEndTheNewerRun() async {
        let hub = SessionEventHub()
        let session = UUID(), first = UUID(), second = UUID()
        await hub.publish(sessionID: session, change: .runStarted(first))
        await hub.publish(sessionID: session, change: .runEnded(first, .processExited))
        await hub.publish(sessionID: session, change: .runStarted(second))
        await hub.publish(sessionID: session, change: .status(ProviderWorkState(activity: .working)))
        // Delayed end/detach notifications of the first run arrive afterwards.
        await hub.publish(sessionID: session, change: .runEnded(first, .requested))
        await hub.publish(sessionID: session, change: .runDetached(first))
        let state = await hub.snapshot().sessions[session]
        #expect(state?.runID == second)
        #expect(state?.status?.activity == .working)
        // The current run's own end still ends it.
        await hub.publish(sessionID: session, change: .runEnded(second, .processExited))
        #expect(await hub.snapshot().sessions[session]?.runID == nil)
    }

    @Test func slowConsumerRecoversRunIdentityStatusStopFailureAndCompletionFromOneFrame() async throws {
        let hub = SessionEventHub()
        let finished = UUID(), failing = UUID(), noisy = UUID()
        let finishedRun = UUID(), failingRun = UUID()
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        // The consumer does not read while all of this happens.
        await hub.publish(sessionID: finished, change: .conversationIdentity("thread-1"))
        await hub.publish(sessionID: finished, change: .runStarted(finishedRun))
        await hub.publish(sessionID: finished, change: .status(ProviderWorkState(activity: .working)))
        await hub.publish(sessionID: failing, change: .runStarted(failingRun))
        await hub.publish(sessionID: failing, change: .stopFailure("2 process(es) still running"))
        await hub.publish(sessionID: finished, change: .status(ProviderWorkState(activity: .turnComplete)))
        for index in 0..<300 {
            await hub.publish(sessionID: noisy, change: .conversationIdentity("noise-\(index)"))
        }
        let frame = try #require(await iterator.next())
        #expect(frame.sequence == 306)
        #expect(frame.sessions[finished]?.runID == finishedRun)
        #expect(frame.sessions[finished]?.conversationID == "thread-1")
        #expect(frame.sessions[finished]?.status?.activity == .turnComplete)
        #expect(frame.sessions[finished]?.unviewedCompletion == true)
        #expect(frame.sessions[finished]?.stopFailure == nil)
        #expect(frame.sessions[failing]?.runID == failingRun)
        #expect(frame.sessions[failing]?.stopFailure == "2 process(es) still running")
        #expect(frame.sessions[failing]?.unviewedCompletion == false)
        // A skipped working to complete to working sequence never leaves a stale finish.
        await hub.publish(sessionID: finished, change: .status(ProviderWorkState(activity: .working)))
        #expect(await hub.snapshot().sessions[finished]?.unviewedCompletion == false)
    }

    @Test func onlyExplicitViewingClearsAnUnviewedCompletion() async {
        let hub = SessionEventHub()
        let watched = UUID(), other = UUID()
        let complete = SessionEventChange.status(ProviderWorkState(activity: .turnComplete))
        await hub.setViewed(sessionID: watched)
        await hub.publish(sessionID: watched, change: complete)
        await hub.publish(sessionID: other, change: complete)
        var states = await hub.snapshot().sessions
        #expect(states[watched]?.unviewedCompletion == false)
        #expect(states[other]?.unviewedCompletion == true)
        // Snapshots, subscriptions and unrelated updates are not viewing.
        _ = await hub.subscribe()
        await hub.publish(sessionID: other, change: .lifecycle(.idle))
        await hub.publish(sessionID: watched, change: .lifecycle(.idle))
        #expect(await hub.snapshot().sessions[other]?.unviewedCompletion == true)
        // Repeating the same reliable state does not mark it again once seen.
        await hub.setViewed(sessionID: other)
        #expect(await hub.snapshot().sessions[other]?.unviewedCompletion == false)
        await hub.setViewed(sessionID: nil)
        await hub.publish(sessionID: other, change: complete)
        states = await hub.snapshot().sessions
        #expect(states[other]?.unviewedCompletion == false)
        // A run that ended without any reliable completion is not "finished".
        let unreliable = UUID(), run = UUID()
        await hub.publish(sessionID: unreliable, change: .runStarted(run))
        await hub.publish(sessionID: unreliable, change: .runEnded(run, .processExited))
        #expect(await hub.snapshot().sessions[unreliable]?.unviewedCompletion == false)
    }
}
