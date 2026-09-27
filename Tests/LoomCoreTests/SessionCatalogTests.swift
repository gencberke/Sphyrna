import Foundation
import SQLite3
import Testing
@testable import LoomCore

@Suite(.serialized)
struct SessionCatalogTests {
    private func temporaryCatalogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-catalog-\(UUID())", isDirectory: true)
            .appendingPathComponent("sessions.sqlite3")
    }

    @Test func catalogPersistsConversationAndCompletedRunAcrossReopen() async throws {
        let url = temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sessionID = UUID()
        let runID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let startedAt = createdAt.addingTimeInterval(10)
        let endedAt = startedAt.addingTimeInterval(20)
        let leader = ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 200)

        do {
            let catalog = try SessionCatalog(url: url)
            let session = ManagedSession(
                id: sessionID, provider: .claude,
                providerConversationID: "claude-before",
                workingDirectory: "/tmp/catalog-workspace"
            )
            try await catalog.insertSession(
                session, title: "Durable session", createdAt: createdAt,
                lastUsedAt: createdAt, lifecycle: .active, pinned: true
            )
            try await catalog.updateProviderConversationID(
                sessionID: sessionID, newID: "claude-after",
                changedAt: createdAt.addingTimeInterval(5)
            )
            let run = ManagedRun(
                id: runID, leader: leader, startedAt: startedAt,
                state: .running, exitStatus: nil, descendants: [leader]
            )
            try await catalog.startRun(run, sessionID: sessionID)
            try await catalog.finishRun(
                runID, endedAt: endedAt, reason: .processExited, exitStatus: 7 << 8
            )
        }

        let reopened = try SessionCatalog(url: url)
        let sessions = try await reopened.sessions()
        let stored = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(stored.session.id == sessionID)
        #expect(stored.session.provider == .claude)
        #expect(stored.session.providerConversationID == "claude-after")
        #expect(stored.session.workingDirectory == "/tmp/catalog-workspace")
        #expect(stored.session.currentRun == nil)
        #expect(stored.title == "Durable session")
        #expect(stored.lifecycle == .active)
        #expect(stored.pinned)

        let runs = try await reopened.runs()
        let storedRun = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(storedRun.id == runID)
        #expect(storedRun.initialSessionID == sessionID)
        #expect(storedRun.leader == leader)
        #expect(storedRun.endedAt == endedAt)
        #expect(storedRun.endReason == .processExited)
        #expect(storedRun.exitStatus == 7 << 8)

        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        #expect(try scalarText("PRAGMA journal_mode", database: handle).lowercased() == "wal")
        #expect(try scalarInt("PRAGMA user_version", database: handle) == SessionCatalog.schemaVersion)
        #expect(try scalarInt("PRAGMA application_id", database: handle) == 1_280_266_061)
    }

    @Test func corruptCatalogIsRejectedWithoutOverwrite() throws {
        let url = temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let sentinel = Data("not a sqlite database: keep me".utf8)
        try sentinel.write(to: url)

        do {
            _ = try SessionCatalog(url: url)
            Issue.record("Corrupt catalog was accepted")
        } catch let error as SessionCatalogError {
            guard case .sqlite = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: url) == sentinel)
    }

    @Test func unmarkedSQLiteDatabaseIsRejectedBeforeWALIsEnabled() throws {
        let url = temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        #expect(sqlite3_exec(handle, "PRAGMA user_version = 1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        do {
            _ = try SessionCatalog(url: url)
            Issue.record("Unmarked SQLite database was accepted")
        } catch let error as SessionCatalogError {
            guard case .foreignDatabase(applicationID: 0) = error else {
                Issue.record("Unexpected catalog error: \(error)")
                return
            }
        }

        var reopened: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &reopened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let reopenedHandle = try #require(reopened)
        defer { sqlite3_close(reopenedHandle) }
        #expect(try scalarText("PRAGMA journal_mode", database: reopenedHandle).lowercased() == "delete")
        #expect(try scalarInt("PRAGMA application_id", database: reopenedHandle) == 0)
    }

    private func scalarInt(_ sql: String, database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SessionCatalogError.invalidRow("test query preparation failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SessionCatalogError.invalidRow("test query returned no row")
        }
        return sqlite3_column_int(statement, 0)
    }

    private func scalarText(_ sql: String, database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SessionCatalogError.invalidRow("test query preparation failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw SessionCatalogError.invalidRow("test query returned no text")
        }
        return String(cString: value)
    }
}
