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

    public enum CodexRoute: Sendable {
        case baseline, direct, disableAutoStart, server(socket: String), remote(socket: String, threadID: String?)
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
        case let .remote(socket, threadID):
            guard capabilities.supportsRemote else { throw LoomError.message("Codex lacks --remote") }
            arguments = threadID.map { ["resume", $0] } ?? []
            arguments += ["--remote", "unix://\(socket)"]
        }
        var env = environment; env["CODEX_HOME"] = home.path
        return Self(arguments: arguments, environment: env)
    }

    public static func claude(capabilities: ProviderCapabilities, config: URL, sessionID: UUID,
                              environment: [String: String]) throws -> Self {
        guard capabilities.supportsSessionID, capabilities.supportsSettings else {
            throw LoomError.message("Claude lacks required --session-id/--settings options")
        }
        var env = environment
        env["CLAUDE_CONFIG_DIR"] = config.path
        env["CLAUDE_CODE_DISABLE_AGENT_VIEW"] = "1"
        return Self(arguments: ["--session-id", sessionID.uuidString, "--settings", "{\"crossSessionInbound\":\"refuse\"}"],
                    environment: env)
    }
}
