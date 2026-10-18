import Foundation
import LoomCore
import Observation

/// The handover between the faces (V19): "Continue in Terminal" and "Continue in Chat" in a session's ⋯ menu.
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
    /// The title of the menu item that moves the session to `target`.
    public static func continueTitle(_ target: SessionFace) -> String {
        target == .terminal ? "Continue in Terminal" : "Continue in Chat"
    }

    /// The tooltip of the menu item that moves the session to `target`. Leaving the terminal loses a prompt that is typed
    /// there and not sent: the Chat face cannot read the TUI's input line.
    public static func continueHelp(_ target: SessionFace) -> String {
        switch target {
        case .terminal: "Moves the session to the terminal when its turn ends. Queued messages and the draft are kept."
        case .chat: "Moves the session to Chat once it rests. A prompt typed but not sent in the terminal is lost."
        }
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

    /// Why the session cannot be moved to the other face right now, in the words the `/` menu shows; nil when it can. A
    /// request that waits and background work refuse (from the hub, whichever face runs the session); so do a start, a
    /// stop, a resume or a handover that is under way.
    public func continueUnavailableReason(sessionID: UUID) -> String? {
        if !actionsAvailable { return "Loom is not ready to move sessions." }
        if handovers[sessionID] != nil { return "This session is already moving." }
        if busy[sessionID] != nil { return HandoverRefusal.busy.description }
        if isDeleting(sessionID) { return "This session is being deleted." }
        switch HandoverStanding(terminal: liveStates[sessionID]) {
        case .requestWaiting: return HandoverRefusal.requestWaiting.description
        case .backgroundWork: return HandoverRefusal.backgroundWork.description
        case .stopped, .idle, .working: return nil
        }
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

    /// "Continue in …" for the selected session (the ⋯ menu, the composer's `/` menu, the policy banner).
    public func continueSelected(in target: SessionFace) {
        guard let id = selectedSessionID else { return }
        continueIn(target, sessionID: id)
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
