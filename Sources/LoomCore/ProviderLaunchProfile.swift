import Foundation

public struct ProviderCapabilities: Codable, Sendable {
    public let version: String
    public let supportsNoDaemon: Bool
    public let supportsRemote: Bool
    public let supportsListen: Bool
    public let supportsDisableDaemonAutoStart: Bool
    public let supportsSessionID: Bool
    public let supportsSettings: Bool
    public let supportsEffort: Bool
    public let supportsName: Bool
    public let supportsPluginDirectory: Bool
    /// Whether `--help` lists `--permission-mode` and `--model`. Neither is a reason to leave the option
    /// out (`claudeAcceptsPermissionMode`, `claudeAcceptsModel`): both are decided by version too.
    public let listsPermissionMode: Bool
    public let listsModel: Bool
    public let listsThinkingDisplay: Bool

    public init(version: String, help: String, serverHelp: String = "", features: String = "") {
        self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        supportsNoDaemon = help.contains("--no-daemon")
        supportsRemote = help.contains("--remote <")
        supportsListen = serverHelp.contains("--listen <")
        supportsDisableDaemonAutoStart = features.split(separator: "\n").contains {
            $0.split(whereSeparator: \.isWhitespace).first == "daemon_auto_start"
        }
        supportsSessionID = help.contains("--session-id <")
        supportsSettings = help.contains("--settings <")
        supportsEffort = help.contains("--effort <")
        supportsName = help.contains("--name <")
        supportsPluginDirectory = help.contains("--plugin-dir <")
        listsPermissionMode = help.contains("--permission-mode <")
        listsModel = help.contains("--model <")
        listsThinkingDisplay = help.contains("--thinking-display <")
    }

    /// The first `major.minor[.patch]` token of the CLI's `--version` line ("2.1.300 (Claude Code)"); nil
    /// when there is none (a fixture or an unreadable answer).
    public var claudeVersion: [Int]? {
        for token in version.split(whereSeparator: \.isWhitespace) {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...3).contains(parts.count) else { continue }
            let numbers = parts.compactMap { Int($0) }
            if numbers.count == parts.count { return numbers }
        }
        return nil
    }

    /// Whether the CLI's version is at least `floor` (a missing patch counts as 0). A version that cannot
    /// be read is not at least anything.
    public func claudeVersionAtLeast(_ floor: [Int]) -> Bool {
        guard let actual = claudeVersion else { return false }
        for index in 0..<max(actual.count, floor.count) {
            let have = index < actual.count ? actual[index] : 0
            let need = index < floor.count ? floor[index] : 0
            if have != need { return have > need }
        }
        return true
    }

    /// The first Claude Code release line that has both options (the 2.x series). `--help` is text that can
    /// change shape and a flag can be left out of it, so a flag that is not listed is gated by this version
    /// and never by the help text alone.
    public static let claudeLaunchChoicesFloor = [2, 0, 0]

    public var claudeAcceptsPermissionMode: Bool {
        listsPermissionMode || claudeVersionAtLeast(Self.claudeLaunchChoicesFloor)
    }

    public var claudeAcceptsModel: Bool {
        listsModel || claudeVersionAtLeast(Self.claudeLaunchChoicesFloor)
    }

    /// The first release `--thinking-display summarized` was seen working in (spike S1). The option is hidden from
    /// `--help`, and an unknown option stops the CLI, so an older or unreadable version goes without it.
    public static let claudeThinkingDisplayFloor = [2, 1, 300]

    public var claudeAcceptsThinkingDisplay: Bool {
        listsThinkingDisplay || claudeVersionAtLeast(Self.claudeThinkingDisplayFloor)
    }

    /// The Claude options this build looked for in `--help` and found, by name: what a journal or a
    /// diagnostics export says the CLI supports.
    public var detectedClaudeOptions: [String] {
        [("--settings", supportsSettings), ("--session-id", supportsSessionID), ("--effort", supportsEffort),
         ("--name", supportsName), ("--plugin-dir", supportsPluginDirectory)]
            .filter { $0.1 }.map { $0.0 }
    }
}

