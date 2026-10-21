import Foundation

/// What went wrong in a lifecycle operation, for the UI to word (the service decides when to report, the UI says how).
public struct SessionFailure: Sendable {
    public enum Kind: Sendable, Equatable {
        case startFailed(ManagedSession.Provider)
        case resumeFailed
        case stopFailed
        /// A move to the terminal failed or was refused. The error is the refusal's words (`HandoverRefusal`) when it was one.
        case handoverFailed
        case answerNotDelivered
        case openRequestNotAnswered
        case openRequestNotDenied
        case openRequestNotDismissed
    }

    public let kind: Kind
    public let error: any Error

    public init(_ kind: Kind, _ error: any Error) {
        self.kind = kind
        self.error = error
    }
}

/// How a Stop that reached the runtime ended, told to the UI before the session's busy state is released.
public struct SessionStopOutcome: Sendable {
    /// The runtime's report; the stop is verified when `report.succeeded`.
    public let report: SessionStopReport
    /// The run the Stop was for, nil when none was known.
    public let run: UUID?
}

/// The one owner of a session's lifecycle: start, resume, stop, the Chat → terminal handover, the answers to a session's
/// requests and to an agent's open requests, deletion, and the session's own writes (title, pin); and of the state those
/// operations pass through (`transitions`). Whatever the harness and
/// whatever the face, the UI sends intents and reads state; what it must do at a moment of an operation it is told by the
/// closure it passed or by `failureHandler`, always on the main actor and before the operation releases what it holds.
///
/// The faces are not here. A structured face is driven through `StructuredFaceHost`; a terminal run draws into the sink
/// `TerminalFaceSinks` gives. Process work stays in the runtime's actors: this class only routes to them.
///
/// Each operation claims its state (busy, a start key, an approval) in the call itself, so a second call right after the
/// first sees it, then runs on a task it returns (nil when it was refused). The task never fails; its end is the
/// operation's end.
@MainActor
public final class SessionService {
    public let runtime: SessionRuntime
    public let transitions: SessionTransitions
    /// The writes to a session's own record (title, pin), over the runtime's catalog.
    public let records: SessionRecordWrites
    /// The app-wide switch ("Sessions run in", D-69): the UI sets it from its preferences.
    public var runsIn: SessionLiveFace
    /// The structured face's host; nil in a test or a window with no runtime, where every session runs in the terminal.
    public var structuredHost: (any StructuredFaceHost)?
    public weak var terminal: (any TerminalFaceSinks)?
    public var failureHandler: @MainActor (SessionFailure) -> Void = { _ in }
    private let startableProviders: Set<ManagedSession.Provider>
    /// Approvals in flight: a second click on "Open Session" must not ask the runtime twice.
    private var approving: Set<UUID> = []
    /// The handovers' tasks, by session (V19): a Cancel or a Stop cancels the task of its session.
    private var handoverTasks: [UUID: Task<Void, Never>] = [:]
    /// Held at a handover's point of no return, with its target (tests act at that phase; nil in the app).
    public var handoverGate: (@MainActor (UUID, SessionLiveFace) async -> Void)?

    public init(runtime: SessionRuntime, startableProviders: Set<ManagedSession.Provider>, runsIn: SessionLiveFace = .chat,
                structuredHost: (any StructuredFaceHost)? = nil, terminal: (any TerminalFaceSinks)? = nil,
                transitions: SessionTransitions = SessionTransitions()) {
        self.runtime = runtime
        records = SessionRecordWrites(catalog: runtime.catalog)
        self.startableProviders = startableProviders
        self.runsIn = runsIn
        self.structuredHost = structuredHost
        self.terminal = terminal
        self.transitions = transitions
    }

    public var facePolicy: FacePolicy {
        FacePolicy(runsIn: runsIn, structuredHostAvailable: structuredHost != nil)
    }

