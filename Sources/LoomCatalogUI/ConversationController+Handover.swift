import Foundation
import LoomChat
import LoomCore

/// The handover from the Chat face to the terminal (V19) is the session service's: `SessionService.handOver` runs it and
/// holds its state (`SessionTransitions.handovers`), and the Chat face takes part through `StructuredFaceHost`. See
/// `Handover` for the rules (the order never has two owners; the point of no return). This extension only forwards the
/// model's intents and does the UI's part at the moments the service tells: look at the terminal, show it, say that a
/// `/clear` ended the move. A failure comes back through `failureHandler` ("The session could not be moved").
extension ConversationController {
    public func handOver(sessionID: UUID, to target: SessionFace) {
        guard let model, model.actionsAvailable else { return }
        service.handOver(
            sessionID: sessionID, to: target == .chat ? .chat : .terminal,
            // Looking at the terminal from now on: a look at the transcript that was picked earlier does not hide it.
            terminalWillStart: { [weak model] card in model?.faces.choose(.terminal, for: card) },
            shown: { [weak model] id in model?.showStarted(id) },
            cleared: { [weak model] in model?.showInfo(HandoverRefusal.cleared.description) }
        )
    }

    /// The user's Cancel: ends a wait that has not reached the point of no return.
    public func cancelHandover(sessionID: UUID) {
        service.cancelHandover(sessionID: sessionID)
    }
}
