import AppKit
import Foundation
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// Shared by `ConnectionsTests` and the tests of other tiers that reuse its fixtures (DEVELOPMENT §3.1).
enum ConnectionsRig {
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

        @MainActor init(claude: HarnessProbeAnswer? = ConnectionsRig.max, claudeFound: Bool = true,
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
                return ConnectionsRig.toolchain(provider)
            })
            model = HarnessHealthModel(connections: connections, checker: checker)
        }
    }

    final class Script: HarnessProbeSource, @unchecked Sendable {
        let lock = NSLock()
        let answer: HarnessProbeAnswer?
        var count = 0
        init(_ answer: HarnessProbeAnswer?) { self.answer = answer }
        var asks: Int { lock.withLock { count } }
        func read() async -> HarnessProbeAnswer? {
            lock.withLock { count += 1 }
            return answer
        }
    }
}
