import Foundation
import Testing
@testable import LoomCore

/// Codex sandboxes every mode Sphyrna starts it in with the network off, which blocks the session channel's Unix socket;
/// the reason follows the launch settings, and the Codex discovery entry offers no command the session cannot run.
struct SessionChannelSandboxTests {
    @Test func everyCodexModeThatSandboxesBlocksTheChannelAndClaudeNeverDoes() throws {
        let codexModes = try #require(HarnessCatalogue.descriptor(for: .codex)?.modes)
        #expect(!codexModes.isEmpty)
        for mode in codexModes {
            let settings = try CodexLaunchSettings(HarnessLaunchChoices(harness: .codex, mode: mode))
            #expect(settings.sandbox != nil, "\(mode) runs Codex in a sandbox")
            #expect(settings.terminalArguments.contains("sandbox_workspace_write.network_access=false"))
            #expect(SessionChannelSandbox.blockedReason(harness: .codex, mode: mode) == SessionChannelSandbox.codexReason)
        }
        #expect(SessionChannelSandbox.blockedReason(harness: .codex, mode: nil) != nil, "a start without a mode asks before edits")
        for mode in HarnessMode.allCases {
            #expect(SessionChannelSandbox.blockedReason(harness: .claude, mode: mode) == nil)
        }
        #expect(SessionChannelSandbox.blockedReason(harness: .claude, mode: nil) == nil)
        #expect(SessionChannelSandbox.codexReason == "Codex's sandbox in this mode blocks Sphyrna's session channel")
    }

    @Test func theCodexDiscoveryEntryNamesTheBlockAndAdvertisesNoChannelCommand() {
        let text = SessionTaskSkill.content
        #expect(text.contains(SessionChannelSandbox.codexReason))
        for command in ["$SPHYRNA_CLI", "--help", "task input", "task report", "inbox --"] {
            #expect(!text.contains(command), "the entry does not offer \(command)")
        }
        let description = text.split(separator: "\n").first { $0.hasPrefix("description: ") }
        #expect(description.map { $0.dropFirst("description: ".count).count <= 300 } == true)
    }

    @Test func onlyADeniedConnectNamesTheSandbox() {
        let denied = ClaudeHookTransportError.system(operation: "connect", code: EPERM)
        let codex = SessionChannelSandbox.helperConnectFailure(denied, environment: ["CODEX_SANDBOX_NETWORK_DISABLED": "1"])
        #expect(codex?.hasPrefix("error: \(SessionChannelSandbox.codexReason);") == true)
        #expect(SessionChannelSandbox.helperConnectFailure(denied, environment: [:])?.contains("A sandbox blocks") == true)
        let missing = ClaudeHookTransportError.system(operation: "connect", code: ENOENT)
        #expect(SessionChannelSandbox.helperConnectFailure(missing, environment: ["CODEX_SANDBOX_NETWORK_DISABLED": "1"]) == nil,
                "a socket that is not there is not the sandbox")
        #expect(SessionChannelSandbox.helperConnectFailure(ClaudeHookTransportError.timeout("reply"), environment: [:]) == nil)
    }
}
