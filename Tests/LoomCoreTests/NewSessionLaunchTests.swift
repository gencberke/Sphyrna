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

/// The branch or worktree of the strip, made in temporary repositories.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GitWorkspaceTests {
    /// A repository with one commit on `main`, in a temporary folder the caller removes.
    static func makeRepository(subfolder: String? = nil) async throws -> (root: URL, project: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-git-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = "/usr/bin/git"
        _ = try await GitWorkspace.run(git, ["-C", root.path, "init", "-q", "-b", "main"], timeout: 20)
        _ = try await GitWorkspace.run(git, ["-C", root.path, "config", "user.email", "test@example.com"], timeout: 20)
        _ = try await GitWorkspace.run(git, ["-C", root.path, "config", "user.name", "Test"], timeout: 20)
        _ = try await GitWorkspace.run(git, ["-C", root.path, "config", "commit.gpgsign", "false"], timeout: 20)
        var project = root
        if let subfolder {
            project = root.appendingPathComponent(subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        try "one\n".write(to: project.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitWorkspace.run(git, ["-C", root.path, "add", "."], timeout: 20)
        _ = try await GitWorkspace.run(git, ["-C", root.path, "commit", "-q", "-m", "first"], timeout: 20)
        return (root, project.path)
    }

    static func branch(_ folder: String) async throws -> String {
        try await GitWorkspace.run("/usr/bin/git", ["-C", folder, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func branches(_ folder: String) async throws -> [String] {
        try await GitWorkspace.run("/usr/bin/git", ["-C", folder, "branch", "--format=%(refname:short)"], timeout: 20)
            .split(separator: "\n").map(String.init).sorted()
    }

    @Test func stayingTouchesNothing() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await GitWorkspace.prepare(.projectFolder, projectFolder: project) == project)
        #expect(try await Self.branches(project) == ["main"])
    }

    @Test func aNewBranchIsMadeInTheProjectFolderAndCheckedOut() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await GitWorkspace.prepare(.newBranch("feat/PAY-418-note"), projectFolder: project)
        #expect(folder == project)
        #expect(try await Self.branch(project) == "feat/PAY-418-note")
        #expect(try await Self.branches(project) == ["feat/PAY-418-note", "main"])
    }

    @Test func aNewWorktreeIsItsOwnFolderUnderTheProjectsClaudeFolder() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await GitWorkspace.prepare(.newWorktree("feat/PAY-418-note"), projectFolder: project)
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: project).resolvingSymlinksInPath().path + "/.claude/worktrees/feat-PAY-418-note"
        #expect(real == expected)
        #expect(FileManager.default.fileExists(atPath: folder + "/file.txt"))
        #expect(try await Self.branch(folder) == "feat/PAY-418-note")
        #expect(try await Self.branch(project) == "main", "the project folder stays where it was")
    }

    @Test func aProjectInsideTheRepositoryStartsAtTheSamePlaceInItsWorktree() async throws {
        let (root, project) = try await Self.makeRepository(subfolder: "apps/api")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await GitWorkspace.prepare(.newWorktree("wt"), projectFolder: project)
        #expect(folder.hasSuffix("/.claude/worktrees/wt/apps/api"))
        #expect(FileManager.default.fileExists(atPath: folder + "/file.txt"))
    }

    @Test func aTakenOrInvalidNameOrAFolderThatIsNoRepositoryFailsAndChangesNothing() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitWorkspace.prepare(.newBranch("taken"), projectFolder: project)
        _ = try await GitWorkspace.run("/usr/bin/git", ["-C", project, "switch", "-q", "main"], timeout: 20)
        await #expect(throws: GitWorkspace.Failure.branchExists("taken")) {
            _ = try await GitWorkspace.prepare(.newBranch("taken"), projectFolder: project)
        }
        await #expect(throws: GitWorkspace.Failure.branchExists("taken")) {
            _ = try await GitWorkspace.prepare(.newWorktree("taken"), projectFolder: project)
        }
        for bad in ["bad name", "-x", "a..b", "x~1", ""] {
            await #expect(throws: GitWorkspace.Failure.invalidBranchName(bad)) {
                _ = try await GitWorkspace.prepare(.newBranch(bad), projectFolder: project)
            }
        }
        #expect(try await Self.branch(project) == "main")
        #expect(try await Self.branches(project) == ["main", "taken"])
        #expect(!FileManager.default.fileExists(atPath: project + "/.claude"))

        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nogit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        await #expect(throws: GitWorkspace.Failure.notARepository(plain.path)) {
            _ = try await GitWorkspace.prepare(.newBranch("x"), projectFolder: plain.path)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: plain.path).isEmpty)
    }

    // MARK: Undo after a failed start

    @Test func undoPutsTheBranchBackAndDeletesTheNewOne() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitWorkspace.run("/usr/bin/git", ["-C", project, "switch", "-q", "-c", "work"], timeout: 20)
        let prepared = try await GitWorkspace.begin(.newBranch("feat/x"), projectFolder: project)
        #expect(try await Self.branch(project) == "feat/x")
        #expect(await GitWorkspace.undo(prepared).isEmpty)
        #expect(try await Self.branch(project) == "work", "back on the branch it was on")
        #expect(try await Self.branches(project) == ["main", "work"])
        let status = try await GitWorkspace.run("/usr/bin/git", ["-C", project, "status", "--porcelain"], timeout: 20)
        #expect(status.isEmpty)
        // The name is free again: a retry works.
        _ = try await GitWorkspace.prepare(.newBranch("feat/x"), projectFolder: project)
        #expect(try await Self.branch(project) == "feat/x")
    }

    @Test func undoOfABranchStartedOnADetachedHeadReturnsToTheCommit() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitWorkspace.run("/usr/bin/git", ["-C", project, "switch", "-q", "--detach"], timeout: 20)
        let prepared = try await GitWorkspace.begin(.newBranch("feat/x"), projectFolder: project)
        #expect(await GitWorkspace.undo(prepared).isEmpty)
        #expect(try await Self.branch(project) == "HEAD")
        #expect(try await Self.branches(project).contains("feat/x") == false)
    }

    @Test func undoRemovesTheWorktreeItsBranchAndTheFoldersItMade() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await GitWorkspace.begin(.newWorktree("feat/x"), projectFolder: project)
        #expect(FileManager.default.fileExists(atPath: prepared.folder))
        #expect(await GitWorkspace.undo(prepared).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: prepared.folder))
        #expect(!FileManager.default.fileExists(atPath: project + "/.claude"), "the folders this start made go with it")
        #expect(try await Self.branches(project) == ["main"])
        let list = try await GitWorkspace.run("/usr/bin/git", ["-C", project, "worktree", "list", "--porcelain"], timeout: 20)
        #expect(list.components(separatedBy: "worktree ").count == 2, "only the project's own worktree is left")
        // A folder that was there before stays.
        try FileManager.default.createDirectory(atPath: project + "/.claude", withIntermediateDirectories: true)
        let again = try await GitWorkspace.begin(.newWorktree("feat/x"), projectFolder: project)
        #expect(await GitWorkspace.undo(again).isEmpty)
        #expect(FileManager.default.fileExists(atPath: project + "/.claude"))
        #expect(!FileManager.default.fileExists(atPath: project + "/.claude/worktrees"))
    }

    @Test func whatCannotBeUndoneIsReportedAndNothingIsForced() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await GitWorkspace.begin(.newBranch("feat/x"), projectFolder: project)
        // Someone moved to another branch and deleted the new one meanwhile: deleting it fails and says so.
        _ = try await GitWorkspace.run("/usr/bin/git", ["-C", project, "switch", "-q", "main"], timeout: 20)
        _ = try await GitWorkspace.run("/usr/bin/git", ["-C", project, "branch", "-D", "feat/x"], timeout: 20)
        let problems = await GitWorkspace.undo(prepared)
        #expect(problems.count == 1 && problems[0].contains("feat/x"), "\(problems)")
        #expect(await GitWorkspace.undo(try await GitWorkspace.begin(.projectFolder, projectFolder: project)).isEmpty)
    }

    // MARK: A hook that does not let go

    /// `post-checkout` hook of the scratch repository (the one Git runs for `switch -c`).
    private static func installHook(_ body: String, in project: String) throws {
        let hook = URL(fileURLWithPath: project).appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\n\(body)\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    private static func killSleepers(_ marker: String) {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "sleep \(marker)"]
        try? kill.run()
        kill.waitUntilExit()
    }

    @Test func aHookThatLeavesABackgroundChildHoldingThePipeDoesNotHangTheCall() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root); Self.killSleepers("598") }
        try Self.installHook("sleep 598 &", in: project)
        let began = Date()
        _ = try await GitWorkspace.begin(.newBranch("feat/x"), projectFolder: project)
        #expect(Date().timeIntervalSince(began) < 10, "git is done; a child that kept the pipe is not waited for")
        #expect(try await Self.branch(project) == "feat/x")
    }

    @Test func aHookThatNeverReturnsTimesOutAfterThirtySecondsAndLeavesNoHungRead() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root); Self.killSleepers("597") }
        try Self.installHook("sleep 597 &\nsleep 597", in: project)
        let began = Date()
        await #expect(throws: GitWorkspace.Failure.git("Git did not answer in time.")) {
            _ = try await GitWorkspace.begin(.newBranch("feat/x"), projectFolder: project)
        }
        let took = Date().timeIntervalSince(began)
        #expect(took > 25 && took < 45, "took \(took) s")
        // The switch had been made when the hook hung: it is put back (without running the hook again).
        #expect(try await Self.branch(project) == "main", "the repository is back on its branch")
        #expect(!(try await GitWorkspace.run("/usr/bin/git", ["-C", project, "branch", "--list", "feat/x"], timeout: 10))
            .contains("feat/x"), "and the new branch is gone")
    }

    @Test func theOutputIsCappedWhileItIsRead() async throws {
        let (root, project) = try await Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = String(repeating: "0123456789abcdef\n", count: 20_000)
        try big.write(to: URL(fileURLWithPath: project).appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let out = try await GitWorkspace.run("/bin/cat", [project + "/big.txt"], timeout: 20)
        #expect(out.utf8.count == 65_536)
    }

    @Test func manyGitStepsAtOnceDoNotStarveTheAsyncPool() async throws {
        // More steps than the pool can grow to (libdispatch adds threads while the pool's own are blocked, up to a
        // limit of a few dozen), each waiting a second and a half for its child (`sleep` stands in for a git that is
        // slow, or hung on a hook). The wait must not hold a thread of the pool.
        let steps = 140
        let began = ContinuousClock.now
        let running = (0..<steps).map { _ in
            Task { try await GitWorkspace.run("/bin/sleep", ["1.5"], timeout: 20) }
        }
        try await Task.sleep(for: .milliseconds(300))
        // Other async work still starts at once: a task of the pool is not queued behind the waiting steps.
        let asked = ContinuousClock.now
        let answered = await Task.detached { ContinuousClock.now }.value
        #expect(answered - asked < .milliseconds(750), "a task waited \(answered - asked) for a thread of the pool")
        for step in running { _ = try await step.value }
        // All the waits overlapped.
        #expect(ContinuousClock.now - began < .seconds(8), "\(steps) steps took \(ContinuousClock.now - began)")
    }

    @Test func aFolderNameIsOneSafeComponent() {
        #expect(GitWorkspace.folderName(for: "feat/PAY-418-note") == "feat-PAY-418-note")
        #expect(GitWorkspace.folderName(for: "../..") == "session")
        #expect(GitWorkspace.folderName(for: "ç/ş") == "session")
    }
}

