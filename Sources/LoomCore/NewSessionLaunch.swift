import Foundation

/// The permission modes of a Claude session, under Loom's own names (D-63). The raw value is what Loom stores in a
/// session's launch choices; for every mode but Ask it is also the CLI's word, and `cliValue` is what the CLI is told.
/// The menus offer `menuModes`: Ask, Ask before edits, Accept edits, Auto and Full access. `plan` is not offered any more,
/// but a session can be in plan mode anyway (its card, a preset), so it keeps its name. Loom lists Full access like the
/// others but never picks it by itself: only a choice the user makes reaches a launch (`NewSessionDefaults`).
public enum ClaudePermissionMode: String, CaseIterable, Codable, Sendable {
    /// Loom's own mode: Claude researches and answers, explains more, and changes nothing. The CLI has no such mode:
    /// it is `dontAsk` with deny rules for the edit tools and an output style (`cliValue`, `ChatAskMode`).
    case ask
    /// The CLI's `default`.
    case askBeforeEdits = "default"
    case acceptEdits
    case plan
    case auto
    case fullAccess = "bypassPermissions"

    /// The modes the menus offer, in order.
    public static let menuModes: [ClaudePermissionMode] = [.ask, .askBeforeEdits, .acceptEdits, .auto, .fullAccess]

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .askBeforeEdits: "Ask before edits"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }

    /// The word the CLI takes for `--permission-mode` and `set_permission_mode`. Ask runs on the CLI's `dontAsk` mode, which
    /// refuses whatever would ask; the deny rules and the output style that complete Ask are control requests of the Chat
    /// driver (`ChatAskMode`), never launch arguments, because a rule given at launch cannot be taken back (spike S9).
    public var cliValue: String {
        switch self {
        case .ask: "dontAsk"
        default: rawValue
        }
    }

    /// The word a launch passes. Ask exists in the Chat face only (D-63, review fix B1): the terminal's TUI has no rules and no
    /// output style behind `dontAsk`, so a terminal start or resume of an Ask session runs in Ask before edits.
    public func launchValue(chat: Bool) -> String {
        self == .ask && !chat ? ClaudePermissionMode.askBeforeEdits.rawValue : cliValue
    }

    /// A mode as Loom names it, from a stored choice or what the CLI reports (`current_permission_mode`, `system/status`).
    /// `dontAsk` is Ask's word to the CLI (D-63) and reads "Ask"; a word that is not a mode of ours (a newer one) reads as the
    /// CLI wrote it, never as another mode.
    public static func title(forRaw raw: String) -> String {
        if let mode = ClaudePermissionMode(rawValue: raw) { return mode.title }
        return raw == ask.cliValue ? ask.title : raw
    }

    /// Whether `raw` is one of the modes the menus offer.
    public static func isOffered(_ raw: String) -> Bool {
        ClaudePermissionMode(rawValue: raw).map(menuModes.contains) ?? false
    }
}

/// What a Claude launch is told about the session's mode, model and effort, as the CLI's own words. All
/// are optional: nil leaves the choice to Claude (its settings, then its default). S2: the CLI restores
/// none of them on a resume, in either face, so Loom passes them on every spawn it can, the terminal's
/// `--resume` included.
///
/// The source of truth for a session's choices is the catalog's `sessions` row (`SessionCatalog.launchChoices`,
/// V16): the runtime writes it when it starts a session and whenever a live change of mode, model or effort
/// succeeds, a moved run (`/clear`) carries it to its new card, and every spawn in either face reads it. The
/// new-session file's older `launched` list is copied into it once (`SessionCatalog.importLaunchChoices`). A
/// session with nothing stored (older ones, sessions an agent opened) passes nothing for mode and model, and the
/// effort its transcript last recorded (`ClaudeTranscriptEffort`), as before.
public struct ClaudeLaunchChoices: Equatable, Sendable, Codable {
    public var permissionMode: String?
    public var model: String?
    /// `low`, `medium`, `high`, `xhigh` or `max`. Older records have none (decoded as nil).
    public var effort: String?

    public init(permissionMode: String? = nil, model: String? = nil, effort: String? = nil) {
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
    }

    public var isEmpty: Bool { permissionMode == nil && model == nil && effort == nil }

    /// Each choice of `newer` that is set replaces this one's.
    public func merging(_ newer: ClaudeLaunchChoices) -> ClaudeLaunchChoices {
        ClaudeLaunchChoices(permissionMode: newer.permissionMode ?? permissionMode, model: newer.model ?? model,
                            effort: newer.effort ?? effort)
    }

    /// What a project remembers for its next session after these choices were recorded on top of what it remembered:
    /// each choice that is set replaces the old one, except Full access, which is never remembered (Loom never picks it by
    /// itself), so the project keeps the mode it had.
    public func remembered(over previous: ClaudeLaunchChoices?) -> ClaudeLaunchChoices {
        var last = previous ?? ClaudeLaunchChoices()
        if let mode = permissionMode, mode != ClaudePermissionMode.fullAccess.rawValue { last.permissionMode = mode }
        if let model { last.model = model }
        if let effort { last.effort = effort }
        return last
    }

    /// A value is passed to the CLI only when it cannot be taken for an option or hide a second argument:
    /// letters, digits and `. _ - : [ ]`, not starting with a dash, at most 80 characters.
    public static func isSafeToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))))
                || ".-_:[]".unicodeScalars.contains($0)
        }
    }
}

/// Where the session's files are, chosen in the draft's strip: Claude starts in the project's folder as it
/// is, on a new branch Loom creates there, or in a new worktree of its own.
public enum SessionWorkspace: Equatable, Sendable {
    case projectFolder
    case newBranch(String)
    case newWorktree(String)
}

/// The first send of a draft (V07): the message becomes Claude's first prompt through the normal start
/// path. `title` is only set for a ticket (it names the session like an agent's request does, D-40); without
/// it Claude names the session itself. Nothing here starts anything.
public struct NewSessionLaunch: Equatable, Sendable {
    /// The most a first message may hold (UTF-8 bytes): it is one argument of the process, and the system's
    /// limit for all arguments and the environment together is 1 MiB.
    public static let maxFirstMessageBytes = 128 * 1024

    public let firstMessage: String
    public let title: String?
    public let ticketKey: String?
    public let choices: ClaudeLaunchChoices
    public let workspace: SessionWorkspace

    public init(firstMessage: String, title: String? = nil, ticketKey: String? = nil,
                choices: ClaudeLaunchChoices = ClaudeLaunchChoices(), workspace: SessionWorkspace = .projectFolder) {
        self.firstMessage = firstMessage
        self.title = title
        self.ticketKey = ticketKey
        self.choices = choices
        self.workspace = workspace
    }
}
