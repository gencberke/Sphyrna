import Foundation
import LoomCore
import Observation

/// The handover between the faces (V19). Since D-69 the face is one app-wide switch (Settings → General → "Sessions run
/// in") and no menu moves a session: the machinery stays for the policy banner's "Switch to Terminal"
/// (`switchToTerminal`) and the evidence command `continue-in` (`continueIn`).
///
/// A handover never runs two owners and never loses a turn:
/// - it **waits** for a turn that runs (the old owner keeps its run until the turn ends; the Chat face holds its queue and
///   refuses new turns meanwhile, `ChatSessionDriver.handOverToTerminal`); a terminal session must also hold still at
///   its prompt for a moment before the move;
/// - it **refuses** while a request waits for the user (an approval, a question, a dialog; a terminal at its prompt is
///   idle, not a request), while background work runs, and while the session is starting, stopping or already being
///   handed over;
/// - it has a **point of no return**: before it, Cancel and Stop end the move and the session goes on where it was;
///   after it (`Phase.switching`) Cancel is no longer offered and a Stop ends the other face's start;
/// - the old owner's run ends in the verified order before the new one starts (the runtime's same-session guard is the
///   second lock), queued messages and drafts are kept.
///
/// The owning face is the run's endpoint, persisted by the runtime (`CatalogSession.runEndpoint`); this file only asks
/// for the move and shows where it stands.
public struct Handover: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Waiting for the running turn to end; it can be cancelled.
        case waiting
        /// The point of no return is passed: the old run is ending and the new one starts. Cancel is not offered.
        case switching
    }

    public let target: SessionFace
    public var phase: Phase

    public init(target: SessionFace, phase: Phase = .waiting) {
        self.target = target
        self.phase = phase
    }
}

/// Where a session stands for a handover, from the old owner's side.
enum HandoverStanding: Equatable {
    /// No run: the session resumes in the new face directly.
    case stopped
    /// A run that takes the handover now.
    case idle
    /// A turn runs: the handover waits for its end.
    case working
    /// A request waits for the user: refused.
    case requestWaiting
    /// Background work runs under the finished turn: refused.
    case backgroundWork

    /// A terminal run, from its hook-reported state in the hub.
    ///
    /// "Waiting for input" is mostly the resting state of a terminal session (the registry's `idle`, and Claude's
    /// `idle_prompt` reminder a minute after a turn): only an input *request* (an MCP elicitation, `agent_needs_input`:
    /// the reason `.input`) is a request that refuses.
    init(terminal state: SessionViewState?) {
        guard let state, state.runID != nil else { self = .stopped; return }
        if !state.waitingRequests.isEmpty { self = .requestWaiting; return }
        switch state.status?.activity {
        case .working?: self = .working
        case .waitingForApproval?: self = .requestWaiting
        case .waitingForInput? where state.reason?.kind == .input: self = .requestWaiting
        default: self = (state.status?.pendingProviderWorkCount ?? 0) > 0 ? .backgroundWork : .idle
        }
    }
}

/// Why a handover was refused (the words the user reads).
enum HandoverRefusal: Error, Equatable, CustomStringConvertible {
    case requestWaiting
    case backgroundWork
    case busy
    /// The terminal session started another turn while the move waited for it to settle.
    case workResumed
    /// A `/clear` moved the session while the move waited: it ended, nothing moved.
    case cleared

    var description: String {
        switch self {
        case .requestWaiting: "A request is waiting for your answer. Answer it first, then continue."
        case .backgroundWork: "Background tasks are still running in this session. Let them finish, or stop the session."
        case .busy: "The session is starting, stopping or already moving. Try again in a moment."
        case .workResumed: "The session started another turn. Continue again when it ends."
        case .cleared: "The session was cleared, so it was not moved."
        }
    }
}

