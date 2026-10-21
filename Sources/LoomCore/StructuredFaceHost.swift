import Foundation

/// How a structured face's error reads to the service.
public enum StructuredFaceErrorKind: Sendable {
    /// A Stop, Quit or face switch cancelled the operation: nothing failed, nothing is reported.
    case stopping
    /// The face's own failure (its child could not start, or ended before it was ready).
    case failure
    /// Any other error (the runtime's, the catalog's).
    case other
}

/// The lifecycle verbs of a session's structured (Chat) face, as `SessionService` needs them. The typed API the UI calls on
/// the face's driver (send, mode, model, rewind, cards) is the face's own and is not here. The face runs the session
/// through the runtime itself; the service only tells it which session and when.
///
/// A start calls `onReady` once the child answered `initialize` (Ready), before the draft's first message goes out, so a
/// caller that tells the UI there is told first. A start that throws before Ready leaves a driver the caller must `forget`.
@MainActor
public protocol StructuredFaceHost: AnyObject {
    /// Starts a new session of a project from a draft.
    func beginNewSession(projectID: UUID?, sessionID: UUID, draft: NewSessionLaunch?,
                         onReady: (@Sendable () async -> Void)?) async throws
    /// Starts the session an agent's approved open request opens.
    func beginOpenedSession(requestID: UUID, sessionID: UUID, onReady: (@Sendable () async -> Void)?) async throws
    /// Resumes a stopped session in the face.
    func resumeSession(sessionID: UUID) async throws
    /// Lets go of a session that never answered (and of its files).
    func forget(sessionID: UUID)
    func errorKind(of error: any Error) -> StructuredFaceErrorKind

    // MARK: The move to the terminal (V19)
    //
    // The face holds the session for the whole move: from `handOverToTerminal` until `finishHandover`, whatever the result,
    // it refuses new turns and keeps its queue. The service tells the same session id throughout; the face keeps the
    // object it began with, so a `/clear` that moves the run to a new card in between does not lose it.

    /// Lets go of the session's run for the terminal: waits for a running turn, refuses what must not be moved (a waiting
    /// request, background work, a start or stop under way: see `handoverRefusal`), tells `pointOfNoReturn` once the wait is
    /// over and the run is about to end, then ends the run in the verified order. Throws `CancellationError` when
    /// `cancelHandover` ended the wait. Returns the card the run ended on: after a `/clear` that is not `sessionID`.
    func handOverToTerminal(sessionID: UUID, pointOfNoReturn: @escaping @Sendable () async -> Void) async throws -> UUID
    /// Ends the wait of a move that has not reached its point of no return (a later call does nothing).
    func cancelHandover(sessionID: UUID)
    /// The run ended for a move that did not happen: the face says it was interrupted, not moved.
    func handoverFailed(sessionID: UUID) async
    /// The terminal has the session: the face notes that it continued there.
    func noteContinuedInTerminal(sessionID: UUID) async
    /// The move is over, made or not: the face is its own again.
    func finishHandover(sessionID: UUID) async
    /// How a refusal or failure of the move reads, nil for any other error.
    func handoverRefusal(of error: any Error) -> HandoverRefusal?
}
