import Foundation
import LoomCore

/// Remora's working memory as a `ConversationForgetting` (LoomCore/ConversationDeletion.swift): when a session is
/// permanently deleted, the journal lines and note items that cite it go. Registering it is the app's (L3).
public struct RemoraMemoryForgetter: ConversationForgetting {
    private let memory: RemoraMemory

    public init(memory: RemoraMemory) { self.memory = memory }

    public func forget(sessionID: UUID, providerIDs: [String]) async throws {
        try await memory.forget(session: sessionID)
    }
}
