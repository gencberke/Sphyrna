import Foundation
import LoomCore

/// What the user did with a chip in the draft: nothing (the chip follows the defaults), chose Claude's own
/// default on purpose, or chose a value.
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
    /// Nothing says anything: Claude decides, from its own settings.
    case cliDefault
}

/// Loom's own start defaults (the third level). Nil: nothing chosen. Settings has no screen for them yet;
/// the store carries them so that one can write them later.
struct NewSessionSettings: Equatable, Sendable, Codable {
    var permissionMode: String?
    var model: String?

    init(permissionMode: String? = nil, model: String? = nil) {
        self.permissionMode = permissionMode
        self.model = model
    }
}

/// The model aliases the draft offers: the CLI takes the alias and decides which release it means.
enum NewSessionModels {
    static let all: [(alias: String, title: String)] = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]

    static func title(of alias: String) -> String {
        all.first { $0.alias == alias }?.title ?? alias
    }
}

/// The value of one chip and where it came from.
struct ResolvedChoice: Equatable, Sendable {
    let value: String?
    let source: DefaultSource
}

struct ResolvedStart: Equatable, Sendable {
    let mode: ResolvedChoice
    let model: ResolvedChoice

    var choices: ClaudeLaunchChoices { ClaudeLaunchChoices(permissionMode: mode.value, model: model.value) }

    /// The mode as the bar names it: always something, so the chip is never blank. Without a choice it
    /// says so; Claude's own settings decide, and Loom cannot know them before the session runs.
    var modeTitle: String {
        mode.value.flatMap { ClaudePermissionMode(rawValue: $0)?.title ?? $0 } ?? NewSessionDefaults.claudeDefaultTitle
    }

    var modelTitle: String {
        model.value.map(NewSessionModels.title(of:)) ?? NewSessionDefaults.claudeDefaultTitle
    }
}

/// The order of the defaults of a new session (CHAT-SPEC → Draft session, D-59): what the user picks in the
/// draft, then what was last used in that project, then Loom's settings, then the CLI's own default (nothing
/// is passed). One rule for every entry point, so the result no longer depends on where the draft was opened
/// (T3 #6508). Loom never picks Full access: only a pick made in this draft can carry it, a remembered or
/// configured one is skipped and the next level answers.
enum NewSessionDefaults {
    static let claudeDefaultTitle = "Claude's default"

    static func resolve(modePick: DraftPick, modelPick: DraftPick, lastUsed: ClaudeLaunchChoices?,
                        settings: NewSessionSettings) -> ResolvedStart {
        ResolvedStart(
            mode: resolve(pick: modePick, remembered: lastUsed?.permissionMode, configured: settings.permissionMode,
                          allowed: { $0 != ClaudePermissionMode.fullAccess.rawValue }),
            model: resolve(pick: modelPick, remembered: lastUsed?.model, configured: settings.model, allowed: { _ in true }))
    }

    private static func resolve(pick: DraftPick, remembered: String?, configured: String?,
                                allowed: (String) -> Bool) -> ResolvedChoice {
        switch pick {
        case .value(let value) where ClaudeLaunchChoices.isSafeToken(value): return ResolvedChoice(value: value, source: .pick)
        case .claudeDefault: return ResolvedChoice(value: nil, source: .pick)
        case .value, .inherit: break
        }
        if let remembered, ClaudeLaunchChoices.isSafeToken(remembered), allowed(remembered) {
            return ResolvedChoice(value: remembered, source: .lastUsed)
        }
        if let configured, ClaudeLaunchChoices.isSafeToken(configured), allowed(configured) {
            return ResolvedChoice(value: configured, source: .settings)
        }
        return ResolvedChoice(value: nil, source: .cliDefault)
    }
}
