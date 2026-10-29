import Foundation
import Testing
@testable import LoomCore

struct ProviderProfileTests {
    @Test func managedClaudeUsesNativePermissionRequestsWithoutChatBypass() throws {
        let capabilities = ProviderCapabilities(version: "2.0.0",
            help: "--settings <s> --session-id <i> --name <n> --effort <e> --permission-mode <m>")
        let choices = ClaudeLaunchChoices(permissionMode: "default", model: "opus", effort: "low")
        let managed = try ProviderLaunchProfile.claude(route: .new(UUID()), capabilities: capabilities,
            config: URL(fileURLWithPath: "/isolated"), environment: [:], choices: choices,
            opening: .init(taskTitle: "Owned task"), face: .managedTask)
        let arguments = managed.launchArguments()
        #expect(arguments.contains("--input-format") && arguments.contains("--output-format"))
        let position = try #require(arguments.firstIndex(of: "--permission-prompt-tool"))
        #expect(arguments.dropFirst(position + 1).first == "stdio")
        #expect(!arguments.contains("--allow-dangerously-skip-permissions"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(arguments.contains("--permission-mode") && arguments.contains("default"))
        #expect(arguments.contains("--model") && arguments.contains("opus"))
        #expect(arguments.contains("--effort") && arguments.contains("low"))
        #expect(!arguments.contains("--"))
        let chat = try ProviderLaunchProfile.claude(route: .new(UUID()), capabilities: capabilities,
            config: URL(fileURLWithPath: "/isolated"), environment: [:], face: .chat)
        #expect(chat.launchArguments().contains("--allow-dangerously-skip-permissions"))
    }

    @Test func approvedTaskClaudeOpeningKeepsNameAndChoicesButHasNoPositionalPrompt() throws {
        let capabilities = ProviderCapabilities(version: "2.0.0", help: "--settings <s> --session-id <i> --name <n> --effort <e>")
        let profile = try ProviderLaunchProfile.claude(route: .new(UUID()), capabilities: capabilities,
            config: URL(fileURLWithPath: "/isolated"), environment: [:],
            choices: ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "opus", effort: "high"),
            opening: .init(taskTitle: "Owned task"))
        let arguments = profile.launchArguments()
        #expect(arguments.contains("Owned task"))
        #expect(arguments.contains("--model") && arguments.contains("opus"))
        #expect(arguments.contains("--effort") && arguments.contains("high"))
        #expect(arguments.contains("--permission-mode") && arguments.contains("acceptEdits"))
        #expect(!arguments.contains("--"))

