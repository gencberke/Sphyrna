import Foundation
import Synchronization
import Testing
@testable import LoomCore

/// The harness health (D-98): the six states from fakes for the toolchain, the probe's sources and the connect switch; the
/// version table; the 5-minute floor and Check Again; the account-change mark; the setup commands. No process runs and no
/// real Claude or Codex is asked.
@Suite(.timeLimit(.minutes(2)))
struct HarnessHealthTests {
    // MARK: Fakes

    private final class Clock: @unchecked Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    /// A probe source that answers from a script and counts its asks.
    private final class Script: HarnessProbeSource, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [HarnessProbeAnswer?]
        private(set) var asks = 0

        init(_ answers: [HarnessProbeAnswer?]) { self.answers = answers }

        func read() async -> HarnessProbeAnswer? {
            lock.withLock {
                asks += 1
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }
    }

    /// The toolchain the checker resolves: a fixed one per provider, or a failure; it counts the resolutions.
    private final class Toolchains: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [ManagedSession.Provider: any Error] = [:]
        private var versions: [ManagedSession.Provider: String] = [.claude: "2.1.300 (Claude Code)", .codex: "codex-cli 0.160.0"]
        private var serverHelp = "--listen <URL>"
        private(set) var calls: [ManagedSession.Provider] = []

        func fail(_ provider: ManagedSession.Provider, with error: (any Error)?) { lock.withLock { failures[provider] = error } }
        func setVersion(_ provider: ManagedSession.Provider, _ text: String) { lock.withLock { versions[provider] = text } }
        func setServerHelp(_ text: String) { lock.withLock { serverHelp = text } }

