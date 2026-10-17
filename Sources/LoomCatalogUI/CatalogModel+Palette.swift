import Observation

/// The state of the command palette. An empty holder so the feature's slice adds its state and logic here,
/// not to `CatalogModel.swift` (same pattern as `tabs` and `deletions`).
@MainActor @Observable
public final class PaletteState {
    public init() {}
}
