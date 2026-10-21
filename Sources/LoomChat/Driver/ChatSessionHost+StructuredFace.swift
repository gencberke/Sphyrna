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
}
