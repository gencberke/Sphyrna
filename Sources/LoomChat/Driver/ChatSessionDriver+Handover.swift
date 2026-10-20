import Foundation
import LoomCore

extension ChatSessionDriver {
    // MARK: Handover (V19)

    /// Chat → Terminal, up to the point where the terminal takes over: this face lets go of the session, and nothing is
    /// cut. The caller then resumes the terminal face (`SessionRuntime.resumeConversation`).
    ///
    /// - A request that waits for the user, background tasks under the finished turn and a start or stop under way
    ///   are refused (`requestWaiting`, `backgroundWork`, `busy`): nothing changes.
    /// - A turn that runs is waited for, not interrupted; the session keeps its run until the turn's `result`. From
    ///   the call on nothing starts another turn here (`handingOver`), and "After this turn" items stay queued. A
    ///   `cancelHandover()` ends the wait with a `CancellationError`, and the session carries on as it was; so does a
    ///   Stop. Requests and background work are checked again after the wait, right before the point of no return
    ///   (a request or a task that began meanwhile refuses).
    /// - `pointOfNoReturn` runs once, when the wait is over and the run is about to end: from then on a cancel does
    ///   nothing, and the caller tells the user that the move is under way.
    /// - Then the run ends in the verified order (`stop()`: stdin closes, the exit is awaited). Queued messages stay,
    ///   paused with `PauseReason.handover` (only by this stop: a Stop or Quit of the user pauses with `interrupted`);
    ///   unread messages and drafts are kept as for any run end. The marker "Continued in Terminal" is the caller's, once
    ///   the terminal has the session (`noteFace`), and `handoverFailed()` when it does not.
    ///
    /// A session with no run here has nothing to let go of: it returns at once. A second call while one is under way
    /// is refused (`busy`), so two handovers never race.
    ///
    /// **The hold outlives this call.** When it returns, the session is still the move's until the caller says the other
    /// face has it or the move failed (`finishHandover()`): between the two, a send is refused (`handingOver`) and the
    /// queue stays, so the driver never starts a run the terminal is about to take. A call that throws releases the hold
    /// itself: the run stays here, so what was picked meanwhile reaches it and the queue goes on (a Cancel after the turn
    /// ended would otherwise leave "After this turn" items with nothing to release them).
    public func handOverToTerminal(pointOfNoReturn: (@Sendable () async -> Void)? = nil) async throws {
        switch phase {
        case .starting, .stopping: throw ChatDriverError.busy
        case .stopped, .failed, .ready, .working, .needsYou: break
        }
        guard !handover.isHolding else { throw ChatDriverError.busy }
        if !phase.isLive {
            // Nothing runs here to let go of; the session is still the move's until it is finished.
            handover.commit()
            return
        }
        guard requests.isEmpty else { throw ChatDriverError.requestWaiting }
        guard background.count == 0 else { throw ChatDriverError.backgroundWork }
        heldPicks = HeldPicks()
        do { try await holdForTerminal(pointOfNoReturn: pointOfNoReturn) } catch {
            // The run stays: what was picked meanwhile reaches it now, then the queue goes on.
            await replayHeldPicks()
            await releaseQueueReportingIssue()
            throw error
        }
        heldPicks = HeldPicks()
    }

    /// The other face has the session, or the move failed or was stopped: the driver is its own again. A send that comes now
    /// resumes the session (when the terminal has it, the runtime refuses a second run).
    public func finishHandover() {
        guard handover.isHolding else { return }
        handover.release()
    }

    private func holdForTerminal(pointOfNoReturn: (@Sendable () async -> Void)?) async throws {
        handover.beginWaiting()
        var moved = false
        defer {
            // A move that is under way keeps its hold (`finishHandover`); one that ended without a move releases it.
            if !moved { handover.release() } else { handover.endStopping() }
        }
        while turnRunning, !handover.isCancelled, run != nil { await waitForTurnEnd(seconds: 1) }
        if handover.isCancelled { throw handover.wasCleared ? ChatDriverError.clearedDuringHandover : CancellationError() }
        // The run ended on its own while the handover waited: there is nothing left to stop.
        guard run != nil, phase.isLive else {
            moved = true
            handover.commit()
            return
        }
        // Checked again: a request or a task that began while the turn ran is not ended by a move.
        // A mode change that was already on its way to the child is let finish (its answer or the timeout); anything picked
        // from now on is held, not sent.
        await handoverParked?()
        await serialMode {}
        if handover.isCancelled { throw handover.wasCleared ? ChatDriverError.clearedDuringHandover : CancellationError() }
        guard requests.isEmpty else { throw ChatDriverError.requestWaiting }
        guard background.count == 0 else { throw ChatDriverError.backgroundWork }
        handover.commit()
        await pointOfNoReturn?()
        handover.beginStopping()
        try await stop()
        // The run is gone: the session stays the move's until the caller finishes it. A stop that threw releases the hold.
        moved = true
    }

    /// Ends the wait of a handover that has not reached its point of no return; the session goes on in the Chat face.
    public func cancelHandover() {
        guard handover.isHolding, !handover.isCommitted else { return }
        handover.cancel()
        wakeTurnEndWaiters()
    }

    /// A handover to the terminal waits or is stopping the run.
    public var isHandingOver: Bool { handover.isHolding }

    /// Tests park a handover here (`handoverParked`, in the core), once its wait for the turn is over and before it decides.
    func setHandoverParked(_ pause: (@Sendable () async -> Void)?) { handoverParked = pause }

