import Foundation

/// Every harness Sphyrna knows, in the order Settings → Connections shows them (D-98, FB6-13): Claude, Codex, opencode,
/// agy, pi. One place describes each harness's command, mark, setup lines, profile folder, version table and capabilities,
/// so a gate asks this instead of its own `switch provider` table.
///
/// opencode, agy and pi are described here from their own `--help` (27 Oct); P1's `SPIKE.md` is not written yet, so their
/// install lines, profile variables and version tables are marked "to confirm" and each becomes startable through its own
/// slice (E1–E3). opencode and agy are frozen for 1.8.0 (D-120): `comingLater` marks them, and taking that line out of a
/// row lets the harness start again. A harness that is not on the PATH reads Not found and its switch is disabled; Claude and Codex are on
/// when found, the others off until switched on (FB6-13, FEEDBACK-7 Q8).
public enum HarnessCatalogue {
    /// The catalogue, in Connections' order.
    public static let all: [HarnessDescriptor] = [claude, codex, opencode, agy, pi]

    /// The descriptor of `id`, nil for an id this build does not describe (an unknown harness).
    public static func descriptor(for id: HarnessID) -> HarnessDescriptor? {
        byID[id]
    }

    public static var ids: [HarnessID] { all.map(\.id) }

    private static let byID: [HarnessID: HarnessDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })

    // MARK: The five rows

    private static let claude = HarnessDescriptor(
        id: .claude,
        displayName: "Claude",
        command: "claude",
        mark: "harness-claude",
        install: HarnessSetupCommand(title: "Install", command: "brew install --cask claude-code",
                                     alternative: "curl -fsSL https://claude.ai/install.sh | bash"),
        signIn: HarnessSetupCommand(title: "Sign In", command: "claude auth login", alternative: nil),
        doctorArguments: ["doctor"],
        docs: URL(string: "https://docs.claude.com/en/docs/claude-code"),
        profileVariable: "CLAUDE_CONFIG_DIR",
        profileFolder: ".claude",
        versions: HarnessVersionTable(minimum: ProviderCapabilities.claudeLaunchChoicesFloor, recommended: [2, 1, 300]),
        pinsDefaultProfile: false,
        capabilities: HarnessCapabilities.intrinsic(ofHarness: HarnessID.claude),
        onWhenFound: true,
        startable: true,
        provider: .claude,
        showsOnboardingWhenMissing: true,
        modes: [.ask, .askBeforeEdits, .acceptEdits, .plan, .auto, .fullAccess],
        agentModes: [.askBeforeEdits, .acceptEdits, .plan, .auto],
        defaultMode: .askBeforeEdits, defaultEfforts: ClaudeLaunchChoices.effortLevels, sharesCrossHarnessModes: true,
        transcriptFormat: .claudeJSONL)

    private static let codex = HarnessDescriptor(
        id: .codex,
        displayName: "Codex",
        command: "codex",
        mark: "harness-codex-template",
        markFallback: "harness-codex",
        install: HarnessSetupCommand(title: "Install", command: "npm install -g @openai/codex",
                                     alternative: "brew install --cask codex"),
        signIn: HarnessSetupCommand(title: "Sign In", command: "codex login", alternative: nil),
        doctorArguments: ["doctor", "--no-color"],
        docs: URL(string: "https://developers.openai.com/codex/cli"),
        profileVariable: "CODEX_HOME",
        profileFolder: ".codex",
        versions: HarnessVersionTable(minimum: nil, recommended: [0, 160, 0]),
        requiresAppServerListen: true,
        pinsDefaultProfile: true,
        capabilities: HarnessCapabilities.intrinsic(ofHarness: HarnessID.codex),
        onWhenFound: true,
        startable: true,
        provider: .codex,
        markRendering: .template,
        showsOnboardingWhenMissing: true,
        modes: [.askBeforeEdits, .acceptEdits],
        agentModes: [.askBeforeEdits, .acceptEdits],
        defaultMode: .askBeforeEdits, sharesCrossHarnessModes: true, transcriptFormat: .codexRolloutJSONL,
        // Both modes run its commands in the seatbelt sandbox with the network off (`CodexLaunchSettings`), which
        // denies the helper's Unix-socket connect (`SessionChannelSandbox`).
        sessionChannelBlocked: .init(modes: [.askBeforeEdits, .acceptEdits], reason: SessionChannelSandbox.codexReason))

    /// opencode 2.2.0 (2.1.4 when P1 was planned). Install lines and the profile variable are to confirm; `opencode auth
    /// login` is its own `auth --help`'s. It has no doctor yet: `opencode debug config` prints the whole resolved config,
    /// provider keys and MCP tokens included, and Deep Check shows a doctor's output on screen. P1 names a safe one.
    private static let opencode = HarnessDescriptor(
        id: .opencode,
        displayName: "opencode",
        command: "opencode",
        mark: "harness-opencode",
        install: HarnessSetupCommand(title: "Install", command: "curl -fsSL https://opencode.ai/install | bash",
                                     alternative: "brew install sst/tap/opencode"),
        signIn: HarnessSetupCommand(title: "Sign In", command: "opencode auth login", alternative: nil),
        doctorArguments: nil,
        docs: URL(string: "https://opencode.ai/docs/cli"),
        profileVariable: "OPENCODE_CONFIG_DIR",
        profileFolder: ".config/opencode",
        capabilities: HarnessCapabilities.intrinsic(ofHarness: HarnessID.opencode),
        onWhenFound: false,
        startable: false,
        comingLater: true,
        markRendering: .luminanceMask)

    /// agy (Antigravity CLI) 1.4.5. Its `--help` lists no install or sign-in subcommand and no doctor. The default profile
    /// root is checked against native event paths; no profile override variable is assumed.
    private static let agy = HarnessDescriptor(
        id: .agy,
        displayName: "agy",
        command: "agy",
        mark: "harness-agy",
        docs: URL(string: "https://antigravity.google/docs/cli/reference"),
        profileFolder: ".gemini/antigravity-cli",
        capabilities: HarnessCapabilities.intrinsic(ofHarness: HarnessID.agy),
        onWhenFound: false,
        startable: true,
        comingLater: true,
        provider: .agy,
        markRendering: .template,
        modes: [.acceptEdits, .auto, .plan], agentModes: [.acceptEdits, .auto, .plan])

    /// pi 0.85.1. Its `--help` lists no sign-in or doctor command and no profile variable; `pi auth check` needs a
    /// provider or a model, so it is not a doctor. Its mark follows the reference's boxed π glyph (C3). It becomes startable
    /// through E3.
    private static let pi = HarnessDescriptor(
        id: .pi,
        displayName: "pi",
        command: "pi",
        mark: "harness-pi",
        install: HarnessSetupCommand(title: "Install", command: "npm install -g @earendil-works/pi-coding-agent",
                                     alternative: nil),
        docs: URL(string: "https://github.com/earendil-works/pi"),
        profileFolder: ".pi/agent",
        capabilities: HarnessCapabilities.intrinsic(ofHarness: HarnessID.pi),
        onWhenFound: false,
        startable: false,
        markRendering: .boxedText("π"))
}
