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
        #expect(startHandlers.first?["async"] == nil)
        #expect(startHandlers.first?["timeout"] as? Int == 1)
        for event in hooks.keys {
            let groups = try #require(hooks[event] as? [[String: Any]])
            let handlers = try #require(groups.first?["hooks"] as? [[String: Any]])
            #expect(handlers.first?["async"] == nil)
            #expect(handlers.first?["timeout"] as? Int == 1)
        }
        let endGroups = try #require(hooks["SessionEnd"] as? [[String: Any]])
        let endHandlers = try #require(endGroups.first?["hooks"] as? [[String: Any]])
        #expect(endHandlers.first?["async"] == nil)
        #expect(endHandlers.first?["timeout"] as? Int == 1)
    }

    @Test func resumeRoutesNeverFallBackToANewConversation() throws {
        let capabilities = ProviderCapabilities(
            version: "test",
            help: "--remote <ADDR> --session-id <id> --settings <settings>"
        )
        let claude = try ProviderLaunchProfile.claude(
            route: .resume("provider-session"), capabilities: capabilities,
            config: URL(fileURLWithPath: "/isolated"), environment: [:]
        )
        #expect(Array(claude.arguments.prefix(2)) == ["--resume", "provider-session"])
        #expect(!claude.arguments.contains("--session-id"))

        let codex = try ProviderLaunchProfile.codex(
            route: .remote(socket: "/tmp/app.sock", threadID: "thread-id", workingDirectory: "/tmp/project space/çalışma"),
            capabilities: capabilities, home: URL(fileURLWithPath: "/isolated"),
            environment: [:]
        )
        #expect(codex.arguments == [
            "resume", "thread-id", "--remote", "unix:///tmp/app.sock", "--cd", "/tmp/project space/çalışma",
        ])
    }

    @Test func resumeCarriesTheRecordedEffortWhenClaudeAcceptsIt() throws {
        let capable = ProviderCapabilities(version: "test", help: "--session-id <id> --settings <settings> --effort <level>")
        func arguments(_ capabilities: ProviderCapabilities, _ effort: String?) throws -> [String] {
            try ProviderLaunchProfile.claude(
                route: .resume("provider-session"), capabilities: capabilities,
                config: URL(fileURLWithPath: "/isolated"), environment: [:], effort: effort
            ).arguments
        }
        #expect(Array(try arguments(capable, "max").prefix(4)) == ["--resume", "provider-session", "--effort", "max"])
        #expect(!(try arguments(capable, nil)).contains("--effort"))
        #expect(!(try arguments(capable, "--dangerously-skip-permissions")).contains("--effort"))
        let older = ProviderCapabilities(version: "test", help: "--session-id <id> --settings <settings>")
        #expect(!(try arguments(older, "max")).contains("--effort"))
    }
}

struct ClaudeTranscriptEffortTests {
    @Test func theLastAssistantEffortInTheTailWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("effort-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let folder = projects.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "0b5f3c2a-1111-4c4c-9d9d-123456789abc"
        let records: [[String: Any]] = [
            ["type": "assistant", "effort": "high"],
            ["type": "system", "content": "Set effort level to max (this session only)"],
            ["type": "assistant", "effort": "max"],
            ["type": "user", "message": ["content": "please use effort low"], "effort": "low"],
            ["type": "assistant"],
        ]
        var text = String(repeating: "x", count: 64) + "\n"   // a line the tail may cut
        for record in records { text += String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)! + "\n" }
        try text.write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        #expect(ClaudeTranscriptEffort.last(conversationID: id, projectsDirectory: projects) == "max")
        // A newer level this build does not know ends the carry-over instead of reviving "max".
        let unknown = String(data: try JSONSerialization.data(withJSONObject: ["type": "assistant", "effort": "auto"]), encoding: .utf8)!
        try (text + unknown + "\n").write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        #expect(ClaudeTranscriptEffort.last(conversationID: id, projectsDirectory: projects) == nil)
        #expect(ClaudeTranscriptEffort.last(conversationID: "missing", projectsDirectory: projects) == nil)
        #expect(ClaudeTranscriptEffort.last(conversationID: "../-tmp-project/\(id)", projectsDirectory: projects) == nil)
    }
}
