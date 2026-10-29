import Foundation
import Testing
@testable import LoomCore

/// V07: what the first send of a draft hands the runtime: the launch arguments (mode, model, message, title),
/// the branch or worktree it creates (in temporary Git repositories only), and the runtime path that starts
/// the session with them. Nothing here touches a real repository or a real Claude.
struct NewSessionLaunchProfileTests {
    private let listed = ProviderCapabilities(
        version: "2.1.300 (Claude Code)",
        help: "--settings <settings> --session-id <id> -n, --name <name> --effort <level> --permission-mode <mode> --model <model>")
    private let config = URL(fileURLWithPath: "/cfg")

    private func arguments(
        _ route: ProviderLaunchProfile.ClaudeRoute = .new(UUID()), _ capabilities: ProviderCapabilities? = nil,
        choices: ClaudeLaunchChoices, effort: String? = nil, opening: ProviderLaunchProfile.ClaudeOpening? = nil
    ) throws -> [String] {
        try ProviderLaunchProfile.claude(
            route: route, capabilities: capabilities ?? listed, config: config, environment: [:], effort: effort,
            choices: choices, opening: opening
        ).launchArguments()
    }

    private func arguments(_ capabilities: ProviderCapabilities, choices: ClaudeLaunchChoices) throws -> [String] {
        try arguments(.new(UUID()), capabilities, choices: choices)
    }

    @Test func modeAndModelGoBeforeTheSettingsAndTheMessageStaysLast() throws {
        let id = UUID()
        let all = try arguments(
            .new(id), choices: ClaudeLaunchChoices(permissionMode: "plan", model: "haiku"),
            opening: .init(title: "PAY-418 Add the note", firstMessage: "-- do it"))
        #expect(all.starts(with: ["--session-id", id.uuidString, "--permission-mode", "plan", "--model", "haiku", "--settings"]))
        #expect(all.suffix(2) == ["--", "-- do it"], "the message is the last argument, guarded against a leading dash")
        let name = try #require(all.firstIndex(of: "-n"))
        #expect(all[name + 1] == "PAY-418 Add the note")
        // Nothing chosen: exactly the arguments of today.
        let plain = try arguments(.new(id), choices: ClaudeLaunchChoices())
        #expect(!plain.contains("--permission-mode") && !plain.contains("--model"))
        #expect(plain.count == 4 && plain.starts(with: ["--session-id", id.uuidString, "--settings"]))
        // Either one alone.
        #expect(try arguments(choices: ClaudeLaunchChoices(model: "opus")).contains("--model"))
        #expect(!(try arguments(choices: ClaudeLaunchChoices(model: "opus"))).contains("--permission-mode"))
    }

    @Test func aValidatedModelEffortIsNotDroppedByTheClaudeLaunchBridge() throws {
        let model = ModelCatalogEntry(harness: .claude, id: "opus", title: "Opus", efforts: ["low", "turbo"])
        let choices = HarnessLaunchChoices(model: model.id, effort: "turbo", mode: .plan)
        try choices.validate(models: [model])
        let args = try arguments(choices: #require(choices.claudeChoices))
        let index = try #require(args.firstIndex(of: "--effort"))
        #expect(args[index + 1] == "turbo")
        #expect(throws: (any Error).self) { try arguments(choices: ClaudeLaunchChoices(effort: "--unsafe")) }
    }

    @Test func aDraftWithoutATitleLeavesTheNamingToClaude() throws {
        let args = try arguments(choices: ClaudeLaunchChoices(), opening: .init(title: "", firstMessage: "fix the flaky test"))
        #expect(!args.contains("-n"))
        #expect(args.suffix(2) == ["--", "fix the flaky test"])
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(
            capabilities: ProviderCapabilities(version: "x", help: ""), route: .new(UUID()),
            opening: .init(title: "", firstMessage: "m")) == ["--settings", "--session-id"])
    }

    @Test func aResumePassesTheSessionsModeAndModelAndTheRecordedEffort() throws {
        let args = try arguments(
            .resume("provider-id"), choices: ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "opus"), effort: "high")
        #expect(args.starts(with: ["--resume", "provider-id", "--effort", "high", "--permission-mode", "acceptEdits", "--model", "opus"]))
        #expect(!(try arguments(.resume("provider-id"), choices: ClaudeLaunchChoices())).contains("--model"))
    }

    @Test func aFlagIsGatedByVersionNotByTheHelpText() throws {
        // Help that lists nothing, a version in the 2.x line: both options are passed.
        let unlisted = ProviderCapabilities(version: "2.1.300 (Claude Code)", help: "")
        #expect(unlisted.claudeAcceptsPermissionMode && unlisted.claudeAcceptsModel)
        #expect(try arguments(unlisted, choices: ClaudeLaunchChoices(permissionMode: "plan", model: "haiku"))
            .contains("--permission-mode"))
        // Help that lists them, an unreadable version: also passed (the CLI itself says it takes them).
        let fixture = ProviderCapabilities(version: "fake 1", help: "--permission-mode <mode> --model <model>")
        #expect(fixture.claudeAcceptsPermissionMode && fixture.claudeAcceptsModel)
        // Neither: a choice the user made is refused, never dropped quietly.
        let old = ProviderCapabilities(version: "1.0.9 (Claude Code)", help: "")
        #expect(!old.claudeAcceptsPermissionMode && !old.claudeAcceptsModel)
        #expect(throws: (any Error).self) { try arguments(old, choices: ClaudeLaunchChoices(permissionMode: "plan")) }
        #expect(throws: (any Error).self) { try arguments(old, choices: ClaudeLaunchChoices(model: "opus")) }
        #expect(try arguments(old, choices: ClaudeLaunchChoices()).count == 4, "no choice, no refusal")
        // The version reads the first dotted token.
        #expect(ProviderCapabilities(version: "2.1.300 (Claude Code)", help: "").cliVersion == [2, 1, 300])
        #expect(ProviderCapabilities(version: "fake-provider 1 claude_config=/x/1.2", help: "").cliVersion == nil)
        #expect(ProviderCapabilities(version: "2.0", help: "").claudeVersionAtLeast([2, 0, 0]))
        #expect(!ProviderCapabilities(version: "1.99.9", help: "").claudeVersionAtLeast([2, 0, 0]))
    }

    @Test func valuesThatCouldPassForOptionsAreRefused() throws {
        for bad in ["--dangerously-skip-permissions", "plan --model x", "", "a;b", String(repeating: "x", count: 81)] {
            #expect(throws: (any Error).self) { try arguments(choices: ClaudeLaunchChoices(permissionMode: bad)) }
            #expect(throws: (any Error).self) { try arguments(choices: ClaudeLaunchChoices(model: bad)) }
        }
        for good in ["plan", "bypassPermissions", "claude-haiku-4-5", "opus[1m]", "claude-3.7:beta"] {
            #expect(ClaudeLaunchChoices.isSafeToken(good))
        }
        #expect(ClaudePermissionMode.askBeforeEdits.rawValue == "default" && ClaudePermissionMode.fullAccess.rawValue == "bypassPermissions")
    }
}
