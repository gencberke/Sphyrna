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

// MARK: Active section phase (FB4-2)

/// The hub decides which live runs belong in the activity view's Active section: under way from the start of a
/// turn, "ended unread" when it finished or failed unseen, out once read.
struct ActivePhaseTests {
    private let working = SessionEventChange.status(ProviderWorkState(activity: .working))
    private let complete = SessionEventChange.status(ProviderWorkState(activity: .turnComplete))
    private let waiting = SessionEventChange.status(ProviderWorkState(activity: .waitingForInput))

    private func phase(_ hub: SessionEventHub, _ id: UUID) async -> ActivePhase? {
        await hub.snapshot().sessions[id]?.activePhase
    }

    private func start(_ hub: SessionEventHub, _ id: UUID) async -> UUID {
        let run = UUID()
        await hub.publish(sessionID: id, change: .runStarted(run))
        return run
    }

    @Test func aTurnPutsTheRunUnderWayAndAFinishNobodySawKeepsItInUntilViewed() async {
        let hub = SessionEventHub(), id = UUID()
        _ = await start(hub, id)
        #expect(await phase(hub, id) == .inactive, "a started run is not in Active until a turn runs")
        await hub.publish(sessionID: id, change: working)
        #expect(await phase(hub, id) == .underWay)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .waitingForApproval)))
        #expect(await phase(hub, id) == .underWay)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: complete)
        #expect(await phase(hub, id) == .endedUnread)
        // Other changes and the idle notice do not read it.
        await hub.publish(sessionID: id, change: waiting)
        await hub.publish(sessionID: id, change: .lifecycle(.idle))
        #expect(await phase(hub, id) == .endedUnread)
        await hub.setViewed(sessionID: id)
        #expect(await phase(hub, id) == .inactive)
    }

    @Test func aFinishWhileTheSessionIsViewedNeverEntersAndItsIdleNoticeStaysOut() async {
        let hub = SessionEventHub(), id = UUID()
        _ = await start(hub, id)
        await hub.setViewed(sessionID: id)
        await hub.publish(sessionID: id, change: working)
        #expect(await phase(hub, id) == .underWay)
        await hub.publish(sessionID: id, change: complete)
        #expect(await phase(hub, id) == .inactive)
        // Claude's waiting notice about a minute after a turn the user read.
        await hub.publish(sessionID: id, change: waiting)
        #expect(await phase(hub, id) == .inactive)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .unknown)))
        #expect(await phase(hub, id) == .inactive)
    }

    @Test func theWaitingNoticeAndARepeatedFinishAfterAReadTurnStayOut() async {
        let hub = SessionEventHub(), id = UUID()
        _ = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: complete)
        await hub.setViewed(sessionID: id)
        await hub.publish(sessionID: id, change: waiting)
        #expect(await phase(hub, id) == .inactive)
        // A repeated finish (nothing changed in the turn) does not bring it back.
        await hub.publish(sessionID: id, change: complete)
        #expect(await phase(hub, id) == .inactive)
        await hub.publish(sessionID: id, change: waiting)
        await hub.publish(sessionID: id, change: complete)
        #expect(await phase(hub, id) == .inactive)
    }

    @Test func aFailedTurnStaysInUntilViewedAndViewingItPublishesTheChange() async throws {
        let hub = SessionEventHub(), id = UUID()
        _ = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .failed("rate limit"))))
        var state = try #require(await hub.snapshot().sessions[id])
        #expect(state.activePhase == .endedUnread)
        #expect(!state.unviewedCompletion, "a failure is not an unviewed completion, yet it ends unread")
        let before = await hub.snapshot().sequence
        await hub.setViewed(sessionID: id)
        state = try #require(await hub.snapshot().sessions[id])
        #expect(state.activePhase == .inactive)
        #expect(await hub.snapshot().sequence == before + 1, "viewing a failed turn is a frame")
        // Viewing something that changes nothing is not.
        await hub.setViewed(sessionID: nil)
        await hub.setViewed(sessionID: id)
        #expect(await hub.snapshot().sequence == before + 1)
    }

    @Test func aQuestionDuringTheTurnStaysInAndMarkReadAcknowledgesIt() async {
        let hub = SessionEventHub(), id = UUID()
        _ = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: waiting)
        #expect(await phase(hub, id) == .underWay, "a question asked during the turn stays under way")
        await hub.markRead(sessionID: id)
        #expect(await phase(hub, id) == .inactive, "an acknowledged question leaves")
        // Marking read while the provider works changes nothing.
        await hub.publish(sessionID: id, change: working)
        await hub.markRead(sessionID: id)
        #expect(await phase(hub, id) == .underWay)
        // And an unread end is read by the mark.
        await hub.publish(sessionID: id, change: complete)
        #expect(await phase(hub, id) == .endedUnread)
        await hub.markRead(sessionID: id)
        #expect(await phase(hub, id) == .inactive)
    }

    @Test func pendingProviderWorkKeepsTheRunUnderWayAfterTheTurn() async {
        let hub = SessionEventHub(), id = UUID()
        _ = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .turnComplete, pendingProviderWorkCount: 2)))
        #expect(await phase(hub, id) == .underWay)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .turnComplete, pendingProviderWorkCount: 1)))
        #expect(await phase(hub, id) == .underWay)
        await hub.publish(sessionID: id, change: complete)
        #expect(await phase(hub, id) == .endedUnread, "the last background task ended unseen")
    }

    @Test func aPromptARunEndAndANewRunTakeTheSessionOut() async {
        let hub = SessionEventHub(), id = UUID(), detached = UUID()
        var run = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        // A late end of an earlier run changes nothing.
        await hub.publish(sessionID: id, change: .runEnded(UUID(), .processExited))
        await hub.publish(sessionID: id, change: .runDetached(detached))
        #expect(await phase(hub, id) == .underWay)
        await hub.publish(sessionID: id, change: .runEnded(run, .processExited))
        #expect(await phase(hub, id) == .inactive)

        // Resume: the new run sits at its prompt.
        run = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: complete)
        #expect(await phase(hub, id) == .endedUnread)
        await hub.publish(sessionID: id, change: .runEnded(run, .processExited))
        #expect(await phase(hub, id) == .inactive)
        run = await start(hub, id)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .atPrompt)))
        #expect(await phase(hub, id) == .inactive)

        // A prompt, a detach and a new run each take a running turn out.
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .atPrompt)))
        #expect(await phase(hub, id) == .inactive)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: .runDetached(run))
        #expect(await phase(hub, id) == .inactive)
        run = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        run = await start(hub, id)
        #expect(await phase(hub, id) == .inactive)
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: .status(nil))
        #expect(await phase(hub, id) == .inactive)
        _ = run
    }

    @Test func aFrameThatChangesNothingStaysSilent() async {
        let hub = SessionEventHub(), id = UUID()
        _ = await start(hub, id)
        await hub.publish(sessionID: id, change: working)
        let sequence = await hub.snapshot().sequence
        await hub.publish(sessionID: id, change: working)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .unknown)))
        await hub.publish(sessionID: id, change: .markedRead)
        #expect(await hub.snapshot().sequence == sequence + 1, "the unknown status is a frame; the repeat and a mark are not")
        #expect(await phase(hub, id) == .underWay)
    }
}
