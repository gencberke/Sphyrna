import Foundation
import LoomCore

// The handover from the Chat face to the terminal (V19) is the session service's (`SessionService.handOver`); its value
// (`Handover`) and its refusals (`HandoverRefusal`) are in LoomCore. This file is the model's side: what the UI asks and
// shows. Since D-69 no menu moves a session: the machinery stays for the policy banner's "Switch to Terminal"
// (`switchToTerminal`) and the evidence command `continue-in` (`continueIn`).

/// What the model asks for a handover. `ConversationController` adopts it (and forwards to the service); a stub without it
/// cannot hand a session over, and the menu does not offer it.
@MainActor
public protocol HandoverIntents: ConversationIntents {
    /// Moves the session to `target`. Runs in the background: `Handover` state on the model shows where it stands, and a
    /// refusal or failure is a banner.
    func handOver(sessionID: UUID, to target: SessionFace)
    /// Ends the wait of a handover that has not stopped the old run yet.
    func cancelHandover(sessionID: UUID)
}

extension CatalogModel {
    /// The only move item the session's ⋯ menu may hold (D-69): the way to end a move that waits. Nil when nothing waits.
    public static func cancelMoveTitle(for handover: Handover?) -> String? {
        guard let handover, handover.phase == .waiting else { return nil }
        return "Cancel Continue in Terminal"
    }

    /// The handover in progress for the session, if any.
    public func handover(of sessionID: UUID) -> Handover? { handovers[sessionID] }

    /// What the header says while a handover is under way.
    public func handoverNotice(of sessionID: UUID) -> String? {
        guard let handover = handovers[sessionID] else { return nil }
        switch handover.phase {
        case .waiting: return "Continuing in Terminal when this turn ends"
        case .switching: return "Moving to Terminal…"
        }
    }

    /// Whether the session can be moved to `target` now: only to the terminal, a Claude session that the Chat face owns (or
    /// that has no owner recorded yet, which counts as the terminal), with no start, stop, resume or handover under way.
    public func canContinue(in target: SessionFace, row: SessionRowModel) -> Bool {
        guard target == .terminal, actionsAvailable, intents is any HandoverIntents, chatSessions != nil,
              capabilities(of: row.record.session.provider).structuredFace, capabilities(of: .claude).startable,
              handovers[row.id] == nil, busy[row.id] == nil, !isDeleting(row.id) else { return false }
        let owner = owningFace(of: row) ?? .terminal
        return owner != target
    }

    /// What the composer says while the session is being moved: sending waits. Nil without a handover.
    public func composerHandoverNotice(of sessionID: UUID) -> String? {
        handovers[sessionID] == nil ? nil : "Moving to the terminal…"
    }

    /// "Continue in Terminal" for the session; a move to Chat is refused (`canContinue`).
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
}