        func resolve(_ provider: ManagedSession.Provider) throws -> ProviderToolchain {
            let (failure, version, help): ((any Error)?, String, String) = lock.withLock {
                calls.append(provider)
                return (failures[provider], versions[provider] ?? "", serverHelp)
            }
            if let failure { throw failure }
            return ProviderToolchain(
                provider: provider, executable: "/opt/fake/bin/\(HarnessHealth.command(provider))",
                capabilities: ProviderCapabilities(version: version, help: "", serverHelp: provider == .codex ? help : ""),
                environment: ["PATH": "/usr/bin:/bin"], profileDirectory: nil)
        }
    }

    private struct Rig {
        let clock = Clock()
        let connections: HarnessConnections
        let toolchains = Toolchains()
        let claude: Script
        let codex: Script
        let checker: HarnessHealthChecker

        init(claude: [HarnessProbeAnswer?] = [], codex: [HarnessProbeAnswer?] = [], connections: HarnessConnections = HarnessConnections()) {
            self.connections = connections
            self.claude = Script(claude)
            self.codex = Script(codex)
            let clock = clock, toolchains = toolchains
            let probe = HarnessProbe(connections: connections, sources: [.claude: self.claude, .codex: self.codex],
                                     clock: { clock.now })
            checker = HarnessHealthChecker(
                connections: connections, probe: probe, toolchain: { try toolchains.resolve($0) }, clock: { clock.now })
        }
    }

    private static let notFound = ProviderToolchainError.executableNotFound(provider: .claude, searched: 4)

    private func subscription(_ email: String, _ plan: String) -> HarnessProbeAnswer {
        HarnessProbeAnswer(
            account: .subscription(email: email, plan: plan),
            windows: [HarnessLimitWindow(id: "five_hour", name: "5-hour", durationMinutes: 300, usedPercent: 10, resetsAt: nil)])
    }

    // MARK: The version table

    @Test func theVersionTableJudgesBelowTheMinimumBelowTheRecommendedAndCurrent() {
        func status(_ provider: ManagedSession.Provider, _ version: String, serverHelp: String = "--listen <URL>") -> HarnessVersionStatus {
            HarnessVersionTable.status(of: ProviderCapabilities(version: version, help: "", serverHelp: serverHelp), provider: provider)
        }
        #expect(HarnessVersionTable.table(for: .claude)?.minimum == ProviderCapabilities.claudeLaunchChoicesFloor, "the oldest the capability checks accept")
        #expect(HarnessVersionTable.table(for: .claude)?.recommended == [2, 1, 300])
        #expect(HarnessVersionTable.table(for: .codex)?.recommended == [0, 160, 0])
        #expect(HarnessVersionTable.table(for: .synthetic) == nil)

        #expect(status(.claude, "1.9.9 (Claude Code)") == .belowMinimum)
        #expect(status(.claude, "2.0.0 (Claude Code)") == .belowRecommended, "the minimum itself is accepted")
        #expect(status(.claude, "2.1.299 (Claude Code)") == .belowRecommended)
        #expect(status(.claude, "2.1.300 (Claude Code)") == .current)
        #expect(status(.claude, "2.2 (Claude Code)") == .current, "a missing patch counts as 0, and newer is current")
        #expect(status(.claude, "fixture") == .unknown, "no version to judge")

        #expect(status(.codex, "codex-cli 0.159.9") == .belowRecommended)
        #expect(status(.codex, "codex-cli 0.160.0") == .current)
        #expect(status(.codex, "codex-cli 0.200.1") == .current)
        #expect(status(.codex, "codex-cli 0.160.0", serverHelp: "") == .belowMinimum, "an app-server with no --listen cannot be asked")
    }

    // MARK: Each state

    @Test func eachStateHasItsHeadline() async {
        // Ready: Claude names a subscription.
        let ready = Rig(claude: [subscription("a@example.invalid", "max")])
        let claude = await ready.checker.check(.claude)
        #expect(claude.state == .ready && claude.headline == "Ready · Claude Max")
        #expect(claude.version == [2, 1, 300] && claude.versionStatus == .current)
        #expect(claude.executable == "/opt/fake/bin/claude" && claude.limitsReadable == true)
        #expect(claude.profileDirectory?.lastPathComponent == ".claude", "the default folder when the toolchain names none")
        #expect(claude.checkedAt == ready.clock.now)

        // Not found: no ask is made of the probe.
        let missing = Rig()
        missing.toolchains.fail(.claude, with: Self.notFound)
        let install = await missing.checker.check(.claude)
        #expect(install.state == .install && install.headline == "Not found" && install.executable == nil)
        #expect(missing.claude.asks == 0, "a CLI that is not there is not asked")

        // Not signed in: Codex says nobody is; Claude answers nothing.
        let codexOut = Rig(codex: [HarnessProbeAnswer(account: HarnessAccount.none, windows: [])])
        let signedOut = await codexOut.checker.check(.codex)
        #expect(signedOut.state == .signIn && signedOut.headline == "Not signed in" && signedOut.note == nil)
        let claudeQuiet = Rig(claude: [nil])
        let silent = await claudeQuiet.checker.check(.claude)
        #expect(silent.state == .attention && silent.headline == "Could not check", "a Claude that named no account is unknown, not signed out")
        #expect(silent.note?.contains("Check Again") == true)

        // Attention: the probe failed for Codex; the CLI would not answer; below the minimum.
        let failed = Rig(codex: [nil])
        let codexFailed = await failed.checker.check(.codex)
        #expect(codexFailed.state == .attention && codexFailed.headline == "Could not check")
        let broken = Rig()
        broken.toolchains.fail(.claude, with: LoomError.environmentTimeout)
        let unreadable = await broken.checker.check(.claude)
        #expect(unreadable.state == .attention && unreadable.headline == "Could not check")
        let old = Rig(claude: [subscription("a@example.invalid", "pro")])
        old.toolchains.setVersion(.claude, "1.0.3 (Claude Code)")
        let tooOld = await old.checker.check(.claude)
        #expect(tooOld.state == .attention && tooOld.headline == "Update needed" && tooOld.versionStatus == .belowMinimum)
        #expect(old.claude.asks == 0, "a CLI below the minimum is not asked")

        // Disabled: the switch is off.
        let off = Rig(claude: [subscription("a@example.invalid", "pro")], connections: HarnessConnections(disconnected: [.claude]))
        let disabled = await off.checker.check(.claude)
        #expect(disabled.state == .disabled && disabled.headline == "Turned off")
    }

    @Test func aPlanAnApiKeyAndAnOldVersionShapeTheReadyHeadline() async {
        let api = Rig(codex: [HarnessProbeAnswer(account: .apiKey, windows: [])])
        let key = await api.checker.check(.codex)
        #expect(key.state == .ready && key.headline == "Ready · API key" && key.limitsReadable == false)

        let planless = Rig(codex: [HarnessProbeAnswer(account: .subscription(email: nil, plan: nil), windows: [])])
        #expect(await planless.checker.check(.codex).headline == "Ready")

        let behind = Rig(claude: [subscription("a@example.invalid", "max")])
        behind.toolchains.setVersion(.claude, "2.1.200 (Claude Code)")
        let recommended = await behind.checker.check(.claude)
        #expect(recommended.state == .ready, "below the recommended version is still ready")
        #expect(recommended.headline == "Ready · Claude Max · Update recommended" && recommended.versionStatus == .belowRecommended)
    }

    @Test func theEmailIsNotInAnythingTheHealthPrints() async {
        let rig = Rig(claude: [subscription("private@example.invalid", "max")])
        let health = await rig.checker.check(.claude)
        #expect(health.account == .subscription(email: "private@example.invalid", plan: "max"), "it is held in memory for the page")
        var dumped = ""
        dump(health, to: &dumped)
        for text in [String(describing: health), String(reflecting: health), dumped] {
            #expect(!text.contains("private@example"))
        }
    }

    // MARK: The floor and Check Again

    @Test func aCheckStandsForFiveMinutesAndCheckAgainBypassesIt() async {
        let rig = Rig(claude: Array(repeating: subscription("a@example.invalid", "pro"), count: 5))
        await rig.checker.check(.claude)
        #expect(rig.toolchains.calls.count == 1 && rig.claude.asks == 1)
        rig.clock.advance(299)
        await rig.checker.check(.claude)
        #expect(rig.toolchains.calls.count == 1 && rig.claude.asks == 1, "inside the floor: the last answer, nothing asked")
        #expect(await rig.checker.lastHealth(of: .claude)?.state == .ready)

        let again = await rig.checker.check(.claude, force: true)
        #expect(rig.toolchains.calls.count == 2 && rig.claude.asks == 2, "Check Again asks the toolchain and the probe now")
        #expect(again.checkedAt == rig.clock.now)

        rig.clock.advance(301)
        await rig.checker.check(.claude)
        #expect(rig.claude.asks == 3, "past the floor: asked again")
        // The floor is per harness.
        await rig.checker.check(.codex)
        #expect(rig.toolchains.calls.filter { $0 == .codex }.count == 1)
    }

    @Test func concurrentChecksShareOneRun() async {
        let rig = Rig(claude: [subscription("a@example.invalid", "pro"), subscription("a@example.invalid", "pro")])
        async let first = rig.checker.check(.claude)
        async let second = rig.checker.check(.claude, force: true)
        let (a, b) = await (first, second)
        #expect(a == b)
        #expect(rig.claude.asks == 1, "the second joined the run that was on its way")
    }

    // MARK: The switch

    @Test func offStopsTheChecksAndTheProbeAndOnChecksAtOnce() async {
        let rig = Rig(claude: Array(repeating: subscription("a@example.invalid", "pro"), count: 4),
                      codex: Array(repeating: HarnessProbeAnswer(account: .apiKey, windows: []), count: 4))
        await rig.checker.check(.claude)
        await rig.checker.check(.codex)
        let before = (rig.toolchains.calls.count, rig.claude.asks, rig.codex.asks)

        rig.connections.setConnected(.codex, false)
        let off = await rig.checker.check(.codex, force: true)
        #expect(off.state == .disabled)
        #expect(await rig.checker.lastHealth(of: .codex) == nil, "what was kept of a switched-off harness is dropped")
        #expect(rig.codex.asks == before.2 && rig.toolchains.calls.count == before.0, "no toolchain and no probe for a harness that is off")
        #expect(await rig.checker.check(.claude, force: false).state == .ready, "the other harness is not affected")
        #expect(rig.claude.asks == before.1)

        // On again, inside the floor: the kept answer was dropped, so it is checked now.
        rig.connections.setConnected(.codex, true)
        let on = await rig.checker.check(.codex)
        #expect(on.state == .ready && rig.codex.asks == before.2 + 1)
    }

    // MARK: Account change

    @Test func anotherEmailOrPlanMarksTheAccountChangedUntilItIsSeen() async {
        let rig = Rig(claude: [
            subscription("a@example.invalid", "pro"), subscription("a@example.invalid", "pro"), subscription("b@example.invalid", "pro"),
            subscription("b@example.invalid", "pro"), subscription("b@example.invalid", "max"),
        ])
        #expect(await rig.checker.check(.claude).accountChanged == false, "the first account is not a change")
        #expect(await rig.checker.check(.claude, force: true).accountChanged == false, "the same account again")
        let changed = await rig.checker.check(.claude, force: true)
        #expect(changed.accountChanged && changed.headline == "Ready · Claude Pro", "another email")
        #expect(await rig.checker.check(.claude, force: true).accountChanged, "the mark stays until the page is seen")
        await rig.checker.acknowledgeAccountChange(.claude)
        #expect(await rig.checker.lastHealth(of: .claude)?.accountChanged == false)
        #expect(await rig.checker.check(.claude).accountChanged == false, "a check inside the floor does not bring it back")
        let plan = await rig.checker.check(.claude, force: true)
        #expect(plan.accountChanged && plan.headline == "Ready · Claude Max", "another plan")
    }

    // MARK: Setup commands

    @Test func setupShowsTheVendorsCommandsAndNeverForAStateThatNeedsNone() {
        #expect(HarnessSetupCommand.command(for: .claude, state: .install)?.command == "brew install --cask claude-code")
        #expect(HarnessSetupCommand.command(for: .claude, state: .install)?.alternative == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(HarnessSetupCommand.command(for: .claude, state: .signIn)?.command == "claude auth login")
        #expect(HarnessSetupCommand.command(for: .codex, state: .install)?.command == "npm install -g @openai/codex")
        #expect(HarnessSetupCommand.command(for: .codex, state: .install)?.alternative == "brew install --cask codex")
        #expect(HarnessSetupCommand.command(for: .codex, state: .signIn)?.command == "codex login")
        #expect(HarnessSetupCommand.command(for: .codex, state: .signIn)?.title == "Sign In")
        for state in [HarnessHealthState.ready, .checking, .disabled, .attention] {
            for provider in HarnessConnections.switchable {
                #expect(HarnessSetupCommand.command(for: provider, state: state) == nil, "\(provider) \(state)")
            }
        }
        #expect(HarnessSetupCommand.command(for: .synthetic, state: .install) == nil)
    }

    @Test func theHeadlineNamesThePlanOnceWhateverFormTheCliGivesIt() async {
        func headline(_ plan: String) async -> String {
            await Rig(claude: [subscription("a@example.invalid", plan)]).checker.check(.claude).headline
        }
        #expect(await headline("max") == "Ready · Claude Max", "a lower-case plan word follows the harness's name")
        #expect(await headline("Claude Pro") == "Ready · Claude Pro", "the CLI's own words are not said twice")
    }

    @Test func deepCheckPinsTheProfileOnlyWhereTheToolchainHasOne() {
        func toolchain(_ provider: ManagedSession.Provider, profile: URL?, environment: [String: String] = [:]) -> ProviderToolchain {
            ProviderToolchain(provider: provider, executable: "/opt/fake/bin/\(HarnessHealth.command(provider))",
                              capabilities: ProviderCapabilities(version: "", help: ""),
                              environment: ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }, profileDirectory: profile)
        }
        let home = HarnessDeepCheck.environment(for: .claude, toolchain: toolchain(.claude, profile: nil))
        #expect(home["CLAUDE_CONFIG_DIR"] == nil, "the default profile is never pinned to ~/.claude")
        #expect(home["NO_COLOR"] == "1" && home["PATH"] == "/usr/bin:/bin")
        let shell = HarnessDeepCheck.environment(
            for: .claude, toolchain: toolchain(.claude, profile: nil, environment: ["CLAUDE_CONFIG_DIR": "/Users/a/.claude-work"]))
        #expect(shell["CLAUDE_CONFIG_DIR"] == "/Users/a/.claude-work", "a folder the login shell names stays as it is")
        let profile = URL(fileURLWithPath: "/Users/a/profiles/work", isDirectory: true)
        let explicit = HarnessDeepCheck.environment(for: .claude, toolchain: toolchain(.claude, profile: profile))
        #expect(explicit["CLAUDE_CONFIG_DIR"] == profile.path, "an explicit profile is pinned")
        let codex = HarnessDeepCheck.environment(for: .codex, toolchain: toolchain(.codex, profile: nil))
        #expect(codex["CODEX_HOME"]?.hasSuffix("/.codex") == true && codex["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func deepCheckNamesTheClisOwnDoctorCommand() {
        #expect(HarnessDeepCheck.display(for: .claude) == "claude doctor")
        #expect(HarnessDeepCheck.display(for: .codex) == "codex doctor --no-color")
        #expect(HarnessDeepCheck.arguments(for: .claude) == ["doctor"])
        #expect(HarnessDeepCheck.clipped(String(repeating: "x", count: 30_000)).hasSuffix("[output cut]"))
        #expect(HarnessDeepCheck.clipped("short") == "short")
    }
}
