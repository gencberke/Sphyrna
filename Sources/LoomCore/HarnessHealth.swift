import Foundation

// One state machine per harness for Settings → Connections and Home's "Connect your agents" (D-98): built from the toolchain
// (is the CLI there, which version), the probe's reading (who is signed in, whether limits can be read) and the connect
// switch. Nothing here starts a process: `HarnessHealthChecker` asks, this file only judges what it was given.

/// Where a harness stands, in the words of the six states of FB5-8.
public enum HarnessHealthState: Equatable, Sendable {
    /// A check is on its way and nothing is known yet.
    case checking
    /// The connect switch is off: Sphyrna does not offer, check or read the harness.
    case disabled
    /// The CLI was not found on the terminal environment's PATH.
    case install
    /// The CLI is there and nobody is signed in.
    case signIn
    /// The CLI is below the minimum version, or could not be checked.
    case attention
    case ready
}

/// How a CLI's version stands against `HarnessVersionTable`.
public enum HarnessVersionStatus: Equatable, Sendable {
    /// No version could be read (a fixture, or an unreadable `--version`).
    case unknown
    case belowMinimum
    case belowRecommended
    case current
}

/// The versions Sphyrna judges a CLI by: the oldest it accepts and the one this release was built against.
public struct HarnessVersionTable: Equatable, Sendable {
    /// The oldest version the code's capability checks accept; nil where the checks read `--help` and never a version.
    public let minimum: [Int]?
    /// The version 1.6.2 was built and checked against.
    public let recommended: [Int]

    /// Claude Code: the 2.x series is the first with `--permission-mode` and `--model` (`claudeLaunchChoicesFloor`), the oldest
    /// version `ProviderCapabilities` accepts. 2.1.300 is the build the app was made against.
    ///
    /// Codex: its capability checks read `--help` (`supportsListen` for the app-server), never a version, so it has no minimum
    /// number here; a CLI whose `app-server` lacks `--listen` counts as below the minimum. 0.160.0 is the build checked against.
    public static func table(for provider: ManagedSession.Provider) -> HarnessVersionTable? {
        switch provider {
        case .claude: HarnessVersionTable(minimum: ProviderCapabilities.claudeLaunchChoicesFloor, recommended: [2, 1, 300])
        case .codex: HarnessVersionTable(minimum: nil, recommended: [0, 160, 0])
        case .synthetic: nil
        }
    }

    /// The version in words: "2.1.300".
    public static func text(_ version: [Int]) -> String { version.map(String.init).joined(separator: ".") }

    /// -1, 0 or 1 as `lhs` is older than, the same as, or newer than `rhs` (a missing patch counts as 0).
    public static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let have = index < lhs.count ? lhs[index] : 0
            let need = index < rhs.count ? rhs[index] : 0
            if have != need { return have < need ? -1 : 1 }
        }
        return 0
    }

    /// Where `capabilities` (what the CLI's own `--version` and `--help` said) stands for `provider`.
    public static func status(of capabilities: ProviderCapabilities, provider: ManagedSession.Provider) -> HarnessVersionStatus {
        guard let table = table(for: provider) else { return .unknown }
        if provider == .codex, !capabilities.supportsListen { return .belowMinimum }
        guard let version = capabilities.claudeVersion else { return .unknown }
        if let minimum = table.minimum, compare(version, minimum) < 0 { return .belowMinimum }
        return compare(version, table.recommended) < 0 ? .belowRecommended : .current
    }
}

/// What Connections and Home know of one harness at one moment. The account (the email is in it) lives in memory only: it
/// has no `Codable`, and `HarnessAccount`'s description leaves the email out, so a health printed by mistake does not carry it.
public struct HarnessHealth: Equatable, Sendable {
    public var provider: ManagedSession.Provider
    public var state: HarnessHealthState
    /// "Ready · Claude Max", "Not signed in", "Not found", "Update needed", "Turned off", "Checking…".
    public var headline: String
    /// One line that says more where the state has something to add (what is wrong, what helps).
    public var note: String?
    public var executable: String?
    public var version: [Int]?
    public var versionStatus: HarnessVersionStatus
    /// Where the CLI keeps its profile (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`, or the default folder).
    public var profileDirectory: URL?
    public var account: HarnessAccount?
    /// Whether the harness's limits could be read at the last check; nil when not known.
    public var limitsReadable: Bool?
    public var checkedAt: Date?
    /// The last check found another email or plan than the one before; shown until the page is seen.
    public var accountChanged: Bool

    public init(provider: ManagedSession.Provider, state: HarnessHealthState, headline: String, note: String? = nil,
                executable: String? = nil, version: [Int]? = nil, versionStatus: HarnessVersionStatus = .unknown,
                profileDirectory: URL? = nil, account: HarnessAccount? = nil, limitsReadable: Bool? = nil,
                checkedAt: Date? = nil, accountChanged: Bool = false) {
        self.provider = provider
        self.state = state
        self.headline = headline
        self.note = note
        self.executable = executable
        self.version = version
        self.versionStatus = versionStatus
        self.profileDirectory = profileDirectory
        self.account = account
        self.limitsReadable = limitsReadable
        self.checkedAt = checkedAt
        self.accountChanged = accountChanged
    }