    public func capabilities(of provider: ManagedSession.Provider) -> HarnessCapabilities {
        HarnessCapabilities.of(provider, startable: startableProviders)
    }

    // MARK: Start

    /// A new Claude session from a draft's first send, in the face the policy names. `cardCreated` is told once the session's
    /// card exists (in the Chat face: once Claude answered `initialize`, normally well under a second, and before the first
    /// message goes out); `notStarted` once instead when nothing was started. A start that fails before the card exists is
    /// `notStarted`; a first message that fails after it goes to the session's own draft. The two exclude each other.
    @discardableResult
    public func startSession(projectID: UUID?, launch: NewSessionLaunch,
                             cardCreated: @escaping @MainActor (UUID) -> Void,
                             notStarted: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        if facePolicy.faceOfStart(capabilities(of: .claude)) == .chat, let host = structuredHost {
            return startInStructuredFace(host: host, projectID: projectID, launch: launch,
                                         cardCreated: cardCreated, notStarted: notStarted)
        }
        return start(provider: .claude, projectID: projectID, draft: launch, cardCreated: cardCreated, notStarted: notStarted)
    }

    private func startInStructuredFace(host: any StructuredFaceHost, projectID: UUID?, launch: NewSessionLaunch,
                                       cardCreated: @escaping @MainActor (UUID) -> Void,
                                       notStarted: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard capabilities(of: .claude).startable else {
            notStarted()
            return nil
        }
        let key = StartKey(provider: .claude, projectID: projectID)
        guard transitions.beginStart(key) else {
            notStarted()
            return nil
        }
        let sessionID = UUID()
        let transitions = transitions
        // The project's start is over once the card was told, or when the start failed: whatever the first message does
        // after Ready belongs to the session's own draft, and the next draft of the project may start meanwhile.
        let release = Once { transitions.endStart(key) }
        let ready = Once {
            transitions.cardCreated(for: key)
            cardCreated(sessionID)
            release.fire()
        }
        return Task {
            defer { release.fire() }
            do {
                try await host.beginNewSession(projectID: projectID, sessionID: sessionID, draft: launch,
                                               onReady: { await MainActor.run { ready.fire() } })
                ready.fire()
            } catch {
                // Cancelled by a Stop while starting: not a failure to report.
                let stopped = host.errorKind(of: error) == .stopping
                // A start that failed before Ready keeps no driver (its card stays, as after a terminal start that
                // failed): nothing shows a live Chat for a session that never answered.
                if !ready.fired, !stopped { host.forget(sessionID: sessionID) }
                if !stopped { failureHandler(SessionFailure(.startFailed(.claude), error)) }
                if !ready.fired { notStarted() }
            }
        }
    }

    /// A new session in the terminal face; `draft` is a new-session draft's first send (V07): the runtime starts Claude
    /// with that message, mode, model and branch choice.
    @discardableResult
    public func start(provider: ManagedSession.Provider, projectID: UUID?, draft: NewSessionLaunch? = nil,
                      cardCreated: @escaping @MainActor (UUID) -> Void = { _ in },
                      notStarted: @escaping @MainActor () -> Void = {}) -> Task<Void, Never>? {
        guard capabilities(of: provider).startable else {
            notStarted()
            return nil
        }
        let key = StartKey(provider: provider, projectID: projectID)
        guard transitions.beginStart(key) else {
            notStarted()
            return nil
        }
        guard let sink = terminal?.newRunSink() else {
            transitions.endStart(key)
            notStarted()
            return nil
        }
        let transitions = transitions
        return Task {
            var pendingSessionID: UUID?
            var reported = false
            defer {
                transitions.endStart(key)
                if let pendingSessionID { transitions.setBusy(pendingSessionID, nil) }
            }
            /// The card exists: the caller is told.
            @MainActor func cardReady(_ launch: RuntimeLaunch) {
                guard !reported else { return }
                reported = true
                cardCreated(launch.sessionID)
            }
            do {
                let launch = try await runtime.startConversation(
                    provider: provider, projectID: projectID, rows: sink.rows,
                    columns: sink.columns, outputSink: sink.output, draft: draft,
                    onTerminalReady: { [self] launch in
                        pendingSessionID = launch.sessionID
                        transitions.cardCreated(for: key)
                        terminal?.adopt(launch, into: sink)
                        transitions.setBusy(launch.sessionID, .starting)
                        cardReady(launch)
                    }
                )
                if pendingSessionID == nil {
                    transitions.cardCreated(for: key)
                    terminal?.adopt(launch, into: sink)
                    cardReady(launch)
                }
            } catch {
                terminal?.runFailedToStart(sink)
                await terminal?.reconcile()
                failureHandler(SessionFailure(.startFailed(provider), error))
                if !reported { notStarted() }
            }
        }
    }