public struct ProviderLaunchProfile: Sendable {
    public let arguments: [String]
    public let environment: [String: String]
    /// Goes after every option, including the toolchain's extra ones: Claude's first prompt.
    public let trailingArguments: [String]
    /// The choices said Ask and this terminal profile runs Ask before edits instead (`SessionRuntime.terminalAskRule`). Building
    /// the profile records nothing; the spawn that uses it (`launchClaude`) records what runs and says so.
    public let replacedAsk: Bool

    public init(arguments: [String], environment: [String: String], trailingArguments: [String] = [], replacedAsk: Bool = false) {
        self.arguments = arguments
        self.environment = environment
        self.trailingArguments = trailingArguments
        self.replacedAsk = replacedAsk
    }

    /// The whole command line in launch order: route and settings, the toolchain's extras, then the
    /// positional prompt (so no extra option can end up after it).
    public func launchArguments(extra: [String] = []) -> [String] {
        arguments + extra + trailingArguments
    }

    public enum CodexRoute: Sendable {
        case baseline, direct, disableAutoStart, server(socket: String), remote(socket: String, threadID: String?, workingDirectory: String)
    }

    public enum ClaudeRoute: Equatable, Sendable {
        case new(UUID)
        case resume(String)
    }

    /// How Loom talks to the Claude it starts: the TUI in a terminal, or the stream-json child of the Chat face
    /// (V16, spike S1) with pipes and the same hooks, plugin and choices.
    public enum ClaudeFace: Equatable, Sendable {
        case terminal
        case chat
    }

