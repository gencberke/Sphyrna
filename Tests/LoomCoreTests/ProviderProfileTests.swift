import Foundation
import Testing
@testable import LoomCore

struct ProviderProfileTests {
    @Test func rejectsUnknownCapabilities() {
        let unknown = ProviderCapabilities(version: "unknown", help: "")
        #expect(throws: (any Error).self) {
            try ProviderLaunchProfile.codex(route: .direct, capabilities: unknown, home: URL(fileURLWithPath: "/isolated"), environment: [:])
        }
        #expect(throws: (any Error).self) {
            try ProviderLaunchProfile.claude(capabilities: unknown, config: URL(fileURLWithPath: "/isolated"), sessionID: UUID(), environment: [:])
        }
    }

    @Test func addsOnlySessionScopedProviderSettings() throws {
        let id = UUID()
        let environment = LaunchEnvironment.make(parent: ["CLAUDECODE": "1", "CODEX_HOME": "/real"], path: "/bin", runID: UUID(), sessionID: id)
        let capabilities = ProviderCapabilities(version: "test", help: "--no-daemon --remote <ADDR> --session-id <id> --settings <settings>")
        let claude = try ProviderLaunchProfile.claude(capabilities: capabilities, config: URL(fileURLWithPath: "/isolated"), sessionID: id, environment: environment)
        #expect(claude.environment["CLAUDECODE"] == nil)
        #expect(claude.environment["CODEX_HOME"] == nil)
        #expect(claude.environment["CLAUDE_CODE_DISABLE_AGENT_VIEW"] == "1")
        #expect(claude.arguments.contains("{\"crossSessionInbound\":\"refuse\"}"))
        let codex = try ProviderLaunchProfile.codex(route: .direct, capabilities: capabilities, home: URL(fileURLWithPath: "/isolated"), environment: environment)
        #expect(codex.arguments == ["--no-daemon"])
        #expect(codex.environment["CODEX_HOME"] == "/isolated")
    }

    @Test func claudeHookSettingsUseOneAuthenticatedCommandTransport() throws {
        let id = UUID()
        let capabilities = ProviderCapabilities(
            version: "test", help: "--session-id <id> --settings <settings>"
        )
        let profile = try ProviderLaunchProfile.claude(
            capabilities: capabilities,
            config: URL(fileURLWithPath: "/isolated"),
            sessionID: id,
            environment: [:],
            hooks: ClaudeHookLaunchConfiguration(
                helperPath: "/Applications/Loom.app/Contents/MacOS/loom-hook",
                socketPath: "/tmp/loom-hook.sock",
                authenticationToken: "secret"
            )
        )
        #expect(profile.environment["LOOM_HOOK_SOCKET"] == "/tmp/loom-hook.sock")
        #expect(profile.environment["LOOM_HOOK_TOKEN"] == "secret")
        let settingsIndex = try #require(profile.arguments.firstIndex(of: "--settings"))
        let settings = try #require(
            JSONSerialization.jsonObject(with: Data(profile.arguments[settingsIndex + 1].utf8))
                as? [String: Any]
        )
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == [
            "SessionStart", "UserPromptSubmit", "Stop", "StopFailure",
            "Notification", "PermissionRequest", "SessionEnd",
        ])
        let startGroups = try #require(hooks["SessionStart"] as? [[String: Any]])
        let startHandlers = try #require(startGroups.first?["hooks"] as? [[String: Any]])
        #expect(startHandlers.first?["command"] as? String == "/Applications/Loom.app/Contents/MacOS/loom-hook")
        #expect(startHandlers.first?["async"] as? Bool == true)
        let endGroups = try #require(hooks["SessionEnd"] as? [[String: Any]])
        let endHandlers = try #require(endGroups.first?["hooks"] as? [[String: Any]])
        #expect(endHandlers.first?["async"] == nil)
        #expect(endHandlers.first?["timeout"] as? Int == 1)
    }
}