    // MARK: Resume

    /// Resumes a stopped session in the face the policy names (D-69), not in the endpoint of its last run: that only says
    /// how the run was driven. `knownProvider` is the UI's own knowledge of the session (nil: the catalog is asked). `shown`
    /// is told once the session runs again, to show it. Refused while the session is busy or its harness is not startable.
    @discardableResult
    public func resume(sessionID: UUID, knownProvider: ManagedSession.Provider?,
                       shown: @escaping @MainActor (UUID) -> Void) -> Task<Void, Never>? {
        // A session that is being moved to the terminal is not resumed: the move starts the terminal's run itself.
        guard transitions.busy[sessionID] == nil, transitions.handovers[sessionID] == nil else { return nil }
        if let knownProvider, !capabilities(of: knownProvider).startable { return nil }
        transitions.setBusy(sessionID, .resuming)
        return Task {
            defer { transitions.setBusy(sessionID, nil) }
            do {
                var provider = knownProvider
                if provider == nil {
                    provider = try await runtime.catalog.session(id: sessionID)?.session.provider
                    // The UI has no row for this id (a direct call): the catalog decides, same rule.
                    if let provider, !capabilities(of: provider).startable { return }
                }
                if let provider, facePolicy.faceOfResume(capabilities(of: provider)) == .chat, let host = structuredHost {
                    try await host.resumeSession(sessionID: sessionID)
                    shown(sessionID)
                } else {
                    // S2: the CLI restores neither mode nor model nor effort; the runtime passes the session's own,
                    // from the catalog (V16).
                    try await resumeInTerminal(sessionID, shown: shown)
                }
            } catch {
                failureHandler(SessionFailure(.resumeFailed, error))
            }
        }
    }

    /// Resumes the session in a terminal run and tells `shown`. Throws what the runtime throws, the sink let go.
    public func resumeInTerminal(_ sessionID: UUID, shown: @MainActor (UUID) -> Void) async throws {
        guard let sink = terminal?.newRunSink() else { return }
        do {
            let launch = try await runtime.resumeConversation(
                sessionID: sessionID, rows: sink.rows, columns: sink.columns, outputSink: sink.output
            )
            terminal?.adopt(launch, into: sink)
            shown(launch.sessionID)
        } catch {
            terminal?.runFailedToStart(sink)
            throw error
        }
    }

    // MARK: Stop

