import Foundation
import Testing
@testable import LoomCore

struct HarnessDraftRuntimeTests {
    @Test func aBareClaudeStartChangesLastHarnessWithoutErasingPriorClaudeChoices() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let oldClaude = ManagedSession(provider: .claude, workingDirectory: folder.path)
        let oldCodex = ManagedSession(provider: .codex, workingDirectory: folder.path)
        try await context.catalog.insertSession(oldClaude, projectID: project.id)
        try await context.catalog.insertSession(oldCodex, projectID: project.id)
        let remembered = ClaudeLaunchChoices(permissionMode: "plan", model: "opus", effort: "high")
        try await context.catalog.recordLaunchChoices(remembered, sessionID: oldClaude.id)
        try await context.catalog.recordLaunchChoices(HarnessLaunchChoices(harness: .codex, model: "codex-test"),
                                                      sessionID: oldCodex.id)
        #expect(try await context.catalog.lastUsedHarnessChoices()[project.id.uuidString]?.lastHarness == .codex)
        let launched = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        let result = try #require(await context.catalog.lastUsedHarnessChoices()[project.id.uuidString])
        #expect(result.lastHarness == .claude && result.choices(for: .claude)?.claudeChoices == remembered)
        #expect((try await context.catalog.lastUsedLaunchChoices()[project.id.uuidString]) == remembered)
        #expect((try await context.runtime.stopConversation(sessionID: launched.sessionID)).succeeded)
    }

    @Test func aFailedBareStartDoesNotChangeTheLastHarness() async throws {
        let context = try await SessionRuntimeTests.makeContext(executableOverride: "/no-such-c4-executable")
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let codex = ManagedSession(provider: .codex, workingDirectory: folder.path)
        try await context.catalog.insertSession(codex, projectID: project.id)
        try await context.catalog.recordLaunchChoices(HarnessLaunchChoices(harness: .codex), sessionID: codex.id)
        await #expect(throws: (any Error).self) {
            _ = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        }
        #expect(try await context.catalog.lastUsedHarnessChoices()[project.id.uuidString]?.lastHarness == .codex)
    }

    @Test func mismatchedDraftIsRefusedBeforeWorkspaceMutationOrSessionCreation() async throws {
        let repository = try await GitWorkspaceTests.makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let project = try await context.catalog.addProject(path: repository.project).project
        let draft = NewSessionLaunch(firstMessage: "go", choices: HarnessLaunchChoices(harness: .codex, model: "codex-test"),
                                     workspace: .newWorktree("c4-no-start"))
        let before = try await context.catalog.sessions().map(\.session.id)
        do {
            _ = try await context.runtime.startConversation(provider: .claude, projectID: project.id, draft: draft)
            Issue.record("A Codex draft must not be routed into Claude")
        } catch {}
        #expect(try await context.catalog.sessions().map(\.session.id) == before)
        #expect(!FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(".claude/worktrees/c4-no-start").path))
    }
}
