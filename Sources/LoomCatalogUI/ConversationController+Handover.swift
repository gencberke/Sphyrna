import Foundation
import LoomChat
import LoomCore

/// The handover from the Chat face to the terminal (V19), on the controller that owns the terminals. The order never has
/// two owners: the Chat run ends in the verified order (and a running turn is waited for first), then the terminal's run
/// starts; the runtime's same-session guard refuses a second run of a session that still has one. See
/// `CatalogModel+Handover` for what is waited for and what is refused. (The other direction, terminal to Chat, was removed:
/// no release build reached it.)
///
/// Every handover has a point of no return (`Handover.Phase.switching`). Before it, Cancel and Stop end the move and the
/// session goes on where it was. After it, Cancel is no longer offered, and a Stop ends the terminal's start: the task
/// is cancelled, and right before the terminal would start (`resumeInTerminal`) the move looks for the cancellation and
/// for a Stop that is under way.
extension ConversationController {
    public func handOver(sessionID: UUID, to target: SessionFace) {
        guard target == .terminal, let model, model.actionsAvailable, model.handovers[sessionID] == nil, model.busy[sessionID] == nil else { return }
        model.setHandover(Handover(target: target), for: sessionID)
        handoverTasks[sessionID] = Task { [weak self] in
            await self?.runHandover(sessionID: sessionID)
        }
    }

    /// The user's Cancel: ends a wait that has not reached the point of no return.
    public func cancelHandover(sessionID: UUID) {
        guard model?.handovers[sessionID]?.phase == .waiting else { return }
        endHandover(sessionID)
    }

    /// A Stop ends a move in any phase: before the point it ends the wait; after it the other face does not start.
    func stopHandover(sessionID: UUID) {
        guard model?.handovers[sessionID] != nil else { return }
        endHandover(sessionID)
    }

    private func endHandover(_ sessionID: UUID) {
        handoverTasks[sessionID]?.cancel()
        // The Chat face's wait is the driver's: it does not look at task cancellation. (After its point of no return it
        // ignores this.)
        if let driver = model?.chatSessions?.existingDriver(for: sessionID) {
            Task { await driver.cancelHandover() }
        }
    }

    /// Whether the move of `sessionID` must not start the terminal now: its task was cancelled or a Stop is under way.
    private func moveEnded(_ sessionID: UUID) -> Bool {
        Task.isCancelled || model?.busy[sessionID] == .stopping
    }

    private func runHandover(sessionID: UUID) async {
        guard let model else { return }
        // The driver object, not its card: a `/clear` that moves the run re-keys it, and the move must still reach it.
        let driver = model.chatSessions?.driver(for: sessionID)
        do {
            try await handOverToTerminal(sessionID)
        } catch {
            // The Chat run ended for a move that did not happen: the queue says it was interrupted, not moved.
            if model.handovers[sessionID]?.phase == .switching { await driver?.handoverFailed() }
            if error is CancellationError || Task.isCancelled {
                // The user ended the move (Cancel, Stop): the session goes on where it was, or stays stopped.
            } else if Self.refusal(error) == .cleared {
                model.showInfo(HandoverRefusal.cleared.description)
            } else {
                report(Self.refusal(error).map { $0 as any Error } ?? error, "The session could not be moved")
            }
        }
        // The move is over, made or not: the Chat driver was holding the session for it (a send was refused meanwhile), and
        // it is its own again now.
        await driver?.finishHandover()
        model.setHandover(nil, for: sessionID)
        handoverTasks[sessionID] = nil
    }

    /// The Chat run ends (after its turn), then the terminal resumes the session.
    private func handOverToTerminal(_ sessionID: UUID) async throws {
        guard let model, let host = model.chatSessions else { throw CatalogModel.LiveChatError.unavailable }
        let driver = host.driver(for: sessionID)
        try await driver.handOverToTerminal(pointOfNoReturn: { [weak self] in
            await self?.passPointOfNoReturn(sessionID, to: .terminal)
        })
        // A session with no run here had nothing to wait for: the move is at its point now.
        if model.handovers[sessionID]?.phase != .switching { await passPointOfNoReturn(sessionID, to: .terminal) }
        // The Chat run has ended; the terminal starts unless a Stop came in meanwhile. The card the run ended on is the
        // driver's now: a `/clear` that moved it after the point (while the stop ran) made a new card, and that card is the
        // session's conversation, not the one the move began on.
        let card = await driver.sessionID
        if moveEnded(sessionID) || moveEnded(card) { throw CancellationError() }
        // Looking at the terminal from now on: a look at the transcript that was picked earlier does not hide it.
        model.faces.choose(.terminal, for: card)
        try await resumeInTerminal(card)
        await driver.noteFace(.continuedInTerminal)
    }

    /// The wait is over: from here Cancel is not offered. (Tests hold the move here, to act at this phase.)
    private func passPointOfNoReturn(_ sessionID: UUID, to target: SessionFace) async {
        model?.setHandover(Handover(target: target, phase: .switching), for: sessionID)
        await handoverGate?(sessionID, target)
    }

    /// The words of a refusal the Chat driver or the gate made, nil for any other error.
    static func refusal(_ error: any Error) -> HandoverRefusal? {
        if let refusal = error as? HandoverRefusal { return refusal }
        switch error as? ChatDriverError {
        case .requestWaiting?: return .requestWaiting
        case .backgroundWork?: return .backgroundWork
        case .busy?, .stopping?: return .busy
        case .clearedDuringHandover?: return .cleared
        default: return nil
        }
    }
}