    /// Stops the session's run. A Stop ends a handover in any phase (the user chose to end the session, not to move it):
    /// before the point of no return the wait ends, after it the terminal does not start. `willStop` runs next, before the
    /// session is busy and before anything is captured. `liveRunID` is the run the UI knows of when no terminal here holds it. `settled` is told when
    /// the runtime answered, after the terminal's own settling and before busy is released (the UI decides about the
    /// session's tab and shows an unverified stop there). A Stop that could not be asked is a `stopFailed`.
    @discardableResult
    public func stop(sessionID: UUID, liveRunID: UUID?, willStop: @MainActor () -> Void = {},
                     settled: @escaping @MainActor (SessionStopOutcome) async -> Void) -> Task<Void, Never>? {
        guard transitions.busy[sessionID] != .stopping else { return nil }
        if transitions.handovers[sessionID] != nil { endHandover(sessionID) }
        willStop()
        transitions.setBusy(sessionID, .stopping)
        // What the user sees now is what stays: taken before any signal.
        let stoppedRun = terminal?.captureForStop(sessionID: sessionID) ?? liveRunID
        return Task {
            defer { transitions.setBusy(sessionID, nil) }
            do {
                let report = try await runtime.stopConversation(sessionID: sessionID)
                if let stoppedRun {
                    // The run's end takes the capture; one that was not taken (a stop that failed) is let go.
                    if report.succeeded { await terminal?.reconcile() }
                    terminal?.releaseStopCapture(run: stoppedRun)
                }
                await settled(SessionStopOutcome(report: report, run: stoppedRun))
            } catch {
                if let stoppedRun { terminal?.releaseStopCapture(run: stoppedRun) }
                failureHandler(SessionFailure(.stopFailed, error))
            }
        }
    }

    // MARK: Handover (Chat → terminal, V19)

    /// Moves a Chat session to the terminal. The order never has two owners: the Chat run ends in the verified order (a
    /// running turn is waited for first), then the terminal's run starts; the runtime's same-session guard refuses a second
    /// run of a session that still has one. Refused (nil) when the target is not the terminal (the other direction was
    /// removed: no release build reached it), without a structured face, or while the session has a handover or is busy.
    ///
    /// The move has a point of no return (`Handover.Phase.switching`). Before it, Cancel and Stop end the move and the
    /// session goes on where it was. After it, Cancel is no longer offered, and a Stop ends the terminal's start: the task is
    /// cancelled, and right before the terminal would start the move looks for the cancellation and for a Stop that is under
    /// way, for the session it began on and for the card a `/clear` moved the run to.
    ///
    /// What the UI does at the moments of the move it is told by closures, on the main actor: `terminalWillStart` with the
    /// card the terminal will resume (the UI looks at the terminal from now on), `shown` once the terminal runs (to show it),
    /// `cleared` when a `/clear` ended the wait (nothing moved, and it is not a failure). A refusal or a failure is reported
    /// as `SessionFailure.Kind.handoverFailed`; a move the user ended (Cancel, Stop) reports nothing. The face is told
    /// `finishHandover` whatever the result, and the handover leaves `transitions` only then.
    @discardableResult
    public func handOver(sessionID: UUID, to target: SessionLiveFace,
                         terminalWillStart: @escaping @MainActor (UUID) -> Void,
                         shown: @escaping @MainActor (UUID) -> Void,
                         cleared: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard target == .terminal, let host = structuredHost,
              transitions.handovers[sessionID] == nil, transitions.busy[sessionID] == nil else { return nil }
        transitions.setHandover(Handover(target: target), for: sessionID)
        let task = Task { [weak self] in
            guard let self else { return }
            await runHandover(sessionID: sessionID, host: host, terminalWillStart: terminalWillStart,
                              shown: shown, cleared: cleared)
        }
        handoverTasks[sessionID] = task
        return task
    }

    /// The user's Cancel: ends a wait that has not reached the point of no return.
    public func cancelHandover(sessionID: UUID) {
        guard transitions.handovers[sessionID]?.phase == .waiting else { return }
        endHandover(sessionID)
    }

    private func endHandover(_ sessionID: UUID) {
        handoverTasks[sessionID]?.cancel()
        // The Chat face's wait is the face's own: it does not look at task cancellation. (After its point of no return it
        // ignores this.)
        structuredHost?.cancelHandover(sessionID: sessionID)
    }

    /// Whether the move must not start the terminal now: its task was cancelled or a Stop is under way for `sessionID`.
    private func moveEnded(_ sessionID: UUID) -> Bool {
        Task.isCancelled || transitions.busy[sessionID] == .stopping
    }

