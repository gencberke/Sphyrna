import Foundation
import Observation

/// One model a harness offers in the composer's pickers.
public struct ModelCatalogEntry: Equatable, Sendable, Identifiable {
    /// The harness that offers the model.
    public var harness: HarnessID
    /// What is passed to the CLI to pick it (Claude's alias, Codex's model slug).
    public var id: String
    /// The name the product shows: Claude's full name ("Opus 5.5"), Codex's display name.
    public var title: String
    /// The line after the title in the popover; nil for none.
    public var note: String?
    /// One line the CLI gives about the model, when it gives one.
    public var description: String?
    /// The effort levels the model takes, in the CLI's order; empty when none is said (see `HarnessEffort`).
    public var efforts: [String]
    /// The level the CLI starts the model at, when it names one.
    public var defaultEffort: String?

    public init(harness: HarnessID, id: String, title: String, note: String? = nil, description: String? = nil,
                efforts: [String] = [], defaultEffort: String? = nil) {
        self.harness = harness
        self.id = id
        self.title = title
        self.note = note
        self.description = description
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
}

/// An effort level's token, checked by its shape only (`^[a-z][a-z0-9-]{0,31}$`), so a level a newer CLI adds still passes
/// and no list of levels is fixed here (FB6-8). A token of another shape is dropped where a CLI's answer is read.
public enum HarnessEffort {
    public static func isToken(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first, isLower(first) else { return false }
        return scalars.dropFirst().allSatisfy { isLower($0) || isDigit($0) || $0.value == 45 }
    }

    /// The tokens of `levels` with the right shape, in their order.
    public static func tokens(_ levels: [String]) -> [String] { levels.filter(isToken) }

    private static func isLower(_ scalar: Unicode.Scalar) -> Bool { (97...122).contains(scalar.value) }
    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }
}

/// The models of each harness, as the composer's popover, the draft's picker and the header's segment show them (D-99).
///
/// Claude's list is the aliases the CLI's `initialize` listed to the last probe, each titled by its full name ("Opus 5.5", from
/// the release it resolves to); until a probe has answered, the three fixed aliases with their short names. Codex's is what `model/list` answered to the last probe (hidden models dropped), and until a probe has answered, or
/// today's names. A harness that is switched off (`connections`) has no models to offer. The catalog is read on the main
/// actor by views; whoever runs the probe hands each Codex reading to `apply(_:)`.
@MainActor @Observable
public final class ModelCatalog {
    /// The one catalog the composer's views read.
    public static let shared = ModelCatalog()

    /// The last Codex model list a probe read; nil before one has answered (the fallback is shown then).
    public private(set) var probedCodex: [ModelCatalogEntry]?
    /// The last Claude model list a probe read (`initialize`'s aliases and their releases); nil before one has answered.
    public private(set) var probedClaude: [HarnessModel]?
    /// Which harnesses are offered; the app hands over the one the preferences keep.
    public var connections: HarnessConnections

    public init(connections: HarnessConnections = HarnessConnections()) {
        self.connections = connections
    }

    /// The models to offer for `provider`: nothing for a harness that is switched off or a provider without a harness.
    public func models(for provider: ManagedSession.Provider) -> [ModelCatalogEntry] {
        guard connections.isConnected(provider) else { return [] }
        return switch provider {
        case .claude: claudeModels
        case .codex: probedCodex ?? Self.codexFallback
        case .synthetic: []
        }
    }

    /// Takes the models of a probe's reading; a reading of Codex with no models (the ask for them failed) leaves the list as
    /// it was, and a reading of another harness changes nothing.
    public func apply(_ reading: HarnessReading) {
        guard !reading.models.isEmpty else { return }
        switch reading.provider {
        case .codex: probedCodex = reading.models.map { Self.entry(of: $0, harness: .codex) }
        case .claude: probedClaude = reading.models
        case .synthetic: break
        }
    }

    /// Claude's aliases to offer: the ones the probe's `initialize` listed (`default`, ids and `[1m]` variants left out), each
    /// with its full name and the note of a known alias; the fixed three before a probe answered.
    public var claudeModels: [ModelCatalogEntry] {
        let listed = (probedClaude ?? []).filter { $0.id != "default" && !$0.id.hasPrefix("claude-") && !$0.id.contains("[") }
        guard !listed.isEmpty else { return Self.claude }
        return listed.map { model in
            ModelCatalogEntry(harness: .claude, id: model.id,
                              title: Self.claudeFullName(resolvedModel: model.resolvedModel, displayName: model.displayName),
                              note: Self.claudeNote(forAlias: model.id), description: model.description,
                              efforts: model.efforts, defaultEffort: model.defaultEffort)
        }
    }