        let ordinary = try ProviderLaunchProfile.claude(route: .new(UUID()), capabilities: capabilities,
            config: URL(fileURLWithPath: "/isolated"), environment: [:],
            opening: .init(title: "Ordinary", firstMessage: "first message"))
        #expect(ordinary.launchArguments().suffix(2) == ["--", "first message"])
    }
    @Test(arguments: [HarnessMode.askBeforeEdits, .acceptEdits])
    func newCodexSafetyFlagsComeAfterExtrasAndBeforeTheFirstMessage(mode: HarnessMode) throws {
        let capabilities = ProviderCapabilities(version: "test", help: "--remote <ADDR>", serverHelp: "--listen <URL>")
        let choices = HarnessLaunchChoices(harness: .codex, mode: mode)
        let profile = try ProviderLaunchProfile.codex(route: .remote(socket: "/tmp/owned.sock", threadID: nil, workingDirectory: "/tmp/project"),
            capabilities: capabilities, home: URL(fileURLWithPath: "/tmp/home"), environment: [:], choices: choices, firstMessage: "hello")
        let extras = ["-c", "approvals_reviewer=\"auto_review\"", "-c", "sandbox_workspace_write.network_access=true"]
        let argv = profile.launchArguments(extra: extras)
        let required = ["-c", "approvals_reviewer=\"user\"", "-c", "sandbox_workspace_write.network_access=false",
                        "--", "hello"]
        #expect(Array(argv.suffix(required.count)) == required)
        #expect(!argv.contains { $0.hasPrefix("sandbox_workspace_write.writable_roots=") })
        #expect((argv.firstIndex(of: extras[1]) ?? -1) < (argv.lastIndex(of: required[1]) ?? -1))
        #expect((argv.firstIndex(of: extras[3]) ?? -1) < (argv.lastIndex(of: required[3]) ?? -1))

        let server = try ProviderLaunchProfile.codex(route: .server(socket: "/tmp/owned.sock"),
            capabilities: capabilities, home: URL(fileURLWithPath: "/tmp/home"), environment: [:], choices: choices)
        let serverSafety = ["-c", "approvals_reviewer=\"user\"", "-c", "sandbox_workspace_write.network_access=false",
                            "-c", "sandbox_workspace_write.writable_roots=[]"]
        #expect(Array(server.arguments.suffix(serverSafety.count)) == serverSafety)
    }

    @Test func codexDoesNotSilentlyRemoveCallerSuppliedArguments() throws {
        let capabilities = ProviderCapabilities(version: "test", help: "--remote <ADDR>", serverHelp: "--listen <URL>")
        let profile = try ProviderLaunchProfile.codex(route: .remote(socket: "/tmp/owned.sock", threadID: nil, workingDirectory: "/tmp/project"),
            capabilities: capabilities, home: URL(fileURLWithPath: "/tmp/home"), environment: [:],
            choices: HarnessLaunchChoices(harness: .codex, mode: .askBeforeEdits), firstMessage: "hello")
        // Construction is intentionally tested without running an incompatible CLI argument.
        let extra = ["-c", "sandbox_workspace_write.writable_roots=[\"/caller-owned\"]"]
        let argv = profile.launchArguments(extra: extra)
        #expect(Array(argv.dropFirst(profile.arguments.count).prefix(extra.count)) == extra)
    }

    @Test func rejectsUnknownCapabilities() throws {
        let unknown = ProviderCapabilities(version: "unknown", help: "")
        #expect(throws: (any Error).self) {
            try ProviderLaunchProfile.codex(route: .direct, capabilities: unknown, home: URL(fileURLWithPath: "/isolated"), environment: [:])
        }
        // Claude's help is text that can change shape: a start is not refused for an option it does
        // not list (Claude's own error is what the user sees); the drift is reported separately.
        let id = UUID()
        let profile = try ProviderLaunchProfile.claude(capabilities: unknown, config: URL(fileURLWithPath: "/isolated"), sessionID: id, environment: [:])
        #expect(profile.arguments.starts(with: ["--session-id", id.uuidString, "--settings"]))
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(capabilities: unknown, route: .new(id))
            == ["--settings", "--session-id"])
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(capabilities: unknown, route: .resume("x"))
            == ["--settings"])
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(
            capabilities: unknown, route: .new(id), opening: .init(title: "t", firstMessage: "m"))
            == ["--settings", "--session-id", "--name"])
        let listed = ProviderCapabilities(version: "x", help: "--settings <s> --session-id <i> --name <n>")
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(
            capabilities: listed, route: .new(id), opening: .init(title: "t", firstMessage: "m")).isEmpty)
        #expect(listed.detectedClaudeOptions == ["--settings", "--session-id", "--name"])
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
            // The subagent list under a card (D-39); no per-tool hooks.
            "SubagentStart", "SubagentStop",
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