    private func runHandover(sessionID: UUID, host: any StructuredFaceHost,
                             terminalWillStart: @MainActor (UUID) -> Void,
                             shown: @MainActor (UUID) -> Void,
                             cleared: @MainActor () -> Void) async {
        do {
            try await moveToTerminal(sessionID, host: host, terminalWillStart: terminalWillStart, shown: shown)
        } catch {
            // The Chat run ended for a move that did not happen: the queue says it was interrupted, not moved.
            if transitions.handovers[sessionID]?.phase == .switching { await host.handoverFailed(sessionID: sessionID) }
            let refusal = host.handoverRefusal(of: error)
            if error is CancellationError || Task.isCancelled {
                // The user ended the move (Cancel, Stop): the session goes on where it was, or stays stopped.
            } else if refusal == .cleared {
                cleared()
            } else {
                failureHandler(SessionFailure(.handoverFailed, refusal.map { $0 as any Error } ?? error))
            }
        }
        // The move is over, made or not: the face was holding the session for it (a send was refused meanwhile), and it is
        // its own again now.
        await host.finishHandover(sessionID: sessionID)
        transitions.setHandover(nil, for: sessionID)
        handoverTasks[sessionID] = nil
    }

    /// The Chat run ends (after its turn), then the terminal resumes the session.
    private func moveToTerminal(_ sessionID: UUID, host: any StructuredFaceHost,
                                terminalWillStart: @MainActor (UUID) -> Void,
                                shown: @MainActor (UUID) -> Void) async throws {
        let card = try await host.handOverToTerminal(sessionID: sessionID, pointOfNoReturn: { [weak self] in
            await self?.passPointOfNoReturn(sessionID, to: .terminal)
        })
        // A session with no run here had nothing to wait for: the move is at its point now.
        if transitions.handovers[sessionID]?.phase != .switching { await passPointOfNoReturn(sessionID, to: .terminal) }
        // The Chat run has ended; the terminal starts unless a Stop came in meanwhile. `card` is the one the run ended on.
        if moveEnded(sessionID) || moveEnded(card) { throw CancellationError() }
        terminalWillStart(card)
        try await resumeInTerminal(card, shown: shown)
        await host.noteContinuedInTerminal(sessionID: sessionID)
    }

    /// The wait is over: from here Cancel is not offered. (Tests hold the move here, to act at this phase.)
    private func passPointOfNoReturn(_ sessionID: UUID, to target: SessionLiveFace) async {
        transitions.setHandover(Handover(target: target, phase: .switching), for: sessionID)
        await handoverGate?(sessionID, target)
    }

    // MARK: Requests

    /// The user's answer to a session's request. A failed answer stays on the request itself; nothing is assumed answered.
    @discardableResult
    public func answer(sessionID: UUID, requestID: String, accept: Bool) -> Task<Void, Never> {
        Task {
            do {
                try await runtime.respond(sessionID: sessionID, requestID: requestID, decision: accept ? .accept : .decline)
            } catch {
                failureHandler(SessionFailure(.answerNotDelivered, error))
            }
        }
    }

    /// "Open Session" on an agent's request (D-40), in the face the policy names. The runtime starts the session through the
    /// normal start path; a terminal run is adopted exactly as a start adopts it. A failed start is shown in the request's
    /// box (the runtime keeps it as failed) and never retried. Refused while the request's approval is in flight.
    @discardableResult
    public func approveOpen(requestID: UUID) -> Task<Void, Never>? {
        guard approving.insert(requestID).inserted else { return nil }
        if facePolicy.faceOfApprovedOpening(capabilities(of: .claude)) == .chat, let host = structuredHost {
            return approveOpenInStructuredFace(requestID: requestID, host: host)
        }
        guard let sink = terminal?.newRunSink() else {
            approving.remove(requestID)
            return nil
        }
        return Task {
            defer { approving.remove(requestID) }
            do {
                let launch = try await runtime.approveOpenRequest(
                    requestID, rows: sink.rows, columns: sink.columns, outputSink: sink.output
                )
                terminal?.adopt(launch, into: sink)
            } catch {
                terminal?.runFailedToStart(sink)
                // A start that failed is on the request's box; only an answer that could not be given is a banner.
                if error is OpenSessionError { failureHandler(SessionFailure(.openRequestNotAnswered, error)) }
            }
        }
    }

