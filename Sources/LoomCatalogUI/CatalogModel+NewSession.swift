import Foundation
import Observation

/// The state of the new-session draft. An empty holder so the feature's slice adds its state and logic here,
/// not to `CatalogModel.swift` (same pattern as `tabs` and `deletions`).
@MainActor @Observable
public final class NewSessionState {
    public init() {}
}

extension CatalogModel {
    /// Shows a project's new-session draft (`nil`: a draft with no project). The draft's own state and its
    /// first send belong to the new-session slice.
    public func showDraft(projectID: UUID?) { navigate(to: .draft(projectID: projectID)) }

    /// "New Session" (⌘N, the menu bar item): today's flow, a Claude session started at once in the context
    /// project. The new-session slice replaces the body with the draft.
    public func beginNewSession(projectID: UUID?) { startConversation(.claude, projectID: projectID) }
}