    /// Tells the run what was picked while the handover held it (a handover that ended without moving the session). The
    /// transitions start from the state the child was in, so Ask's layer, the CLI's mode and the markers come out as for any
    /// pick; a transition that fails leaves the child as it was and the choice back at what it matches.
    private func replayHeldPicks() async {
        let held = heldPicks
        heldPicks = HeldPicks()
        guard run != nil, phase.isLive else { return }
        if let mode = held.mode, let child = held.childMode {
            choices.permissionMode = child.choice
            permissionMode = child.wire
            modeBeforeAsk = child.before
            do { try await setPermissionMode(mode) } catch {
                journal?.record("chat.held_mode_failed", ["error": .string(LoomLog.category(of: error))])
                if let choice = child.choice { await recordChoices(ClaudeLaunchChoices(permissionMode: choice)) }
            }
        }
        if let name = held.model {
            do { try await setModel(name) } catch {
                journal?.record("chat.held_model_failed", ["error": .string(LoomLog.category(of: error))])
                // The pick was recorded when it was made, and the child never took it: the choice, the chip and the catalog
                // go back to what the child runs.
                if let child = held.childModel {
                    choices.model = child.choice
                    liveModel = child.live
                    await runtime.restoreLaunchModel(child.choice, sessionID: sessionID)
                    await followRun()
                    changed()
                    onChoicesChanged(choices)
                }
            }
        }
        do {
            if held.effortCleared { try await clearEffort() } else if let level = held.effort { try await setEffort(level) }
        } catch {
            journal?.record("chat.held_effort_failed", ["error": .string(LoomLog.category(of: error))])
            if let child = held.childEffort {
                choices.effort = child.choice
                effortCleared = child.cleared
                if let level = child.choice {
                    await runtime.recordLaunchChoices(ClaudeLaunchChoices(effort: level), sessionID: sessionID)
                } else {
                    await runtime.clearLaunchEffort(sessionID: sessionID)
                }
                await followRun()
                changed()
                onChoicesChanged(choices)
            }
        }
    }

    /// The terminal did not take the session after the run ended (its resume failed, or a Stop ended the move): the
    /// queue was paused for a move that did not happen, so it says it was interrupted.
    public func handoverFailed() {
        guard queue.paused == .handover else { return }
        pauseQueue(.interrupted)
    }

    /// Where a handover to the terminal is (V19). One value instead of five flags: a combination the flags could not have
    /// (a cancel after the point of no return, a stop that is not committed) cannot be built, and each transition only moves
    /// from the states it is meant for.
    ///
    /// - `none` -> `waiting` (`beginWaiting`); `waiting` -> `cancelled(byClear: false)` (`cancel`).
    /// - `waiting` or `cancelled` -> `cancelled(byClear: true)` (`endByClear`, a `/clear` moved the run).
    /// - Any state -> `committed` (`commit`, the point of no return) -> `stopping` (`beginStopping`) -> `committed`
    ///   (`endStopping`, the stop returned and the move waits for `finishHandover()`).
    /// - Any state -> `none` (`release`).
    enum HandoverState: Equatable {
        /// No handover.
        case none
        /// The handover waits for the running turn; a cancel ends the wait.
        case waiting
        /// The wait was ended: by the user, or (`byClear`) by a `/clear` that moved the run. The handover still holds the
        /// session until `handOverToTerminal` throws and releases it.
        case cancelled(byClear: Bool)
        /// Past the point of no return; also "moved, waiting for `finishHandover()`".
        case committed
        /// The handover's own `stop()` runs: only that stop pauses the queue with `.handover`.
        case stopping

        /// A handover holds the session: nothing starts a turn here.
        var isHolding: Bool { self != .none }
        /// The wait is over and the run is being ended (or is gone) for the other face: a cancel no longer works.
        var isCommitted: Bool { self == .committed || self == .stopping }
        /// The wait was ended, by the user or by a `/clear`.
        var isCancelled: Bool {
            if case .cancelled = self { true } else { false }
        }
        /// The wait was ended by a `/clear` that moved the run (a later cancel by the user keeps it so).
        var wasCleared: Bool { self == .cancelled(byClear: true) }
        /// The handover's own `stop()` runs.
        var isStopping: Bool { self == .stopping }

        /// The handover begins and waits for the running turn.
        mutating func beginWaiting() { self = .waiting }
        /// The point of no return (also: nothing runs here, so the session is the move's at once).
        mutating func commit() { self = .committed }
        /// The user cancels: only a wait that is still on ends. A cancel never undoes a `/clear`, nor a commitment.
        mutating func cancel() {
            if self == .waiting { self = .cancelled(byClear: false) }
        }
        /// A `/clear` moved the run while the handover waited (or had been cancelled): it ends, and was not the user's.
        mutating func endByClear() {
            switch self {
            case .waiting, .cancelled: self = .cancelled(byClear: true)
            case .none, .committed, .stopping: break
            }
        }
        /// The handover's own `stop()` begins.
        mutating func beginStopping() { self = .stopping }
        /// The stop returned and the run is gone: the session stays the move's until `finishHandover()`.
        mutating func endStopping() {
            if self == .stopping { self = .committed }
        }
        /// The driver is its own again (`finishHandover()`, or a handover that ended without a move).
        mutating func release() { self = .none }
    }

    struct HeldPicks {
        /// What the child matched before the first mode pick of the hold: `choices.permissionMode`, the CLI's mode and
        /// `modeBeforeAsk`. The replay starts its transitions from there.
        var childMode: (choice: String?, wire: String?, before: String?)?
        var mode: String?
        var model: String?
        var effort: String?
        var effortCleared = false
        /// What the child matched before the first model pick of the hold: the chosen model and the chip's live name.
        var childModel: (choice: String?, live: String?)?
        /// What the child matched before the first effort pick of the hold.
        var childEffort: (choice: String?, cleared: Bool)?
    }
}