/// What the model asks of the runtime for a handover. `ConversationController` adopts it; a stub without it cannot
/// hand a session over, and the menu does not offer it.
@MainActor
public protocol HandoverIntents: ConversationIntents {
    /// Moves the session to `target`. Runs in the background: `Handover` state on the model shows where it stands, and a
    /// refusal or failure is a banner.
    func handOver(sessionID: UUID, to target: SessionFace)
    /// Ends the wait of a handover that has not stopped the old run yet.
    func cancelHandover(sessionID: UUID)
}

extension CatalogModel {
    /// The name of the move to `target` (the "Cancel …" item of a move that waits, the evidence).
    public static func continueTitle(_ target: SessionFace) -> String {
        target == .terminal ? "Continue in Terminal" : "Continue in Chat"
    }

    /// The only move item the session's ⋯ menu may hold (D-69): the way to end a move that waits. Nil when nothing waits.
    public static func cancelMoveTitle(for handover: Handover?) -> String? {
        guard let handover, handover.phase == .waiting else { return nil }
        return "Cancel " + continueTitle(handover.target)
    }

    /// The handover in progress for the session, if any.
    public func handover(of sessionID: UUID) -> Handover? { handovers[sessionID] }

    /// What the header says while a handover is under way.
    public func handoverNotice(of sessionID: UUID) -> String? {
        guard let handover = handovers[sessionID] else { return nil }
        let face = handover.target == .terminal ? "Terminal" : "Chat"
        switch handover.phase {
        case .waiting:
            // A Chat session waits for its turn; a terminal session also has to rest at its prompt for a moment.
            return handover.target == .terminal ? "Continuing in \(face) when this turn ends" : "Continuing in \(face) when the session rests"
        case .switching: return "Moving to \(face)…"
        }
    }

    /// Whether the session can be moved to `target` now: a Claude session that the other face owns (or that has no owner
    /// recorded yet, which counts as the terminal), with no start, stop, resume or handover under way.
    public func canContinue(in target: SessionFace, row: SessionRowModel) -> Bool {
        guard actionsAvailable, intents is any HandoverIntents, chatSessions != nil,
              row.record.session.provider == .claude, startableProviders.contains(.claude),
              handovers[row.id] == nil, busy[row.id] == nil, !isDeleting(row.id) else { return false }
        let owner = owningFace(of: row) ?? .terminal
        return owner != target
    }

    /// What the composer says while the session is being moved: sending waits. Nil without a handover.
    public func composerHandoverNotice(of sessionID: UUID) -> String? {
        guard let handover = handovers[sessionID] else { return nil }
        return handover.target == .terminal ? "Moving to the terminal…" : "Moving to Chat…"
    }

    /// "Continue in Terminal" / "Continue in Chat" for the session.
    public func continueIn(_ target: SessionFace, sessionID: UUID) {
        guard let row = rowModels[sessionID], canContinue(in: target, row: row),
              let intents = intents as? any HandoverIntents else { return }
        intents.handOver(sessionID: sessionID, to: target)
    }

    /// The policy banner's "Switch to Terminal": the account's policy refuses the Chat face, so Chat cannot go on. The
    /// switch in Settings goes to Terminal (new starts and resumes follow it) and this session moves with the handover.
    public func switchToTerminal(sessionID: UUID) {
        guard let row = rowModels[sessionID], canContinue(in: .terminal, row: row) else { return }
        setNewSessionFace(.terminal)
        continueIn(.terminal, sessionID: sessionID)
    }

    /// Ends the wait of a handover; the session goes on in the face it was in.
    public func cancelHandover(sessionID: UUID) {
        guard handovers[sessionID]?.phase == .waiting, let intents = intents as? any HandoverIntents else { return }
        intents.cancelHandover(sessionID: sessionID)
    }

    // Called by the conversation controller.

    func setHandover(_ value: Handover?, for sessionID: UUID) {
        if handovers[sessionID] != value { handovers[sessionID] = value }
    }
}