    /// The approved opening in the structured face: the host starts it, the request's message goes out once Ready, and no
    /// terminal is adopted. A start that failed is on the request's box; one that failed after the child was spawned (it
    /// never answered `initialize`) has no box left, so it is a banner, and the session's driver goes.
    private func approveOpenInStructuredFace(requestID: UUID, host: any StructuredFaceHost) -> Task<Void, Never> {
        let sessionID = UUID()
        return Task {
            defer { approving.remove(requestID) }
            let ready = Once {}
            do {
                try await host.beginOpenedSession(requestID: requestID, sessionID: sessionID,
                                                  onReady: { await MainActor.run { ready.fire() } })
            } catch {
                let kind = host.errorKind(of: error)
                if !ready.fired, kind != .stopping { host.forget(sessionID: sessionID) }
                if error is OpenSessionError {
                    failureHandler(SessionFailure(.openRequestNotAnswered, error))
                } else if kind == .failure {
                    failureHandler(SessionFailure(.startFailed(.claude), error))
                }
            }
        }
    }

    @discardableResult
    public func denyOpen(requestID: UUID) -> Task<Void, Never> {
        Task {
            do { try await runtime.denyOpenRequest(requestID) }
            catch { failureHandler(SessionFailure(.openRequestNotDenied, error)) }
        }
    }

    @discardableResult
    public func dismissOpen(requestID: UUID) -> Task<Void, Never> {
        Task {
            do { try await runtime.dismissOpenRequest(requestID) }
            catch { failureHandler(SessionFailure(.openRequestNotDismissed, error)) }
        }
    }

    /// The user looked at the session: its finished state is read.
    public func markViewed(sessionID: UUID) async {
        try? await runtime.markViewed(sessionID: sessionID)
    }

    // MARK: The session's own record

    /// The user's writes to a session's record (title, pin): the same catalog methods underneath.
    public func renameSession(sessionID: UUID, to title: String) async throws {
        try await records.rename(sessionID: sessionID, to: title)
    }

    public func setPinned(sessionID: UUID, _ pinned: Bool) async throws {
        try await records.setPinned(sessionID: sessionID, pinned)
    }

    // MARK: Deletion

    // Permanent deletion: the runtime owns every step; these only forward.

    public func deletionPreview(sessionID: UUID) async throws -> ConversationDeletionPreview {
        try await runtime.deletionPreview(id: sessionID)
    }

    public func deleteConversation(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        try await runtime.deleteConversation(id: sessionID)
    }

    public func retryDeletion(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        try await runtime.retryDeletion(id: sessionID)
    }

    public func pendingDeletions() async throws -> [PendingConversationDeletion] {
        try await runtime.pendingDeletions()
    }

    public func removeFromLoomOnly(sessionID: UUID) async throws {
        try await runtime.removeFromLoomOnly(id: sessionID)
    }

    public func deletionRecoveryFailure() async -> String? {
        await runtime.deletionRecoveryFailure()
    }

    public func deleteSideChats(inProject projectID: UUID) async throws {
        try await runtime.deleteSideChats(inProject: projectID)
    }
}

/// An action that runs once, on the main actor (a card told from either of two places).
@MainActor
private final class Once {
    private(set) var fired = false
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    func fire() {
        guard !fired else { return }
        fired = true
        body()
    }
}
