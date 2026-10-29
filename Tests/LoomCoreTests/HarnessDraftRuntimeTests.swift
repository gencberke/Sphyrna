import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct HarnessDraftRuntimeTests {
    @Test(arguments: [HarnessMode.askBeforeEdits, .acceptEdits])
    func aNewCodexMessageCannotInheritAutomaticReviewOrBroaderWorkspace(mode: HarnessMode) async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_GLOBAL_WIDENED": "1"])
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("hostile-default", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .codex, projectID: project.id, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "under requested permissions", choices: HarnessLaunchChoices(harness: .codex, mode: mode)))
        screen.attach(launch.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo under requested permissions"))
        let line = try String(contentsOf: context.state.appendingPathComponent("codex-turn-permissions.log"), encoding: .utf8)
        let permission = try #require(JSONSerialization.jsonObject(with: Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any])
        #expect(permission["reviewer"] as? String == "user")
        #expect(permission["networkAccess"] as? Bool == false)
        #expect(permission["writableRoots"] as? [String] == [])
        let required = ["-c", "approvals_reviewer=\"user\"", "-c", "sandbox_workspace_write.network_access=false",
                        "-c", "sandbox_workspace_write.writable_roots=[]"]
        let serverLine = try String(contentsOf: context.state.appendingPathComponent("codex-server-arguments.log"), encoding: .utf8)
        let server = try #require(JSONSerialization.jsonObject(with: Data(serverLine.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String])
        #expect(Array(server.suffix(required.count)) == required)
        let tuiLine = try String(contentsOf: context.state.appendingPathComponent("codex-tui-arguments.log"), encoding: .utf8)
        let tui = try #require(JSONSerialization.jsonObject(with: Data(tuiLine.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String])
        let end = try #require(tui.firstIndex(of: "--"))
        let tuiSafety = ["-c", "approvals_reviewer=\"user\"", "-c", "sandbox_workspace_write.network_access=false"]
        #expect(end >= tuiSafety.count && Array(tui[(end - tuiSafety.count)..<end]) == tuiSafety)
        #expect(!tui.contains { $0.hasPrefix("sandbox_workspace_write.writable_roots=") })
        #expect(Array(tui.suffix(2)) == ["--", "under requested permissions"])
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aNewDefaultCodexDraftUsesSafePermissionsBeforeItsFirstMessage() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_GLOBAL_FULL": "1"])
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("safe-default", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .codex, projectID: project.id, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "first under safe permissions", choices: HarnessLaunchChoices(harness: .codex)))
        screen.attach(launch.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo first under safe permissions"))
        let identity = try #require(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID)
        let atTurn = try String(contentsOf: context.state.appendingPathComponent("codex-turn-settings.log"), encoding: .utf8)
        #expect(atTurn.split(separator: "\n").map(String.init) == ["\(identity) read-only on-request"])
        let requested = try await context.catalog.launchChoices(sessionID: launch.sessionID)
        #expect(requested.model == nil && requested.effort == nil && requested.permissionMode == nil)
        let arguments = try String(contentsOf: context.state.appendingPathComponent("codex-tui-arguments.log"), encoding: .utf8)
        let argv = try #require(JSONSerialization.jsonObject(with: Data(arguments.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String])
        #expect(!argv.contains("-m") && !argv.contains { $0.hasPrefix("model_reasoning_effort=") })
        let serverLine = try String(contentsOf: context.state.appendingPathComponent("codex-server-arguments.log"), encoding: .utf8)
        let serverArgv = try #require(JSONSerialization.jsonObject(with: Data(serverLine.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String])
        #expect(serverArgv.contains("sandbox_mode=\"read-only\"") && serverArgv.contains("approval_policy=\"on-request\""))
        #expect(!serverArgv.contains { $0.hasPrefix("model=") || $0.hasPrefix("model_reasoning_effort=") })
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func codexDraftStartsWithItsChoicesAndFirstMessageThenResumesItsIdentity() async throws {
        let model = ModelCatalogEntry(harness: .codex, id: "fake-codex-alpha", title: "Fake Codex",
                                      efforts: ["low", "high"], defaultEffort: "low", isDefault: true)
        let context = try await SessionRuntimeTests.makeContext(openedModels: { _ in [model] })
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("codex-draft", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let choices = HarnessLaunchChoices(harness: .codex, model: model.id, effort: "high", mode: .acceptEdits)
        let draft = NewSessionLaunch(firstMessage: "first from draft", choices: choices)
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .codex, projectID: project.id,
                                                                  outputSink: screen, draft: draft)
        screen.attach(launch.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo first from draft"))
        let firstArguments = try String(contentsOf: context.state.appendingPathComponent("codex-tui-arguments.log"), encoding: .utf8)
        let first = try #require(firstArguments.split(separator: "\n").first)
        let argv = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String])
        #expect(argv.contains("-m") && argv.contains(model.id) && argv.contains("model_reasoning_effort=\"high\""))
        #expect(argv.contains("workspace-write") && argv.contains("on-request"))
        #expect(Array(argv.suffix(2)) == ["--", "first from draft"])
        let serverLine = try String(contentsOf: context.state.appendingPathComponent("codex-server-arguments.log"), encoding: .utf8)
        let serverArgv = try #require(JSONSerialization.jsonObject(with: Data(serverLine.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String])
        #expect(serverArgv.contains("model=\"\(model.id)\"") && serverArgv.contains("model_reasoning_effort=\"high\""))
        #expect(serverArgv.contains("sandbox_mode=\"workspace-write\"") && serverArgv.contains("approval_policy=\"on-request\""))
        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        let identity = try #require(record.session.providerConversationID)
        #expect(record.session.provider == .codex)
        let stored = try await context.catalog.launchChoices(sessionID: launch.sessionID)
        #expect(stored.model == model.id && stored.effort == "high" && stored.permissionMode == "acceptEdits")
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        let resumedScreen = SessionRuntimeTests.Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: resumedScreen)
        resumedScreen.attach(resumed.terminal)
        #expect(await resumedScreen.contains("RESUMED-CODEX \(identity)"))
        let argumentLines = try String(contentsOf: context.state.appendingPathComponent("codex-tui-arguments.log"), encoding: .utf8)
            .split(separator: "\n")
        #expect(argumentLines.count == 2)
        let resumeArgv = try #require(JSONSerialization.jsonObject(with: Data(argumentLines.last!.utf8)) as? [String])
        #expect(!resumeArgv.contains("-m") && !resumeArgv.contains("-s") && !resumeArgv.contains("-a"))
        let turns = try String(contentsOf: context.state.appendingPathComponent("codex-joins.log"), encoding: .utf8)
        #expect(turns.split(separator: "\n").filter { $0.hasPrefix("turn-start ") }.count == 1)
        #expect(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID == identity)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aSafeActualModeResumesWithoutReplacingAnUnknownStoredMode() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeCodexTests.launchCodex(context)
        try await screen.send("work 5")
        #expect(await screen.contains("CODEX-TURN-DONE completed echo work 5"))
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        // Seed a future raw value as an older catalog could have stored it.
        try await context.catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "future-codex-mode"),
                                                      sessionID: launch.sessionID, rememberingInProject: false)
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID)
        #expect(resumed.sessionID == launch.sessionID)
        #expect(try await context.catalog.launchChoices(sessionID: launch.sessionID).permissionMode == "future-codex-mode")
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func nativeSafeSettingsSurviveResumeWithoutChangingRequestedChoices() async throws {
        let model = ModelCatalogEntry(harness: .codex, id: "fake-codex-alpha", title: "Fake Codex",
                                      efforts: ["low", "high"], defaultEffort: "low", isDefault: true)
        let context = try await SessionRuntimeTests.makeContext(openedModels: { _ in [model] })
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("native-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let choices = HarnessLaunchChoices(harness: .codex, model: model.id, effort: "high", mode: .acceptEdits)
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .codex, projectID: project.id, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "persist this thread", choices: choices))
        screen.attach(launch.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo persist this thread"))
        let identity = try #require(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID)
        try await screen.send("/settings-safe")
        #expect(await screen.contains("SETTINGS-SAVED /settings-safe"))
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        let resumedScreen = SessionRuntimeTests.Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: resumedScreen)
        resumedScreen.attach(resumed.terminal)
        #expect(await resumedScreen.contains("RESUMED-CODEX \(identity)"))
        let data = try Data(contentsOf: context.state.appendingPathComponent("codex-thread-\(identity).settings"))
        let actual = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(actual["model"] as? String == "fake-codex-beta" && actual["effort"] as? String == "low")
        #expect(actual["sandbox"] as? String == "read-only" && actual["approval"] as? String == "on-request")
        let effective = try #require(await context.runtime.codexResumeSettings(forSession: launch.sessionID))
        #expect(effective.model == "fake-codex-beta" && effective.effort == "low" && effective.mode == .askBeforeEdits)
        let joins = try String(contentsOf: context.state.appendingPathComponent("codex-joins.log"), encoding: .utf8)
            .split(separator: "\n").filter { $0.hasPrefix("join ") }
        #expect(!joins.isEmpty && joins.allSatisfy { $0.hasSuffix(" excludeTurns,threadId") })
        let requested = try await context.catalog.launchChoices(sessionID: launch.sessionID)
        #expect(requested.model == model.id && requested.effort == "high" && requested.permissionMode == "acceptEdits")
        #expect(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID == identity)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["/settings-full", "/settings-unknown", "/settings-network", "/settings-roots", "/settings-never", "/settings-reviewer"])
    func unverifiedActualPermissionsAreRefusedBeforeLaunchingTheResumeTUI(command: String) async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeCodexTests.launchCodex(context)
        try await screen.send("work 5")
        #expect(await screen.contains("CODEX-TURN-DONE completed echo work 5"))
        try await screen.send(command)
        #expect(await screen.contains("SETTINGS-SAVED \(command)"))
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        let arguments = context.state.appendingPathComponent("codex-tui-arguments.log")
        let before = try String(contentsOf: arguments, encoding: .utf8)
        do {
            _ = try await context.runtime.resumeConversation(sessionID: launch.sessionID)
            Issue.record("Unverified permissions must be refused before launching the TUI")
            _ = try? await context.runtime.stopConversation(sessionID: launch.sessionID)
        } catch {
            #expect(String(describing: error).contains("permission"))
        }
        #expect(try String(contentsOf: arguments, encoding: .utf8) == before)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["wrong", "wrong-cwd"])
    func resumeRefusesADifferentIdentityOrWorkingDirectoryBeforeTUI(mode: String) async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": mode])
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeCodexTests.launchCodex(context)
        try await screen.send("work 5")
        #expect(await screen.contains("CODEX-TURN-DONE completed echo work 5"))
        let identity = try #require(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        let arguments = context.state.appendingPathComponent("codex-tui-arguments.log")
        let before = try String(contentsOf: arguments, encoding: .utf8)
        do {
            _ = try await context.runtime.resumeConversation(sessionID: launch.sessionID)
            Issue.record("A different identity or directory must be refused before launching the TUI")
            _ = try? await context.runtime.stopConversation(sessionID: launch.sessionID)
        } catch {
            #expect(String(describing: error).contains(mode == "wrong" ? "identity" : "directory"))
        }
        #expect(try String(contentsOf: arguments, encoding: .utf8) == before)
        #expect(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID == identity)
        #expect((await context.runtime.shutdown()).succeeded)
    }

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

    @Test(arguments: ["stay", "branch", "worktree"])
    func aCodexDraftStartsInItsSelectedWorkspace(kind: String) async throws {
        let repository = try await GitWorkspaceTests.makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let project = try await context.catalog.addProject(path: repository.project).project
        let workspace: SessionWorkspace = switch kind {
        case "branch": .newBranch("codex-branch")
        case "worktree": .newWorktree("codex-worktree")
        default: .projectFolder
        }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .codex, projectID: project.id, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "workspace once", choices: HarnessLaunchChoices(harness: .codex), workspace: workspace))
        screen.attach(launch.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo workspace once"))
        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        let expected = kind == "worktree" ? repository.project + "/.claude/worktrees/codex-worktree" : repository.project
        #expect(realPath(URL(fileURLWithPath: record.session.workingDirectory)) == realPath(URL(fileURLWithPath: expected)))
        #expect(screen.snapshot.contains("cwd=\(realPath(URL(fileURLWithPath: expected)))"))
        #expect(try await GitWorkspaceTests.branch(record.session.workingDirectory) ==
                (kind == "branch" ? "codex-branch" : kind == "worktree" ? "codex-worktree" : "main"))
        #expect(try await GitWorkspaceTests.branch(repository.project) == (kind == "branch" ? "codex-branch" : "main"))
        let turns = try String(contentsOf: context.state.appendingPathComponent("codex-joins.log"), encoding: .utf8)
        #expect(turns.split(separator: "\n").filter { $0.hasPrefix("turn-start ") }.count == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["branch", "worktree"])
    func aCodexTUIFailureUndoesOnlyItsNewWorkspace(kind: String) async throws {
        let repository = try await GitWorkspaceTests.makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_EXIT_AT_START": "1"])
        defer { context.cleanup() }
        let project = try await context.catalog.addProject(path: repository.project).project
        let workspace: SessionWorkspace = kind == "branch" ? .newBranch("failed-codex") : .newWorktree("failed-codex")
        await #expect(throws: (any Error).self) {
            _ = try await context.runtime.startConversation(provider: .codex, projectID: project.id,
                draft: NewSessionLaunch(firstMessage: "go", choices: HarnessLaunchChoices(harness: .codex), workspace: workspace))
        }
        #expect(try await GitWorkspaceTests.branch(repository.project) == "main")
        #expect(try await GitWorkspaceTests.branches(repository.project) == ["main"])
        #expect(!FileManager.default.fileExists(atPath: repository.project + "/.claude/worktrees/failed-codex"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["full", "unknown-mode", "nul"])
    func invalidCodexInputsAreRefusedBeforeWorkspaceOrSpawn(kind: String) async throws {
        let repository = try await GitWorkspaceTests.makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let project = try await context.catalog.addProject(path: repository.project).project
        let mode: HarnessMode? = kind == "full" ? .fullAccess : kind == "unknown-mode" ? .plan : .askBeforeEdits
        let draft = NewSessionLaunch(firstMessage: kind == "nul" ? "before\0after" : "go",
            choices: HarnessLaunchChoices(harness: .codex, mode: mode), workspace: .newBranch("must-not-exist"))
        await #expect(throws: (any Error).self) {
            _ = try await context.runtime.startConversation(provider: .codex, projectID: project.id, draft: draft)
        }
        #expect(try await context.catalog.sessions().isEmpty)
        #expect(try await GitWorkspaceTests.branch(repository.project) == "main")
        #expect(try await GitWorkspaceTests.branches(repository.project) == ["main"])
        #expect(!FileManager.default.fileExists(atPath: context.state.appendingPathComponent("codex-tui-arguments.log").path))
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
