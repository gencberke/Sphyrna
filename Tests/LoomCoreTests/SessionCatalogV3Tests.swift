import Foundation
import SQLite3
import Testing
@testable import LoomCore

/// CP4-B: schema 3 (deletion records, stale_since, app state), the delete
/// transaction, the fences and the skip-and-count handling of bad rows.
@Suite(.serialized)
struct SessionCatalogV3Tests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-catalog-v3-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Runs SQL on a separate short-lived connection; returns the first
    /// column of every row as text (NULL as "NULL").
    @discardableResult
    private func sql(_ statement: String, at url: URL, readOnly: Bool = false) throws -> [String] {
        var database: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        #expect(sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2_000)
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw SessionCatalogError.invalidRow("test SQL failed: \(statement)")
        }
        defer { sqlite3_finalize(prepared) }
        var rows: [String] = []
        var result = sqlite3_step(prepared)
        while result == SQLITE_ROW {
            let count = sqlite3_column_count(prepared)
            rows.append((0..<count).map { column in
                sqlite3_column_type(prepared, column) == SQLITE_NULL
                    ? "NULL" : String(cString: sqlite3_column_text(prepared, column))
            }.joined(separator: "|"))
            result = sqlite3_step(prepared)
        }
        guard result == SQLITE_DONE else { throw SessionCatalogError.invalidRow("test SQL failed: \(statement)") }
        return rows
    }

    private func exec(_ statements: [String], at url: URL) throws {
        for statement in statements { try sql(statement, at: url) }
    }

    // MARK: Schema 2 fixture

    private struct SchemaTwoIDs {
        let sessions = [UUID(), UUID(), UUID()]
        let runs = [UUID(), UUID()]
        let project = UUID()
    }

    /// A schema 2 database exactly as the previous build wrote it (WAL mode).
    private func writeSchemaTwo(at url: URL) throws -> SchemaTwoIDs {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let ids = SchemaTwoIDs()
        try exec([
            "PRAGMA journal_mode = WAL",
            "PRAGMA application_id = 1280266061",
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL,
                provider_conversation_id TEXT, working_directory TEXT NOT NULL, title TEXT,
                created_at REAL NOT NULL, last_used_at REAL NOT NULL,
                lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active', 'idle', 'stale')),
                pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)))
            """,
            """
            CREATE TABLE runs (
                id TEXT PRIMARY KEY NOT NULL, initial_session_id TEXT NOT NULL REFERENCES sessions(id),
                leader_pid INTEGER NOT NULL, leader_start_seconds INTEGER NOT NULL,
                leader_start_microseconds INTEGER NOT NULL, started_at REAL NOT NULL,
                ended_at REAL, end_reason TEXT, exit_status INTEGER)
            """,
            """
            CREATE TABLE run_sessions (
                run_id TEXT NOT NULL REFERENCES runs(id), session_id TEXT NOT NULL REFERENCES sessions(id),
                linked_at REAL NOT NULL, unlinked_at REAL,
                PRIMARY KEY (run_id, session_id, linked_at))
            """,
            """
            CREATE TABLE provider_identity_changes (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                previous_id TEXT, new_id TEXT NOT NULL, changed_at REAL NOT NULL)
            """,
            """
            CREATE TABLE projects (
                id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
                sort_order INTEGER NOT NULL, collapsed INTEGER NOT NULL DEFAULT 0 CHECK (collapsed IN (0, 1)),
                created_at REAL NOT NULL)
            """,
            "ALTER TABLE sessions ADD COLUMN project_id TEXT REFERENCES projects(id)",
            "ALTER TABLE sessions ADD COLUMN title_is_custom INTEGER NOT NULL DEFAULT 0 CHECK (title_is_custom IN (0, 1))",
            "CREATE INDEX sessions_last_used ON sessions(last_used_at DESC, id DESC)",
            "CREATE INDEX sessions_created ON sessions(created_at, id)",
            "CREATE INDEX sessions_project_created ON sessions(project_id, created_at, id)",
            "CREATE INDEX sessions_lifecycle_used ON sessions(lifecycle, last_used_at)",
            "CREATE INDEX sessions_conversation ON sessions(provider, provider_conversation_id)",
            "INSERT INTO projects VALUES ('\(ids.project)', '/tmp/p', 'p', 0, 0, 50)",
            """
            INSERT INTO sessions (id, provider, provider_conversation_id, working_directory, title,
                created_at, last_used_at, lifecycle, pinned, project_id, title_is_custom) VALUES
            ('\(ids.sessions[0])', 'claude', 'claude-old', '/tmp/one', 'First', 100, 200, 'idle', 1, '\(ids.project)', 1),
            ('\(ids.sessions[1])', 'claude', 'claude-new', '/tmp/one', NULL, 300, 400, 'active', 0, NULL, 0),
            ('\(ids.sessions[2])', 'codex', NULL, '/tmp/two', 'Third', 500, 600, 'stale', 0, NULL, 0)
            """,
            """
            INSERT INTO runs VALUES
            ('\(ids.runs[0])', '\(ids.sessions[0])', 41, 1000, 2000, 110, 390, 'processExited', 256),
            ('\(ids.runs[1])', '\(ids.sessions[2])', 42, 1001, 2001, 510, NULL, NULL, NULL)
            """,
            """
            INSERT INTO run_sessions VALUES
            ('\(ids.runs[0])', '\(ids.sessions[0])', 110, 300),
            ('\(ids.runs[0])', '\(ids.sessions[1])', 300, NULL),
            ('\(ids.runs[1])', '\(ids.sessions[2])', 510, NULL)
            """,
            """
            INSERT INTO provider_identity_changes (session_id, previous_id, new_id, changed_at)
            VALUES ('\(ids.sessions[1])', 'claude-old', 'claude-new', 300)
            """,
            "PRAGMA user_version = 2",
        ], at: url)
        return ids
    }

    /// Every schema 2 column of every table, in a comparable form.
    private func schemaTwoDump(at url: URL) throws -> [String] {
        try [
            "SELECT id, provider, provider_conversation_id, working_directory, title, created_at, last_used_at, lifecycle, pinned, project_id, title_is_custom FROM sessions ORDER BY id",
            "SELECT * FROM runs ORDER BY id",
            "SELECT * FROM run_sessions ORDER BY run_id, session_id, linked_at",
            "SELECT * FROM provider_identity_changes ORDER BY sequence",
            "SELECT * FROM projects ORDER BY id",
        ].flatMap { try sql($0, at: url, readOnly: true) }
    }

    private func catalogURL(_ root: URL) -> URL { root.appendingPathComponent("catalog.sqlite3") }

    private func claude(_ directory: String = "/tmp/w") -> ManagedSession {
        ManagedSession(provider: .claude, workingDirectory: directory)
    }

    private func plan(for sessionID: UUID, ids: [String]? = nil) -> CatalogDeletionPlan {
        CatalogDeletionPlan(provider: .claude, providerIDs: ids ?? [sessionID.uuidString],
                            configDirectory: "/tmp/claude-config", workingDirectory: "/tmp/w")
    }

    // MARK: Migration

    @Test func schemaTwoMigratesToThreeKeepingEveryRowAndIdentity() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        let ids = try writeSchemaTwo(at: url)
        let before = try schemaTwoDump(at: url)
        #expect(before.count == 10)

        let catalog = try SessionCatalog(url: url)
        #expect(try schemaTwoDump(at: url) == before)
        #expect(try sql("PRAGMA user_version", at: url) == ["3"])
        #expect(SessionCatalog.schemaVersion == 3)
        #expect(try sql("PRAGMA foreign_key_check", at: url).isEmpty)
        #expect(try sql("PRAGMA quick_check", at: url) == ["ok"])
        #expect(try sql("""
            SELECT name FROM sqlite_master WHERE type = 'index'
            AND name IN ('run_sessions_session', 'runs_initial_session', 'identity_changes_session')
            ORDER BY name
            """, at: url) == ["identity_changes_session", "run_sessions_session", "runs_initial_session"])
        #expect(try sql("SELECT count(*) FROM deletions", at: url) == ["0"])
        #expect(try sql("SELECT count(*) FROM sessions WHERE stale_since IS NOT NULL", at: url) == ["0"])

        let sessions = try await catalog.sessions()
        #expect(Set(sessions.map(\.session.id)) == Set(ids.sessions))
        #expect(sessions.allSatisfy { $0.staleSince == nil })
        #expect(try await catalog.runs().count == 2)
        #expect(try await catalog.runSessionLinks().count == 3)
        #expect(try await catalog.pendingDeletions().isEmpty)
        #expect(await catalog.skippedRowCount == 0)

        let reopened = try SessionCatalog(url: url)
        #expect(try await reopened.sessions().count == 3)
    }

    @Test func interruptedVersionThreeMigrationRollsBackAndReopensClean() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        _ = try writeSchemaTwo(at: url)
        let before = try schemaTwoDump(at: url)

        struct Interrupted: Error {}
        do {
            _ = try SessionCatalog(url: url, versionedMigrationFailpoint: { version in
                if version == 3 { throw Interrupted() }
            })
            Issue.record("The version 3 failpoint did not interrupt the migration")
        } catch is Interrupted {}

        #expect(try sql("PRAGMA user_version", at: url) == ["2"])
        #expect(try sql("SELECT count(*) FROM sqlite_master WHERE name IN ('deletions', 'app_state')", at: url) == ["0"])
        #expect(try sql("SELECT count(*) FROM pragma_table_info('sessions') WHERE name = 'stale_since'", at: url) == ["0"])
        #expect(try schemaTwoDump(at: url) == before)

        let catalog = try SessionCatalog(url: url)
        #expect(try await catalog.sessions().count == 3)
        #expect(try sql("PRAGMA user_version", at: url) == ["3"])
        #expect(try schemaTwoDump(at: url) == before)
    }

    @Test func interruptedChainFromSchemaOneLeavesSchemaOne() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        // Schema 1: the schema 2 fixture minus the 2-only parts is awkward to build,
        // so reuse the fixture tool's shape through plain SQL.
        try exec([
            "PRAGMA journal_mode = WAL", "PRAGMA application_id = 1280266061",
            "CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL, provider_conversation_id TEXT, working_directory TEXT NOT NULL, title TEXT, created_at REAL NOT NULL, last_used_at REAL NOT NULL, lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active', 'idle', 'stale')), pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)))",
            "CREATE TABLE runs (id TEXT PRIMARY KEY NOT NULL, initial_session_id TEXT NOT NULL REFERENCES sessions(id), leader_pid INTEGER NOT NULL, leader_start_seconds INTEGER NOT NULL, leader_start_microseconds INTEGER NOT NULL, started_at REAL NOT NULL, ended_at REAL, end_reason TEXT, exit_status INTEGER)",
            "CREATE TABLE run_sessions (run_id TEXT NOT NULL REFERENCES runs(id), session_id TEXT NOT NULL REFERENCES sessions(id), linked_at REAL NOT NULL, unlinked_at REAL, PRIMARY KEY (run_id, session_id, linked_at))",
            "CREATE TABLE provider_identity_changes (sequence INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), previous_id TEXT, new_id TEXT NOT NULL, changed_at REAL NOT NULL)",
            "INSERT INTO sessions VALUES ('\(UUID())', 'claude', 'c', '/tmp', 'One', 1, 2, 'idle', 0)",
            "PRAGMA user_version = 1",
        ], at: url)

        struct Interrupted: Error {}
        do {
            _ = try SessionCatalog(url: url, versionedMigrationFailpoint: { version in
                if version == 3 { throw Interrupted() }
            })
            Issue.record("The failpoint did not interrupt the chain")
        } catch is Interrupted {}
        #expect(try sql("PRAGMA user_version", at: url) == ["1"])
        #expect(try sql("SELECT count(*) FROM sqlite_master WHERE name = 'projects'", at: url) == ["0"])

        let catalog = try SessionCatalog(url: url)
        #expect(try await catalog.sessions().map(\.title) == ["One"])
        #expect(try sql("PRAGMA user_version", at: url) == ["3"])
    }

    @Test func aBuildOlderThanTheFileRefusesItAndLeavesItUntouched() throws {
        // A schema 2 build refuses `user_version > 2` with the same guard that
        // this build applies to a newer catalog (DP-CP4-4: no downgrade).
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        _ = try SessionCatalog(url: url)
        try exec(["PRAGMA user_version = \(SessionCatalog.schemaVersion + 1)"], at: url)
        let before = try Data(contentsOf: url)
        do {
            _ = try SessionCatalog(url: url)
            Issue.record("A newer catalog was accepted")
        } catch let error as SessionCatalogError {
            guard case let .unsupportedSchema(version) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(version == SessionCatalog.schemaVersion + 1)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func theAppConnectionOverwritesDeletedContent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try CatalogDatabase(url: catalogURL(root))
        // 1 = ON (the build default is 2 = FAST, which is not a documented guarantee).
        #expect(try database.scalarInt64("PRAGMA secure_delete") == 1)
    }

    // MARK: Delete transaction

    @Test func deleteRepointsASharedRunAndLeavesOtherConversationsIntact() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        let catalog = try SessionCatalog(url: url)
        let first = claude(), cleared = claude(), other = claude()
        try await catalog.insertSession(first, title: "first", createdAt: Date(timeIntervalSince1970: 10))
        try await catalog.insertSession(other, title: "other", createdAt: Date(timeIntervalSince1970: 11))
        let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)
        let sharedRun = ManagedRun(id: UUID(), leader: leader, startedAt: Date(timeIntervalSince1970: 20),
                                   state: .running, exitStatus: nil, descendants: [leader])
        try await catalog.startRun(sharedRun, sessionID: first.id)
        try await catalog.updateProviderConversationID(sessionID: first.id, newID: "claude-first")
        // /clear: the live run moves to a new conversation.
        try await catalog.transitionRun(sharedRun.id, from: first.id, to: cleared,
                                        at: Date(timeIntervalSince1970: 30))
        let soloRun = ManagedRun(id: UUID(), leader: leader, startedAt: Date(timeIntervalSince1970: 40),
                                 state: .running, exitStatus: nil, descendants: [leader])
        try await catalog.startRun(soloRun, sessionID: other.id)
        // A run whose only conversation is the deleted one is deleted with it.
        let doomedRun = ManagedRun(id: UUID(), leader: leader, startedAt: Date(timeIntervalSince1970: 50),
                                   state: .running, exitStatus: nil, descendants: [leader])
        let doomed = claude()
        try await catalog.insertSession(doomed, title: "doomed", createdAt: Date(timeIntervalSince1970: 12))
        try await catalog.startRun(doomedRun, sessionID: doomed.id)
        try await catalog.updateProviderConversationID(sessionID: doomed.id, newID: "claude-doomed")

        try await catalog.beginDeletion(sessionID: first.id, plan: plan(for: first.id))
        #expect(try await catalog.deleteSessionRows(sessionID: first.id))

        #expect(try await catalog.session(id: first.id) == nil)
        let runs = try await catalog.runs()
        #expect(runs.first { $0.id == sharedRun.id }?.initialSessionID == cleared.id)
        #expect(runs.contains { $0.id == soloRun.id })
        let links = try await catalog.runSessionLinks()
        #expect(links.filter { $0.runID == sharedRun.id }.map(\.sessionID) == [cleared.id])
        #expect(links.contains { $0.sessionID == other.id })
        #expect(try await catalog.session(id: cleared.id)?.lifecycle == .active)
        #expect(try await catalog.session(id: other.id)?.title == "other")
        #expect(try sql("SELECT count(*) FROM provider_identity_changes WHERE session_id = '\(first.id)'", at: url) == ["0"])
        #expect(try sql("PRAGMA foreign_key_check", at: url).isEmpty)

        // The run of the deleted conversation alone disappears with it.
        try await catalog.beginDeletion(sessionID: doomed.id, plan: plan(for: doomed.id))
        #expect(try await catalog.deleteSessionRows(sessionID: doomed.id))
        #expect(try await catalog.runs().contains { $0.id == doomedRun.id } == false)
        #expect(try await catalog.runs().count == 2)
        #expect(try sql("PRAGMA foreign_key_check", at: url).isEmpty)
        #expect(try sql("PRAGMA quick_check", at: url) == ["ok"])

        // Idempotent: a repeated delete is a no-op, not an error.
        #expect(try await catalog.deleteSessionRows(sessionID: first.id) == false)

        let reopened = try SessionCatalog(url: url)
        #expect(Set(try await reopened.sessions().map(\.session.id)) == [cleared.id, other.id])
    }

    @Test func aFailureInsideTheDeleteTransactionRollsBackAndTheRetryCompletes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        struct Interrupted: Error {}
        let armed = LockedFlag(true)
        let catalog = try SessionCatalog(url: url, deleteRowsFailpoint: {
            if armed.value { throw Interrupted() }
        })
        let target = claude()
        try await catalog.insertSession(target, title: "target")
        let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)
        let run = ManagedRun(id: UUID(), leader: leader, startedAt: Date(), state: .running,
                             exitStatus: nil, descendants: [leader])
        try await catalog.startRun(run, sessionID: target.id)
        try await catalog.beginDeletion(sessionID: target.id, plan: plan(for: target.id))

        do {
            try await catalog.deleteSessionRows(sessionID: target.id)
            Issue.record("The failpoint did not interrupt the delete")
        } catch is Interrupted {}
        #expect(try await catalog.session(id: target.id) != nil)
        #expect(try await catalog.runs().count == 1)
        #expect(try await catalog.runSessionLinks().count == 1)

        armed.value = false
        #expect(try await catalog.deleteSessionRows(sessionID: target.id))
        #expect(try await catalog.session(id: target.id) == nil)
        #expect(try await catalog.runs().isEmpty)
    }

    // MARK: Deletion records

    @Test func deletionStatesPersistAcrossReopenAndNeverGoBack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        let target = claude()
        let started = Date(timeIntervalSince1970: 1_000)
        var catalog = try SessionCatalog(url: url)
        try await catalog.insertSession(target, title: "SECRET-TITLE-MARKER")
        let ids = [target.id.uuidString, "11111111-2222-3333-4444-555555555555"]
        try await catalog.beginDeletion(sessionID: target.id, plan: plan(for: target.id, ids: ids), at: started)

        do {
            try await catalog.beginDeletion(sessionID: target.id, plan: plan(for: target.id))
            Issue.record("A second beginDeletion was accepted")
        } catch let error as SessionCatalogError {
            guard case .deletionAlreadyRequested = error else { throw error }
        }
        do {
            try await catalog.beginDeletion(sessionID: UUID(), plan: plan(for: UUID()))
            Issue.record("A deletion for an unknown conversation was accepted")
        } catch let error as SessionCatalogError {
            guard case .invalidRow = error else { throw error }
        }

        var expectedAttempts = 0
        for (index, state) in CatalogDeletionState.allCases.enumerated() {
            catalog = try SessionCatalog(url: url)   // "crash": reopen before each step
            let before = try #require(try await catalog.pendingDeletions().first)
            #expect(before.plan.providerIDs == ids)
            #expect(before.plan.configDirectory == "/tmp/claude-config")
            let failure = index == 2
                ? CatalogDeletionFailure(category: "Partial Failure!", file: "/Users/someone/.claude/projects/x/\(target.id).jsonl")
                : nil
            if failure != nil { expectedAttempts += 1 }
            try await catalog.advanceDeletion(sessionID: target.id, to: state, error: failure,
                                              at: started.addingTimeInterval(Double(index + 1)))
            let after = try #require(try await catalog.deletion(for: target.id))
            #expect(after.state == state)
            #expect(after.attempts == expectedAttempts)
            #expect(after.requestedAt == started)
            if let failure {
                #expect(after.lastError == "partial-failure-: \(target.id).jsonl")
                #expect(failure.fileName == "\(target.id).jsonl")
            } else {
                #expect(after.lastError == nil)
            }
        }
        // A retry in the same state is allowed; going back is not.
        try await catalog.advanceDeletion(sessionID: target.id, to: .verifying,
                                          error: CatalogDeletionFailure(category: "verify"))
        do {
            try await catalog.advanceDeletion(sessionID: target.id, to: .stopping)
            Issue.record("A deletion went back a state")
        } catch let error as SessionCatalogError {
            guard case .invalidRow = error else { throw error }
        }
        #expect(try await catalog.deletion(for: target.id)?.attempts == expectedAttempts + 1)

        // The record carries neither a title nor a directory path inside errors.
        let record = try sql("SELECT * FROM deletions", at: url, readOnly: true)
        #expect(record.count == 1)
        #expect(record.allSatisfy { !$0.contains("SECRET-TITLE-MARKER") && !$0.contains("/Users/someone") })

        try await catalog.finishDeletion(sessionID: target.id)
        try await catalog.finishDeletion(sessionID: target.id)   // absent is fine
        #expect(try await catalog.pendingDeletions().isEmpty)
    }

    @Test func fencesRefuseOrExcludeAConversationWithAPendingDeletion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        let catalog = try SessionCatalog(url: url)
        let project = try await catalog.addProject(path: root.path).project
        let target = claude(), bystander = claude(), runTarget = claude()
        let old = Date(timeIntervalSince1970: 100)
        try await catalog.insertSession(target, title: "pending", createdAt: old, lastUsedAt: old,
                                        lifecycle: .idle, projectID: project.id)
        try await catalog.insertSession(bystander, title: "bystander", createdAt: old, lastUsedAt: old,
                                        lifecycle: .idle, projectID: project.id)
        try await catalog.insertSession(runTarget, title: "run target", createdAt: old, lastUsedAt: old)
        let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)
        let run = ManagedRun(id: UUID(), leader: leader, startedAt: Date(), state: .running,
                             exitStatus: nil, descendants: [leader])
        try await catalog.startRun(run, sessionID: bystander.id)

        try await catalog.beginDeletion(sessionID: target.id, plan: plan(for: target.id))
        try await catalog.beginDeletion(sessionID: runTarget.id, plan: plan(for: runTarget.id))

        // Lists and counts exclude the pending ids.
        #expect(try await catalog.sessions().map(\.session.id) == [bystander.id])
        #expect(try await catalog.sessionPage(CatalogQuery()).sessions.map(\.session.id) == [bystander.id])
        #expect(try await catalog.sessionPage(CatalogQuery(scope: .unassigned)).sessions.isEmpty)
        #expect(try await catalog.sessionCounts()[project.id] == 1)
        #expect(try await catalog.sessionCounts()[nil] == nil)

        // Use and reactivation are refused and write nothing.
        for reactivate in [false, true] {
            do {
                try await catalog.markUsed(sessionID: target.id, reactivate: reactivate)
                Issue.record("markUsed(reactivate: \(reactivate)) was accepted for a pending id")
            } catch let error as SessionCatalogError {
                guard case .deletionPending(target.id) = error else { throw error }
            }
        }
        let untouched = try #require(try await catalog.session(id: target.id))
        #expect(untouched.lastUsedAt == old)
        #expect(untouched.lifecycle == .idle)
        // Starting a run on it or moving a live run to it is refused.
        do {
            try await catalog.startRun(ManagedRun(id: UUID(), leader: leader, startedAt: Date(), state: .running,
                                                  exitStatus: nil, descendants: [leader]), sessionID: target.id)
            Issue.record("startRun was accepted for a pending id")
        } catch let error as SessionCatalogError {
            guard case .deletionPending = error else { throw error }
        }
        do {
            try await catalog.transitionRun(run.id, from: bystander.id, toExistingSessionID: target.id)
            Issue.record("transitionRun to a pending id was accepted")
        } catch let error as SessionCatalogError {
            guard case .deletionPending = error else { throw error }
        }
        #expect(try await catalog.runSessionLinks().filter { $0.unlinkedAt == nil }.map(\.sessionID) == [bystander.id])
        // The stale pass leaves it alone (and still classifies the bystander).
        let stale = try await catalog.classifyStale(before: Date(), staleAfter: 60)
        #expect(stale == [bystander.id])
        #expect(try await catalog.session(id: target.id)?.lifecycle == .idle)
        #expect(try await catalog.oldestStaleCandidate() == nil)
        // A direct lookup still works: the deleter needs the row.
        #expect(try await catalog.isDeletionPending(target.id))

        // Once the record is gone the id is usable again.
        try await catalog.finishDeletion(sessionID: target.id)
        try await catalog.markUsed(sessionID: target.id, at: Date(timeIntervalSince1970: 500))
        #expect(try await catalog.session(id: target.id)?.lastUsedAt == Date(timeIntervalSince1970: 500))
    }

    // MARK: Identity questions, stale_since, pin, app state

    @Test func providerIDsCollectEveryIdentityAndSharingIsDetected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: catalogURL(root))
        let a = ManagedSession(provider: .claude, providerConversationID: "conv-a", workingDirectory: "/tmp/a")
        let b = ManagedSession(provider: .claude, providerConversationID: "conv-b", workingDirectory: "/tmp/b")
        let c = ManagedSession(provider: .claude, providerConversationID: nil, workingDirectory: "/tmp/c")
        for session in [a, b, c] { try await catalog.insertSession(session) }
        try await catalog.updateProviderConversationID(sessionID: a.id, newID: "conv-a2")
        try await catalog.updateProviderConversationID(sessionID: c.id, newID: "conv-b")   // c shares b's id

        let idsA = try await catalog.providerIDs(of: a.id)
        #expect(idsA.first == a.id.uuidString)
        #expect(Set(idsA) == [a.id.uuidString, "conv-a", "conv-a2"])
        #expect(try await catalog.providerIDs(of: c.id).contains("conv-b"))
        #expect(try await catalog.providerIDs(of: UUID()).count == 1)

        #expect(try await catalog.isProviderIDShared("conv-a2", excluding: a.id) == false)
        #expect(try await catalog.isProviderIDShared(a.id.uuidString, excluding: a.id) == false)
        #expect(try await catalog.isProviderIDShared("conv-b", excluding: b.id))
        #expect(try await catalog.isProviderIDShared("CONV-B", excluding: c.id))
        #expect(try await catalog.isProviderIDShared(b.id.uuidString.lowercased(), excluding: a.id))
        #expect(try await catalog.isProviderIDShared("conv-a", excluding: UUID()))
    }

    @Test func staleSinceFollowsClassificationAndClearsOnReactivation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: catalogURL(root))
        let known = claude(), unknown = claude(), live = claude()
        for (session, used) in [(known, 1_000.0), (unknown, 2_000.0), (live, 100.0)] {
            try await catalog.insertSession(session, createdAt: Date(timeIntervalSince1970: 1),
                                            lastUsedAt: Date(timeIntervalSince1970: used))
        }
        // Without staleAfter the value stays unknown (NULL).
        try await catalog.classifyStale(before: Date(timeIntervalSince1970: 3_000), excluding: [known.id, live.id])
        #expect(try await catalog.session(id: unknown.id)?.lifecycle == .stale)
        #expect(try await catalog.session(id: unknown.id)?.staleSince == nil)
        // With it: last use + staleAfter; a running row is skipped.
        let changed = try await catalog.classifyStale(
            before: Date(timeIntervalSince1970: 3_000), excluding: [live.id], staleAfter: 500
        )
        #expect(changed == [known.id])
        #expect(try await catalog.session(id: known.id)?.staleSince == Date(timeIntervalSince1970: 1_500))
        #expect(try await catalog.session(id: live.id)?.staleSince == nil)
        // A view keeps both the state and the value; a reactivation clears it.
        try await catalog.markUsed(sessionID: known.id, at: Date(timeIntervalSince1970: 4_000))
        #expect(try await catalog.session(id: known.id)?.lifecycle == .stale)
        #expect(try await catalog.session(id: known.id)?.staleSince == Date(timeIntervalSince1970: 1_500))
        try await catalog.markUsed(sessionID: known.id, at: Date(timeIntervalSince1970: 5_000), reactivate: true)
        #expect(try await catalog.session(id: known.id)?.lifecycle == .active)
        #expect(try await catalog.session(id: known.id)?.staleSince == nil)
        // Any other move out of stale clears it too.
        try await catalog.classifyStale(before: Date(timeIntervalSince1970: 9_000), staleAfter: 1)
        #expect(try await catalog.session(id: known.id)?.staleSince == Date(timeIntervalSince1970: 5_001))
        try await catalog.updateLifecycle(sessionID: known.id, lifecycle: .idle)
        #expect(try await catalog.session(id: known.id)?.staleSince == nil)
    }

    @Test func pinAndAppStateAreStoredAndSurviveReopen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        let catalog = try SessionCatalog(url: url)
        let session = claude()
        try await catalog.insertSession(session)
        try await catalog.setPinned(true, for: session.id)
        try await catalog.setAppState("last_cleanup_at", to: "100")
        try await catalog.setAppState("last_cleanup_at", to: "200")
        try await catalog.setAppState("last_launch_at", to: "300")
        do {
            try await catalog.setPinned(true, for: UUID())
            Issue.record("Pinning an unknown conversation was accepted")
        } catch let error as SessionCatalogError {
            guard case .invalidRow = error else { throw error }
        }
        let reopened = try SessionCatalog(url: url)
        #expect(try await reopened.session(id: session.id)?.pinned == true)
        #expect(try await reopened.appState("last_cleanup_at") == "200")
        #expect(try await reopened.appState("last_launch_at") == "300")
        #expect(try await reopened.appState("missing") == nil)
        try await reopened.setPinned(false, for: session.id)
        #expect(try await reopened.session(id: session.id)?.pinned == false)
    }

    // MARK: Undecodable rows

    @Test func undecodableRowsAreSkippedCountedAndNeverTouched() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        let catalog = try SessionCatalog(url: url)
        var good: [UUID] = []
        for index in 0..<7 {
            let session = claude()
            good.append(session.id)
            try await catalog.insertSession(
                session, title: "good \(index)", createdAt: Date(timeIntervalSince1970: Double(1_000 + index)),
                lastUsedAt: Date(timeIntervalSince1970: Double(1_000 + index))
            )
        }
        // Bad rows interleaved with the good ones (the lifecycle CHECK keeps
        // an unknown lifecycle out of the table, so: provider, UUID, project).
        let badProjectSession = UUID()
        try exec([
            "INSERT INTO sessions (id, provider, working_directory, created_at, last_used_at, lifecycle, pinned) VALUES ('not-a-uuid', 'claude', '/x', 1002.5, 1002.5, 'idle', 0)",
            "INSERT INTO sessions (id, provider, working_directory, created_at, last_used_at, lifecycle, pinned) VALUES ('\(UUID())', 'martian', '/x', 1003.5, 1003.5, 'active', 0)",
        ], at: url)
        // Raw connections do not enforce foreign keys, so the dangling project id is writable.
        try sql("""
            INSERT INTO sessions (id, provider, working_directory, created_at, last_used_at, lifecycle, pinned, project_id)
            VALUES ('\(badProjectSession)', 'claude', '/x', 1004.5, 1004.5, 'idle', 0, 'also-not-a-uuid')
            """, at: url)
        try sql("INSERT INTO sessions (id, provider, working_directory, created_at, last_used_at, lifecycle, pinned) VALUES ('zzzz', 'claude', '/x', 5000, 5000, 'idle', 0)", at: url)
        let rawBefore = try sql("SELECT * FROM sessions WHERE id IN ('not-a-uuid', 'zzzz') OR provider = 'martian' OR project_id IS NOT NULL ORDER BY id", at: url)
        #expect(rawBefore.count == 4)

        let listed = try await catalog.sessions()
        #expect(listed.map(\.session.id) == good)
        #expect(await catalog.skippedRowCount == 4)

        // Paging stays correct: every good row exactly once, in order, no
        // short page hiding a later one, and the scan reports what it skipped.
        var seen: [UUID] = []
        var cursor: CatalogCursor?
        var skippedPerPage: [Int] = []
        var pages = 0
        repeat {
            let page = try await catalog.sessionPage(
                CatalogQuery(order: .creation, limit: 2), after: cursor
            )
            seen += page.sessions.map(\.session.id)
            skippedPerPage.append(page.skippedRowCount)
            cursor = page.next
            pages += 1
            #expect(page.sessions.count == 2 || page.next == nil)
        } while cursor != nil && pages < 20
        #expect(seen == good)
        #expect(skippedPerPage.reduce(0, +) >= 4)
        let recent = try await catalog.sessionPage(CatalogQuery(limit: 100))
        #expect(recent.sessions.count == 7)
        #expect(recent.next == nil)
        #expect(recent.skippedRowCount == 4)

        #expect(try await catalog.sessions(ids: good + [badProjectSession]).count == 7)
        #expect(await catalog.skippedRowCount == 4)   // distinct rows, not reads

        // Bad rows are never written or deleted.
        #expect(try sql("SELECT * FROM sessions WHERE id IN ('not-a-uuid', 'zzzz') OR provider = 'martian' OR project_id IS NOT NULL ORDER BY id", at: url) == rawBefore)
        #expect(try sql("SELECT count(*) FROM sessions", at: url) == ["11"])
    }

    // MARK: Trace

    @Test func noTitleBytesRemainInTheCatalogFilesAfterDeleteAndCheckpoint() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = catalogURL(root)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let catalog = try SessionCatalog(url: url)
        let marker = "TRACE-MARKER-\(UUID().uuidString)"
        let keeper = "KEEP-MARKER-\(UUID().uuidString)"
        let renamed = "RENAMED-MARKER-\(UUID().uuidString)"
        let target = claude(), bystander = claude()
        try await catalog.insertSession(target, title: marker)
        try await catalog.insertSession(bystander, title: keeper)
        for index in 0..<200 {   // enough rows to spread pages and give the file some size
            try await catalog.insertSession(claude(), title: "filler row \(index) \(UUID())")
        }
        _ = try await catalog.renameSession(sessionID: target.id, to: renamed)
        try await catalog.recordTerminalTitle(sessionID: bystander.id, title: keeper)

        func bytes(of file: URL) -> Data { (try? Data(contentsOf: file)) ?? Data() }
        func occurrences(_ text: String) -> Int {
            var count = 0
            for file in [url, wal] {
                var data = bytes(of: file)
                while let range = data.range(of: Data(text.utf8)) {
                    count += 1
                    data = data.subdata(in: range.upperBound..<data.count)
                }
            }
            return count
        }
        // The probe has power: before the delete the title is on disk.
        #expect(occurrences(renamed) > 0)
        #expect(occurrences(keeper) > 0)

        try await catalog.beginDeletion(sessionID: target.id, plan: plan(for: target.id))
        try await catalog.advanceDeletion(sessionID: target.id, to: .catalog)
        #expect(try await catalog.deleteSessionRows(sessionID: target.id))
        #expect(bytes(of: wal).isEmpty)    // the checkpoint truncated the WAL
        #expect(occurrences(marker) == 0)
        #expect(occurrences(renamed) == 0)
        #expect(occurrences(keeper) > 0)   // another conversation's title is still there
        try await catalog.advanceDeletion(sessionID: target.id, to: .verifying)
        try await catalog.finishDeletion(sessionID: target.id)
        #expect(occurrences(renamed) == 0)
        #expect(try sql("PRAGMA quick_check", at: url, readOnly: true) == ["ok"])
        #expect(try sql("PRAGMA foreign_key_check", at: url, readOnly: true).isEmpty)
        let reopened = try SessionCatalog(url: url)
        #expect(try await reopened.session(id: target.id) == nil)
        #expect(try await reopened.session(id: bystander.id)?.title == keeper)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
