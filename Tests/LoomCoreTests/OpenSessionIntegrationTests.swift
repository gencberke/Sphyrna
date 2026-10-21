import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore

private final class OpenBundleAnchor: NSObject {}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    var stdout: [String] { lock.withLock { out } }
    var stderr: [String] { lock.withLock { err } }
    var output: OpenSessionCommand.Output {
        .init(standardOutput: { [self] line in lock.withLock { out.append(line) } },
              standardError: { [self] line in lock.withLock { err.append(line) } })
    }
}

// MARK: Catalog

@Suite(.serialized)
struct OpenSessionCatalogTests {
    private func sql(_ statement: String, at url: URL) throws -> [String] {
        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw SessionCatalogError.invalidRow("test SQL failed: \(statement)")
        }
        defer { sqlite3_finalize(prepared) }
        var rows: [String] = []
        var result = sqlite3_step(prepared)
        while result == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(prepared)).map { column in
                sqlite3_column_type(prepared, column) == SQLITE_NULL
                    ? "NULL" : String(cString: sqlite3_column_text(prepared, column))
            }.joined(separator: "|"))
            result = sqlite3_step(prepared)
        }
        guard result == SQLITE_DONE else { throw SessionCatalogError.invalidRow("test SQL failed: \(statement)") }
        return rows
    }

    @Test func aCatalogOf030GainsTheTwoOriginColumnsAndStaysReadableByThatBuild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-origin-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let old = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        do {
            let catalog = try SessionCatalog(url: url)
            try await catalog.insertSession(old, title: "kept", createdAt: Date(timeIntervalSince1970: 10),
                                            lastUsedAt: Date(timeIntervalSince1970: 100))
        }
        // What 0.3.0 left on disk: schema 3 with the activity column, without the origin columns.
        _ = try sql("ALTER TABLE sessions DROP COLUMN ticket_key", at: url)
        _ = try sql("ALTER TABLE sessions DROP COLUMN opened_by", at: url)
        let named = "SELECT count(*) FROM pragma_table_info('sessions') WHERE name IN ('ticket_key', 'opened_by')"
        #expect(try sql(named, at: url) == ["0"])

        for _ in 0..<2 { // the second open is idempotent
            let catalog = try SessionCatalog(url: url)
            let row = try #require(try await catalog.session(id: old.id))
            #expect(row.title == "kept" && row.openedBy == nil)
            #expect(try sql(named, at: url) == ["2"])
            #expect(try sql("PRAGMA user_version", at: url) == ["3"], "no version bump: 0.3.0 must still open the catalog")
        }

        // 0.3.0 names its columns in every statement and checks only its own: all still work.
        let zeroThreeSelect = """
            SELECT s.id, s.provider, s.provider_conversation_id, s.working_directory, s.title,
                   s.created_at, s.last_used_at, s.lifecycle, s.pinned, s.project_id, s.title_is_custom,
                   s.stale_since, COALESCE(s.last_activity_at, s.last_used_at)
            FROM sessions s ORDER BY s.created_at, s.id
            """
        #expect(try sql(zeroThreeSelect, at: url).count == 1)
        #expect(try sql("""
            SELECT count(*) FROM pragma_table_info('sessions')
            WHERE name IN ('project_id', 'title_is_custom', 'stale_since')
            """, at: url) == ["3"])
        let written = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        _ = try sql("""
            INSERT INTO sessions (id, provider, provider_conversation_id, working_directory, title,
                created_at, last_used_at, lifecycle, pinned, project_id, stale_since, last_activity_at)
            VALUES ('\(written.id.uuidString)', 'claude', NULL, '/tmp', 'by 0.3.0', 20, 200, 'idle', 0, NULL, NULL, 200)
            """, at: url)
        let catalog = try SessionCatalog(url: url)
        let read = try #require(try await catalog.session(id: written.id))
        #expect(read.title == "by 0.3.0" && read.openedBy == nil)
    }

    @Test func aNewSessionWritesNoKeyKeepsItsRequesterAndAnAutomaticTitle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-origin-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let catalog = try SessionCatalog(url: url)
        let asker = UUID()
        let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        try await catalog.insertSession(session, title: "EDDP-1 First", openedBy: asker)
        let row = try #require(try await catalog.session(id: session.id))
        #expect(row.openedBy == asker)
        #expect(try sql("SELECT ticket_key IS NULL, opened_by FROM sessions", at: url) == ["1|\(asker.uuidString)"])
        #expect(row.title == "EDDP-1 First" && row.titleIsCustom == false)
        // An automatic title: a rename wins, and an empty rename returns to automatic.
        try await catalog.renameSession(sessionID: session.id, to: "Mine")
        #expect(try await catalog.recordTerminalTitle(sessionID: session.id, title: "Claude's own") == false)
        let page = try await catalog.sessionPage(CatalogQuery())
        #expect(page.sessions.first?.openedBy == asker)
    }

    @Test func aRowThatHoldsAKeyFromAnOlderLoomStillDecodesWithItsOtherColumnsInPlace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-origin-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let asker = UUID()
        let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        do {
            let catalog = try SessionCatalog(url: url)
            try await catalog.insertSession(session, title: "EDDP-412 Fix login", openedBy: asker)
        }
        _ = try sql("UPDATE sessions SET ticket_key = 'EDDP-412', run_endpoint = 'pipe'", at: url)
        let catalog = try SessionCatalog(url: url)
        let row = try #require(try await catalog.session(id: session.id))
        // The column older builds read stays in the table; a row that has a value in it still loads.
        #expect(row.openedBy == asker && row.runEndpoint == .pipe && row.title == "EDDP-412 Fix login")
        #expect(try await catalog.sessions().first?.title == "EDDP-412 Fix login")
        #expect(try await catalog.sessionPage(CatalogQuery()).sessions.first?.openedBy == asker)
    }
}

// MARK: Launch profile

struct OpenSessionLaunchProfileTests {
    private let capabilities = ProviderCapabilities(
        version: "x", help: "--settings <settings> --session-id <id> -n, --name <name> --effort <level>"
    )
    private let hooks = ClaudeHookLaunchConfiguration(
        helperPath: "/Apps/Loom Dev.app/Contents/Helpers/loom-hook", socketPath: "/tmp/h.sock",
        authenticationToken: "token", controlSocketPath: "/tmp/c.sock"
    )

    @Test func theTitleIsTheSessionNameAndTheMessageTheLastPositionalAfterTheOptions() throws {
        let id = UUID()
        let message = "--not-an-option\nsecond line"
        let profile = try ProviderLaunchProfile.claude(
            route: .new(id), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"),
            environment: [:], hooks: hooks,
            opening: .init(title: "EDDP-412 Fix login", firstMessage: message)
        )
        let arguments = profile.launchArguments(extra: ["--model", "opus"])
        #expect(arguments.suffix(2) == ["--", message], "the prompt is last and guarded against a leading dash")
        let name = try #require(arguments.firstIndex(of: "-n"))
        #expect(arguments[name + 1] == "EDDP-412 Fix login")
        #expect(arguments.starts(with: ["--session-id", id.uuidString]))
        let separator = try #require(arguments.firstIndex(of: "--"))
        #expect(try #require(arguments.firstIndex(of: "--settings")) < name)
        #expect(try #require(arguments.firstIndex(of: "--model")) < separator, "extra options stay before the prompt")
        #expect(arguments.filter { $0 == message }.count == 1)
    }

    @Test func withoutAnOpeningTheArgumentsAreExactlyWhatTheyWere() throws {
        let id = UUID()
        let profile = try ProviderLaunchProfile.claude(
            route: .new(id), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"),
            environment: [:], hooks: hooks
        )
        #expect(profile.trailingArguments.isEmpty)
        #expect(profile.arguments.count == 4)
        #expect(profile.arguments.starts(with: ["--session-id", id.uuidString, "--settings"]))
        #expect(!profile.arguments.contains("-n") && !profile.arguments.contains("--"))
    }

    @Test func claudeSessionsGetTheCommandAndTheControlSocketInTheirEnvironment() throws {
        let profile = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"),
            environment: ["KEEP": "1"], hooks: hooks
        )
        #expect(profile.environment["LOOM_CLI"] == "/Apps/Loom Dev.app/Contents/Helpers/loom-hook")
        #expect(profile.environment["LOOM_CONTROL_SOCKET"] == "/tmp/c.sock")
        #expect(profile.environment["LOOM_HOOK_TOKEN"] == "token" && profile.environment["KEEP"] == "1")
        let resumed = try ProviderLaunchProfile.claude(
            route: .resume("abc"), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"),
            environment: [:], hooks: hooks
        )
        #expect(resumed.environment["LOOM_CLI"] != nil, "a resumed session can ask too")
        let withoutHooks = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"),
            environment: [:]
        )
        #expect(withoutHooks.environment["LOOM_CLI"] == nil && withoutHooks.environment["LOOM_CONTROL_SOCKET"] == nil)
    }

    @Test func loomsSkillFolderRidesAlongWhenClaudeKnowsPluginFolders() throws {
        let withPlugin = ClaudeHookLaunchConfiguration(
            helperPath: hooks.helperPath, socketPath: hooks.socketPath, authenticationToken: "token",
            controlSocketPath: "/tmp/c.sock", pluginDirectory: "/data/claude-plugin"
        )
        let capable = ProviderCapabilities(version: "x", help: "--settings <settings> --session-id <id> --plugin-dir <path>")
        for route in [ProviderLaunchProfile.ClaudeRoute.new(UUID()), .resume("abc")] {
            let profile = try ProviderLaunchProfile.claude(
                route: route, capabilities: capable, config: URL(fileURLWithPath: "/cfg"), environment: [:], hooks: withPlugin)
            let index = try #require(profile.arguments.firstIndex(of: "--plugin-dir"))
            #expect(profile.arguments[index + 1] == "/data/claude-plugin")
        }
        // A Claude without the option, or a run without the plugin, launches as before.
        for (caps, launchHooks) in [(capabilities, withPlugin), (capable, hooks)] {
            let profile = try ProviderLaunchProfile.claude(
                route: .new(UUID()), capabilities: caps, config: URL(fileURLWithPath: "/cfg"), environment: [:], hooks: launchHooks)
            #expect(!profile.arguments.contains("--plugin-dir"))
        }
    }

    @Test func theSkillNamesTheCommandAsTheHelperUnderstandsItAndIsWrittenOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-plugin-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ClaudeLoomPlugin.install(in: root)
        let skillFile = folder.appendingPathComponent("skills/open-session/SKILL.md")
        let skill = try String(contentsOf: skillFile, encoding: .utf8)
        let manifest = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: Any])
        #expect(manifest["name"] as? String == "loom")
        #expect(skill.hasPrefix("---\nname: open-session\ndescription: "))
        // Every option and result line the skill names is one the command has.
        for word in ["\"$LOOM_CLI\" open", "--title", "--project", "--message-file", "--message -",
                     "started <", "pending: ...", "denied", "error: "] {
            #expect(OpenSessionCommand.usage.contains(word), "usage lacks \(word)")
            #expect(skill.contains(word), "skill lacks \(word)")
        }
        // D-69: no tracker key, no `exists` line in the skill or the result lines; the command still takes an old
        // agent's --ticket and says so. The skill tells an agent that reuses sessions to ask the user.
        #expect(!skill.contains("--ticket") && !skill.contains("exists <") && !skill.contains("<KEY>"))
        #expect(!OpenSessionCommand.usage.contains("exists <"))
        #expect(OpenSessionCommand.usage.contains("--ticket <key>") && OpenSessionCommand.usage.contains("ignored"))
        #expect(skill.contains("`open` always starts a new session") && skill.contains("ask the user"))
        #expect(skill.contains("\(Int(OpenSessionLimits.serverReplyDelay)) seconds"))
        // An unchanged file is left alone; a changed one is put back.
        let written = try FileManager.default.attributesOfItem(atPath: skillFile.path)[.modificationDate] as? Date
        try "old".write(to: folder.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
        try ClaudeLoomPlugin.install(in: root)
        #expect(try FileManager.default.attributesOfItem(atPath: skillFile.path)[.modificationDate] as? Date == written)
        #expect(try Data(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json")) == Data(ClaudeLoomPlugin.manifest.utf8))
    }

    @Test func aFirstMessageNeedsANewSession() throws {
        #expect(throws: LoomError.self) {
            _ = try ProviderLaunchProfile.claude(
                route: .resume("abc"), capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"),
                environment: [:], hooks: hooks, opening: .init(title: "t", firstMessage: "m")
            )
        }
        // A help text without --name no longer refuses the start: the option is passed and the
        // drift is reported (CLI drift, H1-B).
        let old = ProviderCapabilities(version: "x", help: "--settings <settings> --session-id <id>")
        let profile = try ProviderLaunchProfile.claude(
            route: .new(UUID()), capabilities: old, config: URL(fileURLWithPath: "/cfg"),
            environment: [:], hooks: hooks, opening: .init(title: "t", firstMessage: "m")
        )
        #expect(profile.arguments.contains("-n"))
        #expect(ProviderLaunchProfile.missingRequiredClaudeOptions(
            capabilities: old, route: .new(UUID()), opening: .init(title: "t", firstMessage: "m")) == ["--name"])
    }
}

// MARK: The command

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OpenSessionCommandTests {
    private func environment(_ rig: OpenRig) -> [String: String] {
        ["LOOM_CONTROL_SOCKET": rig.socketPath, "LOOM_HOOK_TOKEN": rig.token,
         "LOOM_SESSION_ID": rig.requester.id.uuidString, "LOOM_MANAGED_RUN_ID": rig.runID.uuidString]
    }

    private func run(
        _ arguments: [String], environment: [String: String], stdin: Data = Data(), timeout: TimeInterval = 10
    ) async -> (code: Int32, out: CommandOutput) {
        let out = CommandOutput()
        let code = await Task.detached {
            OpenSessionCommand.run(
                arguments: arguments, environment: environment, readStandardInput: { stdin },
                output: out.output, replyTimeout: timeout
            )
        }.value
        return (code, out)
    }

    private func messageFile(_ rig: OpenRig, _ text: String) throws -> String {
        let path = rig.root.appendingPathComponent("message-\(UUID().uuidString.prefix(6)).txt")
        try Data(text.utf8).write(to: path)
        return path.path
    }

    @Test func helpPrintsTheUsageAndNeedsNoLoom() async {
        for arguments in [["--help"], ["open", "--help"], ["open", "--title", "x", "--help"]] {
            let (code, out) = await run(arguments, environment: [:])
            #expect(code == 0, "\(arguments)")
            #expect(out.stdout.joined().contains("usage: \"$LOOM_CLI\" open --title"))
        }
    }

    @Test func badArgumentsExitTwoBeforeAnythingIsSent() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let env = environment(rig)
        let big = try messageFile(rig, String(repeating: "m", count: 65_537))
        let binary = rig.root.appendingPathComponent("binary.bin")
        try Data([0xFF, 0xFE, 0xFD]).write(to: binary)
        let ok = try messageFile(rig, "hello")
        let cases: [(String, [String])] = [
            ("no title", ["open", "--message", "-"]),
            ("no message source", ["open", "--title", "T"]),
            ("both sources", ["open", "--title", "T", "--message", "-", "--message-file", ok]),
            ("unknown option", ["open", "--title", "T", "--message", "-", "--bogus", "1"]),
            ("inline message text", ["open", "--title", "T", "--message", "do it now"]),
            ("missing value", ["open", "--title"]),
            ("duplicate", ["open", "--title", "A", "--title", "B", "--message", "-"]),
            ("empty title", ["open", "--title", "  ", "--message", "-"]),
            ("missing file", ["open", "--title", "T", "--message-file", "/nonexistent/message.txt"]),
            ("oversize file", ["open", "--title", "T", "--message-file", big]),
            ("not UTF-8", ["open", "--title", "T", "--message-file", binary.path]),
            ("unknown command", ["frobnicate"]),
        ]
        for (name, arguments) in cases {
            let (code, out) = await run(arguments, environment: env, stdin: Data("hello".utf8))
            #expect(code == 2, "\(name)")
            #expect(out.stderr.joined().hasPrefix("error: "), "\(name)")
            #expect(out.stdout.isEmpty, "\(name)")
        }
        let empty = await run(["open", "--title", "T", "--message", "-"], environment: env, stdin: Data())
        #expect(empty.code == 2, "an empty message is refused")
        let over = await run(["open", "--title", "T", "--message", "-"], environment: env,
                             stdin: Data(String(repeating: "m", count: 65_537).utf8))
        #expect(over.code == 2, "an oversize message on standard input is refused")
        #expect(await rig.coordinator.snapshot().isEmpty)
    }

    @Test func outsideLoomOrWithoutAnAnswerTheCommandExitsThree() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let arguments = ["open", "--title", "T", "--message", "-"]
        let stdin = Data("hello".utf8)

        let bare = await run(arguments, environment: [:], stdin: stdin)
        #expect(bare.code == 3)
        #expect(bare.out.stdout.first?.hasPrefix("error: not running inside a Sphyrna session") == true)

        var partial = environment(rig)
        partial["LOOM_MANAGED_RUN_ID"] = "not-a-uuid"
        #expect(await run(arguments, environment: partial, stdin: stdin).code == 3)

        var gone = environment(rig)
        gone["LOOM_CONTROL_SOCKET"] = rig.root.appendingPathComponent("nobody.sock").path
        #expect(await run(arguments, environment: gone, stdin: stdin).code == 3, "Loom unreachable")

        var wrong = environment(rig)
        wrong["LOOM_HOOK_TOKEN"] = "someone else"
        let denied = await run(arguments, environment: wrong, stdin: stdin)
        #expect(denied.code == 3)
        #expect(denied.out.stdout.first?.hasPrefix("error: ") == true)

        var stale = environment(rig)
        stale["LOOM_MANAGED_RUN_ID"] = UUID().uuidString
        #expect(await run(arguments, environment: stale, stdin: stdin).code == 3, "a run Loom does not know")
        #expect(await rig.coordinator.snapshot().isEmpty)
    }

    @Test func startedDeniedAndInvalidMapToTheirLinesAndExitCodes() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let env = environment(rig)
        let recorder = StartRecorder()
        let file = try messageFile(rig, "First line\nSecond line — çalışın")

        // started: arguments reach the request as given, from a file.
        let started = Task { await run(["open", "--title=Fix login", "--project", "beta",
                                        "--message-file", file], environment: env) }
        let entry = try #require(await rig.waitForEntries(1).first)
        #expect(entry.title == "Fix login" && entry.projectID == rig.projectB.id)
        #expect(entry.message == "First line\nSecond line — çalışın")
        let newID = try await rig.coordinator.approve(entry.id, start: recorder.start)
        let first = await started.value
        #expect(first.code == 0)
        #expect(first.out.stdout == ["started \(newID.uuidString.lowercased()) \"Fix login\""])

        // denied (the message on standard input).
        let refused = Task { await run(["open", "--title", "Nope", "--message", "-"], environment: env,
                                       stdin: Data("from stdin".utf8)) }
        let waiting = try #require(await rig.waitForEntries(1).first)
        #expect(waiting.message == "from stdin" && waiting.projectID == rig.projectA.id)
        // A second command from the same session meanwhile is refused with exit 2.
        let second = await run(["open", "--title", "Again", "--message", "-"], environment: env, stdin: Data("x".utf8))
        #expect(second.code == 2)
        #expect(second.out.stdout == ["error: a request from this session is already waiting"])
        try await rig.coordinator.deny(waiting.id)
        let denied = await refused.value
        #expect(denied.code == 1 && denied.out.stdout == ["denied"])

        #expect(recorder.recorded.count == 1)

        // invalid in Loom (unknown project): exit 2 with the reason.
        let unknown = await run(["open", "--title", "T", "--project", "nope", "--message", "-"], environment: env,
                                stdin: Data("x".utf8))
        #expect(unknown.code == 2 && unknown.out.stdout.first?.hasPrefix("error: no Sphyrna project") == true)
    }

    @Test func anOldAgentsTicketFlagStillExitsZeroAndChangesNothing() async throws {
        // Agent rules written for 0.4.x pass `--ticket <key>`. It is accepted and ignored (D-69): no validation of
        // the key, no lookup, no `exists` line, and the request is an ordinary one.
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let env = environment(rig)
        let recorder = StartRecorder()
        // A session whose title starts with the key exists: it must not turn the request into anything else.
        let held = ManagedSession(provider: .claude, workingDirectory: rig.projectA.path)
        try await rig.catalog.insertSession(held, title: "EDDP-412 Fix login", projectID: rig.projectA.id)

        for (index, ticket) in [["--ticket", "EDDP-412"], ["--ticket=eddp-412"], ["--ticket", "not even a valid key / at all"]].enumerated() {
            let command = Task { await run(["open", "--title", "EDDP-412 Fix login"] + ticket + ["--message", "-"],
                                           environment: env, stdin: Data("go \(index)".utf8)) }
            let entry = try #require(await rig.waitForEntries(1).first)
            #expect(entry.title == "EDDP-412 Fix login" && entry.phase == .waiting && entry.message == "go \(index)")
            let newID = try await rig.coordinator.approve(entry.id, start: recorder.start)
            let result = await command.value
            #expect(result.code == 0, "\(ticket)")
            #expect(result.out.stdout == ["started \(newID.uuidString.lowercased()) \"EDDP-412 Fix login\""])
            #expect(result.out.stderr.isEmpty)
        }
        #expect(recorder.recorded.count == 3)
        // Giving it twice is still a usage error, like any option.
        let twice = await run(["open", "--title", "T", "--ticket", "A-1", "--ticket", "B-2", "--message", "-"],
                              environment: env, stdin: Data("x".utf8))
        #expect(twice.code == 2)
        #expect(OpenSessionCommand.usage.contains("accepted and ignored"))
    }

    @Test func anUndecidedRequestExitsZeroWithAPendingLine() async throws {
        let rig = try await OpenRig.make(replyDelay: 0.3)
        defer { rig.cleanup() }
        let (code, out) = await run(["open", "--title", "Wait", "--message", "-"], environment: environment(rig),
                                    stdin: Data("hello".utf8))
        #expect(code == 0)
        #expect(out.stdout.first?.hasPrefix("pending: approve or deny it in Sphyrna") == true)
        #expect(out.stdout.first?.contains("lost if Sphyrna quits") == true)
        #expect(await rig.coordinator.snapshot().count == 1, "the request stays")
    }

    @Test func theClientGivesUpWhenLoomDoesNotAnswerInTime() async throws {
        let rig = try await OpenRig.make(replyDelay: 30)
        defer { rig.cleanup() }
        let (code, out) = await run(["open", "--title", "Wait", "--message", "-"], environment: environment(rig),
                                    stdin: Data("hello".utf8), timeout: 0.5)
        #expect(code == 3)
        #expect(out.stdout.first?.hasPrefix("error: Sphyrna could not be reached or did not answer") == true)
        #expect(OpenSessionLimits.clientWait > OpenSessionLimits.serverReplyDelay)
    }

    // MARK: The helper binary

    private func runHelper(_ arguments: [String], environment: [String: String], stdin: Data = Data())
        async throws -> (code: Int32, out: String, err: String) {
        let helper = Bundle(for: OpenBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-hook")
        return try await Task.detached {
            let process = Process()
            process.executableURL = helper
            process.arguments = arguments
            process.environment = environment
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }.value
    }

    @Test func theHelperBinaryAsksOverTheControlSocketAndWithoutArgumentsStaysAHookHelper() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let recorder = StartRecorder()

        let help = try await runHelper(["open", "--help"], environment: [:])
        #expect(help.code == 0 && help.out.contains("usage:"))
        let outside = try await runHelper(["open", "--title", "T", "--message", "-"], environment: [:], stdin: Data("m".utf8))
        #expect(outside.code == 3 && outside.out.hasPrefix("error: not running inside a Sphyrna session"))
        let bad = try await runHelper(["open", "--title", "T"], environment: environment(rig))
        #expect(bad.code == 2 && bad.err.hasPrefix("error: "))

        // No arguments: the hook path, unchanged (no Loom connection and no payload: exit 1, no output).
        let hook = try await runHelper([], environment: [:])
        #expect(hook.code == 1 && hook.out.isEmpty && hook.err.isEmpty)

        let asked = Task { try await runHelper(
            ["open", "--title", "From the binary", "--ticket", "BIN-1", "--message", "-"], // an old agent's flag
            environment: environment(rig), stdin: Data("Do the thing".utf8)
        ) }
        let entry = try #require(await rig.waitForEntries(1).first)
        #expect(entry.message == "Do the thing" && entry.title == "From the binary")
        let newID = try await rig.coordinator.approve(entry.id, start: recorder.start)
        let result = try await asked.value
        #expect(result.code == 0)
        #expect(result.out == "started \(newID.uuidString.lowercased()) \"From the binary\"\n")
    }
}

// MARK: Through the runtime

@Suite(.serialized, .timeLimit(.minutes(2)))
struct OpenSessionRuntimeTests {
    private func stub() throws -> (script: String, directory: URL) {
        let directory = URL(fileURLWithPath: "/tmp/lo-stub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("claude-stub.sh")
        try """
            #!/bin/sh
            printf '%s\\0' "$@" > "$LOOM_FAKE_STATE/argv-$LOOM_SESSION_ID"
            printf '%s\\n%s\\n' "$LOOM_CLI" "$LOOM_CONTROL_SOCKET" > "$LOOM_FAKE_STATE/env-$LOOM_SESSION_ID"
            exec sleep 120
            """.write(to: script, atomically: true, encoding: .utf8)
        #expect(chmod(script.path, 0o755) == 0)
        return (script.path, directory)
    }

    private func arguments(of session: UUID, in context: RuntimeContext) async -> [String]? {
        let file = context.state.appendingPathComponent("argv-\(session.uuidString)")
        let appeared = await SessionRuntimeTests.waitUntil { FileManager.default.fileExists(atPath: file.path) }
        guard appeared,
              let data = try? Data(contentsOf: file) else { return nil }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    @Test func claudeSessionsStartWithLoomsSkillFolderWrittenBeforeThem() async throws {
        let (script, directory) = try stub()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await SessionRuntimeTests.makeContext(executableOverride: script, claudePlugin: true)
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        let argv = try #require(await arguments(of: launch.sessionID, in: context))
        let index = try #require(argv.firstIndex(of: "--plugin-dir"))
        let plugin = URL(fileURLWithPath: argv[index + 1])
        #expect(plugin.standardizedFileURL == context.root.appendingPathComponent("claude-plugin").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: plugin.appendingPathComponent("skills/open-session/SKILL.md").path))
    }

    @Test func approvingARequestStartsANormalSessionWithTheNameTheMessageAndItsOrigin() async throws {
        let (script, directory) = try stub()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await SessionRuntimeTests.makeContext(executableOverride: script)
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project

        // The asking session: a normal Loom session (its stub never sends hook events).
        let requester = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        try await context.catalog.renameSession(sessionID: requester.sessionID, to: "Planner")
        let hooks = try #require(await context.runtime.hookConfiguration)
        let control = try #require(hooks.controlSocketPath)
        #expect(control.hasSuffix(".sock") && control.contains("/c-"))

        func ask(_ title: String, message: String, token: String? = nil,
                 from asker: RuntimeLaunch? = nil, session: UUID? = nil, run: UUID? = nil) -> Task<OpenSessionReply, any Error> {
            let asker = asker ?? requester
            let request = OpenSessionWireRequest(
                authenticationToken: token ?? hooks.authenticationToken, sessionID: session ?? asker.sessionID,
                managedRunID: run ?? asker.runID, title: title, project: nil, message: message
            )
            return Task.detached { try OpenSessionClient.exchange(request, socketPath: control) }
        }

        // Only the live run, for the card it was launched on, with the run's token.
        #expect(try await ask("Nope", message: "x", token: "wrong").value.status == .unavailable)
        #expect(try await ask("Nope", message: "x", session: UUID()).value.status == .unavailable)
        #expect(try await ask("Nope", message: "x", run: UUID()).value.status == .unavailable)
        #expect(await context.runtime.openRequestSnapshot().isEmpty)
        let message = "--starts with a dash\nand has a second line"
        let reply = ask("EDDP-412 Fix login", message: message)
        #expect(await SessionRuntimeTests.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let pending = try #require(await context.runtime.openRequestSnapshot().first)
        #expect(pending.requesterTitle == "Planner" && pending.projectID == project.id)
        // Asking started nothing: the catalog still has only the requester.
        #expect(try await context.catalog.sessions().map(\.session.id) == [requester.sessionID])

        let launch = try #require(try await context.runtime.approveOpenRequest(pending.id))
        let answer = try await reply.value
        #expect(answer.status == .started && answer.sessionID == launch.sessionID)
        #expect(await context.runtime.openRequestSnapshot().isEmpty)

        // The process was launched with the name and the message after every option.
        let argv = try #require(await arguments(of: launch.sessionID, in: context))
        #expect(argv.suffix(2) == ["--", message])
        let name = try #require(argv.firstIndex(of: "-n"))
        #expect(argv[name + 1] == "EDDP-412 Fix login")
        #expect(argv.starts(with: ["--session-id", launch.sessionID.uuidString]))
        let requesterArgv = try #require(await arguments(of: requester.sessionID, in: context))
        #expect(!requesterArgv.contains("-n") && !requesterArgv.contains("--"), "a user-started session is unchanged")
        // Its environment carries the command and the socket, like every Claude session.
        let envFile = context.state.appendingPathComponent("env-\(launch.sessionID.uuidString)")
        #expect(await SessionRuntimeTests.waitUntil { FileManager.default.fileExists(atPath: envFile.path) })
        let env = try String(contentsOf: envFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(env == [hooks.helperPath, control])

        // A normal Loom session: a card with the requested title (automatic), its origin and a run, and no tracker key.
        let row = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(row.title == "EDDP-412 Fix login" && row.titleIsCustom == false)
        #expect(row.openedBy == requester.sessionID)
        #expect(row.projectID == project.id && row.session.workingDirectory == project.path)
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(try await context.catalog.runs().contains { $0.id == launch.runID })

        // Loom does not look up existing sessions: asking again under the same title waits like any request.
        let same = ask("EDDP-412 Fix login", message: "again")
        #expect(await SessionRuntimeTests.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let waiting = try #require(await context.runtime.openRequestSnapshot().first)
        #expect(waiting.phase == .waiting && waiting.title == "EDDP-412 Fix login")
        try await context.runtime.denyOpenRequest(waiting.id)
        #expect(try await same.value.status == .denied)
        #expect(try await context.catalog.sessions().count == 2)

        // Deny starts nothing; a later approve of a denied request is refused.
        let no = ask("Denied", message: "no")
        #expect(await SessionRuntimeTests.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let denied = try #require(await context.runtime.openRequestSnapshot().first)
        try await context.runtime.denyOpenRequest(denied.id)
        #expect(try await no.value.status == .denied)
        await #expect(throws: OpenSessionError.self) { _ = try await context.runtime.approveOpenRequest(denied.id) }
        #expect(try await context.catalog.sessions().count == 2)

        // A run that has ended is no longer a live run: its token and ids ask nothing of Loom.
        _ = try await context.runtime.stopConversation(sessionID: requester.sessionID)
        #expect(try await ask("Too late", message: "late").value.status == .unavailable)
        #expect(await context.runtime.openRequestSnapshot().isEmpty)

        // Quit answers anyone still waiting and removes the control socket.
        let last = ask("At quit", message: "bye", from: launch)
        #expect(await SessionRuntimeTests.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(try await last.value.status == .unavailable)
        #expect(await SessionRuntimeTests.waitUntil { access(control, F_OK) != 0 })
    }
}
