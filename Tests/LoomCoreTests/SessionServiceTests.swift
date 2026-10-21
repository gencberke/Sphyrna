import Foundation
import Testing
@testable import LoomCore

/// R5a: the session service owns the lifecycle's orchestration and its transition state. Both faces are fakes (a structured
/// host that records what it was asked and a terminal that hands out sinks); the runtime is the real one over the fake
/// provider, so a terminal run and its Stop are real. Nothing waits on a clock: each test awaits the task an operation returns.

private struct HostFailure: Error {}
private struct HostStopping: Error {}

@MainActor
private final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }
}

@MainActor
private final class FakeHost: StructuredFaceHost {
    enum Script {
        /// Ready, then done.
        case ready
        /// Fails before Ready with this error.
        case failBeforeReady(any Error)
        /// Ready, then fails (a first message that went wrong).
        case failAfterReady
        /// Ready, then waits for the gate.
        case readyThenHold(Gate)
        /// Waits for the gate before Ready.
        case holdBeforeReady(Gate)
    }

    var script = Script.ready
    private(set) var newSessions: [(project: UUID?, session: UUID, draft: NewSessionLaunch?)] = []
    private(set) var opened: [(request: UUID, session: UUID)] = []
    private(set) var resumed: [UUID] = []
    private(set) var forgotten: [UUID] = []

    func beginNewSession(projectID: UUID?, sessionID: UUID, draft: NewSessionLaunch?,
                         onReady: (@Sendable () async -> Void)?) async throws {
        newSessions.append((projectID, sessionID, draft))
        try await run(onReady)
    }

    func beginOpenedSession(requestID: UUID, sessionID: UUID, onReady: (@Sendable () async -> Void)?) async throws {
        opened.append((requestID, sessionID))
        try await run(onReady)
    }

    private func run(_ onReady: (@Sendable () async -> Void)?) async throws {
        switch script {
        case .ready:
            await onReady?()
        case let .failBeforeReady(error):
            throw error
        case .failAfterReady:
            await onReady?()
            throw HostFailure()
        case let .readyThenHold(gate):
            await onReady?()
            await gate.wait()
        case let .holdBeforeReady(gate):
            await gate.wait()
            await onReady?()
        }
    }

    func resumeSession(sessionID: UUID) async throws { resumed.append(sessionID) }

    func forget(sessionID: UUID) { forgotten.append(sessionID) }

    func errorKind(of error: any Error) -> StructuredFaceErrorKind {
        if error is HostStopping { return .stopping }
        return error is HostFailure ? .failure : .other
    }
}

@MainActor
private final class FakeSinks: TerminalFaceSinks {
    private(set) var requested = 0
    private(set) var adopted: [RuntimeLaunch] = []
    private(set) var failed = 0
    private(set) var reconciles = 0
    private(set) var captured: [UUID] = []
    private(set) var released: [UUID] = []
    private(set) var order: [String] = []
    private let screen = SessionRuntimeTests.Screen()

    func newRunSink() -> TerminalRunSink? {
        requested += 1
        return TerminalRunSink(rows: 24, columns: 80, output: screen, handle: NSObject())
    }

    func adopt(_ launch: RuntimeLaunch, into sink: TerminalRunSink) {
        adopted.append(launch)
        screen.attach(launch.terminal)
        order.append("adopt")
    }

    func runFailedToStart(_ sink: TerminalRunSink) { failed += 1 }

    func reconcile() async {
        reconciles += 1
        order.append("reconcile")
    }

    func captureForStop(sessionID: UUID) -> UUID? {
        order.append("capture")
        guard let run = adopted.last?.runID else { return nil }
        captured.append(run)
        return run
    }

    func releaseStopCapture(run: UUID) { released.append(run) }
}

/// What the UI was told, in order.
@MainActor
private final class Told {
    private(set) var cards: [UUID] = []
    private(set) var notStarted = 0
    private(set) var failures: [SessionFailure.Kind] = []
    var events: [String] = []

    func failure(_ failure: SessionFailure) {
        failures.append(failure.kind)
        events.append("failure")
    }

    func card(_ id: UUID) {
        cards.append(id)
        events.append("card")
    }

