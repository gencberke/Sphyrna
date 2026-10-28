import Foundation
import SQLite3
import Testing
@testable import LoomCore

struct HarnessProjectChoicesTests {
    @Test func projectMemoryIsPerHarnessAndNeverWritesAnotherProvidersRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c4-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let claude = ManagedSession(provider: .claude, workingDirectory: root.path)
        let codex = ManagedSession(provider: .codex, workingDirectory: root.path)
        try await catalog.insertSession(claude)
        try await catalog.insertSession(codex)
        let claudeChoices = HarnessLaunchChoices(model: "opus", effort: "high", mode: .acceptEdits)
        let codexChoices = HarnessLaunchChoices(harness: .codex, model: "codex-test", effort: "low")
        try await catalog.recordLaunchChoices(claudeChoices, sessionID: claude.id)
        try await catalog.recordLaunchChoices(codexChoices, sessionID: codex.id)
        let key = SessionCatalog.noProjectKey
        let remembered = try #require(await catalog.lastUsedHarnessChoices()[key])
        #expect(remembered.lastHarness == .codex)
        #expect(remembered.choices(for: .claude) == claudeChoices)
        #expect(remembered.choices(for: .codex) == codexChoices)
        #expect(try await catalog.lastUsedLaunchChoices()[key] == claudeChoices.claudeChoices)

        // Neither direction of a neutral cross-provider update changes the row or its project memory.
        try await catalog.recordLaunchChoices(HarnessLaunchChoices(model: "wrong"), sessionID: codex.id)
        try await catalog.recordLaunchChoices(HarnessLaunchChoices(harness: .codex, model: "wrong"), sessionID: claude.id)
        #expect(try await catalog.launchChoices(sessionID: codex.id).model == "codex-test")
        #expect(try await catalog.launchChoices(sessionID: claude.id).model == "opus")
        #expect(try await catalog.lastUsedHarnessChoices()[key] == remembered)

        // Agent-opened choices are recorded on the row, but never become project defaults.
        try await catalog.recordLaunchChoices(HarnessLaunchChoices(harness: .codex, model: "agent"),
                                              sessionID: codex.id, rememberingInProject: false)
        #expect(try await catalog.launchChoices(sessionID: codex.id).model == "agent")
        #expect(try await catalog.lastUsedHarnessChoices()[key] == remembered)

        try await catalog.recordLaunchChoices(HarnessLaunchChoices(model: "sonnet"), sessionID: claude.id)
        try await catalog.recordLaunchChoices(HarnessLaunchChoices(harness: .codex), sessionID: codex.id)
        let afterDefaultStart = try #require(await catalog.lastUsedHarnessChoices()[key])
        #expect(afterDefaultStart.lastHarness == .codex)
        #expect(afterDefaultStart.choices(for: .claude)?.model == "sonnet")
        #expect(afterDefaultStart.choices(for: .codex) == codexChoices)
        try await catalog.recordLaunchChoices(HarnessLaunchChoices(harness: .codex, model: "codex-next"),
                                              sessionID: codex.id, completeNewStart: true)
        let afterSwitch = try #require(await catalog.lastUsedHarnessChoices()[key]?.choices(for: .codex))
        #expect(afterSwitch.model == "codex-next" && afterSwitch.effort == nil)
    }

    @Test func identicalRememberedChoicesDoNotRewriteTheHarnessMap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c4-writes-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let catalog = try SessionCatalog(url: url)
        let session = ManagedSession(provider: .codex, workingDirectory: root.path)
        try await catalog.insertSession(session)
        let choices = HarnessLaunchChoices(harness: .codex, model: "codex-test")
        try await catalog.recordLaunchChoices(choices, sessionID: session.id)

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
            CREATE TABLE c4_write_counter (value INTEGER NOT NULL);
            INSERT INTO c4_write_counter VALUES (0);
            CREATE TRIGGER c4_count_update AFTER UPDATE ON app_state
            WHEN NEW.key = 'launch.last-used-harnesses'
            BEGIN UPDATE c4_write_counter SET value = value + 1; END;
            """, nil, nil, nil) == SQLITE_OK)
        try await catalog.recordLaunchChoices(choices, sessionID: session.id)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT value FROM c4_write_counter", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
    }

    @Test func aCompleteNewStartReplacesDefaultsButPartialLiveChangesStillMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c4-default-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(session)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "plan", model: "opus", effort: "high"),
                                              sessionID: session.id)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(model: "sonnet"), sessionID: session.id)
        #expect(try await catalog.lastUsedLaunchChoices()["none"]?.effort == "high", "a partial live change still merges")
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "bypassPermissions", model: "sonnet"),
                                              sessionID: session.id, completeNewStart: true)
        let afterModel = try #require(await catalog.lastUsedLaunchChoices()["none"])
        #expect(afterModel.permissionMode == "plan" && afterModel.model == "sonnet" && afterModel.effort == nil)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "default"),
                                              sessionID: session.id, completeNewStart: true)
        let afterDefault = try #require(await catalog.lastUsedLaunchChoices()["none"])
        #expect(afterDefault.permissionMode == "default" && afterDefault.model == nil && afterDefault.effort == nil)
    }
}
