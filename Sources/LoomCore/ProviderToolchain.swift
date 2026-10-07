import Darwin
import Foundation

/// Everything needed to start one provider CLI: where it is, what it supports,
/// and the user's resolved terminal environment. `profileDirectory == nil`
/// means the provider's own default profile (`~/.claude`, `~/.codex`): the
/// runtime then sets no profile variable for Claude and the CLI keeps using
/// its normal credentials. Acceptance runs pass an isolated directory.
public struct ProviderToolchain: Sendable {
    public let provider: ManagedSession.Provider
    public let executable: String
    public let capabilities: ProviderCapabilities
    public let environment: [String: String]
    public let profileDirectory: URL?
    /// Appended after the runtime's route arguments (fixtures, model flags).
    public let extraArguments: [String]
    public let warnings: [String]

    public init(
        provider: ManagedSession.Provider, executable: String,
        capabilities: ProviderCapabilities, environment: [String: String],
        profileDirectory: URL? = nil, extraArguments: [String] = [],
        warnings: [String] = []
    ) {
        self.provider = provider
        self.executable = executable
        self.capabilities = capabilities
        self.environment = environment
        self.profileDirectory = profileDirectory
        self.extraArguments = extraArguments
        self.warnings = warnings
    }
}

/// Failures the user can fix and retry; none of them leaves a catalog row,
/// process or reservation behind.
public enum ProviderToolchainError: Error, CustomStringConvertible, Equatable, Sendable {
    case executableNotFound(provider: ManagedSession.Provider, searched: Int)
    case capabilityProbeFailed(command: String, detail: String)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .executableNotFound(provider, searched):
            "\(provider.rawValue) was not found on the PATH of your terminal environment (\(searched) folders searched)"
        case let .capabilityProbeFailed(command, detail):
            "\(command) could not be inspected: \(detail)"
        case let .unsupported(reason):
            reason
        }
    }
}

/// Resolves a provider toolchain once the user's terminal environment is
/// known. Injected so tests can point the runtime at fixture executables.
public typealias ProviderToolchainResolver =
    @Sendable (_ provider: ManagedSession.Provider) async throws -> ProviderToolchain

public enum ProviderToolchainProbe {
    /// First executable named `name` on the environment's PATH.
    public static func find(
        _ name: String, in environment: [String: String]
    ) -> (path: String, searched: Int)? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in folders {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name).path
            if access(candidate, X_OK) == 0 { return (candidate, folders.count) }
        }
        return nil
    }
}

/// Production resolver: the user's real terminal environment (resolved once by
/// the supervisor and cached only after it succeeds), the first matching
/// executable on its PATH, and capabilities read from the CLI itself. Nothing
/// is pinned to a provider version.
public actor SystemProviderToolchains {
    private let supervisor: ProcessSupervisor
    private let origin: LaunchEnvironment.LaunchOrigin
    private let claudeProfile: URL?
    private let codexHome: URL?
    private let environmentSource: (@Sendable () async throws -> LaunchEnvironment.Resolution)?
    private var environment: LaunchEnvironment.Resolution?
    private var resolved: [ManagedSession.Provider: ProviderToolchain] = [:]

    public init(
        supervisor: ProcessSupervisor, origin: LaunchEnvironment.LaunchOrigin,
        claudeProfile: URL? = nil, codexHome: URL? = nil,
        environmentSource: (@Sendable () async throws -> LaunchEnvironment.Resolution)? = nil
    ) {
        self.supervisor = supervisor
        self.origin = origin
        self.claudeProfile = claudeProfile
        self.codexHome = codexHome
        self.environmentSource = environmentSource
    }

    public var resolver: ProviderToolchainResolver {
        { [self] provider in try await toolchain(for: provider) }
    }

    public func toolchain(for provider: ManagedSession.Provider) async throws -> ProviderToolchain {
        if let cached = resolved[provider] { return cached }
        let resolution: LaunchEnvironment.Resolution
        if let environment { resolution = environment }
        else {
            if let environmentSource { resolution = try await environmentSource() }
            else { resolution = try await supervisor.terminalEnvironment(origin: origin) }
            environment = resolution
        }
        let value: ProviderToolchain
        switch provider {
        case .claude: value = try await claude(resolution)
        case .codex: value = try await codex(resolution)
        case .synthetic:
            throw ProviderToolchainError.unsupported("Synthetic sessions have no provider CLI")
        }
        resolved[provider] = value
        return value
    }

    private func claude(_ resolution: LaunchEnvironment.Resolution) async throws -> ProviderToolchain {
        guard let found = ProviderToolchainProbe.find("claude", in: resolution.environment) else {
            throw ProviderToolchainError.executableNotFound(
                provider: .claude,
                searched: (resolution.environment["PATH"] ?? "").split(separator: ":").count
            )
        }
        var probe = resolution.environment
        if let claudeProfile { probe["CLAUDE_CONFIG_DIR"] = claudeProfile.path }
        let version = try await capture(found.path, ["--version"], probe)
        let help = try await capture(found.path, ["--help"], probe)
        return ProviderToolchain(
            provider: .claude, executable: found.path,
            capabilities: ProviderCapabilities(version: version, help: help),
            environment: resolution.environment, profileDirectory: claudeProfile,
            warnings: resolution.warnings
        )
    }

    private func codex(_ resolution: LaunchEnvironment.Resolution) async throws -> ProviderToolchain {
        guard let found = ProviderToolchainProbe.find("codex", in: resolution.environment) else {
            throw ProviderToolchainError.executableNotFound(
                provider: .codex,
                searched: (resolution.environment["PATH"] ?? "").split(separator: ":").count
            )
        }
        // Explicit acceptance override > the user's terminal environment > the default profile.
        let home = codexHome
            ?? resolution.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        var probe = resolution.environment
        probe["CODEX_HOME"] = home.path
        let version = try await capture(found.path, ["--version"], probe)
        let help = try await capture(found.path, ["--help"], probe)
        let serverHelp = try await capture(found.path, ["app-server", "--help"], probe)
        return ProviderToolchain(
            provider: .codex, executable: found.path,
            capabilities: ProviderCapabilities(version: version, help: help, serverHelp: serverHelp),
            environment: resolution.environment, profileDirectory: home,
            warnings: resolution.warnings
        )
    }

    /// Capability queries go through the supervisor, so they are tracked,
    /// bounded and stopped by Quit like the environment shell.
    private func capture(
        _ executable: String, _ arguments: [String], _ environment: [String: String]
    ) async throws -> String {
        let command = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        do {
            return try await supervisor.captureHelper(executable, arguments, environment: environment)
        } catch let error as SessionManagementError {
            throw error
        } catch {
            throw ProviderToolchainError.capabilityProbeFailed(command: command, detail: String(describing: error))
        }
    }
}
