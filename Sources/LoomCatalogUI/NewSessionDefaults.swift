import Foundation
import LoomCore

/// What the user did with a chip in the draft: nothing (the chip follows the defaults), chose the model's or the effort's own
/// default on purpose, or chose a value. The mode has no such pick any more (D-63): an older draft that chose "Claude's
/// default" for it reads as nothing chosen.
enum DraftPick: Equatable, Sendable, Codable {
    case inherit
    case claudeDefault
    case value(String)

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "claudeDefault": self = .claudeDefault
        case "value": self = .value(try container.decode(String.self, forKey: .value))
        default: self = .inherit
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit: try container.encode("inherit", forKey: .kind)
        case .claudeDefault: try container.encode("claudeDefault", forKey: .kind)
        case .value(let value):
            try container.encode("value", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Where a chip's value came from, in the order the spec fixes (CHAT-SPEC → Draft session).
enum DefaultSource: Equatable, Sendable {
    case pick
    case lastUsed
    case settings
    /// Nothing says anything: Claude decides, from its own settings (the model and the effort).
    case cliDefault
    /// Nothing says anything about the mode: Loom starts in Ask before edits, passed to the CLI explicitly (D-63).
    case loomDefault
}

/// Loom's own start defaults. Nil: nothing chosen. The mode is Settings → General → "Mode of new sessions" (D-69): nil is
/// "Last used in the project", a value is one fixed mode, Full access included because the user picked it there. The
/// model has no screen yet; the store carries it so that one can write it later.
struct NewSessionSettings: Equatable, Sendable, Codable {
    var permissionMode: String?
    var model: String?

    init(permissionMode: String? = nil, model: String? = nil) {
        self.permissionMode = permissionMode
        self.model = model
    }
}

/// What the draft offers besides Claude's model aliases (`ModelCatalog.claude`).
enum NewSessionModels {
    /// The effort levels the CLI takes (`--effort`, `claude --help` on 2.1.300). Before a session runs no model's own list
    /// is known, and the current aliases (default, opus, sonnet, haiku) all list the five, so the draft offers them.
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
}

/// The value of one chip and where it came from.
struct ResolvedChoice: Equatable, Sendable {
    let value: String?
    let source: DefaultSource
}

struct ResolvedStart: Equatable, Sendable {
    let mode: ResolvedChoice
    let model: ResolvedChoice
    let effort: ResolvedChoice

    var choices: ClaudeLaunchChoices {
        ClaudeLaunchChoices(permissionMode: mode.value, model: model.value, effort: effort.value)
    }

    /// The mode as the bar names it: Loom's name, always something (the mode always has a value).
    var modeTitle: String {
        mode.value.map(ClaudePermissionMode.title(forRaw:)) ?? ClaudePermissionMode.askBeforeEdits.title
    }

    /// The model as the bar names it: the chosen one by its full name ("Opus 5.5", once the probe said which release the alias
    /// means), else "Default model" (the CLI decides which). The names come from the model's catalogue (`CatalogModel.modelCatalog`).
    @MainActor func modelTitle(in catalog: ModelCatalog) -> String {
        model.value.map(catalog.claudeTitle(of:)) ?? NewSessionDefaults.defaultModelTitle
    }

    /// The effort as the bar names it, in the lighter word after the model; nil when none is chosen.
    var effortTitle: String? { effort.value.map(ComposerBarText.effortLabel) }
}

/// The order of the defaults of a new session (CHAT-SPEC → Draft session, D-59, D-63, D-69). The mode: what the user picks
/// in the draft, then the fixed mode of Settings (when the user set one), then what was last used in that project, then
/// Ask before edits (the CLI's `default`), passed explicitly, so Loom never depends on the CLI's own setting. The model
/// and the effort: the pick, then what was last used, then Loom's settings; with none the CLI decides. One rule for
/// every entry point, so the result no longer depends on where the draft was opened (T3 #6508). Loom never picks Full
/// access by itself: it carries only a pick made in this draft or the mode the user fixed in Settings, and a
/// remembered one is skipped (the project keeps its earlier mode). A mode the menus do not offer (plan) is skipped.
enum NewSessionDefaults {
    static let defaultModelTitle = "Default model"
    static let fallbackMode = ClaudePermissionMode.askBeforeEdits.rawValue

    static func resolve(modePick: DraftPick, modelPick: DraftPick, effortPick: DraftPick = .inherit,
                        lastUsed: ClaudeLaunchChoices?, settings: NewSessionSettings, askAllowed: Bool = true) -> ResolvedStart {
        // Ask is a Chat mode: where the session starts in the terminal, Ask (picked, remembered or configured) becomes Ask
        // before edits.
        func startable(_ mode: String?) -> String? {
            !askAllowed && mode == ClaudePermissionMode.ask.rawValue ? ClaudePermissionMode.askBeforeEdits.rawValue : mode
        }
        var pick = modePick == .claudeDefault ? .inherit : modePick
        if case let .value(value) = pick { pick = .value(startable(value) ?? value) }
        let mode = resolve(pick: pick, levels: [
            (startable(settings.permissionMode), .settings, { ClaudePermissionMode.isOffered($0) }),
            (startable(lastUsed?.permissionMode), .lastUsed,
             { $0 != ClaudePermissionMode.fullAccess.rawValue && ClaudePermissionMode.isOffered($0) }),
        ])
        return ResolvedStart(
            mode: mode.value == nil ? ResolvedChoice(value: fallbackMode, source: .loomDefault) : mode,
            model: resolve(pick: modelPick, remembered: lastUsed?.model, configured: settings.model, allowed: { _ in true }),
            effort: resolve(pick: effortPick, remembered: lastUsed?.effort, configured: nil,
                            allowed: { NewSessionModels.effortLevels.contains($0) }))
    }

    private static func resolve(pick: DraftPick, remembered: String?, configured: String?,
                                allowed: @escaping (String) -> Bool) -> ResolvedChoice {
        resolve(pick: pick, levels: [(remembered, .lastUsed, allowed), (configured, .settings, allowed)])
    }

    /// The pick, else the first level (in the order given) whose value is safe and allowed.
    private static func resolve(pick: DraftPick, levels: [(value: String?, source: DefaultSource, allowed: (String) -> Bool)])
        -> ResolvedChoice {
        switch pick {
        case .value(let value) where ClaudeLaunchChoices.isSafeToken(value): return ResolvedChoice(value: value, source: .pick)
        case .claudeDefault: return ResolvedChoice(value: nil, source: .pick)
        case .value, .inherit: break
        }
        for level in levels {
            if let value = level.value, ClaudeLaunchChoices.isSafeToken(value), level.allowed(value) {
                return ResolvedChoice(value: value, source: level.source)
            }
        }
        return ResolvedChoice(value: nil, source: .cliDefault)
    }
}
