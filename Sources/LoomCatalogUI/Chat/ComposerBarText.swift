import Foundation
import LoomChat
import LoomCore

/// The words of the composer's bar (CHAT-SPEC → The bar): the mode as plain text, the model with its effort, the context.
/// Pure, so each rule is tested without a view.
enum ComposerBarText {
    static let defaultModel = "Default model"
    static let claudeDefaultMode = "Claude's default"

    // MARK: Mode

    /// The mode the session runs in (the CLI's word, else the one Loom passes), as its title.
    static func modeTitle(permissionMode: String?, choices: ClaudeLaunchChoices) -> String {
        guard let raw = permissionMode ?? choices.permissionMode else { return claudeDefaultMode }
        return ClaudePermissionMode(rawValue: raw)?.title ?? raw
    }

    static func selectedMode(permissionMode: String?, choices: ClaudeLaunchChoices) -> String? {
        permissionMode ?? choices.permissionMode
    }

    // MARK: Model and effort

    /// The model chip's name: the model the CLI reported, else the one chosen, else "Default model" (the Release A review
    /// found two pickers reading "Claude's default").
    static func modelTitle(_ state: ChatComposerState) -> String {
        if let resolved = state.resolvedModel, !resolved.isEmpty {
            if let option = state.models.first(where: { $0.resolvedModel == resolved }), let name = option.displayName,
               !name.isEmpty, !option.value.isEmpty, option.value != "default" {
                return name
            }
            return prettyModel(resolved)
        }
        guard let chosen = state.choices.model, !chosen.isEmpty else { return defaultModel }
        if chosen == "default" { return defaultModel }
        if let option = state.models.first(where: { $0.value == chosen }) {
            if let resolved = option.resolvedModel, !resolved.isEmpty { return prettyModel(resolved) }
            if let name = option.displayName, !name.isEmpty { return name }
        }
        return chosen.hasPrefix("claude-") ? prettyModel(chosen) : NewSessionModels.title(of: chosen)
    }

    /// "Opus 5.5" from `claude-opus-5-5`, "Sonnet 3.5" from `claude-3-5-sonnet-20241022`, "Opus 5.5 1M" from
    /// `claude-opus-5-5[1m]`; a name that is not shaped like that stays as it is.
    static func prettyModel(_ id: String) -> String {
        var name = id.lowercased()
        var extended = false
        if name.hasSuffix("[1m]") {
            extended = true
            name = String(name.dropLast(4))
        }
        if name.hasPrefix("claude-") { name = String(name.dropFirst(7)) }
        let tokens = name.split(separator: "-").map(String.init)
        guard let family = tokens.first(where: { $0.contains { $0.isLetter } }), !family.isEmpty else { return id }
        let version = tokens.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        var title = family.prefix(1).uppercased() + family.dropFirst()
        if !version.isEmpty { title += " " + version.joined(separator: ".") }
        return extended ? title + " 1M" : title
    }

    /// The effort as the chip shows it, in a lighter tone: nil when none is known.
    static func effortTitle(_ state: ChatComposerState) -> String? {
        guard let level = state.choices.effort ?? state.reportedEffort else { return nil }
        return effortLabel(level)
    }

    static func effortLabel(_ level: String) -> String {
        switch level {
        case "xhigh": "Extra high"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    /// The effort levels to offer: the chosen model's own list, else the standard five.
    static func effortLevels(_ state: ChatComposerState) -> [String] {
        let chosen = state.choices.model
        let option = state.models.first { $0.value == chosen }
            ?? state.models.first { $0.resolvedModel != nil && $0.resolvedModel == state.resolvedModel }
        let own = option?.supportedEffortLevels ?? []
        return own.isEmpty ? ["low", "medium", "high", "xhigh", "max"] : own
    }

    /// The models to offer: the aliases the CLI listed (an id is left out), else Loom's three.
    static func modelChoices(_ state: ChatComposerState) -> [(value: String, title: String)] {
        let listed = state.models.filter { !$0.value.hasPrefix("claude-") && !$0.value.contains("[") }
        guard !listed.isEmpty else { return NewSessionModels.all.map { ($0.alias, $0.title) } }
        return listed.map { option in
            let title: String
            if option.value == "default" { title = defaultModel } else {
                title = option.resolvedModel.map(prettyModel) ?? option.displayName ?? NewSessionModels.title(of: option.value)
            }
            return (option.value, title)
        }
    }

    // MARK: Context

    /// What the ring and its popover show: the driver's figure when it has one, else the usage index's.
    static func contextUsage(_ state: ChatComposerState, fallback: ContextUsage?) -> ContextUsage? {
        if let tokens = state.contextTokens {
            return ContextUsage(tokens: Int64(tokens), window: state.contextWindow.map(Int64.init),
                                model: state.contextModel ?? state.choices.model ?? "")
        }
        return fallback
    }

    /// "Context · 120K of 1M (12%)", or "Context · 84K" while the window is not known.
    static func contextLine(_ usage: ContextUsage) -> String {
        let used = UsageFormat.tokens(usage.tokens)
        guard let window = usage.window, let percent = usage.percent else { return "Context \u{00B7} \(used)" }
        return "Context \u{00B7} \(used) of \(UsageFormat.tokens(window)) (\(UsageFormat.percent(percent)))"
    }
}
