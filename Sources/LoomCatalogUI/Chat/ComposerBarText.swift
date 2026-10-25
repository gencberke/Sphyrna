import Foundation
import LoomChat
import LoomCore

/// The words of the composer's bar (CHAT-SPEC → The bar): the mode as plain text, the model with its effort, the context.
/// Pure, so each rule is tested without a view.
enum ComposerBarText {
    static let defaultModel = "Default model"
    /// The mode chip before anything says which mode runs (an older session no process has reported on yet).
    static let unknownMode = "Mode"

    // MARK: Mode

    /// The mode the bar selects: the CLI's mode once the process reported one (`dontAsk` is Ask's word, D-63), else the
    /// session's chosen mode (a stopped session, or one that has not reported yet).
    static func selectedMode(permissionMode: String?, choices: ClaudeLaunchChoices) -> String? {
        if permissionMode == ClaudePermissionMode.ask.cliValue { return ClaudePermissionMode.ask.rawValue }
        return permissionMode ?? choices.permissionMode
    }

    /// The mode's title under Loom's name; "Mode" while nothing says. The CLI's `current_permission_mode` of an older
    /// session reads here as Loom names it ("default" is Ask before edits).
    static func modeTitle(permissionMode: String?, choices: ClaudeLaunchChoices) -> String {
        guard let raw = selectedMode(permissionMode: permissionMode, choices: choices) else { return unknownMode }
        return ClaudePermissionMode.title(forRaw: raw)
    }

    /// The one line under a mode's name in the mode list.
    static func modeDetail(_ mode: ClaudePermissionMode) -> String {
        switch mode {
        case .ask: "Researches and answers. Changes nothing."
        case .askBeforeEdits: "Asks before it edits or runs a command."
        case .acceptEdits: "Edits files without asking."
        case .auto: "Approves safe actions, asks about the rest."
        case .fullAccess: "Runs everything without asking."
        case .plan: "Plans first, then asks to build."
        }
    }

    // MARK: Model and effort

    /// The model the chip stands for when the CLI has named none: the one the usage index saw the session run on last
    /// (`observed`), used only while no model is chosen either. A stopped session has neither, and a resume passes this same
    /// model back (`ClaudeTranscriptModel`), so the chip and the next run agree.
    private static func runningModel(_ state: ChatComposerState, observed: String?) -> String? {
        if let resolved = state.resolvedModel, !resolved.isEmpty { return resolved }
        guard (state.choices.model ?? "").isEmpty, let observed, !observed.isEmpty else { return nil }
        return observed
    }

    /// The model chip's name: the model the CLI reported, else the one chosen, else the one the session last ran on, else
    /// "Default model" (the Release A review found two pickers reading "Claude's default").
    static func modelTitle(_ state: ChatComposerState, observed: String? = nil) -> String {
        if let resolved = runningModel(state, observed: observed) {
            // The full name of the release ("Opus 5.5"), not the CLI's short display name ("Opus").
            if let full = ModelCatalog.prettyClaudeID(resolved) { return full }
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
        return chosen.hasPrefix("claude-") ? prettyModel(chosen) : ModelCatalog.claudeTitle(of: chosen)
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

    /// The model option the bar's model chip stands for: the one chosen (`default` when none), else the one that runs.
    private static func currentOption(_ state: ChatComposerState, observed: String? = nil) -> ModelOption? {
        if let chosen = state.choices.model, let option = state.models.first(where: { $0.value == chosen }) { return option }
        if let resolved = runningModel(state, observed: observed), let option = state.models.first(where: { $0.value != "default" && $0.resolvedModel == resolved })
            ?? state.models.first(where: { $0.resolvedModel == resolved }) { return option }
        return state.models.first { $0.value == "default" }
    }

    /// The effort levels to offer: the model's own list when the CLI sent them (`supportedEffortLevels`, and none for a model
    /// without effort: Haiku 4.5 on 2.1.300), else the five the CLI takes. A CLI that sends no list for any model has not
    /// told us about this one either.
    static func effortLevels(_ state: ChatComposerState, observed: String? = nil) -> [String] {
        let standard = NewSessionModels.effortLevels
        guard state.models.contains(where: { !$0.supportedEffortLevels.isEmpty }) else { return standard }
        guard let option = currentOption(state, observed: observed) else { return standard }
        return option.supportedEffortLevels
    }

    /// One row of the model list.
    struct ModelRow: Equatable, Identifiable {
        var value: String
        var title: String
        var id: String { value }
    }

    /// The models to offer after Default: the aliases the CLI listed (an id is left out), else Loom's three.
    static func modelRows(_ state: ChatComposerState) -> [ModelRow] {
        let listed = state.models.filter { $0.value != "default" && !$0.value.hasPrefix("claude-") && !$0.value.contains("[") }
        guard !listed.isEmpty else { return ModelCatalog.claude.map { ModelRow(value: $0.id, title: $0.title) } }
        return listed.map { option in
            ModelRow(value: option.value,
                     title: option.resolvedModel.map(prettyModel) ?? option.displayName ?? ModelCatalog.claudeTitle(of: option.value))
        }
    }

    /// Where the slider's reset goes: the effort the session had when it was opened, as the model now chosen takes it; nil is
    /// the CLI's own (Default) when it had none, or the model offers none.
    static func resetTarget(_ state: ChatComposerState, effortBaseline: String?, observed: String? = nil) -> String? {
        effortBaseline.flatMap { ChatEffort.clamped($0, to: effortLevels(state, observed: observed)) }
    }

    /// What the model chip and its popovers show for a session.
    static func modelPicker(_ state: ChatComposerState, effortBaseline: String?, observedModel: String? = nil) -> ComposerModelPicker {
        let level = state.choices.effort ?? state.reportedEffort
        return ComposerModelPicker(
            modelTitle: modelTitle(state, observed: observedModel), effortTitle: effortTitle(state), rows: modelRows(state),
            chosenModel: state.choices.model, levels: effortLevels(state, observed: observedModel), chosenLevel: level,
            canResetEffort: level != nil && level != resetTarget(state, effortBaseline: effortBaseline, observed: observedModel))
    }

    /// Whether the Default row is the chosen one: no choice, or the choice named `default`.
    static func isDefaultModelChosen(_ choice: String?) -> Bool { choice == nil || choice == "default" || choice?.isEmpty == true }

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
