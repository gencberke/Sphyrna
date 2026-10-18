import Foundation

/// The permission modes Loom offers when it starts a Claude session (the `--permission-mode` values).
/// "Ask before edits" is Claude's `default`. Loom lists Full access like the others (no warning colour,
/// DESIGN and CHAT-SPEC → The bar) but never picks it by itself: only a choice the user makes in the draft
/// reaches the launch (`NewSessionDefaults`).
public enum ClaudePermissionMode: String, CaseIterable, Codable, Sendable {
    case askBeforeEdits = "default"
    case acceptEdits
    case plan
    case auto
    case fullAccess = "bypassPermissions"

    public var title: String {
        switch self {
        case .askBeforeEdits: "Ask before edits"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan mode"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
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
