import AppKit
import Foundation
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// Settings → Connections and Home's "Connect your agents" (D-98): the page's values for Claude ready, Codex not found and Codex not
/// signed in; the switch through the health model and a reload of the preferences; the setup commands and the re-check on the next
/// activation; Home's cards and compact card; the seven tabs' fit. No view is drawn, no process runs, and no real Claude or Codex
/// is asked.
@MainActor
struct ConnectionsTests {
    // MARK: Fakes

    final class Script: HarnessProbeSource, @unchecked Sendable {
        private let lock = NSLock()
        private let answer: HarnessProbeAnswer?
        private var count = 0
        init(_ answer: HarnessProbeAnswer?) { self.answer = answer }
        var asks: Int { lock.withLock { count } }
        func read() async -> HarnessProbeAnswer? {
            lock.withLock { count += 1 }
            return answer
        }
    }

    nonisolated static func toolchain(_ provider: ManagedSession.Provider, version: String? = nil) -> ProviderToolchain {
        ProviderToolchain(
            provider: provider, executable: "/opt/fake/bin/\(HarnessHealth.command(provider))",
            capabilities: ProviderCapabilities(
                version: version ?? (provider == .codex ? "codex-cli 0.160.0" : "2.1.300 (Claude Code)"), help: "",
                serverHelp: provider == .codex ? "--listen <URL>" : ""),
            environment: ["PATH": "/usr/bin:/bin"], profileDirectory: nil)
    }

    static let max = HarnessProbeAnswer(
        account: .subscription(email: "a@example.invalid", plan: "max"),
        windows: [HarnessLimitWindow(id: "five_hour", name: "5-hour", durationMinutes: 300, usedPercent: 10, resetsAt: nil)])

    struct Rig {
        let connections: HarnessConnections
        let claude: Script
        let codex: Script
        let model: HarnessHealthModel

        @MainActor init(claude: HarnessProbeAnswer? = ConnectionsTests.max, claudeFound: Bool = true,
                        codex: HarnessProbeAnswer? = nil, codexFound: Bool = false,
                        connections: HarnessConnections = HarnessConnections()) {
            self.connections = connections
            self.claude = Script(claude)
            self.codex = Script(codex)
            let probe = HarnessProbe(connections: connections, sources: [.claude: self.claude, .codex: self.codex])
            let checker = HarnessHealthChecker(connections: connections, probe: probe, toolchain: { provider in
                if (provider == .claude && !claudeFound) || (provider == .codex && !codexFound) {
                    throw ProviderToolchainError.executableNotFound(provider: provider, searched: 3)
                }
                return ConnectionsTests.toolchain(provider)
            })
            model = HarnessHealthModel(connections: connections, checker: checker)
        }
    }

    // MARK: The page model

    @Test func theRowAndDetailForClaudeReady() async {
        let rig = Rig()
        rig.model.checkAll()
        await rig.model.settle()
        let health = rig.model.health(of: .claude)
        let row = ConnectionsContent.row(for: health, connected: true, startNote: nil)
        #expect(row.name == "Claude" && row.version == "2.1.300" && row.headline == "Ready · Claude Max")
        #expect(row.accessibilityLabel == "Claude, Ready · Claude Max", "the row reads its name and headline; the switch is its own element")
        let detail = ConnectionsContent.detail(for: health)
        #expect(detail.location == "/opt/fake/bin/claude" && detail.path == "/opt/fake/bin/claude")
        #expect(detail.version == "2.1.300 · up to date")
        #expect(detail.account == "a@example.invalid · Max", "the email is shown here, in the detail")
        #expect(detail.profile?.hasSuffix(".claude") == true && detail.limits == "Readable")
        #expect(detail.checked == "Checked just now")
        #expect(detail.setup == nil && detail.canDeepCheck && detail.deepCheckCommand == "claude doctor")
    }

