import Observation

/// The state of the project page. An empty holder so the feature's slice adds its state and logic here,
/// not to `CatalogModel.swift` (same pattern as `tabs` and `deletions`).
@MainActor @Observable
public final class ProjectPageState {
    public init() {}
}
