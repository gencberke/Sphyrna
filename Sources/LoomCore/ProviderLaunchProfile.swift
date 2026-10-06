import Foundation

public struct ProviderCapabilities: Codable, Sendable {
    public let version: String
    public let supportsNoDaemon: Bool
    public let supportsRemote: Bool
    public let supportsListen: Bool
    public let supportsDisableDaemonAutoStart: Bool
    public let supportsSessionID: Bool
    public let supportsSettings: Bool

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
    }
}

public struct ProviderLaunchProfile: Sendable {
    public let arguments: [String]
    public let environment: [String: String]

    public init(arguments: [String], environment: [String: String]) {
        self.arguments = arguments
        self.environment = environment
    }

    public enum CodexRoute: Sendable {
        case baseline, direct, disableAutoStart, server(socket: String), remote(socket: String, threadID: String?, workingDirectory: String)
    }

    public enum ClaudeRoute: Equatable, Sendable {
        case new(UUID)
        case resume(String)
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
        hooks: ClaudeHookLaunchConfiguration? = nil
    ) throws -> Self {
        guard capabilities.supportsSettings else {
            throw LoomError.message("Claude lacks required --settings option")
        }
        let routeArguments: [String]
        switch route {
        case let .new(sessionID):
            guard capabilities.supportsSessionID else {
                throw LoomError.message("Claude lacks required --session-id option")
            }
            routeArguments = ["--session-id", sessionID.uuidString]
        case let .resume(providerSessionID):
            guard !providerSessionID.isEmpty else {
                throw LoomError.message("Claude resume requires a provider session identity")
            }
            routeArguments = ["--resume", providerSessionID]
        }
        var env = environment
        env["CLAUDE_CONFIG_DIR"] = config.path
        env["CLAUDE_CODE_DISABLE_AGENT_VIEW"] = "1"
        if let hooks {
            env["LOOM_HOOK_SOCKET"] = hooks.socketPath
            env["LOOM_HOOK_TOKEN"] = hooks.authenticationToken
        }
        let settings = try claudeSettings(hooks: hooks)
        return Self(arguments: routeArguments + ["--settings", settings],
                    environment: env)
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

    public init(helperPath: String, socketPath: String, authenticationToken: String) {
        self.helperPath = helperPath
        self.socketPath = socketPath
        self.authenticationToken = authenticationToken
    }
}