    @Test func theRowAndDetailForCodexNotFoundAndNotSignedIn() async {
        let missing = Rig()
        missing.model.checkAll()
        await missing.model.settle()
        let note = CatalogModel.newSessionUnavailableReason(.codex, startable: [.claude])
        #expect(note != nil, "a production build cannot start Codex sessions")
        let health = missing.model.health(of: .codex)
        let row = ConnectionsContent.row(for: health, connected: true, startNote: note)
        #expect(row.version == "—" && row.headline == "Not found")
        #expect(row.accessibilityLabel == "Codex, Not found, \(note ?? "")")
        let detail = ConnectionsContent.detail(for: health)
        #expect(detail.path == nil && detail.location == "Not found on your terminal's PATH")
        #expect(detail.version == "—" && detail.account == "—" && detail.limits == "Not checked yet")
        #expect(detail.setup?.command == "npm install -g @openai/codex" && detail.setup?.alternative == "brew install --cask codex")
        #expect(!detail.canDeepCheck, "there is nothing to run")

        let signedOut = Rig(codex: HarnessProbeAnswer(account: HarnessAccount.none, windows: []), codexFound: true)
        signedOut.model.checkAll()
        await signedOut.model.settle()
        let out = signedOut.model.health(of: .codex)
        let outDetail = ConnectionsContent.detail(for: out)
        #expect(out.state == .signIn && out.headline == "Not signed in")
        #expect(outDetail.account == "Nobody is signed in" && outDetail.setup?.command == "codex login")
        #expect(outDetail.version == "0.160.0 · up to date" && outDetail.canDeepCheck)
        #expect(outDetail.deepCheckCommand == "codex doctor --no-color")
    }

    @Test func aChangedAccountShowsOnTheRowUntilThePageIsSeen() async {
        let rig = Rig()
        rig.model.check(.claude)
        await rig.model.settle()
        var health = rig.model.health(of: .claude)
        health.accountChanged = true
        let row = ConnectionsContent.row(for: health, connected: true, startNote: nil)
        #expect(row.showsAccountChanged && row.accessibilityLabel == "Claude, Ready · Claude Max, Account changed")
    }

    // MARK: The switch

    @Test func offStopsChecksAndProbesAndSurvivesAReloadOfThePreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-connections-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("p.json")
        let store = UIPreferencesStore(url: url)
        // The same wiring the app makes: the switch starts from the stored flags and a change goes back to the file.
        let connections = HarnessConnections(disconnected: store.current.disconnectedHarnesses) { provider, connected in
            MainActor.assumeIsolated { _ = try? store.update { $0.setHarnessConnected(provider, connected) } }
        }
        let rig = Rig(codex: HarnessProbeAnswer(account: .apiKey, windows: []), codexFound: true, connections: connections)
        rig.model.checkAll()
        await rig.model.settle()
        #expect(rig.model.health(of: .claude).state == .ready && rig.model.health(of: .codex).state == .ready)
        let asks = (rig.claude.asks, rig.codex.asks)

        rig.model.setConnected(.claude, false)
        await rig.model.settle()
        #expect(rig.model.health(of: .claude).state == .disabled && rig.model.health(of: .claude).headline == "Turned off")
        rig.model.checkAll(force: true)
        rig.model.checkAgain(.claude)
        await rig.model.settle()
        #expect(rig.claude.asks == asks.0, "off: not checked and not probed, even by Check Again")
        #expect(rig.codex.asks == asks.1 + 1, "the other harness is checked as before")
        #expect(rig.model.healths.map(\.state) == [.disabled, .ready])

        // A reload of the preferences: the switch is still off, and a new health model leaves Claude alone.
        let reread = UIPreferencesStore(url: url)
        #expect(reread.current.disconnectedHarnesses == [.claude])
        let reloaded = Rig(connections: HarnessConnections(disconnected: reread.current.disconnectedHarnesses))
        reloaded.model.checkAll()
        await reloaded.model.settle()
        #expect(reloaded.claude.asks == 0 && reloaded.model.health(of: .claude).state == .disabled)

