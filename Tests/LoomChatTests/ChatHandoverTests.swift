import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore

// The handover between the faces (V19), on the driver and the runtime with the fake provider: Chat → Terminal waits for a
// running turn and refuses a waiting request, never runs two owners and never loses a message; Terminal → Chat resumes
// the session with its queue and draft where they were.

private final class HandoverScreen: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func receive(_ data: Data) { lock.withLock { buffer += String(decoding: data, as: UTF8.self) } }

    var text: String { lock.withLock { buffer } }
}

/// A latch a test opens to let a parked task go on.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct ChatHandoverTests {
    @Test func anIdleSessionHandsOverToTheTerminalAndBackWithItsQueueAndDraft() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let queues = ChatQueueStore(directory: rig.root.appendingPathComponent("q", isDirectory: true))
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("d", isDirectory: true))
        let driver = rig.driver(id, queue: queues, drafts: drafts)
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        // The turn's own end (its queue release) can still be on its way when the phase reads Ready, and it would send an
        // item queued meanwhile. The handover's hold stops it, so the item is queued under the hold: the handover is parked
        // right before its stop, which is where the queue is paused for it.
        let parked = Gate()
        await driver.setHandoverParked { await parked.wait() }
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        _ = try await driver.enqueue("for later")
        try drafts.prepend(texts: ["an unsent thought"], attachments: [], sessionID: id)
        await parked.open()
        try await handover.value
        #expect(await driver.currentPhase == .stopped)
        let left = await driver.snapshot()
        // The marker is the caller's, once the terminal really has the session (fix round: a resume that fails leaves none).
        #expect(!left.markers.contains(.face(.continuedInTerminal)))
        // Nothing lost: the queued message waits (paused for the handover) and the draft is on disk.
        #expect(left.queue.items.map(\.text) == ["for later"] && left.queue.paused == .handover)
        #expect(try drafts.load(sessionID: id)?.text == "an unsent thought")
        #expect(try queues.load(sessionID: id).items.count == 1)
        // The persisted owner is the Chat endpoint until the terminal run starts.
        #expect(try await rig.catalog.runEndpoint(sessionID: id) == .pipe)

        // The terminal takes the session; the endpoint follows the run.
        let screen = HandoverScreen()
        _ = try await rig.runtime.resumeConversation(sessionID: id, outputSink: screen)
        #expect(await waitUntil { screen.text.lowercased().contains("resumed \(id.uuidString.lowercased())") })
        #expect(try await rig.catalog.runEndpoint(sessionID: id) == .terminal)

        // And back: the Chat face resumes it with the queue still paused and the draft in place.
        let host = await MainActor.run { ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root) }
        let again = try await host.enterChat(sessionID: id)
        #expect(await again.currentPhase == .ready)
        #expect(try await rig.catalog.runEndpoint(sessionID: id) == .pipe)
        #expect(await host.driver(for: id).snapshot().phase == .ready)
        await rig.finish()
    }

    @Test func aRunningTurnIsWaitedForNeverCutAndNothingNewStartsMeanwhile() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })

        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        // Waiting: the run lives and the turn goes on; a second owner cannot start; a send that would start a turn
        // is refused, while "After this turn" still queues.
        #expect(await rig.supervisor.session(id: id)?.currentRun != nil)
        await #expect(throws: SessionRuntimeError.self) {
            _ = try await rig.runtime.resumeConversation(sessionID: id, outputSink: HandoverScreen())
        }
        await #expect(throws: ChatDriverError.handingOver) { _ = try await driver.send("too soon") }
        let queued = try await driver.send("after this turn", timing: .afterTurn)
        guard case .queued = queued else { Issue.record("not queued: \(queued)"); return }
        await #expect(throws: ChatDriverError.busy) { try await driver.handOverToTerminal() }

        try await handover.value
        #expect(await driver.currentPhase == .stopped)
        let snapshot = await driver.snapshot()
        // The turn finished by itself: it was not interrupted, and the queued message was not sent into a new turn.
        #expect(snapshot.model.turns.last?.status == .succeeded)
        #expect(!snapshot.youStopped)
        #expect(snapshot.queue.items.map(\.text) == ["after this turn"] && snapshot.queue.paused == .handover)
        // The hold outlives the stop until the caller has finished the move (`finishHandover`).
        #expect(await driver.isHandingOver)
        await driver.finishHandover()
        #expect(!(await driver.isHandingOver))
        await rig.finish()
    }

    @Test func aWaitingRequestRefusesAndNothingChanges() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        await #expect(throws: ChatDriverError.requestWaiting) { try await driver.handOverToTerminal() }
        let snapshot = await driver.snapshot()
        #expect(snapshot.phase == .needsYou && snapshot.requests.count == 1 && snapshot.runID != nil)
        #expect(!(await driver.isHandingOver))
        // A send is not held back afterwards: the refusal left no hold behind.
        try await driver.answer(requestID: snapshot.requests[0].requestID, .allowOnce)
        #expect(await idle(driver))
        _ = try await driver.send("still here")
        #expect(await idle(driver))
        await rig.finish()
    }

    @Test func cancellingTheWaitLeavesTheSessionInChat() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        await driver.cancelHandover()
        await #expect(throws: CancellationError.self) { try await handover.value }
        #expect(!(await driver.isHandingOver))
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(snapshot.phase == .ready && snapshot.runID != nil && !snapshot.markers.contains(.face(.continuedInTerminal)))
        _ = try await driver.send("carry on")
        #expect(await idle(driver))
        await rig.finish()
    }

    @Test func aStoppedSessionHandsOverWithoutAnythingToStop() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        try await driver.handOverToTerminal()
        #expect(await driver.currentPhase == .stopped)
        await rig.finish()
    }

    // MARK: Fix round

    /// S5: "started" is told only after `initialize`. A child that exits before it fails the start with nothing told and
    /// nothing kept: the draft page still has the text.
    @Test func aStartThatFailsBeforeReadyTellsNothingAndKeepsNothing() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_INIT": "exit"])
        let id = UUID()
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("d", isDirectory: true))
        let driver = rig.driver(id, drafts: drafts)
        let ready = ReadyFlag()
        do {
            try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: "do the thing"),
                                      onReady: { ready.raise() })
            Issue.record("the child exits before it is ready; the start must fail")
        } catch {}
        #expect(!ready.isRaised, "the draft is told nothing before Ready")
        #expect(try drafts.load(sessionID: id) == nil, "the text goes back to the draft page, not into a session's draft")
        await rig.finish()
    }

    /// S5: after Ready the draft is told first, then the first message goes out.
    @Test func readyIsToldBeforeTheFirstMessageGoesOut() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        let ready = ReadyFlag()
        let seen = ReadyFlag()
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: "first"), onReady: {
            ready.raise()
            if await !driver.snapshot().model.entries.contains(where: { if case .user = $0.body { true } else { false } }) { seen.raise() }
        })
        #expect(ready.isRaised && seen.isRaised, "no message was in the stream when Ready was told")
        #expect(await waitUntil { await driver.snapshot().texts.contains("Fake answer to: first") })
        await rig.finish()
    }

    /// S1: the wait has a point of no return. The closure runs once, after the turn, before the run ends; a cancel from
    /// then on does nothing and the run ends.
    @Test func theWaitHasAPointOfNoReturnAfterWhichCancelDoesNothing() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 1500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let log = PointLog()
        let handover = Task {
            try await driver.handOverToTerminal(pointOfNoReturn: {
                log.note(turnRunning: await driver.snapshot().turnRunning, phase: await driver.currentPhase)
                await driver.cancelHandover()
            })
        }
        #expect(await waitUntil { await driver.isHandingOver })
        try await handover.value
        #expect(log.calls == 1 && log.turnRunning == false && log.phase == .ready,
                "the point comes once, after the turn, with the run still up")
        #expect(await driver.currentPhase == .stopped, "the cancel after the point did not save the run")
        await rig.finish()
    }

    /// S1 / M2: a Stop during the wait ends the handover, and the queue says it was interrupted, not moved.
    @Test func aStopDuringTheWaitPausesTheQueueAsInterruptedNotMoved() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 4000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        _ = try await driver.enqueue("for later")
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        _ = try await driver.stop()
        _ = try? await handover.value
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        let snapshot = await driver.snapshot()
        #expect(snapshot.queue.items.map(\.text) == ["for later"])
        #expect(snapshot.queue.paused == .interrupted, "a Stop is not a move: \(String(describing: snapshot.queue.paused))")
        await driver.finishHandover()
        #expect(!(await driver.isHandingOver))
        await rig.finish()
    }

    /// M2: a handover whose terminal start failed leaves the queue interrupted, not "moved to the terminal".
    @Test func aFailedMoveTurnsTheQueuePauseIntoInterrupted() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        _ = try await driver.enqueue("for later")
        try await driver.handOverToTerminal()
        #expect(await driver.snapshot().queue.paused == .handover)
        await driver.handoverFailed()
        #expect(await driver.snapshot().queue.paused == .interrupted)
        await rig.finish()
    }

    /// S3: background tasks under a finished turn refuse at once.
    @Test func backgroundWorkRefusesAHandoverAtOnce() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 9000")
        #expect(await waitUntil(15) {
            await driver.snapshot().model.entries.filter { if case .tool = $0.body { true } else { false } }.count == 3
        })
        let waiting = try await driver.send("look now")
        #expect(await waitUntil { await driver.snapshot().delivery(waiting.id) == .queued })
        #expect(try await driver.readNow(messageID: waiting.id))
        #expect(await waitUntil { await driver.snapshot().backgroundTaskCount == 1 })
        #expect(await idle(driver, 15))
        await #expect(throws: ChatDriverError.backgroundWork) { try await driver.handOverToTerminal() }
        #expect(await driver.currentPhase == .ready)
        #expect(!(await driver.isHandingOver))
        await rig.finish()
    }

    /// S3: a task that began while the handover waited refuses it right before the point of no return.
    @Test func backgroundWorkThatBeginsDuringTheWaitRefusesBeforeThePoint() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 9000")
        #expect(await waitUntil(15) {
            await driver.snapshot().model.entries.filter { if case .tool = $0.body { true } else { false } }.count == 3
        })
        // Sent before the handover begins (a send is refused while it waits); read now once it waits.
        let waiting = try await driver.send("look now")
        #expect(await waitUntil { await driver.snapshot().delivery(waiting.id) == .queued })
        let log = PointLog()
        let handover = Task { try await driver.handOverToTerminal(pointOfNoReturn: { log.note(turnRunning: false, phase: .ready) }) }
        #expect(await waitUntil { await driver.isHandingOver })
        #expect(try await driver.readNow(messageID: waiting.id))
        await #expect(throws: ChatDriverError.backgroundWork) { try await handover.value }
        #expect(log.calls == 0, "refused before the point of no return")
        #expect(await driver.currentPhase == .ready, "the session stays in Chat")
        #expect(await driver.snapshot().runID != nil)
        await rig.finish()
    }

    /// M3: a `/clear` moves the run while the handover waits: the handover ends, with its own error.
    @Test func aClearDuringTheWaitEndsTheHandover() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 4000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        await driver.followMove(to: UUID())
        await #expect(throws: ChatDriverError.clearedDuringHandover) { try await handover.value }
        #expect(await driver.snapshot().runID != nil, "the run was not ended by the handover")
        await rig.finish()
    }

    /// M9: the move to a new card writes the endpoint before anyone is told the run started there.
    @Test func aClearWritesTheEndpointBeforeTheRunStartedFrame() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        var frames = await rig.events.subscribe().makeAsyncIterator()
        try await driver.send("/clear")
        var card: UUID?
        let deadline = Date().addingTimeInterval(20)
        while card == nil, Date() < deadline, let frame = await frames.next() {
            card = frame.sessions.first { $0.key != id && $0.value.runID != nil }?.key
        }
        let moved = try #require(card, "no frame told the run started on the new card")
        #expect(try await rig.catalog.runEndpoint(sessionID: moved) == .pipe,
                "the frame that names the new card's run is read after the endpoint is written")
        await rig.finish()
    }
}

private final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

private final class PointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (calls: Int, turnRunning: Bool?, phase: ChatDriverPhase?) = (0, nil, nil)
    func note(turnRunning: Bool, phase: ChatDriverPhase) { lock.withLock { state = (state.calls + 1, turnRunning, phase) } }
    var calls: Int { lock.withLock { state.calls } }
    var turnRunning: Bool? { lock.withLock { state.turnRunning } }
    var phase: ChatDriverPhase? { lock.withLock { state.phase } }
}
