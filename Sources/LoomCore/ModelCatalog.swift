import Foundation
import Observation

/// One model a harness offers in the composer's pickers.
public struct ModelCatalogEntry: Equatable, Sendable, Identifiable {
    /// What is passed to the CLI to pick it (Claude's alias, Codex's model slug).
    public var id: String
    public var title: String
    /// The line after the title in the popover; nil for none.
    public var note: String?
    public var isDefault: Bool
    /// The effort levels it takes (empty: not known, or none).
    public var efforts: [String]

    public init(id: String, title: String, note: String? = nil, isDefault: Bool = false, efforts: [String] = []) {
        self.id = id
        self.title = title
        self.note = note
        self.isDefault = isDefault
        self.efforts = efforts
    }
}

/// The models of each harness, as the composer's popover, the draft's picker and the header's segment show them (D-99).
///
/// Claude's list is fixed: the three aliases the CLI takes (it decides which release each means), with the words under them.
/// Codex's is what `model/list` answered to the last probe (hidden models dropped), and until a probe has answered, or
/// today's names. A harness that is switched off (`connections`) has no models to offer. The catalog is read on the main
/// actor by views; whoever runs the probe hands each Codex reading to `apply(_:)`.
@MainActor @Observable
public final class ModelCatalog {
    /// The one catalog the composer's views read.
    public static let shared = ModelCatalog()

    /// The last Codex model list a probe read; nil before one has answered (the fallback is shown then).
    public private(set) var probedCodex: [ModelCatalogEntry]?
    /// Which harnesses are offered; the app hands over the one the preferences keep.
    public var connections: HarnessConnections

    public init(connections: HarnessConnections = HarnessConnections()) {
        self.connections = connections
    }

    /// The models to offer for `provider`: nothing for a harness that is switched off or a provider without a harness.
    public func models(for provider: ManagedSession.Provider) -> [ModelCatalogEntry] {
        guard connections.isConnected(provider) else { return [] }
        return switch provider {
        case .claude: Self.claude
        case .codex: probedCodex ?? Self.codexFallback
        case .synthetic: []
        }
    }

    /// Takes the models of a probe's reading; a reading of Codex with no models (the ask for them failed) leaves the list as
    /// it was, and a reading of another harness changes nothing.
    public func apply(_ reading: HarnessReading) {
        guard reading.provider == .codex, !reading.models.isEmpty else { return }
        probedCodex = reading.models.map(Self.entry(of:))
    }

    /// Back to today's names: the harness's account changed.
    public func forgetProbed(_ provider: ManagedSession.Provider) {
        if provider == .codex { probedCodex = nil }
    }

    // MARK: The fixed parts

    /// Claude Code's models: the aliases the CLI takes, and what each is for.
    public nonisolated static let claude: [ModelCatalogEntry] = [
        ModelCatalogEntry(id: "opus", title: "Opus", note: "Long agentic coding"),
        ModelCatalogEntry(id: "sonnet", title: "Sonnet", note: "Fast, everyday work"),
        ModelCatalogEntry(id: "haiku", title: "Haiku", note: "Quick answers, no effort"),
    ]

    /// The title of a Claude alias; the alias itself when it is not one of the three.
    public nonisolated static func claudeTitle(of alias: String) -> String {
        claude.first { $0.id == alias }?.title ?? alias
    }

    /// The words under a Claude model in the popover: the alias's own, and "Recommended" for Default (`default` is the
    /// CLI's choice, not an alias of the list). Read in lower case; a model not listed has none.
    public nonisolated static func claudeNote(forAlias alias: String) -> String? {
        let key = alias.lowercased()
        return key == "default" ? "Recommended" : claude.first { $0.id == key }?.note
    }

    /// What Codex's group shows before a probe has answered.
    public nonisolated static let codexFallback: [ModelCatalogEntry] = [
        ModelCatalogEntry(id: "GPT-6 Astra", title: "GPT-6 Astra", note: "Most capable"),
        ModelCatalogEntry(id: "GPT-6.1 Sol", title: "GPT-6.1 Sol", note: "Near Astra, for less"),
        ModelCatalogEntry(id: "GPT-6 Luna", title: "GPT-6 Luna", note: "Focused, high-volume work"),
    ]

    private nonisolated static func entry(of model: HarnessModel) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: model.id, title: model.displayName, note: model.isDefault ? "Default" : nil, isDefault: model.isDefault,
            efforts: model.efforts)
    }
}
