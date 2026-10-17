import Observation

/// The state of the new-session draft. An empty holder so the feature's slice adds its state and logic here,
/// not to `CatalogModel.swift` (same pattern as `tabs` and `deletions`).
@MainActor @Observable
public final class NewSessionState {
    public init() {}
}