    public static func checking(_ provider: ManagedSession.Provider) -> HarnessHealth {
        HarnessHealth(provider: provider, state: .checking, headline: "Checking…")
    }

    public static func disabled(_ provider: ManagedSession.Provider) -> HarnessHealth {
        HarnessHealth(provider: provider, state: .disabled, headline: "Turned off")
    }

    /// The CLI is not on the PATH.
    static func notFound(_ provider: ManagedSession.Provider, at now: Date) -> HarnessHealth {
        HarnessHealth(provider: provider, state: .install, headline: "Not found",
                      note: "Sphyrna looked on your terminal's PATH and found no \(Self.command(provider)) command.", checkedAt: now)
    }

    /// The toolchain could not be resolved for another reason (the CLI would not answer `--version`, say).
    static func unreadable(_ provider: ManagedSession.Provider, at now: Date) -> HarnessHealth {
        HarnessHealth(provider: provider, state: .attention, headline: "Could not check",
                      note: "The \(Self.command(provider)) command did not answer. Choose Check Again, or run it in Terminal to see why.",
                      checkedAt: now)
    }

    /// The executable's name on the PATH.
    public static func command(_ provider: ManagedSession.Provider) -> String {
        provider == .codex ? "codex" : "claude"
    }

    /// Where the CLI keeps its profile: the toolchain's own folder, else the variable the CLI reads, else its default.
    public static func profileDirectory(of toolchain: ProviderToolchain) -> URL {
        if let folder = toolchain.profileDirectory { return folder }
        let variable = toolchain.provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        if let path = toolchain.environment[variable], path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(toolchain.provider == .codex ? ".codex" : ".claude", isDirectory: true)
    }

    /// "Max" from the CLI's own lower-case `max`.
    public static func planName(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// The plan as the headline says it: the CLI's own word with the harness's name before it ("Claude Max" from `max`), and not
    /// said twice when the CLI already names the product ("Claude Pro").
    static func planTitle(_ plan: String, harness name: String) -> String {
        plan.lowercased().hasPrefix(name.lowercased()) ? planName(plan) : "\(name) \(planName(plan))"
    }

    /// The health of a CLI that was found, from what the toolchain says of it and the probe's `reading` (nil: the ask gave
    /// nothing). Pure: `HarnessHealthChecker` supplies the inputs.
    public static func evaluate(provider: ManagedSession.Provider, toolchain: ProviderToolchain, reading: HarnessReading?,
                                at now: Date) -> HarnessHealth {
        let name = HarnessCapabilities.intrinsic(of: provider).displayName
        let status = HarnessVersionTable.status(of: toolchain.capabilities, provider: provider)
        var health = HarnessHealth(
            provider: provider, state: .ready, headline: "Ready", executable: toolchain.executable,
            version: toolchain.capabilities.claudeVersion ?? reading?.version.flatMap(Self.parse),
            versionStatus: status, profileDirectory: profileDirectory(of: toolchain),
            account: reading?.account, limitsReadable: reading.map { !$0.windows.isEmpty }, checkedAt: now)
        if status == .belowMinimum {
            health.state = .attention
            health.headline = "Update needed"
            health.note = "This \(name) is older than Sphyrna can work with. Update it, then choose Check Again."
            return health
        }
        switch (provider, reading?.account) {
        case (_, HarnessAccount.none?):
            return health.signedOut()
        case (.claude, nil) where reading?.windows.isEmpty == true, (_, nil) where reading == nil:
            // A check that answered nothing, or Claude's that named no account, is unknown: only an explicit `.none` account
            // says nobody is signed in, so a signed-in user is never told to sign in.
            health.state = .attention
            health.headline = "Could not check"
            health.note = "Sphyrna could not read \(name)'s answer. Choose Check Again."
            return health
        default:
            break
        }
        switch reading?.account {
        case .apiKey?: health.headline = "Ready · API key"
        case let .subscription(_, plan?)?: health.headline = "Ready · \(planTitle(plan, harness: name))"
        default: break
        }
        if status == .belowRecommended {
            health.headline += " · Update recommended"
            health.note = "Sphyrna 1.6.2 was built against \(HarnessVersionTable.table(for: provider).map { HarnessVersionTable.text($0.recommended) } ?? ""). An update is not required."
        }
        return health
    }

    private func signedOut() -> HarnessHealth {
        var health = self
        health.state = .signIn
        health.headline = "Not signed in"
        return health
    }

    /// The first `major.minor[.patch]` token of a version text.
    static func parse(_ text: String) -> [Int]? {
        ProviderCapabilities(version: text, help: "").claudeVersion
    }
}
