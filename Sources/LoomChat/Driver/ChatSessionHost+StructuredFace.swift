import Foundation
import LoomCore

/// The host as Claude's structured face for `SessionService`: the lifecycle verbs only. The typed driver API the UI calls
/// (send, mode, model, rewind, cards) stays on `ChatSessionDriver`.
extension ChatSessionHost: StructuredFaceHost {
    public func beginNewSession(projectID: UUID?, sessionID: UUID, draft: NewSessionLaunch?,
                                onReady: (@Sendable () async -> Void)?) async throws {
        try await startNewSession(projectID: projectID, sessionID: sessionID, draft: draft, onReady: onReady)
    }

    public func beginOpenedSession(requestID: UUID, sessionID: UUID, onReady: (@Sendable () async -> Void)?) async throws {
        try await startOpenedSession(requestID: requestID, sessionID: sessionID, onReady: onReady)
    }

    public func resumeSession(sessionID: UUID) async throws {
        try await driver(for: sessionID).resume()
    }

    public func errorKind(of error: any Error) -> StructuredFaceErrorKind {
        guard let error = error as? ChatDriverError else { return .other }
        return error == .stopping ? .stopping : .failure
    }

    // MARK: What a session's run is doing

    public func isLive(sessionID: UUID) async -> Bool {
        guard let driver = existingDriver(for: sessionID) else { return false }
        return await driver.currentPhase.isLive
    }

    public func isLiveAndSettled(sessionID: UUID) async -> Bool {
        guard let driver = existingDriver(for: sessionID) else { return false }
        return await driver.isLiveAndSettled
    }

    public func isHandingOver(sessionID: UUID) async -> Bool {
        // The driver a move holds first: a `/clear` in the move re-keys the driver, and the session id still names it.
        guard let driver = movingDrivers[sessionID] ?? existingDriver(for: sessionID) else { return false }
        return await driver.isHandingOver
    }

    /// The Close stop: the process stops in the driver's order (interrupt, `result`, stdin, exit). One that was not running is
    /// not an error. Whatever ended the run, the session's "allow edits" permission belonged to the process that is gone: it
    /// reads off at once (the driver's next start turns it off again).
    public func closeSession(sessionID: UUID) async throws {
        guard let driver = existingDriver(for: sessionID) else { return }
        var failure: (any Error)?
        do {
            _ = try await driver.stop()
        } catch SessionRuntimeError.notRunning {
        } catch {
            failure = error
        }
        if await !driver.currentPhase.isLive { await driver.setAllowsEdits(false) }
        if let failure { throw failure }
    }

    // MARK: The move to the terminal (V19)

    public func handOverToTerminal(sessionID: UUID, pointOfNoReturn: @escaping @Sendable () async -> Void) async throws -> UUID {
        // The driver object, not its card: a `/clear` that moves the run re-keys it, and the move must still reach it.
        let driver = driver(for: sessionID)
        movingDrivers[sessionID] = driver
        try await driver.handOverToTerminal(pointOfNoReturn: pointOfNoReturn)
        // The card the run ended on is the driver's now: a `/clear` that moved it after the point (while the stop ran) made
        // a new card, and that card is the session's conversation, not the one the move began on.
        return await driver.sessionID
    }

    public func cancelHandover(sessionID: UUID) {
        // The Chat face's wait is the driver's: it does not look at task cancellation. (After its point of no return it
        // ignores this.)
        guard let driver = existingDriver(for: sessionID) else { return }
        Task { await driver.cancelHandover() }
    }

    public func handoverFailed(sessionID: UUID) async {
        await movingDrivers[sessionID]?.handoverFailed()
    }

    public func noteContinuedInTerminal(sessionID: UUID) async {
        await movingDrivers[sessionID]?.noteFace(.continuedInTerminal)
    }

    public func finishHandover(sessionID: UUID) async {
        let driver = movingDrivers.removeValue(forKey: sessionID)
        await driver?.finishHandover()
    }

    public func handoverRefusal(of error: any Error) -> HandoverRefusal? { Self.handoverRefusal(of: error) }

    /// The words of a refusal the Chat driver or the gate made, nil for any other error.
    public static func handoverRefusal(of error: any Error) -> HandoverRefusal? {
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