    func none() {
        notStarted += 1
        events.append("notStarted")
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
@MainActor
struct SessionServiceTests {
    private struct Rig {
        let context: RuntimeContext
        let service: SessionService
        let host: FakeHost
        let sinks: FakeSinks
        let told: Told
    }

    private func makeRig(runsIn: SessionLiveFace = .chat, host hasHost: Bool = true, startable: Set<ManagedSession.Provider> = [.claude, .codex]) async throws -> Rig {
        let context = try await SessionRuntimeTests.makeContext()
        let host = FakeHost()
        let sinks = FakeSinks()
        let told = Told()
        let service = SessionService(runtime: context.runtime, startableProviders: startable, runsIn: runsIn,
                                     structuredHost: hasHost ? host : nil, terminal: sinks)
        service.failureHandler = { told.failure($0) }
        return Rig(context: context, service: service, host: host, sinks: sinks, told: told)
    }

    private func start(_ rig: Rig, projectID: UUID? = nil) -> Task<Void, Never>? {
        rig.service.startSession(projectID: projectID, launch: NewSessionLaunch(firstMessage: "hello"),
                                 cardCreated: { rig.told.card($0) }, notStarted: { rig.told.none() })
    }

    // MARK: Faces

    @Test func aStartGoesToTheFaceThePolicyNames() async throws {
        let chat = try await makeRig(runsIn: .chat)
        defer { chat.context.cleanup() }
        await start(chat)?.value
        #expect(chat.host.newSessions.count == 1 && chat.sinks.requested == 0)
        #expect(chat.told.cards == [chat.host.newSessions[0].session])

        // The switch on Terminal, or no structured host: the terminal starts it.
        for (runsIn, hasHost) in [(SessionLiveFace.terminal, true), (.chat, false)] {
            let terminal = try await makeRig(runsIn: runsIn, host: hasHost)
            defer { terminal.context.cleanup() }
            await start(terminal)?.value
            #expect(terminal.host.newSessions.isEmpty)
            #expect(terminal.sinks.requested == 1 && terminal.sinks.adopted.count == 1)
            #expect(terminal.told.cards == [terminal.sinks.adopted[0].sessionID])
            #expect(terminal.service.transitions.busy.isEmpty && terminal.service.transitions.startingKeys.isEmpty)
            _ = await terminal.context.runtime.shutdown()
        }
    }

    @Test func aHarnessThatCannotBeStartedStartsNothingInEitherFace() async throws {
        for runsIn in [SessionLiveFace.chat, .terminal] {
            let rig = try await makeRig(runsIn: runsIn, startable: [.codex])
            defer { rig.context.cleanup() }
            #expect(start(rig) == nil)
            #expect(rig.told.notStarted == 1 && rig.told.cards.isEmpty)
            #expect(rig.host.newSessions.isEmpty && rig.sinks.requested == 0)
        }
    }

    @Test func aResumeGoesToTheFaceThePolicyNames() async throws {
        let id = UUID()
        let chat = try await makeRig(runsIn: .chat)
        defer { chat.context.cleanup() }
        var shown: [UUID] = []
        await chat.service.resume(sessionID: id, knownProvider: .claude, shown: { shown.append($0) })?.value
        #expect(chat.host.resumed == [id] && shown == [id] && chat.sinks.requested == 0)
        #expect(chat.service.transitions.busy[id] == nil)

        // In the terminal the runtime resumes it; a session it does not know fails there, and the sink is let go.
        let terminal = try await makeRig(runsIn: .terminal)
        defer { terminal.context.cleanup() }
        await terminal.service.resume(sessionID: id, knownProvider: .claude, shown: { shown.append($0) })?.value
        #expect(terminal.host.resumed.isEmpty && terminal.sinks.requested == 1 && terminal.sinks.failed == 1)
        #expect(terminal.told.failures == [.resumeFailed] && shown == [id])
        #expect(terminal.service.transitions.busy[id] == nil)
    }

    @Test func aResumeIsRefusedWhileTheSessionIsBusyOrItsHarnessCannotStart() async throws {
        let rig = try await makeRig(startable: [.claude])
        defer { rig.context.cleanup() }
        let id = UUID()
        rig.service.transitions.setBusy(id, .stopping)
        #expect(rig.service.resume(sessionID: id, knownProvider: .claude, shown: { _ in }) == nil)
        #expect(rig.service.resume(sessionID: UUID(), knownProvider: .codex, shown: { _ in }) == nil)
        #expect(rig.host.resumed.isEmpty && rig.told.failures.isEmpty)
    }

    @Test func anApprovedOpeningGoesToTheFaceThePolicyNames() async throws {
        let request = UUID()
        let chat = try await makeRig(runsIn: .chat)
        defer { chat.context.cleanup() }
        await chat.service.approveOpen(requestID: request)?.value
        #expect(chat.host.opened.map(\.request) == [request] && chat.sinks.requested == 0)

        // In the terminal the runtime answers; a request it does not hold is a banner, and the sink is let go.
        let terminal = try await makeRig(runsIn: .terminal)
        defer { terminal.context.cleanup() }
        await terminal.service.approveOpen(requestID: request)?.value
        #expect(terminal.host.opened.isEmpty && terminal.sinks.requested == 1 && terminal.sinks.failed == 1)
        #expect(terminal.told.failures == [.openRequestNotAnswered])
    }

    @Test func aSecondApprovalOfTheSameRequestIsRefusedWhileTheFirstRuns() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let gate = Gate()
        rig.host.script = .holdBeforeReady(gate)
        let request = UUID()
        let first = rig.service.approveOpen(requestID: request)
        #expect(first != nil && rig.service.approveOpen(requestID: request) == nil)
        gate.open()
        await first?.value
        #expect(rig.host.opened.count == 1)
        await rig.service.approveOpen(requestID: request)?.value
        #expect(rig.host.opened.count == 2)
    }

    // MARK: Start keys

    @Test func aSecondStartOfTheSameKeyIsRefusedWhileTheFirstRuns() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let gate = Gate()
        rig.host.script = .holdBeforeReady(gate)
        let project = UUID()
        let first = start(rig, projectID: project)
        let key = StartKey(provider: .claude, projectID: project)
        #expect(first != nil && rig.service.transitions.startingKeys == [key])
        // Another project's start is its own key.
        let other = start(rig, projectID: UUID())
        #expect(other != nil)

        #expect(start(rig, projectID: project) == nil)
        #expect(rig.told.notStarted == 1)

        gate.open()
        await first?.value
        await other?.value
        #expect(rig.host.newSessions.count == 2)
        #expect(rig.service.transitions.startingKeys.isEmpty && rig.service.transitions.preparingStarts.isEmpty)
        #expect(start(rig, projectID: project) != nil)
    }

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

