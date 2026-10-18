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

        // The terminal face is unchanged: the TUI keeps its own checkpoints.
        let terminal = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"), environment: [:])
        #expect(terminal.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == nil)
        #expect(!terminal.launchArguments().contains("--input-format"))

        // An older CLI that does not list the hidden option does not get it.
        let older = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: ProviderCapabilities(version: "2.1.200 (Claude Code)", help: Self.help),
            config: URL(fileURLWithPath: "/cfg"), environment: [:], face: .chat)
        #expect(!older.launchArguments().contains("--thinking-display"))
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
        #expect(state.waitingRequests.last?.toolName == "command")
        #expect(state.waitingRequests.last?.arrivedAt == nil)
    }
}
