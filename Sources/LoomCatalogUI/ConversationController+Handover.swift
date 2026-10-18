import Foundation
import LoomChat
import LoomCore

/// The handover between the faces (V19), on the controller that owns the terminals. The order never has two owners:
/// the old face's run ends in the verified order (and a running turn is waited for first), then the new face's run
/// starts; the runtime's same-session guard refuses a second run of a session that still has one. See
/// `CatalogModel+Handover` for what is waited for and what is refused.
///
/// Every handover has a point of no return (`Handover.Phase.switching`). Before it, Cancel and Stop end the move and the
/// session goes on where it was. After it, Cancel is no longer offered, and a Stop ends the other face's start: the task
/// is cancelled, and right before the new face would start (`resumeInTerminal`, the Chat resume) the move looks for the
/// cancellation and for a Stop that is under way.
extension ConversationController {
    public func handOver(sessionID: UUID, to target: SessionFace) {
        guard let model, model.actionsAvailable, model.handovers[sessionID] == nil, model.busy[sessionID] == nil else { return }
        model.setHandover(Handover(target: target), for: sessionID)
        handoverTasks[sessionID] = Task { [weak self] in
            await self?.runHandover(sessionID: sessionID, to: target)
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

    /// Whether the move of `sessionID` must not start the new face now: its task was cancelled or a Stop is under way.
    private func moveEnded(_ sessionID: UUID) -> Bool {
        Task.isCancelled || model?.busy[sessionID] == .stopping
    }

    private func runHandover(sessionID: UUID, to target: SessionFace) async {
        guard let model else { return }
        let driver = model.chatSessions?.existingDriver(for: sessionID)
        defer {
            model.setHandover(nil, for: sessionID)
            handoverTasks[sessionID] = nil
        }
        do {
            switch target {
            case .terminal: try await handOverToTerminal(sessionID)
            case .chat: try await handOverToChat(sessionID)
            }
        } catch {
            // The Chat run ended for a move that did not happen: the queue says it was interrupted, not moved.
            if target == .terminal, model.handovers[sessionID]?.phase == .switching { await driver?.handoverFailed() }
            if error is CancellationError || Task.isCancelled {
                // The user ended the move (Cancel, Stop): the session goes on where it was, or stays stopped.
            } else if let reset = error as? ChatDriverError, reset == .clearedDuringHandover {
                model.showInfo(HandoverRefusal.cleared.description)
            } else {
                report(Self.refusal(error).map { $0 as any Error } ?? error, "The session could not be moved")
            }
        }
    }

    /// Chat → Terminal: the Chat run ends (after its turn), then the terminal resumes the session.
    private func handOverToTerminal(_ sessionID: UUID) async throws {
        guard let model, let host = model.chatSessions else { throw CatalogModel.LiveChatError.unavailable }
        let driver = host.driver(for: sessionID)
        try await driver.handOverToTerminal(pointOfNoReturn: { [weak self] in
            await self?.passPointOfNoReturn(sessionID, to: .terminal)
        })
        // A session with no run here had nothing to wait for: the move is at its point now.
        if model.handovers[sessionID]?.phase != .switching { await passPointOfNoReturn(sessionID, to: .terminal) }
        // The Chat run has ended; the terminal starts unless a Stop came in meanwhile.
        if moveEnded(sessionID) { throw CancellationError() }
        // Looking at the terminal from now on: a look at the transcript that was picked earlier does not hide it.
        model.faces.choose(.terminal, for: sessionID)
        try await resumeInTerminal(sessionID)
        await driver.noteFace(.continuedInTerminal)
    }

    /// Terminal → Chat: a turn under way in the terminal is waited for and the session must rest for a moment; a waiting
    /// request or background work refuses. Then the terminal run ends and the Chat face resumes the session.
    private func handOverToChat(_ sessionID: UUID) async throws {
        guard let model, let host = model.chatSessions else { throw CatalogModel.LiveChatError.unavailable }
        try await awaitTerminalRest(sessionID)
        await passPointOfNoReturn(sessionID, to: .chat)
        _ = try await host.enterChat(sessionID: sessionID, beforeResume: { [weak self] in
            self?.moveEnded(sessionID) == false
        })
        // The chat shows the whole session; the last terminal screen of the run that just ended is not kept.
        releaseEndedScreen(sessionID)
        model.faces.choose(.chat, for: sessionID)
        model.showStarted(sessionID)
    }

    /// The wait is over: from here Cancel is not offered. (Tests hold the move here, to act at this phase.)
    private func passPointOfNoReturn(_ sessionID: UUID, to target: SessionFace) async {
        model?.setHandover(Handover(target: target, phase: .switching), for: sessionID)
        await handoverGate?(sessionID, target)
    }

    /// Returns once the session's terminal run has been at rest (not in a turn, no request, no background work) for
    /// `handoverSettle`. A turn under way is waited for, and one that starts again within the settle time restarts it:
    /// the first idle frame between two hooks is not the end. A request waiting or background work refuses (also if it
    /// appears meanwhile); and the standing is looked at once more right before the move, refusing if work resumed.
    private func awaitTerminalRest(_ sessionID: UUID) async throws {
        let clock = ContinuousClock()
        var restingSince: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            switch await terminalStanding(sessionID) {
            case .stopped: return
            case .requestWaiting: throw HandoverRefusal.requestWaiting
            case .backgroundWork: throw HandoverRefusal.backgroundWork
            case .working: restingSince = nil
            case .idle:
                let since = restingSince ?? clock.now
                restingSince = since
                if since.duration(to: clock.now) >= handoverSettle {
                    // Right before the move: work that resumed in the last moment refuses.
                    switch await terminalStanding(sessionID) {
                    case .stopped, .idle: return
                    case .working: throw HandoverRefusal.workResumed
                    case .requestWaiting: throw HandoverRefusal.requestWaiting
                    case .backgroundWork: throw HandoverRefusal.backgroundWork
                    }
                }
            }
            try await Task.sleep(for: min(.milliseconds(50), handoverSettle / 3))
        }
    }

    private func terminalStanding(_ sessionID: UUID) async -> HandoverStanding {
        HandoverStanding(terminal: await runtime.supervisor.events.snapshot().sessions[sessionID])
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