    // MARK: Stop

    @Test func busyHoldsThroughAStopAndIsClearedAfterIt() async throws {
        let rig = try await makeRig(runsIn: .terminal)
        defer { rig.context.cleanup() }
        await start(rig)?.value
        let launch = try #require(rig.sinks.adopted.first)
        let id = launch.sessionID
        #expect(rig.service.transitions.busy[id] == nil)

        var during: ConversationBusy?
        var secondRefused = false
        var verified = false
        var run: UUID?
        var handoverEnded = false
        let task = rig.service.stop(sessionID: id, liveRunID: nil, willStop: {
            handoverEnded = true
            #expect(rig.service.transitions.busy[id] == nil)
        }, settled: { outcome in
            // The terminal settled first; busy still holds while the UI decides about the tab.
            during = rig.service.transitions.busy[id]
            secondRefused = rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in }) == nil
            verified = outcome.report.succeeded
            run = outcome.run
        })
        #expect(rig.service.transitions.busy[id] == .stopping)
        await task?.value
        #expect(handoverEnded && during == .stopping && secondRefused && verified)
        #expect(run == launch.runID && rig.sinks.captured == [launch.runID] && rig.sinks.released == [launch.runID])
        // The screen is kept before any signal, and the surfaces settle before the UI is told.
        #expect(rig.sinks.order == ["adopt", "capture", "reconcile"])
        #expect(rig.service.transitions.busy[id] == nil)
        _ = await rig.context.runtime.shutdown()
    }

    @Test func busyIsClearedAfterAStopThatFailed() async throws {
        let rig = try await makeRig(runsIn: .terminal)
        defer { rig.context.cleanup() }
        let id = UUID()
        var settled = false
        let task = rig.service.stop(sessionID: id, liveRunID: UUID(), settled: { _ in settled = true })
        #expect(rig.service.transitions.busy[id] == .stopping)
        await task?.value
        // A session the runtime does not know cannot be stopped: a banner, no verdict, and the capture is let go.
        #expect(!settled && rig.told.failures == [.stopFailed])
        #expect(rig.service.transitions.busy[id] == nil)
        #expect(rig.sinks.released.count == 1)
        // And it may be stopped again.
        #expect(rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in }) != nil)
    }

    // MARK: Answers

    @Test func anAnswerTheRuntimeCannotTakeIsABannerOnce() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        await rig.service.answer(sessionID: UUID(), requestID: "none", accept: true).value
        #expect(rig.told.failures == [.answerNotDelivered])
        await rig.service.denyOpen(requestID: UUID()).value
        await rig.service.dismissOpen(requestID: UUID()).value
        #expect(rig.told.failures == [.answerNotDelivered, .openRequestNotDenied, .openRequestNotDismissed])
    }
}
