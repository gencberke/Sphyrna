import Foundation
import Testing
@testable import LoomCore

/// V16: a session's mode, model and effort live in the catalog (runtime-owned), and every spawn in either face passes
/// them; the Chat face's argv and environment. No real Claude, no real repository.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct LaunchChoicesCatalogTests {
    private static func temporaryCatalog() throws -> (URL, SessionCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-choices-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3")))
    }

    @Test func theFirstOfThreeHundredAndOneSessionsKeepsItsMode() async throws {
        let (root, catalog) = try Self.temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids: [UUID] = []
        for index in 0..<301 {
            let session = ManagedSession(provider: .claude, workingDirectory: root.path)
            try await catalog.insertSession(session)
            try await catalog.recordLaunchChoices(
                ClaudeLaunchChoices(permissionMode: index == 0 ? "plan" : "acceptEdits", model: "haiku"),
                sessionID: session.id)
            ids.append(session.id)
        }
        #expect(try await catalog.launchChoices(sessionID: ids[0]) == ClaudeLaunchChoices(permissionMode: "plan", model: "haiku"))
        // A later change records only what changed.
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(effort: "high"), sessionID: ids[0])
        #expect(try await catalog.launchChoices(sessionID: ids[0])
            == ClaudeLaunchChoices(permissionMode: "plan", model: "haiku", effort: "high"))
    }

    @Test func theOldLaunchedListFillsOnlySessionsWithoutStoredChoices() async throws {
        let (root, catalog) = try Self.temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = ManagedSession(provider: .claude, workingDirectory: root.path)
        let empty = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(stored)
        try await catalog.insertSession(empty)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "acceptEdits"), sessionID: stored.id)
        let imported = try await catalog.importLaunchChoices([
            stored.id: ClaudeLaunchChoices(permissionMode: "plan"), empty.id: ClaudeLaunchChoices(model: "opus"),
        ])
        #expect(imported == 1)
        #expect(try await catalog.launchChoices(sessionID: stored.id).permissionMode == "acceptEdits")
        #expect(try await catalog.launchChoices(sessionID: empty.id).model == "opus")
        // Again: nothing changes.
        #expect(try await catalog.importLaunchChoices([empty.id: ClaudeLaunchChoices(model: "sonnet")]) == 0)
    }

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

    private static func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    @Test func aTerminalResumePassesTheStoredModeModelAndEffortWithNoUI() async throws {
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-choices-rec-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: try Self.recordingExecutable(in: holder), claudeVersion: "2.1.300 (Claude Code)",
            extraClaudeHelp: "--permission-mode <mode> --model <model>")
        defer { context.cleanup() }
        let argv = context.state.appendingPathComponent("argv.txt")
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: nil, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "hello",
                                    choices: ClaudeLaunchChoices(permissionMode: "plan", model: "haiku", effort: "high")))
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        let id = launch.sessionID
        #expect(await SessionRuntimeTests.waitUntil {
            (try? await context.catalog.session(id: id))?.session.providerConversationID != nil
        })
        #expect(try await context.catalog.launchChoices(sessionID: id)
            == ClaudeLaunchChoices(permissionMode: "plan", model: "haiku", effort: "high"))
        #expect(try await context.catalog.runEndpoint(sessionID: id) == .terminal)
        #expect(try await context.runtime.stopConversation(sessionID: id).succeeded)
        try FileManager.default.removeItem(at: argv)

        let again = SessionRuntimeTests.Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: id, outputSink: again)
        again.attach(resumed.terminal)
        #expect(await again.contains("FAKE-CLAUDE READY"))
        _ = await SessionRuntimeTests.waitUntil { FileManager.default.fileExists(atPath: argv.path) }
        let args = ((try? String(contentsOf: argv, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(args.first == "--resume")
        #expect(Self.value(after: "--permission-mode", in: args) == "plan")
        #expect(Self.value(after: "--model", in: args) == "haiku")
        #expect(Self.value(after: "--effort", in: args) == "high")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// Review B1: a terminal start or resume of an Ask session runs in Ask before edits, the catalog records what really ran,
    /// and the session says so in one line.
    @Test func aTerminalStartAndResumeOfAnAskSessionRunInAskBeforeEditsAndSayIt() async throws {
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-choices-ask-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: try Self.recordingExecutable(in: holder), claudeVersion: "2.1.300 (Claude Code)",
            extraClaudeHelp: "--permission-mode <mode> --model <model>")
        defer { context.cleanup() }
        let argv = context.state.appendingPathComponent("argv.txt")
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: nil, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "hello", choices: ClaudeLaunchChoices(permissionMode: "ask", model: "haiku")))
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        let id = launch.sessionID
        _ = await SessionRuntimeTests.waitUntil { FileManager.default.fileExists(atPath: argv.path) }
        var args = ((try? String(contentsOf: argv, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(Self.value(after: "--permission-mode", in: args) == "default", "\(args)")
        #expect(try await context.catalog.launchChoices(sessionID: id).permissionMode == "default")
        let notice = "Ask works in Chat. This terminal session runs in Ask before edits."
        #expect(await SessionRuntimeTests.waitUntil {
            await context.runtime.supervisor.events.snapshot().sessions[id]?.issue == notice
        })
        #expect(try await context.runtime.stopConversation(sessionID: id).succeeded)
        try FileManager.default.removeItem(at: argv)

        // A session that was left in Ask by a Chat run resumes in the terminal in Ask before edits too.
        try await context.catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "ask"), sessionID: id)
        let again = SessionRuntimeTests.Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: id, outputSink: again)
        again.attach(resumed.terminal)
        #expect(await again.contains("FAKE-CLAUDE READY"))
        _ = await SessionRuntimeTests.waitUntil { FileManager.default.fileExists(atPath: argv.path) }
        args = ((try? String(contentsOf: argv, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(args.first == "--resume")
        #expect(Self.value(after: "--permission-mode", in: args) == "default", "\(args)")
        #expect(try await context.catalog.launchChoices(sessionID: id).permissionMode == "default")
        #expect(await SessionRuntimeTests.waitUntil {
            await context.runtime.supervisor.events.snapshot().sessions[id]?.issue == notice
        })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// The merge's rule (seam 1): every terminal spawn builds its profile through `claudeProfile` with face `.terminal`, and that
    /// is where Ask becomes Ask before edits, for a new start, a resume, a handover to the terminal and an Open Session request
    /// alike. The Chat face keeps `dontAsk`; Full access in the terminal is V07's `--permission-mode bypassPermissions` and no D-62 flag.
    @Test func everyTerminalProfileRunsAskAsAskBeforeEditsAndFullAccessIsUnchanged() async throws {
        let context = try await SessionRuntimeTests.makeContext(
            claudeVersion: "2.1.300 (Claude Code)", extraClaudeHelp: "--permission-mode <mode> --model <model>")
        defer { context.cleanup() }
        let toolchain = try await context.runtime.toolchain(for: .claude)
        let hooks = try await context.runtime.ensureHooksForTesting()
        func arguments(_ route: ProviderLaunchProfile.ClaudeRoute, _ mode: String?, face: ProviderLaunchProfile.ClaudeFace) async throws -> [String] {
            try await context.runtime.claudeProfile(
                route: route, toolchain: toolchain, sessionID: UUID(), hooks: hooks,
                choices: ClaudeLaunchChoices(permissionMode: mode), face: face).launchArguments()
        }
        for route in [ProviderLaunchProfile.ClaudeRoute.new(UUID()), .resume("abc-123")] {
            for ask in ["ask", "dontAsk"] {
                let terminal = try await arguments(route, ask, face: .terminal)
                #expect(Self.value(after: "--permission-mode", in: terminal) == "default", "\(route) \(ask): \(terminal)")
                #expect(!terminal.contains("dontAsk"))
            }
            #expect(Self.value(after: "--permission-mode", in: try await arguments(route, "ask", face: .chat)) == "dontAsk")
            for mode in ["default", "acceptEdits", "auto", "plan"] {
                #expect(Self.value(after: "--permission-mode", in: try await arguments(route, mode, face: .terminal)) == mode)
            }
            // Full access in the terminal is what V07 made it: the mode word, and none of the Chat face's flag.
            let full = try await arguments(route, "bypassPermissions", face: .terminal)
            #expect(Self.value(after: "--permission-mode", in: full) == "bypassPermissions")
            #expect(!full.contains("--allow-dangerously-skip-permissions"))
            #expect(try await arguments(route, "bypassPermissions", face: .chat).contains("--allow-dangerously-skip-permissions"))
        }
        // The notice and the record belong to the spawn that follows the newest profile: a stale mark does not survive a
        // profile that replaced nothing.
        let session = UUID()
        _ = try await context.runtime.claudeProfile(route: .new(session), toolchain: toolchain, sessionID: session, hooks: hooks,
                                                    choices: ClaudeLaunchChoices(permissionMode: "ask"), face: .terminal)
        #expect(await context.runtime.askReplacedInTerminal.contains(session))
        _ = try await context.runtime.claudeProfile(route: .new(session), toolchain: toolchain, sessionID: session, hooks: hooks,
                                                    choices: ClaudeLaunchChoices(permissionMode: "acceptEdits"), face: .terminal)
        #expect(!(await context.runtime.askReplacedInTerminal.contains(session)))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// Seam 1, the Open Session request (D-40): it always starts in the terminal and carries no choices, so the TUI is told no
    /// mode at all; the session is not in Ask.
    @Test func anOpenSessionStartPassesNoModeAndRunsNoAsk() async throws {
        let holder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-choices-open-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: holder) }
        let context = try await SessionRuntimeTests.makeContext(
            executableOverride: try Self.recordingExecutable(in: holder), claudeVersion: "2.1.300 (Claude Code)",
            extraClaudeHelp: "--permission-mode <mode> --model <model>")
        defer { context.cleanup() }
        let argv = context.state.appendingPathComponent("argv.txt")
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: nil, outputSink: screen,
            opening: SessionOpening(title: "Opened", firstMessage: "do it", ticketKey: nil, openedBy: UUID()))
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        _ = await SessionRuntimeTests.waitUntil { FileManager.default.fileExists(atPath: argv.path) }
        let args = ((try? String(contentsOf: argv, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(!args.contains("dontAsk") && Self.value(after: "--permission-mode", in: args) == nil, "\(args)")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    // MARK: The Chat face's spawn

    private static let help =
        "--settings <settings> --session-id <id> -n, --name <name> --effort <level> --permission-mode <mode> --model <model>"
    private let capabilities = ProviderCapabilities(version: "2.1.300 (Claude Code)", help: Self.help)

    @Test func aChatSpawnSpeaksStreamJsonWithCheckpointsAndNoArgumentPrompt() throws {
        let profile = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"), environment: [:],
            choices: ClaudeLaunchChoices(permissionMode: "plan", model: "haiku", effort: "low"),
            opening: ProviderLaunchProfile.ClaudeOpening(title: "Title", firstMessage: "hello"), face: .chat)
        let args = profile.launchArguments()
        #expect(args.starts(with: ProviderLaunchProfile.claudeChatArguments))
        #expect(Self.value(after: "--thinking-display", in: args) == "summarized")
        #expect(Self.value(after: "--permission-mode", in: args) == "plan")
        #expect(Self.value(after: "--model", in: args) == "haiku")
        #expect(Self.value(after: "--effort", in: args) == "low")
        #expect(Self.value(after: "-n", in: args) == "Title")
        // The first message goes over stdin.
        #expect(!args.contains("hello") && !args.contains("--"))
        // File checkpoints from the first turn (S8), session state events (S1).
        #expect(profile.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "true")
        #expect(profile.environment["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] == "1")

        // D-62: Full access is selectable in the live chip, on every Chat spawn and resume; never in the terminal's.
        #expect(args.contains("--allow-dangerously-skip-permissions"))
        #expect(Self.value(after: "--permission-mode", in: args) == "plan", "the flag starts the child in no mode of its own")
        let resumed = try ProviderLaunchProfile.claude(
            route: .resume("abc-123"), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"), environment: [:],
            choices: ClaudeLaunchChoices(permissionMode: "acceptEdits"), face: .chat)
        #expect(resumed.launchArguments().contains("--allow-dangerously-skip-permissions"))
        let fullAccessChoice = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"), environment: [:], face: .chat)
        #expect(Self.value(after: "--permission-mode", in: fullAccessChoice.launchArguments()) == nil, "no mode unless a choice names one")

        // The terminal face is unchanged: the TUI keeps its own checkpoints.
        let terminal = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"), environment: [:])
        #expect(!terminal.launchArguments().contains("--allow-dangerously-skip-permissions"))
        let terminalResume = try ProviderLaunchProfile.claude(
            route: .resume("abc-123"), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"), environment: [:])
        #expect(!terminalResume.launchArguments().contains("--allow-dangerously-skip-permissions"))
        #expect(terminal.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == nil)
        #expect(!terminal.launchArguments().contains("--input-format"))

        // An older CLI that does not list the hidden option does not get it.
        let older = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: ProviderCapabilities(version: "2.1.200 (Claude Code)", help: Self.help),
            config: URL(fileURLWithPath: "/cfg"), environment: [:], face: .chat)
        #expect(!older.launchArguments().contains("--thinking-display"))
    }

    /// D-63: Ask is Loom's own word, a mode of the Chat face. The Chat spawn starts the CLI in `dontAsk` and nothing else about
    /// Ask goes on the command line (a deny rule given at launch cannot be taken back); the terminal never runs `dontAsk`: its
    /// TUI has no rules and no style behind it, so it starts in Ask before edits (review B1). Every other mode keeps its word.
    @Test func askLaunchesAsDontAskInChatAndAsAskBeforeEditsInTheTerminalWithNoRulesOnTheCommandLine() throws {
        func arguments(_ mode: String?, face: ProviderLaunchProfile.ClaudeFace = .chat) throws -> [String] {
            try ProviderLaunchProfile.claude(
                route: .new(UUID()), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"), environment: [:],
                choices: ClaudeLaunchChoices(permissionMode: mode), face: face).launchArguments()
        }
        for face in [ProviderLaunchProfile.ClaudeFace.chat, .terminal] {
            let ask = try arguments("ask", face: face)
            #expect(Self.value(after: "--permission-mode", in: ask) == (face == .chat ? "dontAsk" : "default"))
            #expect(!ask.contains("--disallowedTools") && !ask.contains("--disallowed-tools") && !ask.contains("--allowedTools"))
            #expect(!ask.joined(separator: " ").contains("outputStyle"), "the style is a live setting, never a flag")
        }
        for mode in ["default", "acceptEdits", "auto", "bypassPermissions", "plan"] {
            #expect(Self.value(after: "--permission-mode", in: try arguments(mode)) == mode)
        }
        #expect(Self.value(after: "--permission-mode", in: try arguments(nil)) == nil)
    }

    @Test func theModesAreTheFiveOfD63UnderLoomsNamesAndAskCarriesItsStyle() throws {
        #expect(ClaudePermissionMode.menuModes.map(\.rawValue) == ["ask", "default", "acceptEdits", "auto", "bypassPermissions"])
        #expect(ClaudePermissionMode.menuModes.map(\.title) == ["Ask", "Ask before edits", "Accept edits", "Auto", "Full access"])
        #expect(ClaudePermissionMode.title(forRaw: "default") == "Ask before edits")
        #expect(ClaudePermissionMode.title(forRaw: "dontAsk") == "Ask", "dontAsk is Ask's word to the CLI")
        #expect(ClaudePermissionMode.title(forRaw: "something-newer") == "something-newer")
        // The style Ask turns on is in the plugin Loom installs, under the name `outputStyle` takes.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-plugin-ask-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ClaudeLoomPlugin.install(in: root)
        let style = try String(contentsOf: folder.appendingPathComponent("output-styles/ask.md"), encoding: .utf8)
        #expect(style.hasPrefix("---\nname: Ask\n") && ClaudeLoomPlugin.askStyleName == "loom:Ask")
        #expect(!style.localizedCaseInsensitiveContains("conversation"))
    }

    /// A moved run (`/clear`) carries its choices and face to the new card; choices the card already has stay.
    @Test func aMovedRunCarriesItsChoicesAndFace() async throws {
        let (root, catalog) = try Self.temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ManagedSession(provider: .claude, workingDirectory: root.path)
        let destination = ManagedSession(provider: .claude, workingDirectory: root.path)
        let other = ManagedSession(provider: .claude, workingDirectory: root.path)
        for session in [source, destination, other] { try await catalog.insertSession(session) }
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "m1", effort: "high"),
                                              sessionID: source.id)
        try await catalog.carryLaunchState(from: source.id, to: destination.id, endpoint: .pipe)
        #expect(try await catalog.launchChoices(sessionID: destination.id)
            == ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "m1", effort: "high"))
        #expect(try await catalog.runEndpoint(sessionID: destination.id) == .pipe)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(model: "m2"), sessionID: other.id)
        try await catalog.carryLaunchState(from: source.id, to: other.id, endpoint: .terminal)
        #expect(try await catalog.launchChoices(sessionID: other.id)
            == ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "m2", effort: "high"))
        #expect(try await catalog.runEndpoint(sessionID: other.id) == .terminal)
    }

    /// V19: the owning face is on the session's record in every list read, so a stopped session resumes in it.
    @Test func theRecordNamesTheOwningFaceInEveryRead() async throws {
        let (root, catalog) = try Self.temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(session)
        #expect(try await catalog.session(id: session.id)?.runEndpoint == nil, "a session that never ran has no owner")
        try await catalog.setRunEndpoint(.pipe, sessionID: session.id)
        #expect(try await catalog.session(id: session.id)?.runEndpoint == .pipe)
        #expect(try await catalog.listedSession(id: session.id)?.runEndpoint == .pipe)
        try await catalog.setRunEndpoint(.terminal, sessionID: session.id)
        #expect(try await catalog.session(id: session.id)?.runEndpoint == .terminal)
        // The row Home's Continue reads keeps its own columns after the record's.
        _ = try await catalog.sessionsEndedByQuit(since: .distantPast, limit: 5)
    }

    /// V18 reads one list of waiting requests whatever the provider: the Chat face's and Codex's answerable ones.
    @Test func waitingRequestsListBothProviders() {
        let chat = ProviderPendingRequest(requestID: "r1", toolUseID: "t1", kind: .question, toolName: "AskUserQuestion",
                                          summary: "Which database?", arrivedAt: Date())
        let state = SessionViewState(
            userRequests: [ProviderUserRequest(id: "c1", kind: .command, summary: "rm -rf build"),
                           ProviderUserRequest(id: "c2", kind: .unsupported("mcp"), summary: "not here")],
            pendingRequests: [chat])
        #expect(state.waitingRequests.map(\.requestID) == ["r1", "c1"])
        #expect(state.waitingRequests.last?.kind == .approval)
        // Named as Claude's own tools are, so every place that words a request reads a Codex command like a Bash one.
        #expect(state.waitingRequests.last?.toolName == "Bash")
        #expect(state.waitingRequests.last?.arrivedAt == nil)
    }
}
