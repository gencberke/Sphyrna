import Foundation

/// What Sphyrna shows to set a harness up: the vendor's own command, for the person to run in their own terminal. Sphyrna
/// never runs these commands, never types into Terminal and never handles credentials (D-98).
public struct HarnessSetupCommand: Equatable, Sendable {
    /// "Install" or "Sign In".
    public let title: String
    /// The vendor's command, as it is typed.
    public let command: String
    /// Another way the vendor offers, shown beside it.
    public let alternative: String?

    /// The command for a harness in `state`: how to install it while it is not found, how to sign in while nobody is. Nil for
    /// any other state, and for a harness whose vendor line is not known yet (agy: P1's spike).
    public static func command(forHarness id: HarnessID, state: HarnessHealthState) -> HarnessSetupCommand? {
        switch state {
        case .install: install(forHarness: id)
        case .signIn: signIn(forHarness: id)
        default: nil
        }
    }

    /// The vendor's macOS install commands, from the harness's descriptor.
    public static func install(forHarness id: HarnessID) -> HarnessSetupCommand? {
        HarnessCatalogue.descriptor(for: id)?.install
    }

    /// The vendor's sign-in command, from the harness's descriptor.
    public static func signIn(forHarness id: HarnessID) -> HarnessSetupCommand? {
        HarnessCatalogue.descriptor(for: id)?.signIn
    }

    // MARK: Providers (C2 moves these callers to the harness ids)

    public static func command(for provider: ManagedSession.Provider, state: HarnessHealthState) -> HarnessSetupCommand? {
        command(forHarness: HarnessID(provider), state: state)
    }

    public static func install(_ provider: ManagedSession.Provider) -> HarnessSetupCommand? {
        install(forHarness: HarnessID(provider))
    }

    public static func signIn(_ provider: ManagedSession.Provider) -> HarnessSetupCommand? {
        signIn(forHarness: HarnessID(provider))
    }
}

/// Deep Check: the CLI's own health command, run on request (a button; never on its own) through the supervisor, with a time
/// limit, in a neutral folder of Sphyrna's, and shown as text.
public struct HarnessDeepCheck: Sendable {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// The command ran and reported a status of 0.
        public var succeeded: Bool

        public init(text: String, succeeded: Bool) {
            self.text = text
            self.succeeded = succeeded
        }
    }

    /// The CLI arguments of `id`'s Deep Check, nil when the harness has no health command (agy and pi). Codex's text form
    /// (`--json` is a redacted report for machines).
    public static func arguments(forHarness id: HarnessID) -> [String]? {
        HarnessCatalogue.descriptor(for: id)?.doctorArguments
    }

    /// The child's environment: the toolchain's, without colour, with the profile pinned where the descriptor says so.
    /// Codex's profile folder is always pinned (`pinsDefaultProfile`). Claude's is pinned only when the toolchain has a
    /// profile of its own: for the default profile the variable stays as the login shell had it, and is never set to
    /// `~/.claude` (Claude names its stored login after an explicit config folder; see `ClaudePlanLimitsFetcher`).
    static func environment(forHarness id: HarnessID, toolchain: ProviderToolchain) -> [String: String] {
        var environment = toolchain.environment
        if let descriptor = HarnessCatalogue.descriptor(for: id), let variable = descriptor.profileVariable,
           descriptor.pinsDefaultProfile || toolchain.profileDirectory != nil {
            environment[variable] = HarnessHealth.profileDirectory(of: toolchain).path
        }
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// The command as the person reads it ("claude doctor"), nil when the harness has no health command.
    public static func display(forHarness id: HarnessID) -> String? {
        HarnessCatalogue.descriptor(for: id)?.doctorCommand
    }

    /// How long a Deep Check may run before it is stopped, in seconds.
    public static let defaultTimeout: TimeInterval = 30

    /// The longest output kept: a doctor's report is a page, not a log.
    static let outputLimit = 256 * 1024
    static let keptCharacters = 20_000

    private let supervisor: ProcessSupervisor
    private let toolchain: @Sendable (ManagedSession.Provider) async throws -> ProviderToolchain
    private let workingDirectory: URL
    private let timeout: TimeInterval

    public init(supervisor: ProcessSupervisor, toolchain: @escaping @Sendable (ManagedSession.Provider) async throws -> ProviderToolchain,
                workingDirectory: URL, timeout: TimeInterval = HarnessDeepCheck.defaultTimeout) {
        self.supervisor = supervisor
        self.toolchain = toolchain
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    /// Runs the command. Its output and its status line come back as text; a failure to start or a timeout is told in words.
    public func run(_ provider: ManagedSession.Provider) async -> Result {
        let id = HarnessID(provider)
        guard let arguments = Self.arguments(forHarness: id) else {
            return Result(text: "The \(HarnessHealth.command(forHarness: id)) command has no health check.", succeeded: false)
        }
        do {
            let resolved = try await toolchain(provider)
            try FileManager.default.createDirectory(
                at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let environment = Self.environment(forHarness: id, toolchain: resolved)
            // A fixed script with the folder and the command as its arguments: nothing is spliced into the shell's text. Standard
            // error joins the output, and the status is printed, so a command that fails still shows what it said.
            let script = #"cd "$1" || exit 1; shift; "$@" 2>&1 </dev/null; printf '\n[exit status %s]\n' "$?""#
            let output = try await supervisor.captureHelper(
                "/bin/sh", ["-c", script, "sh", workingDirectory.path, resolved.executable] + arguments,
                environment: environment, timeout: timeout, outputLimit: Self.outputLimit)
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(text: Self.clipped(text), succeeded: text.hasSuffix("[exit status 0]"))
        } catch ProviderToolchainError.executableNotFound {
            return Result(text: "The \(HarnessHealth.command(forHarness: id)) command was not found.", succeeded: false)
        } catch LoomError.environmentTimeout {
            return Result(text: "The check did not finish in \(Int(timeout)) seconds and was stopped.", succeeded: false)
        } catch {
            return Result(text: "The check could not run (\(LoomLog.category(of: error))).", succeeded: false)
        }
    }

    static func clipped(_ text: String) -> String {
        text.count <= keptCharacters ? text : String(text.prefix(keptCharacters)) + "\n[output cut]"
    }

    // MARK: Providers (C2 moves these callers to the harness ids)

    public static func arguments(for provider: ManagedSession.Provider) -> [String] {
        arguments(forHarness: HarnessID(provider)) ?? []
    }

    static func environment(for provider: ManagedSession.Provider, toolchain: ProviderToolchain) -> [String: String] {
        environment(forHarness: HarnessID(provider), toolchain: toolchain)
    }

    public static func display(for provider: ManagedSession.Provider) -> String {
        display(forHarness: HarnessID(provider)) ?? ""
    }
}
