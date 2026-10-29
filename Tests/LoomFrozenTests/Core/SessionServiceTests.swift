import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private typealias HostFailure = SessionServiceShared.HostFailure
private typealias HostStopping = SessionServiceShared.HostStopping
private typealias Gate = SessionServiceShared.Gate
private typealias FakeHost = SessionServiceShared.FakeHost
private typealias FakeSinks = SessionServiceShared.FakeSinks
private typealias Told = SessionServiceShared.Told

/// R5a: the session service owns the lifecycle's orchestration and its transition state. Both faces are fakes (a structured
/// host that records what it was asked and a terminal that hands out sinks); the runtime is the real one over the fake
/// provider, so a terminal run and its Stop are real. Nothing waits on a clock: each test awaits the task an operation returns.

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
@MainActor
struct SessionServiceTests: SessionServiceFixtures {
    // MARK: Start keys

    @Test func theStructuredStartKeyIsReleasedAtReadyWhateverTheFirstMessageDoes() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let gate = Gate()
        rig.host.script = .readyThenHold(gate)
        let task = start(rig)
        // Ready was told, so the card exists and the next draft of the project may start while the message is still going.
        while rig.told.cards.isEmpty { await Task.yield() }
        #expect(rig.service.transitions.startingKeys.isEmpty)
        #expect(start(rig) != nil)
        gate.open()
        await task?.value
    }

    // MARK: Failures

    @Test func aStructuredStartThatFailsBeforeReadyForgetsItsSessionAndTellsOnce() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failBeforeReady(HostFailure())
        await start(rig)?.value
        let session = try #require(rig.host.newSessions.first?.session)
        #expect(rig.host.forgotten == [session])
        #expect(rig.told.failures == [.startFailed(.claude)] && rig.told.notStarted == 1 && rig.told.cards.isEmpty)
        // The banner comes before the draft is told, and the key is free again.
        #expect(rig.told.events == ["failure", "notStarted"])
        #expect(rig.service.transitions.startingKeys.isEmpty)
    }

    @Test func aStructuredStartThatFailsAfterReadyKeepsItsSessionAndOnlyReports() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failAfterReady
        await start(rig)?.value
        #expect(rig.host.forgotten.isEmpty && rig.told.cards.count == 1 && rig.told.notStarted == 0)
        #expect(rig.told.failures == [.startFailed(.claude)])
        #expect(rig.told.events == ["card", "failure"])
    }

    @Test func aStoppingCancellationReportsNothingAndKeepsTheOtherOutcome() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failBeforeReady(HostStopping())
        await start(rig)?.value
        #expect(rig.told.failures.isEmpty)
        #expect(rig.told.notStarted == 1 && rig.host.forgotten.isEmpty)
        #expect(rig.service.transitions.startingKeys.isEmpty)

        // The same in an approved opening.
        rig.host.script = .failBeforeReady(HostStopping())
        await rig.service.approveOpen(requestID: UUID())?.value
        #expect(rig.told.failures.isEmpty && rig.host.forgotten.isEmpty)
    }

    @Test func anApprovedOpeningThatFailedBeforeReadyForgetsItsSessionAndIsABanner() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failBeforeReady(HostFailure())
        await rig.service.approveOpen(requestID: UUID())?.value
        #expect(rig.host.forgotten == [rig.host.opened[0].session])
        #expect(rig.told.failures == [.startFailed(.claude)])
    }

    // MARK: Handover (Chat → terminal)

    /// Lets the move's task begin and reach the face.
    private func untilTheFaceHasTheMove(_ rig: Rig, _ id: UUID) async {
        while !rig.host.moveBegan.contains(id) { await Task.yield() }
    }

    @Test func aCancelBeforeThePointEndsTheMoveAndTheFaceIsToldItIsOver() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .waits
        let task = handOver(rig, id, log)
        #expect(rig.service.transitions.handovers[id] == Handover(target: .terminal, phase: .waiting))
        // A second move of the same session is refused while one is under way.
        #expect(handOver(rig, id) == nil)

        rig.service.cancelHandover(sessionID: id)
        await task?.value
        #expect(rig.host.cancelled == [id])
        // Nothing moved, nothing failed, nothing was told to the UI; the face is its own again.
        #expect(log.events.isEmpty && rig.told.failures.isEmpty && rig.sinks.requested == 0)
        #expect(rig.host.movesFailed.isEmpty, "the run did not end for a move")
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aCancelAtThePointOfNoReturnDoesNothing() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let gate = Gate()
        var reached: [SessionLiveFace] = []
        rig.service.handoverGate = { _, target in
            reached.append(target)
            await gate.wait()
        }
        rig.host.move = .failsAfterPoint(HostFailure())
        let task = handOver(rig, id)
        await untilTheFaceHasTheMove(rig, id)
        while reached.isEmpty { await Task.yield() }
        #expect(rig.service.transitions.handovers[id]?.phase == .switching)
        rig.service.cancelHandover(sessionID: id)
        #expect(rig.host.cancelled.isEmpty, "Cancel is not offered after the point")
        #expect(rig.service.transitions.handovers[id]?.phase == .switching)
        gate.open()
        await task?.value
        // The run ended for a move that did not happen: the face is told, and the failure is a banner.
        #expect(rig.host.movesFailed == [id] && rig.told.failures == [.handoverFailed])
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aStopEndsAWaitingMove() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .waits
        let task = handOver(rig, id, log)
        let stop = rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in })
        #expect(rig.host.cancelled == [id], "the Stop ended the wait")
        await task?.value
        await stop?.value
        #expect(log.events.isEmpty && !rig.told.failures.contains(.handoverFailed))
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aStopAtThePointOfNoReturnStopsTheTerminalStart() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        let gate = Gate()
        var reached = false
        rig.service.handoverGate = { _, _ in
            reached = true
            await gate.wait()
        }
        rig.host.move = .moves(card: id)
        let task = handOver(rig, id, log)
        while !reached { await Task.yield() }
        let stop = rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in })
        gate.open()
        await task?.value
        await stop?.value
        // The terminal never started: no look at it, no sink, no run; the Chat run that ended is told it was interrupted.
        #expect(log.events.isEmpty && rig.sinks.requested == 0 && rig.host.continuedInTerminal.isEmpty)
        #expect(rig.host.movesFailed == [id])
        #expect(!rig.told.failures.contains(.handoverFailed), "a move the user ended is not a failure")
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aStopOfTheCardAClearMovedTheRunToStopsTheTerminalStartToo() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID(), card = UUID()
        let log = MoveLog()
        let gate = Gate()
        var reached = false
        rig.service.handoverGate = { _, _ in
            reached = true
            await gate.wait()
        }
        rig.host.move = .moves(card: card)
        let task = handOver(rig, id, log)
        while !reached { await Task.yield() }
        rig.service.transitions.setBusy(card, .stopping)
        gate.open()
        await task?.value
        rig.service.transitions.setBusy(card, nil)
        #expect(log.events.isEmpty && rig.sinks.requested == 0)
        #expect(rig.host.movesFailed == [id] && rig.told.failures.isEmpty)
        #expect(rig.host.finished == [id])
    }

    @Test func aMoveThatSucceedsLooksAtTheTerminalFirstThenResumesTheCardTheRunEndedOn() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        // The card the run ended on is a session the runtime can resume (a `/clear` made it).
        let session = ManagedSession(provider: .claude, providerConversationID: "moved-1", workingDirectory: rig.context.home.path)
        try await rig.context.supervisor.createSession(session)
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .moves(card: session.id)
        await handOver(rig, id, log)?.value
        #expect(log.events == ["willStart:card", "shown"])
        #expect(rig.sinks.adopted.map(\.sessionID) == [session.id])
        #expect(rig.host.continuedInTerminal == [id], "the face notes it on the session the move began on")
        #expect(rig.host.movesFailed.isEmpty && rig.told.failures.isEmpty)
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
        _ = await rig.context.runtime.shutdown()
    }

    @Test func aRefusalIsABannerInTheWordsOfTheRefusal() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        for refusal in [HandoverRefusal.requestWaiting, .backgroundWork, .busy] {
            let id = UUID()
            rig.host.move = .refuses(refusal)
            await handOver(rig, id)?.value
            #expect(rig.host.finished.last == id && rig.service.transitions.handovers[id] == nil)
        }
        #expect(rig.told.failures == [.handoverFailed, .handoverFailed, .handoverFailed])
        let words = rig.told.failureErrors.map { ($0 as? HandoverRefusal)?.description }
        #expect(words == [HandoverRefusal.requestWaiting, .backgroundWork, .busy].map(\.description))
        #expect(rig.host.movesFailed.isEmpty, "a refusal comes before the point: no run ended")
        // Any other error is reported as it is.
        rig.host.move = .refuses(HostFailure())
        await handOver(rig, UUID())?.value
        #expect(rig.told.failureErrors.last is HostFailure)
    }

    @Test func aClearDuringTheWaitIsAnInfoNotAFailure() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .refuses(HandoverRefusal.cleared)
        await handOver(rig, id, log)?.value
        #expect(log.events == ["cleared"] && rig.told.failures.isEmpty)
        #expect(rig.host.finished == [id])
    }

    @Test func theFaceIsToldTheMoveIsOverWhateverTheResult() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        // The terminal cannot start (the runtime does not know the card): the run ended for nothing, the banner says so.
        let id = UUID(), card = UUID()
        rig.host.move = .moves(card: card)
        await handOver(rig, id)?.value
        #expect(rig.told.failures == [.handoverFailed])
        #expect(rig.host.finished == [id] && rig.host.continuedInTerminal.isEmpty)
        #expect(rig.service.transitions.handovers[id] == nil)
    }

    @Test func theOtherDirectionIsNotAMove() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        #expect(rig.service.handOver(sessionID: UUID(), to: .chat, terminalWillStart: { _ in }, shown: { _ in }, cleared: {}) == nil)
    }

    // MARK: Side chats (D-72)

    private func sideChatRig() async throws -> (rig: Rig, parent: UUID, side: UUID) {
        (try await makeRig(), UUID(), UUID())
    }

    @Test func anIdleSideChatThatIsNoLongerOpenIsStoppedAtOnceAndOneThatIsStillOpenIsNot() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.host.settled = [side]
        rig.service.sideChatShown(side, in: parent)
        // Asked while it is the open one: nothing to retire.
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed.isEmpty)
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed == [side])
    }

    @Test func aBusySideChatIsStoppedOnlyOnceItHasSettled() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.service.sideChatShown(side, in: parent)
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed.isEmpty, "a running turn or a waiting card is not cut")
        // Read while still busy: nothing yet, and it keeps waiting.
        await rig.service.sideChatRead(side, in: parent)?.value
        #expect(rig.host.closed.isEmpty)
        rig.host.settled = [side]
        let read = rig.service.sideChatRead(side, in: parent)
        await read?.value
        #expect(rig.host.closed == [side])
        // Done: later reads have nothing to do.
        #expect(rig.service.sideChatRead(side, in: parent) == nil)
    }

    @Test func aSideChatOpenedAgainBeforeItSettledStays() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.service.sideChatShown(side, in: parent)
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        rig.service.sideChatShown(side, in: parent)
        rig.host.settled = [side]
        #expect(rig.service.sideChatRead(side, in: parent) == nil)
        #expect(rig.host.closed.isEmpty)
        // And the flag is gone for good: it is retired again only by being left again.
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed == [side])
    }

    @Test func theParentsStopRetiresTheOpenSideChatToo() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        let other = UUID()
        rig.host.live = [side, other]
        rig.host.settled = [side, other]
        rig.service.sideChatShown(side, in: parent)
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side, other])
        #expect(Set(rig.host.closed) == [side, other], "the open one is retired as well")
    }

    @Test func aBusySideChatThatTheParentsStopRetiredIsNotSavedByOpeningItAgain() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.service.sideChatShown(side, in: parent)
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed.isEmpty, "not cut while its turn runs")
        // Reopened (or never left): still the parent's stop.
        rig.service.sideChatShown(side, in: parent)
        rig.host.settled = [side]
        await rig.service.sideChatRead(side, in: parent)?.value
        #expect(rig.host.closed == [side])
    }

    @Test func aRunThatEndedInAMoveToTheTerminalIsNotAParentStop() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.host.settled = [side]
        rig.host.handingOver = [parent]
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        rig.host.handingOver = []
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed == [side])
    }

    @Test func aRunThatMovedOffItsCardByAClearAndEndedInAMoveIsNotAParentStopEither() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        let runCard = UUID()
        rig.host.live = [side]
        rig.host.settled = [side]
        // The side chats were forked from `parent`; after a `/clear` its run is on `runCard`, which is the one being moved.
        rig.host.handingOver = [runCard]
        await rig.service.parentRunEnded(parent, runCard: runCard, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        // The same parent whose run card is not being moved was stopped.
        await rig.service.parentRunEnded(parent, runCard: UUID(), sideChats: [side])
        #expect(rig.host.closed == [side])
    }

    /// Told late, after the face let go of its handover state: a move is still not a stop, while the service's own move is
    /// under way or once the card's terminal run is live.
    @Test func aRunEndToldAfterTheFaceLetGoOfTheMoveIsStillNotAParentStop() async throws {
        let rig = try await makeRig(runsIn: .chat)
        defer { rig.context.cleanup() }
        await rig.service.start(provider: .claude, projectID: nil)?.value
        let card = try #require(rig.sinks.adopted.first?.sessionID)
        let side = UUID()
        rig.host.live = [side]
        rig.host.settled = [side]
        // The terminal runs the card (the move is done): nothing retires.
        await rig.service.parentRunEnded(card, runCard: card, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        let stopTask = rig.service.stop(sessionID: card, liveRunID: nil, settled: { _ in })
        await stopTask?.value
        // The service's move is still under way: nothing retires either.
        rig.service.transitions.setHandover(Handover(target: .terminal, phase: .switching), for: card)
        await rig.service.parentRunEnded(card, runCard: card, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        // No move and no run: a stop.
        rig.service.transitions.setHandover(nil, for: card)
        await rig.service.parentRunEnded(card, runCard: card, sideChats: [side])
        #expect(rig.host.closed == [side])
        _ = await rig.context.runtime.shutdown()
    }

    @Test func aSideChatWithNoLiveRunIsLeftAlone() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.settled = [side]
        await rig.service.sideChatLeft(side, in: parent)
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        // Nothing was kept for it: when a later run settles, no read ends it.
        rig.host.live = [side]
        #expect(rig.service.sideChatRead(side, in: parent) == nil)
        #expect(rig.host.closed.isEmpty)
    }

    @Test func aRetirementThatCouldNotStopTheSideChatIsToldToTheUI() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        let told = Told()
        rig.service.sideChatCloseFailed = { parent, side, _ in told.closeFailed.append((parent, side)) }
        rig.host.live = [side]
        rig.host.settled = [side]
        rig.host.closeFailure = HostFailure()
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed == [side] && told.closeFailed.count == 1 && told.closeFailed[0] == (parent, side))
        // The user's own Close answers its caller.
        #expect(await rig.service.closeSideChat(side) is HostFailure)
        #expect(told.closeFailed.count == 1)
        rig.host.closeFailure = nil
        #expect(await rig.service.closeSideChat(side) == nil)
    }
}
