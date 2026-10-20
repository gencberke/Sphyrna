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
    /// The executable as it was when the capabilities were read; nil when the resolver did not
    /// record it (the runtime then stamps the file when it first caches the toolchain).
    public let executableStamp: ExecutableStamp?

    public init(
        provider: ManagedSession.Provider, executable: String,
        capabilities: ProviderCapabilities, environment: [String: String],
        profileDirectory: URL? = nil, extraArguments: [String] = [],
        warnings: [String] = [], executableStamp: ExecutableStamp? = nil
    ) {
        self.provider = provider
        self.executable = executable
        self.capabilities = capabilities
        self.environment = environment
        self.profileDirectory = profileDirectory
        self.extraArguments = extraArguments
        self.warnings = warnings
        self.executableStamp = executableStamp
    }
}

/// Which file an executable path pointed at, and when it last changed. A cached toolchain
/// (capabilities read from `--help`) is only as current as the file it was read from: a CLI
/// update replaces the file (new inode) or rewrites it (new mtime or size).
public struct ExecutableStamp: Equatable, Sendable {
    public let inode: UInt64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int
    public let size: Int64

    /// nil when the path does not exist (or is not reachable). Follows symlinks, as `exec` does.
    public static func read(_ path: String) -> ExecutableStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return ExecutableStamp(
            inode: UInt64(info.st_ino), modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec, size: Int64(info.st_size))
    }
}

/// How a capability probe failed, without its output: what the journal may keep (an output can carry a path or provider text).
public enum ProbeFailureKind: Equatable, Sendable, CustomStringConvertible {
    case timeout
    /// The CLI ran and exited with this status.
    case exit(Int32)
    /// It could not be started or read (a spawn, pipe or scope error).
    case spawn

    public var description: String {
        switch self {
        case .timeout: "timeout"
        case let .exit(status): "exit \(status)"
        case .spawn: "spawn"
        }
    }

    init(_ error: any Error) {
        switch error {
        case LoomError.environmentTimeout: self = .timeout
        case let LoomError.helperExit(status, _): self = .exit(status)
        default: self = .spawn
        }
    }
}

/// Failures the user can fix and retry; none of them leaves a catalog row,
/// process or reservation behind.
public enum ProviderToolchainError: Error, CustomStringConvertible, Equatable, Sendable {
    case executableNotFound(provider: ManagedSession.Provider, searched: Int)
    case capabilityProbeFailed(command: String, detail: String, kind: ProbeFailureKind)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .executableNotFound(provider, searched):
            "\(provider.rawValue) was not found on the PATH of your terminal environment (\(searched) folders searched)"
        case let .capabilityProbeFailed(command, detail, _):
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
    private var environmentTask: Task<LaunchEnvironment.Resolution, any Error>?
    private var resolved: [ManagedSession.Provider: ProviderToolchain] = [:]
    /// Resolutions since this object was created, per provider (tests and the diagnostics read it).
    public private(set) var resolutionCount = 0

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

    /// The cached toolchain while the executable it was read from is unchanged; otherwise it is
    /// resolved again (a CLI update must not leave Loom launching with the old one's capabilities).
    /// A missing executable also drops the terminal environment, so a CLI installed somewhere new
    /// since is found through a fresh PATH.
    public func toolchain(for provider: ManagedSession.Provider) async throws -> ProviderToolchain {
        if let cached = resolved[provider] {
            let current = ExecutableStamp.read(cached.executable)
            if let current, current == cached.executableStamp { return cached }
            LoomLog.notice(.toolchain, "\(provider.rawValue) executable \(current == nil ? "is gone" : "changed"); resolving again")
            resolved[provider] = nil
            if current == nil { dropTerminalEnvironment() }
        }
        let resolution = try await terminalEnvironment()
        let value: ProviderToolchain
        switch provider {
        case .claude: value = try await claude(resolution)
        case .codex: value = try await codex(resolution)
        case .synthetic:
            throw ProviderToolchainError.unsupported("Synthetic sessions have no provider CLI")
        }
        resolved[provider] = value
        resolutionCount += 1
        return value
    }

    /// The user's terminal environment: read once (one login shell), kept after it succeeded and shared by everything that
    /// asks, a toolchain and the delete target's `CLAUDE_CONFIG_DIR` (DP-CP4-8) alike. An ask that comes while the shell is
    /// still running waits for that one; a failure is not kept, so the next ask reads again.
    public func terminalEnvironment() async throws -> LaunchEnvironment.Resolution {
        if let environment { return environment }
        let task: Task<LaunchEnvironment.Resolution, any Error>
        if let environmentTask { task = environmentTask } else {
            let supervisor = supervisor, origin = origin, source = environmentSource
            task = Task {
                if let source { return try await source() }
                return try await supervisor.terminalEnvironment(origin: origin)
            }
            environmentTask = task
        }
        do {
            let resolution = try await task.value
            // Dropped meanwhile (the executable vanished): this answer is not kept.
            if environmentTask == task { environment = resolution; environmentTask = nil }
            return resolution
        } catch {
            if environmentTask == task { environmentTask = nil }
            throw error
        }
    }

    private func dropTerminalEnvironment() {
        environment = nil
        environmentTask = nil
    }

    /// Forgets what was resolved for a provider (a launch failed): the next ask resolves again.
    public func invalidate(_ provider: ManagedSession.Provider) {
        resolved[provider] = nil
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
        // Stamped before the probes: a file replaced while they run reads as changed next time.
        let stamp = ExecutableStamp.read(found.path)
        let version = try await capture(found.path, ["--version"], probe)
        let help = try await capture(found.path, ["--help"], probe)
        return ProviderToolchain(
            provider: .claude, executable: found.path,
            capabilities: ProviderCapabilities(version: version, help: help),
            environment: resolution.environment, profileDirectory: claudeProfile,
            warnings: resolution.warnings, executableStamp: stamp
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
        let stamp = ExecutableStamp.read(found.path)
        let version = try await capture(found.path, ["--version"], probe)
        let help = try await capture(found.path, ["--help"], probe)
        let serverHelp = try await capture(found.path, ["app-server", "--help"], probe)
        return ProviderToolchain(
            provider: .codex, executable: found.path,
            capabilities: ProviderCapabilities(version: version, help: help, serverHelp: serverHelp),
            environment: resolution.environment, profileDirectory: home,
            warnings: resolution.warnings, executableStamp: stamp
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
            throw ProviderToolchainError.capabilityProbeFailed(
                command: command, detail: String(describing: error), kind: ProbeFailureKind(error))
        }
    }
}