struct ClaudeTranscriptModelTests {
    private func write(_ records: [[String: Any]], id: String, to projects: URL) throws {
        let folder = projects.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = String(repeating: "x", count: 64) + "\n"   // a line the tail may cut
        for record in records { text += String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)! + "\n" }
        try text.write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    @Test func theLastRealAssistantModelWinsAndSyntheticOnesSayNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let id = "0b5f3c2a-2222-4c4c-9d9d-123456789abc"
        try write([
            ["type": "assistant", "message": ["model": "claude-opus-5-5"]],
            ["type": "assistant", "message": ["model": "claude-haiku-5-5"]],
            ["type": "user", "message": ["model": "claude-sonnet-5-5", "content": "model"]],
            ["type": "assistant", "message": ["model": "<synthetic>"]],
            ["type": "assistant"],
        ], id: id, to: projects)
        #expect(ClaudeTranscriptModel.last(conversationID: id, projectsDirectory: projects) == "claude-haiku-5-5")
        #expect(ClaudeTranscriptModel.last(conversationID: "missing", projectsDirectory: projects) == nil)
        #expect(ClaudeTranscriptModel.last(conversationID: "../-tmp-project/\(id)", projectsDirectory: projects) == nil)
        try write([["type": "assistant", "message": ["model": "<synthetic>"]]], id: id, to: projects)
        #expect(ClaudeTranscriptModel.last(conversationID: id, projectsDirectory: projects) == nil)
    }
}

