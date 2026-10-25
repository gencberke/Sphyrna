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
    /// any other state.
    public static func command(for provider: ManagedSession.Provider, state: HarnessHealthState) -> HarnessSetupCommand? {
        switch state {
        case .install: install(provider)
        case .signIn: signIn(provider)
        default: nil
        }
    }

    /// The vendor's macOS install commands, checked on 25 Oct.
    public static func install(_ provider: ManagedSession.Provider) -> HarnessSetupCommand? {
        switch provider {
        case .claude:
            HarnessSetupCommand(title: "Install", command: "brew install --cask claude-code",
                                alternative: "curl -fsSL https://claude.ai/install.sh | bash")
        case .codex:
            HarnessSetupCommand(title: "Install", command: "npm install -g @openai/codex", alternative: "brew install --cask codex")
        case .synthetic: nil
        }
    }

    public static func signIn(_ provider: ManagedSession.Provider) -> HarnessSetupCommand? {
        switch provider {
        case .claude: HarnessSetupCommand(title: "Sign In", command: "claude auth login", alternative: nil)
        case .codex: HarnessSetupCommand(title: "Sign In", command: "codex login", alternative: nil)
        case .synthetic: nil
        }
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

    /// The CLI arguments of `provider`'s Deep Check. Codex's text form (`--json` is a redacted report for machines).
    public static func arguments(for provider: ManagedSession.Provider) -> [String] {
        provider == .codex ? ["doctor", "--no-color"] : ["doctor"]
    }

    /// The command as the person reads it: "claude doctor".
    public static func display(for provider: ManagedSession.Provider) -> String {
        ([HarnessHealth.command(provider)] + arguments(for: provider)).joined(separator: " ")
    }

    /// The longest output kept: a doctor's report is a page, not a log.
    static let outputLimit = 256 * 1024
    static let keptCharacters = 20_000

    private let supervisor: ProcessSupervisor
    private let toolchain: @Sendable (ManagedSession.Provider) async throws -> ProviderToolchain
    private let workingDirectory: URL
    private let timeout: TimeInterval

    public init(supervisor: ProcessSupervisor, toolchain: @escaping @Sendable (ManagedSession.Provider) async throws -> ProviderToolchain,
                workingDirectory: URL, timeout: TimeInterval = 30) {
        self.supervisor = supervisor
        self.toolchain = toolchain
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    /// Runs the command. Its output and its status line come back as text; a failure to start or a timeout is told in words.
    public func run(_ provider: ManagedSession.Provider) async -> Result {
        do {
            let resolved = try await toolchain(provider)
            try FileManager.default.createDirectory(
                at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var environment = resolved.environment
            environment[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = HarnessHealth.profileDirectory(of: resolved).path
            environment["NO_COLOR"] = "1"
            // A fixed script with the folder and the command as its arguments: nothing is spliced into the shell's text. Standard
            // error joins the output, and the status is printed, so a command that fails still shows what it said.
            let script = #"cd "$1" || exit 1; shift; "$@" 2>&1 </dev/null; printf '\n[exit status %s]\n' "$?""#
            let output = try await supervisor.captureHelper(
                "/bin/sh", ["-c", script, "sh", workingDirectory.path, resolved.executable] + Self.arguments(for: provider),
                environment: environment, timeout: timeout, outputLimit: Self.outputLimit)
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(text: Self.clipped(text), succeeded: text.hasSuffix("[exit status 0]"))
        } catch ProviderToolchainError.executableNotFound {
            return Result(text: "The \(HarnessHealth.command(provider)) command was not found.", succeeded: false)
        } catch LoomError.environmentTimeout {
            return Result(text: "The check did not finish in \(Int(timeout)) seconds and was stopped.", succeeded: false)
        } catch {
            return Result(text: "The check could not run (\(LoomLog.category(of: error))).", succeeded: false)
        }
    }

    static func clipped(_ text: String) -> String {
        text.count <= keptCharacters ? text : String(text.prefix(keptCharacters)) + "\n[output cut]"
    }
}
