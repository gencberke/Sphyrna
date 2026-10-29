import Foundation

/// App-only selected-child metadata; task content is read separately.
public struct ManagedTaskChildSnapshot: Sendable {
    public let task: SessionTaskProjection
    public let presentation: ManagedTaskPresentation?
}

extension SessionRuntime {
    /// Native identity/settings remain nil until actually reported and
    /// validated by the provider.
    public func managedTaskPresentation(taskID: UUID) -> ManagedTaskPresentation? {
        managedTaskPresentations[taskID]
    }

    /// Uses the indexed child relationship, without relying on sidebar state.
    public func managedTaskForChild(sessionID: UUID) async throws -> ManagedTaskChildSnapshot? {
        guard let coordinator = taskCoordinator else { throw SessionTaskError.storage }
        guard let task = try await coordinator.projectionForChild(sessionID), task.childSessionID == sessionID else { return nil }
        let value = managedTaskPresentations[task.id]
        let presentation = value?.run.sessionID == sessionID ? value : nil
        return ManagedTaskChildSnapshot(task: task, presentation: presentation)
    }
}