        rig.model.setConnected(.claude, true)
        await rig.model.settle()
        #expect(rig.model.health(of: .claude).state == .ready && rig.claude.asks == asks.0 + 1, "on again: checked at once")
        #expect(UIPreferencesStore(url: url).current.disconnectedHarnesses.isEmpty)
    }

    // MARK: Setup and the re-check

    @Test func copyAndOpenTerminalShowTheCommandAndTheNextActivationChecksAgainOnce() async {
        let rig = Rig(claude: nil, claudeFound: true)
        var copied: [String] = []
        var opened = 0
        rig.model.copyToPasteboard = { copied.append($0) }
        rig.model.openTerminalApp = { opened += 1; return true }

        rig.model.appBecameActive()
        await rig.model.settle()
        #expect(rig.model.health(of: .claude).state == .signIn, "found, and nobody is signed in")
        let asks = rig.claude.asks
        let command = HarnessSetupCommand.command(for: .claude, state: .signIn)
        #expect(command?.command == "claude auth login")

        rig.model.appBecameActive()
        await rig.model.settle()
        #expect(rig.claude.asks == asks, "an activation inside the floor asks nothing")

        // Copy, then Open Terminal: nothing is run, and the next activation asks once, past the floor.
        if let command { rig.model.copy(command, for: .claude) }
        rig.model.openTerminal(for: .claude)
        #expect(copied == ["claude auth login"] && opened == 1)
        #expect(rig.model.rechecksOnActivation == [.claude])
        rig.model.appBecameActive()
        await rig.model.settle()
        #expect(rig.claude.asks == asks + 1, "bypassed the floor")
        #expect(rig.model.rechecksOnActivation.isEmpty)
        rig.model.appBecameActive()
        await rig.model.settle()
        #expect(rig.claude.asks == asks + 1, "once: the next activation stands under the floor again")
    }

    @Test func theCheckTriggersAreThePageActivationAndASessionRunAllUnderTheFloor() async {
        let rig = Rig()
        rig.model.pageOpened()
        await rig.model.settle()
        #expect(rig.claude.asks == 1)
        rig.model.sessionRunChanged()
        rig.model.appBecameActive()
        rig.model.pageOpened()
        await rig.model.settle()
        #expect(rig.claude.asks == 1, "all under the 5-minute floor")
        rig.model.checkAgain(.claude)
        await rig.model.settle()
        #expect(rig.claude.asks == 2, "Check Again bypasses it")
    }

    @Test func theSwitchHelpSaysSessionsKeepWorkingAndNamesSphyrna() {
        #expect(ConnectionsContent.switchHelp.contains("Sessions that exist keep working") && !ConnectionsContent.switchHelp.contains("Loom"))
        #expect(ConnectionsContent.switchHelp.contains("never signs the CLI out"))
    }

    // MARK: Seven tabs

    @Test func sevenTabsFitTheBand() {
        let sections = SettingsSection.available(cleanupReview: true)
        #expect(sections.map(\.title) == ["General", "Connections", "Theme", "Usage", "Sessions", "Remora", "About"])
        #expect(SettingsSection.available(cleanupReview: false).map(\.title) == ["General", "Connections", "Theme", "Usage", "Remora", "About"])
        let width = SettingsBand.tabsWidth(of: sections.map(\.title))
        #expect(width <= SettingsBand.tabsRoom, "seven tabs take \(Int(width)) pt of the \(Int(SettingsBand.tabsRoom)) pt the band leaves")
        #expect(SettingsBand.tabsRoom <= LoomTheme.Settings.width)
        // The window keeps its size: nothing about the tabs widened it.
        #expect(LoomTheme.Settings.width == 680)
        // Without Connections the same band took less: the new tab costs its label and one gap.
        let six = SettingsBand.tabsWidth(of: sections.filter { $0 != .connections }.map(\.title))
        #expect(width > six && width - six < 120)
    }
}