    /// The effort levels a Claude alias takes: the ones the last probe listed for that alias; the five the CLI takes when
    /// the probe said nothing about any model (a probe that lists levels for one model and none for another means that one
    /// takes none).
    public func claudeEfforts(for alias: String) -> [String] {
        let models = probedClaude ?? []
        guard models.contains(where: { !$0.efforts.isEmpty }) else { return Self.claudeEffortLevels }
        return models.first { $0.id == alias }?.efforts ?? Self.claudeEffortLevels
    }

    /// The five levels the CLI takes when a probe does not say.
    private nonisolated static let claudeEffortLevels = ClaudeLaunchChoices.effortLevels

    /// The name of a Claude alias as the product shows it: the full name of the release the probe said it resolves to, else
    /// the fixed short title, else the alias itself.
    public func claudeTitle(of alias: String) -> String {
        if let model = probedClaude?.first(where: { $0.id == alias }) {
            return Self.claudeFullName(resolvedModel: model.resolvedModel, displayName: model.displayName)
        }
        return Self.claudeTitle(of: alias)
    }

    /// A Claude model's full name from the release id: "Opus 5.5" from `claude-opus-5-5`, "Sonnet 3.5" from
    /// `claude-3-5-sonnet-20241022`, "Opus 5.5 1M" from `claude-opus-5-5[1m]`. An id not shaped like that falls back to the
    /// CLI's display name, and with none to the id itself.
    public nonisolated static func claudeFullName(resolvedModel: String?, displayName: String?) -> String {
        if let resolvedModel, let name = prettyClaudeID(resolvedModel) { return name }
        if let displayName, !displayName.isEmpty { return displayName }
        return resolvedModel ?? ""
    }

    /// The full name of a `claude-…` release id; nil for an id that is not one.
    public nonisolated static func prettyClaudeID(_ id: String) -> String? {
        var name = id.lowercased()
        var extended = false
        if name.hasSuffix("[1m]") {
            extended = true
            name = String(name.dropLast(4))
        }
        guard name.hasPrefix("claude-") else { return nil }
        name = String(name.dropFirst(7))
        let tokens = name.split(separator: "-").map(String.init)
        guard let family = tokens.first(where: { $0.contains { $0.isLetter } }), !family.isEmpty,
              family.allSatisfy(\.isLetter) else { return nil }
        let version = tokens.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        guard !version.isEmpty else { return nil }
        let title = family.prefix(1).uppercased() + family.dropFirst() + " " + version.joined(separator: ".")
        return extended ? title + " 1M" : title
    }

    // MARK: The fixed parts

    /// Claude Code's models: the aliases the CLI takes, and what each is for.
    public nonisolated static let claude: [ModelCatalogEntry] = [
        ModelCatalogEntry(harness: .claude, id: "opus", title: "Opus", note: "Long agentic coding"),
        ModelCatalogEntry(harness: .claude, id: "sonnet", title: "Sonnet", note: "Fast, everyday work"),
        ModelCatalogEntry(harness: .claude, id: "haiku", title: "Haiku", note: "Quick answers, no effort"),
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
        ModelCatalogEntry(harness: .codex, id: "GPT-6 Astra", title: "GPT-6 Astra", note: "Most capable"),
        ModelCatalogEntry(harness: .codex, id: "GPT-6.1 Sol", title: "GPT-6.1 Sol", note: "Near Astra, for less"),
        ModelCatalogEntry(harness: .codex, id: "GPT-6 Luna", title: "GPT-6 Luna", note: "Focused, high-volume work"),
    ]

    private nonisolated static func entry(of model: HarnessModel, harness: HarnessID) -> ModelCatalogEntry {
        ModelCatalogEntry(harness: harness, id: model.id, title: model.displayName, note: model.isDefault ? "Default" : nil,
                          description: model.description, efforts: model.efforts, defaultEffort: model.defaultEffort)
    }
}
