import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore
import LoomTestSupport

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
        #expect(manifest["name"] as? String == "sphyrna")
        #expect(skill.hasPrefix("---\nname: open-session\ndescription: "))
        // Every option and result line the skill names is one the command has.
        for word in ["\"$SPHYRNA_CLI\" open", "--title", "--project", "--message-file", "--message -",
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
