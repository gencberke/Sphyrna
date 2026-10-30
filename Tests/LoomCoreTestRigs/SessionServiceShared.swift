import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// What both halves of `SessionServiceTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum SessionServiceShared {
    struct HostFailure: Error {}

    struct HostStopping: Error {}

    @MainActor
    final class Gate {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []

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
    final class FakeHost: StructuredFaceHost {
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

        func run(_ onReady: (@Sendable () async -> Void)?) async throws {
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

        /// Held by `resumeSession` until it opens, then thrown (a Stop that ended the wait for `initialize`).
        var resumeHold: (gate: Gate, error: any Error)?

        func resumeSession(sessionID: UUID) async throws {
            resumed.append(sessionID)
            guard let resumeHold else { return }
            let gate = resumeHold.gate
            await gate.wait()
            throw resumeHold.error
        }

        func forget(sessionID: UUID) { forgotten.append(sessionID) }

        func errorKind(of error: any Error) -> StructuredFaceErrorKind {
            if error is HostStopping { return .stopping }
            return error is HostFailure ? .failure : .other
        }

        // The move to the terminal.
        enum Move {
            /// Passes the point of no return, ends the run and answers the card it ended on.
            case moves(card: UUID)
            /// Waits for a Cancel, then throws `CancellationError` (the Chat face's wait).
            case waits
            /// Refuses before the point of no return.
            case refuses(any Error)
            /// Passes the point of no return, then fails.
            case failsAfterPoint(any Error)
        }

        var move = Move.waits
        let cancel = Gate()
        private(set) var moveBegan: [UUID] = []
        private(set) var cancelled: [UUID] = []
        private(set) var movesFailed: [UUID] = []
        private(set) var continuedInTerminal: [UUID] = []
        private(set) var finished: [UUID] = []

        func handOverToTerminal(sessionID: UUID, pointOfNoReturn: @escaping @Sendable () async -> Void) async throws -> UUID {
            moveBegan.append(sessionID)
            switch move {
            case let .moves(card):
                await pointOfNoReturn()
                return card
            case .waits:
                await cancel.wait()
                throw CancellationError()
            case let .refuses(error):
                throw error
            case let .failsAfterPoint(error):
                await pointOfNoReturn()
                throw error
            }
        }

        func cancelHandover(sessionID: UUID) {
            cancelled.append(sessionID)
            cancel.open()
        }

        func handoverFailed(sessionID: UUID) async { movesFailed.append(sessionID) }
        func noteContinuedInTerminal(sessionID: UUID) async { continuedInTerminal.append(sessionID) }
        func finishHandover(sessionID: UUID) async { finished.append(sessionID) }
        func handoverRefusal(of error: any Error) -> HandoverRefusal? { error as? HandoverRefusal }

        // What a session's run is doing: set by the test, by id.
        var live: Set<UUID> = []
        var settled: Set<UUID> = []
        var handingOver: Set<UUID> = []
        var closeFailure: (any Error)?
        private(set) var closed: [UUID] = []

        func isLive(sessionID: UUID) async -> Bool { live.contains(sessionID) }
        func isLiveAndSettled(sessionID: UUID) async -> Bool { live.contains(sessionID) && settled.contains(sessionID) }
        func isHandingOver(sessionID: UUID) async -> Bool { handingOver.contains(sessionID) }

        func closeSession(sessionID: UUID) async throws {
            closed.append(sessionID)
            if let closeFailure { throw closeFailure }
            live.remove(sessionID)
        }
    }

    @MainActor
    final class FakeSinks: TerminalFaceSinks {
        private(set) var requested = 0
        private(set) var adopted: [RuntimeLaunch] = []
        private(set) var failed = 0
        private(set) var reconciles = 0
        private(set) var captured: [UUID] = []
        private(set) var released: [UUID] = []
        private(set) var order: [String] = []
        let screen = SessionRuntimeRig.Screen()

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
    final class Told {
        private(set) var cards: [UUID] = []
        private(set) var notStarted = 0
        private(set) var failures: [SessionFailure.Kind] = []
        private(set) var failureErrors: [any Error] = []
        var events: [String] = []
        /// A side chat's Close that the rule's retirement could not do (parent, side chat).
        var closeFailed: [(UUID, UUID)] = []

        func failure(_ failure: SessionFailure) {
            failures.append(failure.kind)
            failureErrors.append(failure.error)
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

    struct Rig {
        let context: RuntimeContext
        let service: SessionService
        let host: FakeHost
        let sinks: FakeSinks
        let told: Told
    }

    /// What the UI was told during a move, in order.
    final class MoveLog {
        var events: [String] = []
    }
}

/// `SessionServiceTests`'s fixtures, for both halves of the suite.
@MainActor protocol SessionServiceFixtures {}

extension SessionServiceFixtures {
    typealias HostFailure = SessionServiceShared.HostFailure

    typealias HostStopping = SessionServiceShared.HostStopping

    typealias Gate = SessionServiceShared.Gate

    typealias FakeHost = SessionServiceShared.FakeHost

    typealias FakeSinks = SessionServiceShared.FakeSinks

    typealias Told = SessionServiceShared.Told

    typealias Rig = SessionServiceShared.Rig

    func makeRig(runsIn: SessionLiveFace = .chat, host hasHost: Bool = true, startable: Set<ManagedSession.Provider> = [.claude, .codex],
                         extraEnvironment: [String: String] = [:], scoped: Bool = false, durableLedger: Bool = false,
                         claudeVersion: String = "fake 1") async throws -> Rig {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: extraEnvironment,
            scoped: scoped, durableLedger: durableLedger, claudeVersion: claudeVersion)
        let host = FakeHost()
        let sinks = FakeSinks()
        let told = Told()
        let service = SessionService(runtime: context.runtime, startableProviders: startable, runsIn: runsIn,
                                     structuredHost: hasHost ? host : nil, terminal: sinks)
        service.failureHandler = { told.failure($0) }
        return Rig(context: context, service: service, host: host, sinks: sinks, told: told)
    }

    func start(_ rig: Rig, projectID: UUID? = nil) -> Task<Void, Never>? {
        rig.service.startSession(projectID: projectID, launch: NewSessionLaunch(firstMessage: "hello"),
                                 cardCreated: { rig.told.card($0) }, notStarted: { rig.told.none() })
    }

    typealias MoveLog = SessionServiceShared.MoveLog

    func handOver(_ rig: Rig, _ id: UUID, _ log: MoveLog = MoveLog()) -> Task<Void, Never>? {
        rig.service.handOver(
            sessionID: id, to: .terminal,
            terminalWillStart: { log.events.append("willStart:\($0 == id ? "same" : "card")") },
            shown: { _ in log.events.append("shown") },
            cleared: { log.events.append("cleared") }
        )
    }
}
