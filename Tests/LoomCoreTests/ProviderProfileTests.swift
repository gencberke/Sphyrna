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
}