struct ClaudeDefaultModelTests {
    @Test func theDefaultIsTheSettingsModelElseTheEnvironmentsAndAnAliasMatchesByFamily() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("default-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ClaudeDefaultModel.configured(configDirectory: root, environment: [:]) == nil)
        #expect(ClaudeDefaultModel.configured(configDirectory: root, environment: ["ANTHROPIC_MODEL": "sonnet"]) == "sonnet")
        try Data(#"{"model": "opus[1m]"}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
        #expect(ClaudeDefaultModel.configured(configDirectory: root, environment: ["ANTHROPIC_MODEL": "sonnet"]) == "opus[1m]")
        try Data("not json".utf8).write(to: root.appendingPathComponent("settings.json"))
        #expect(ClaudeDefaultModel.configured(configDirectory: root, environment: [:]) == nil)

        #expect(ClaudeDefaultModel.matches(default: "opus[1m]", transcriptModel: "claude-opus-5-5"))
        #expect(ClaudeDefaultModel.matches(default: "opus", transcriptModel: "claude-opus-4-1-20250805"))
        #expect(ClaudeDefaultModel.matches(default: "sonnet", transcriptModel: "claude-3-5-sonnet-20241022"))
        #expect(!ClaudeDefaultModel.matches(default: "opus[1m]", transcriptModel: "claude-haiku-5-5"))
        #expect(ClaudeDefaultModel.matches(default: "claude-opus-5-5[1m]", transcriptModel: "claude-opus-5-5"))
        #expect(!ClaudeDefaultModel.matches(default: "claude-opus-5-5", transcriptModel: "claude-opus-4-1"))
        #expect(!ClaudeDefaultModel.matches(default: "default", transcriptModel: "claude-opus-5-5"))
        #expect(!ClaudeDefaultModel.matches(default: "opusplan", transcriptModel: "claude-opus-5-5"))
    }

    // MARK: Side chat fork (V22)

    @Test func aForkRouteResumesTheParentIntoANewIdAndAnAskRuleIsALaunchSetting() throws {
        let fork = UUID().uuidString.lowercased()
        let capabilities = ProviderCapabilities(
            version: "test", help: "--session-id <id> --settings <settings> --fork-session --permission-mode <mode>")
        #expect(capabilities.supportsForkSession)
        var choices = ClaudeLaunchChoices()
        choices.permissionMode = ClaudePermissionMode.askBeforeEdits.rawValue
        let profile = try ProviderLaunchProfile.claude(
            route: .fork(parent: "parent-conv", newID: fork), capabilities: capabilities, config: URL(fileURLWithPath: "/isolated"),
            environment: [:], choices: choices, face: .chat, askRules: ["Write", "Bash"])
        let arguments = profile.arguments
        let at = try #require(arguments.firstIndex(of: "--resume"))
        #expect(Array(arguments[at...].prefix(5)) == ["--resume", "parent-conv", "--fork-session", "--session-id", fork])
        #expect(arguments.contains("--permission-mode"))
        let settings = try #require(arguments.drop(while: { $0 != "--settings" }).dropFirst().first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        #expect((object["permissions"] as? [String: Any])?["ask"] as? [String] == ["Write", "Bash"])
        // No ask rules, no permissions entry: a main session's settings are what they were.
        let plain = try ProviderLaunchProfile.claude(
            route: .resume("conv"), capabilities: capabilities, config: URL(fileURLWithPath: "/isolated"), environment: [:])
        let plainSettings = try #require(plain.arguments.drop(while: { $0 != "--settings" }).dropFirst().first)
        #expect(!plainSettings.contains("permissions"))
    }

    @Test func aForkRouteRefusesWhatTheCLITakesNoCardFor() throws {
        let capabilities = ProviderCapabilities(version: "test", help: "--session-id <id> --settings <settings> --fork-session")
        let config = URL(fileURLWithPath: "/isolated")
        // Not a UUID: the CLI exits before any output, so the start is refused before a card exists.
        #expect(throws: (any Error).self) {
            try ProviderLaunchProfile.claude(route: .fork(parent: "p", newID: "not-a-uuid"), capabilities: capabilities,
                                             config: config, environment: [:])
        }
        #expect(throws: (any Error).self) {
            try ProviderLaunchProfile.claude(route: .fork(parent: "", newID: UUID().uuidString), capabilities: capabilities,
                                             config: config, environment: [:])
        }
        // A fork never carries a first message on the command line.
        #expect(throws: (any Error).self) {
            try ProviderLaunchProfile.claude(route: .fork(parent: "p", newID: UUID().uuidString), capabilities: capabilities,
                                             config: config, environment: [:], opening: .init(title: "t", firstMessage: "m"))
        }
        let id = UUID()
        let unknown = ProviderCapabilities(version: "unknown", help: "")
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(capabilities: unknown, route: .fork(parent: "p", newID: id.uuidString))
            == ["--settings", "--session-id", "--fork-session"])
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(capabilities: capabilities, route: .fork(parent: "p", newID: id.uuidString))
            .isEmpty)
        #expect(capabilities.detectedClaudeOptions.contains("--fork-session"))
    }

    // MARK: A subagent's words on the Chat stream (R4)

    @Test func aChatSpawnPassesForwardSubagentTextExactlyWhenTheHelpListsItOnEveryRouteAndTheTerminalNever() throws {
        let base = "--session-id <id> --settings <settings> --fork-session --permission-mode <mode>"
        let listing = ProviderCapabilities(version: "2.1.300 (Claude Code)", help: base + " --forward-subagent-text")
        let plain = ProviderCapabilities(version: "2.1.300 (Claude Code)", help: base)
        #expect(listing.supportsForwardSubagentText)
        #expect(!plain.supportsForwardSubagentText)
        let config = URL(fileURLWithPath: "/isolated")
        let routes: [ProviderLaunchProfile.ClaudeRoute] = [
            .new(UUID()), .resume("parent-conv"), .fork(parent: "parent-conv", newID: UUID().uuidString.lowercased()),
        ]
        for route in routes {
            let chat = try ProviderLaunchProfile.claude(
                route: route, capabilities: listing, config: config, environment: [:], face: .chat)
            #expect(chat.launchArguments().filter { $0 == "--forward-subagent-text" }.count == 1, "\(route)")
            // A CLI that does not list it starts as before, with no error.
            let without = try ProviderLaunchProfile.claude(
                route: route, capabilities: plain, config: config, environment: [:], face: .chat)
            #expect(!without.launchArguments().contains("--forward-subagent-text"), "\(route)")
            // The terminal face never carries it: the TUI shows a subagent's words itself.
            let terminal = try ProviderLaunchProfile.claude(
                route: route, capabilities: listing, config: config, environment: [:], face: .terminal)
            #expect(!terminal.launchArguments().contains("--forward-subagent-text"), "\(route)")
        }
    }
}
