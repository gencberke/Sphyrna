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
}
