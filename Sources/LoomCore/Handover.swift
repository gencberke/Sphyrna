import Foundation

/// The handover from the Chat face to the terminal (V19), as the session service holds it. Since D-69 the face is one
/// app-wide switch (Settings → General → "Sessions run in") and no menu moves a session: the machinery stays for the policy
/// banner's "Switch to Terminal" and the evidence command `continue-in`. The other direction, terminal to Chat, was
/// removed: no release build reached it.
///
/// A handover never runs two owners and never loses a turn:
/// - it **waits** for a turn that runs (the Chat run is kept until the turn ends; the Chat face holds its queue and
///   refuses new turns meanwhile);
/// - it **refuses** while a request waits for the user (an approval, a question, a dialog), while background work runs,
///   and while the session is starting, stopping or already being handed over;
/// - it has a **point of no return**: before it, Cancel and Stop end the move and the session goes on where it was;
///   after it (`Phase.switching`) Cancel is no longer offered and a Stop ends the terminal's start;
/// - the Chat run ends in the verified order before the terminal's starts (the runtime's same-session guard is the
///   second lock), queued messages and drafts are kept.
///
/// The owning face is the run's endpoint, persisted by the runtime (`CatalogSession.runEndpoint`); this value only says
/// where a move stands.
public struct Handover: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Waiting for the running turn to end; it can be cancelled.
        case waiting
        /// The point of no return is passed: the old run is ending and the new one starts. Cancel is not offered.
        case switching
    }

    /// The face the session moves to (only the terminal today).
    public let target: SessionLiveFace
    public var phase: Phase

    public init(target: SessionLiveFace, phase: Phase = .waiting) {
        self.target = target
        self.phase = phase
    }
}

/// Why a handover was refused (the words the user reads).
public enum HandoverRefusal: Error, Equatable, CustomStringConvertible, Sendable {
    case requestWaiting
    case backgroundWork
    case busy
    /// A `/clear` moved the session while the move waited: it ended, nothing moved.
    case cleared

    public var description: String {
        switch self {
        case .requestWaiting: "A request is waiting for your answer. Answer it first, then continue."
        case .backgroundWork: "Background tasks are still running in this session. Let them finish, or stop the session."
        case .busy: "The session is starting, stopping or already moving. Try again in a moment."
        case .cleared: "The session was cleared, so it was not moved."
        }
    }
}