    /// The options that make a Chat-face child (S1): NDJSON both ways, partial messages, the echo of every send,
    /// requests over the control channel. Never `--bare` (it skips the user's login).
    ///
    /// `--allow-dangerously-skip-permissions` (D-62) is passed on every Chat spawn and resume: it only makes Full access
    /// selectable in the live chip (the CLI refuses a live switch to `bypassPermissions` without it). It starts the child
    /// in no mode; Loom never picks Full access by itself. The terminal face's spawn does not carry it.
    public static let claudeChatArguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
        "--allow-dangerously-skip-permissions",
    ]

    /// A new session an agent asked Loom to open (D-40): Claude gets the title as its session name
    /// and the message as its first prompt.
    public struct ClaudeOpening: Equatable, Sendable {
        public let title: String
        public let firstMessage: String

        public init(title: String, firstMessage: String) {
            self.title = title
            self.firstMessage = firstMessage
        }
    }

    public static func codex(route: CodexRoute, capabilities: ProviderCapabilities,
                             home: URL, environment: [String: String]) throws -> Self {
        var arguments: [String]
        switch route {
        case .baseline: arguments = []
        case .direct:
            guard capabilities.supportsNoDaemon else { throw LoomError.message("Codex lacks --no-daemon") }
            arguments = ["--no-daemon"]
        case .disableAutoStart:
            guard capabilities.supportsDisableDaemonAutoStart else { throw LoomError.message("Codex lacks daemon_auto_start feature") }
            arguments = ["--disable", "daemon_auto_start"]
        case let .server(socket):
            guard capabilities.supportsListen else { throw LoomError.message("Codex app-server lacks --listen") }
            arguments = ["app-server", "--listen", "unix://\(socket)"]
        case let .remote(socket, threadID, workingDirectory):
            guard capabilities.supportsRemote else { throw LoomError.message("Codex lacks --remote") }
            arguments = threadID.map { ["resume", $0] } ?? []
            arguments += ["--remote", "unix://\(socket)", "--cd", workingDirectory]
        }
        var env = environment; env["CODEX_HOME"] = home.path
        return Self(arguments: arguments, environment: env)
    }

    public static func claude(capabilities: ProviderCapabilities, config: URL, sessionID: UUID,
                              environment: [String: String],
                              hooks: ClaudeHookLaunchConfiguration? = nil) throws -> Self {
        try claude(
            route: .new(sessionID), capabilities: capabilities, config: config,
            environment: environment, hooks: hooks
        )
    }

    public static func claude(
        route: ClaudeRoute, capabilities: ProviderCapabilities, config: URL,
        environment: [String: String],
        hooks: ClaudeHookLaunchConfiguration? = nil,
        effort: String? = nil,
        model: String? = nil,
        choices: ClaudeLaunchChoices = ClaudeLaunchChoices(),
        opening: ClaudeOpening? = nil,
        face: ClaudeFace = .terminal
    ) throws -> Self {
        // `--help` is text that can change shape without the option going away, so an option it does
        // not mention is passed anyway: if Claude really lacks it, Claude's own error is what the
        // user sees. `missingRequiredClaudeOptions` is how the caller logs and journals the drift.
        let routeArguments: [String]
        switch route {
        case let .new(sessionID):
            routeArguments = ["--session-id", sessionID.uuidString]
        case let .resume(providerSessionID):
            guard !providerSessionID.isEmpty else {
                throw LoomError.message("Claude resume requires a provider session identity")
            }
            routeArguments = ["--resume", providerSessionID]
        }
        // The level the session's record names, else the one its transcript last recorded; without either Claude
        // falls back to the saved default.
        var effortArguments: [String] = []
        if capabilities.supportsEffort, let level = choices.effort ?? effort, ClaudeTranscriptEffort.levels.contains(level) {
            effortArguments = ["--effort", level]
        }
        // The session's mode and model (V07). A choice the user made is never dropped quietly: a CLI that
        // cannot take the option, or a value that is not a plain word, refuses the start before any card
        // exists, so the draft keeps its text.
        var choiceArguments: [String] = []
        if let mode = choices.permissionMode {
            guard capabilities.claudeAcceptsPermissionMode else {
                throw LoomError.message("This Claude CLI does not take --permission-mode (\(capabilities.version))")
            }
            guard ClaudeLaunchChoices.isSafeToken(mode) else { throw LoomError.message("The permission mode is not valid") }
            // The CLI's word for the mode. Ask is Loom's own mode of the Chat face: there it runs on `dontAsk` (with rules and a
            // style set by control requests), and a terminal launch starts it in Ask before edits instead (D-63).
            choiceArguments += ["--permission-mode", ClaudePermissionMode(rawValue: mode)?.launchValue(chat: face == .chat) ?? mode]
        }
        // The model the session's record names, else the one its transcript last recorded (a resume only; the caller has
        // checked the option and the token, a transcript value is never a refusal).
        if choices.model == nil, let model, capabilities.claudeAcceptsModel, ClaudeLaunchChoices.isSafeToken(model) {
            choiceArguments += ["--model", model]
        }
        if let model = choices.model {
            guard capabilities.claudeAcceptsModel else {
                throw LoomError.message("This Claude CLI does not take --model (\(capabilities.version))")
            }
            guard ClaudeLaunchChoices.isSafeToken(model) else { throw LoomError.message("The model is not valid") }
            choiceArguments += ["--model", model]
        }
        var openingArguments: [String] = []
        var trailing: [String] = []
        if let opening, face == .chat {
            // The Chat face sends its first message over stdin; only the name is an option.
            guard case .new = route else {
                throw LoomError.message("Only a new Claude session can start with a first message")
            }
            if !opening.title.isEmpty { openingArguments = ["-n", opening.title] }
        } else if let opening {
            guard case .new = route else {
                throw LoomError.message("Only a new Claude session can start with a first message")
            }
            // An empty title leaves the naming to Claude.
            if !opening.title.isEmpty { openingArguments = ["-n", opening.title] }
            // After `--` a message that starts with a dash is still the prompt, not an option.
            trailing = ["--", opening.firstMessage]
        }
        var env = environment
        env["CLAUDE_CONFIG_DIR"] = config.path
        env["CLAUDE_CODE_DISABLE_AGENT_VIEW"] = "1"
        var faceArguments: [String] = []
        if face == .chat {
            faceArguments = claudeChatArguments
            // Readable thinking (S1 §D14): the default `updates` display sends empty thinking text. A hidden option,
            // so it is passed only where it is known to exist.
            if capabilities.claudeAcceptsThinkingDisplay { faceArguments += ["--thinking-display", "summarized"] }
            // `system/session_state_changed` (S1 §D8): idle, running, requires_action.
            env["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = "1"
            // File checkpoints from the session's first turn (S8): without them `rewind_files` answers "File rewinding
            // is not enabled", and a message sent before the switch has no checkpoint. `rewind_files` takes the uuid
            // Loom put on its own user line (the id of its row in the live model). The terminal keeps its own.
            env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true"
        }
        if let hooks {
            env["LOOM_HOOK_SOCKET"] = hooks.socketPath
            env["LOOM_HOOK_TOKEN"] = hooks.authenticationToken
            // The bundled helper doubles as the agent's way to ask for another session (D-40).
            env["LOOM_CLI"] = hooks.helperPath
            if let control = hooks.controlSocketPath { env["LOOM_CONTROL_SOCKET"] = control }
        }
        // Loom's skill for `"$LOOM_CLI" open` (D-42); a Claude without the option runs without it.
        var pluginArguments: [String] = []
        if let plugin = hooks?.pluginDirectory, capabilities.supportsPluginDirectory {
            pluginArguments = ["--plugin-dir", plugin]
        }
        let settings = try claudeSettings(hooks: hooks)
        return Self(
            arguments: faceArguments + routeArguments + effortArguments + choiceArguments + ["--settings", settings]
                + pluginArguments + openingArguments,
            environment: env, trailingArguments: trailing
        )
    }

    /// The options a Claude start of this kind needs that `--help` did not list. Informational:
    /// `claude(route:...)` passes them anyway.
    public static func missingRequiredClaudeOptions(
        capabilities: ProviderCapabilities, route: ClaudeRoute, opening: ClaudeOpening? = nil
    ) -> [String] {
        var missing: [String] = []
        if !capabilities.supportsSettings { missing.append("--settings") }
        if case .new = route, !capabilities.supportsSessionID { missing.append("--session-id") }
        if let opening, !opening.title.isEmpty, !capabilities.supportsName { missing.append("--name") }
        return missing
    }

    private static func claudeSettings(hooks: ClaudeHookLaunchConfiguration?) throws -> String {
        var settings: [String: Any] = ["crossSessionInbound": "refuse"]
        if let hooks {
            // These authority events only forward local IPC. Keep helpers
            // synchronous and bounded so Loom does not reorder identity/state
            // by racing helper startup; helpers return no provider decision.
            let bounded: [String: Any] = [
                "type": "command", "command": hooks.helperPath,
                "args": [], "timeout": 1,
            ]
            var eventHooks: [String: Any] = [:]
            for event in [
                "SessionStart", "UserPromptSubmit", "Stop", "StopFailure",
                "Notification", "PermissionRequest", "SessionEnd",
                // The subagent list under a card (D-39). No per-tool hooks: each hook spawns a helper.
                "SubagentStart", "SubagentStop",
            ] {
                eventHooks[event] = [["hooks": [bounded]]]
            }
            settings["hooks"] = eventHooks
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.sortedKeys]
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw LoomError.message("Could not encode Claude session settings")
        }
        return value
    }
}

public struct ClaudeHookLaunchConfiguration: Equatable, Sendable {
    public let helperPath: String
    public let socketPath: String
    public let authenticationToken: String
    /// The request/response socket of `loom-hook open`; nil when this run has none.
    public let controlSocketPath: String?
    /// `ClaudeLoomPlugin`'s folder, passed as `--plugin-dir`; nil when it could not be written.
    public let pluginDirectory: String?

    public init(helperPath: String, socketPath: String, authenticationToken: String,
                controlSocketPath: String? = nil, pluginDirectory: String? = nil) {
        self.helperPath = helperPath
        self.socketPath = socketPath
        self.authenticationToken = authenticationToken
        self.controlSocketPath = controlSocketPath
        self.pluginDirectory = pluginDirectory
    }
}