/// The runtime path: a draft's first send starts Claude with the message, mode, model, title and folder.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct NewSessionRuntimeTests {
    /// A stand-in for the CLI that records its arguments, then becomes the fixture.
    private static func recordingExecutable(in root: URL) throws -> String {
        let fake = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        let script = root.appendingPathComponent("claude-recorder")
        let text = """
        #!/bin/sh
        case "$1" in --version|--help) exec "\(fake)" "$@";; esac
        printf '%s\\n' "$@" > "$LOOM_FAKE_STATE/argv.txt"
        exec "\(fake)" "$@"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private static func recordedArguments(_ context: RuntimeContext) async -> [String] {
        let url = context.state.appendingPathComponent("argv.txt")
        _ = await SessionRuntimeTests.waitUntil { FileManager.default.fileExists(atPath: url.path) }
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func theFirstSendStartsClaudeWithTheMessageModeAndModelAndNoNameOrKey() async throws {
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nsrec-script-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        let recorder = try Self.recordingExecutable(in: holder)
        let context = try await SessionRuntimeTests.makeContext(executableOverride: recorder, claudeVersion: "2.1.300 (Claude Code)")
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project

        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: project.id, outputSink: screen,
            draft: NewSessionLaunch(
                firstMessage: "Add the reverse-charge note",
                choices: ClaudeLaunchChoices(permissionMode: "plan", model: "haiku")))
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))

        let args = await Self.recordedArguments(context)
        let mode = try #require(args.firstIndex(of: "--permission-mode"))
        #expect(args[mode + 1] == "plan")
        let model = try #require(args.firstIndex(of: "--model"))
        #expect(args[model + 1] == "haiku")
        #expect(args.suffix(2) == ["--", "Add the reverse-charge note"])
        #expect(!args.contains("-n"), "a draft is never titled by Loom: Claude names the session")
        #expect(try #require(args.firstIndex(of: "--settings")) > model, "choices come before the settings")

        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(record.title == nil, "no title is made up")
        #expect(record.projectID == project.id && record.session.workingDirectory == folder.path)
        #expect(record.openedBy == nil, "a draft is the user's own start, not an agent's request")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aDraftWithNothingChosenStartsLikeAnyNewSessionPlusTheMessage() async throws {
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nsrec-script-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: try Self.recordingExecutable(in: holder), claudeVersion: "2.1.300 (Claude Code)")
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: nil, outputSink: screen, draft: NewSessionLaunch(firstMessage: "fix the flaky test"))
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        let args = await Self.recordedArguments(context)
        #expect(!args.contains("--permission-mode") && !args.contains("--model") && !args.contains("-n"))
        #expect(args.suffix(2) == ["--", "fix the flaky test"])
        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(record.session.workingDirectory == context.home.path)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aChoiceTheCliCannotTakeRefusesTheStartBeforeAnyCard() async throws {
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nsrec-script-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: try Self.recordingExecutable(in: holder), claudeVersion: "1.0.9 (Claude Code)")
        defer { context.cleanup() }
        await #expect(throws: (any Error).self) {
            _ = try await context.runtime.startConversation(
                provider: .claude, projectID: nil,
                draft: NewSessionLaunch(firstMessage: "m", choices: ClaudeLaunchChoices(permissionMode: "plan")))
        }
        #expect(try await context.catalog.sessions().isEmpty)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aWorktreeSessionRunsInItsOwnFolderAndABranchThatExistsLeavesNoCard() async throws {
        let (repository, projectPath) = try await GitWorkspaceTests.makeRepository()
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nsrec-script-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: holder)
        }
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: try Self.recordingExecutable(in: holder), claudeVersion: "2.1.300 (Claude Code)")
        defer { context.cleanup() }
        let project = try await context.catalog.addProject(path: projectPath).project

        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: project.id, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "go", workspace: .newWorktree("feat/x")))
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(record.projectID == project.id, "the session belongs to the project")
        #expect(record.session.workingDirectory.hasSuffix("/.claude/worktrees/feat-x"))
        #expect(screen.snapshot.contains("cwd=\(realPath(URL(fileURLWithPath: record.session.workingDirectory)))"))
        #expect(try await GitWorkspaceTests.branch(projectPath) == "main")

        // The branch now exists: a second start with the same name fails, and no card appears.
        await #expect(throws: GitWorkspace.Failure.branchExists("feat/x")) {
            _ = try await context.runtime.startConversation(
                provider: .claude, projectID: project.id,
                draft: NewSessionLaunch(firstMessage: "again", workspace: .newBranch("feat/x")))
        }
        #expect(try await context.catalog.sessions().count == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aStartThatFailsToSpawnPutsTheNewBranchAndTheNewWorktreeBack() async throws {
        let (repository, projectPath) = try await GitWorkspaceTests.makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        // The toolchain says an executable that cannot be run: everything before the spawn goes through.
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: "/nonexistent/claude", claudeVersion: "2.1.300 (Claude Code)")
        defer { context.cleanup() }
        let project = try await context.catalog.addProject(path: projectPath).project

        for (index, workspace) in [SessionWorkspace.newBranch("feat/x"), .newWorktree("feat/x")].enumerated() {
            await #expect(throws: (any Error).self) {
                _ = try await context.runtime.startConversation(
                    provider: .claude, projectID: project.id, draft: NewSessionLaunch(firstMessage: "go", workspace: workspace))
            }
            // The failure came at the spawn, after the git step and the card: that is what is being undone.
            #expect(try await context.catalog.sessions().count == index + 1)
            #expect(try await GitWorkspaceTests.branch(projectPath) == "main")
            #expect(try await GitWorkspaceTests.branches(projectPath) == ["main"], "no branch left behind: \(workspace)")
            #expect(!FileManager.default.fileExists(atPath: projectPath + "/.claude"))
            let status = try await GitWorkspace.run("/usr/bin/git", ["-C", projectPath, "status", "--porcelain"], timeout: 20)
            #expect(status.isEmpty, "git status is clean: \(status)")
            // The name is free for the retry.
            #expect(try await GitWorkspace.begin(.newBranch("feat/x"), projectFolder: projectPath).folder == projectPath)
            #expect(await GitWorkspace.undo(try await GitWorkspace.begin(.projectFolder, projectFolder: projectPath)).isEmpty)
            _ = try await GitWorkspace.run("/usr/bin/git", ["-C", projectPath, "switch", "-q", "main"], timeout: 20)
            _ = try await GitWorkspace.run("/usr/bin/git", ["-C", projectPath, "branch", "-D", "feat/x"], timeout: 20)
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aResumeGivesTheClaudeProcessTheRecordedModeAndModel() async throws {
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nsrec-script-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: try Self.recordingExecutable(in: holder), claudeVersion: "2.1.300 (Claude Code)")
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: nil, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "first", choices: ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "opus")))
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        // The CLI binds its identity at the first prompt (as the runtime tests do): send one, then stop and resume.
        try await screen.send("remember this")
        #expect(await screen.contains("echo: remember this"))
        #expect(try await SessionRuntimeTests.waitUntil {
            try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID != nil
        })
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await SessionRuntimeTests.waitUntil { await context.supervisor.runContext(runID: launch.runID) == nil })
        try? FileManager.default.removeItem(at: context.state.appendingPathComponent("argv.txt"))

        let resumedScreen = SessionRuntimeTests.Screen()
        let resumed = try await context.runtime.resumeConversation(
            sessionID: launch.sessionID, outputSink: resumedScreen,
            choices: ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "opus"))
        resumedScreen.attach(resumed.terminal)
        #expect(await resumedScreen.contains("RESUMED"))
        let args = await Self.recordedArguments(context)
        #expect(args.starts(with: ["--resume"]))
        let mode = try #require(args.firstIndex(of: "--permission-mode"))
        #expect(args[mode + 1] == "acceptEdits")
        let model = try #require(args.firstIndex(of: "--model"))
        #expect(args[model + 1] == "opus")
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
