import Foundation
import SQLite3

final class CatalogDatabase: @unchecked Sendable {
    static let applicationID: Int32 = 1_280_266_061 // ASCII "LOOM"
    let handle: OpaquePointer
    /// Runs inside the migration transaction after the DDL of each target
    /// version (2, then 3) and before COMMIT.
    private let migrationFailpoint: ((Int32) throws -> Void)?

    convenience init(url: URL, migrationFailpoint: (() throws -> Void)? = nil) throws {
        try self.init(url: url, versionedMigrationFailpoint: migrationFailpoint.map { hook in { _ in try hook() } })
    }

    init(url: URL, versionedMigrationFailpoint: ((Int32) throws -> Void)?) throws {
        self.migrationFailpoint = versionedMigrationFailpoint
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "could not allocate connection"
            if let connection { sqlite3_close(connection) }
            throw SessionCatalogError.sqlite(operation: "open", code: result, message: message)
        }
        handle = connection
        try configure()
    }

    deinit { sqlite3_close(handle) }

    func configure() throws {
        sqlite3_busy_timeout(handle, 2_000)
        let registered = sqlite3_create_function_v2(
            handle, "loom_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, _, values in
                guard let values, let text = sqlite3_value_text(values[0]) else {
                    sqlite3_result_null(context)
                    return
                }
                let folded = String(cString: text).folding(options: [.caseInsensitive], locale: nil)
                sqlite3_result_text(context, folded, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }, nil, nil, nil
        )
        guard registered == SQLITE_OK else { throw error(operation: "register fold function", code: registered) }
        try execute("PRAGMA foreign_keys = ON")
        // Deleted conversations must not survive as freed-page bytes (contract
        // section 8); the default is only "fast" and not a documented guarantee.
        try execute("PRAGMA secure_delete = ON")
        let integrity = try scalarText("PRAGMA quick_check")
        guard integrity == "ok" else {
            throw SessionCatalogError.sqlite(operation: "integrity check", code: SQLITE_CORRUPT,
                                             message: integrity)
        }
        let version = Int32(try scalarInt64("PRAGMA user_version"))
        let applicationID = Int32(try scalarInt64("PRAGMA application_id"))
        guard version <= SessionCatalog.schemaVersion else {
            throw SessionCatalogError.unsupportedSchema(version)
        }
        if applicationID != 0 && applicationID != Self.applicationID {
            throw SessionCatalogError.foreignDatabase(applicationID: applicationID)
        }
        if applicationID == 0 {
            let tables = try scalarInt64("""
                SELECT count(*) FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """)
            guard version == 0, tables == 0 else {
                throw SessionCatalogError.foreignDatabase(applicationID: applicationID)
            }
        }
        if version == 0 { try createSchema() }
        else if version < SessionCatalog.schemaVersion { try migrate(from: version) }
        try ensureActivityColumn()
        try ensureOriginColumns()
        try validateSchema()
        guard try scalarText("PRAGMA journal_mode = WAL").lowercased() == "wal" else {
            throw SessionCatalogError.sqlite(operation: "enable WAL", code: SQLITE_ERROR,
                                             message: "journal mode did not become WAL")
        }
        try execute("PRAGMA synchronous = NORMAL")
    }

    func createSchema() throws {
        try transaction {
            try execute("PRAGMA application_id = \(Self.applicationID)")
            try execute("""
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    provider TEXT NOT NULL,
                    provider_conversation_id TEXT,
                    working_directory TEXT NOT NULL,
                    title TEXT,
                    created_at REAL NOT NULL,
                    last_used_at REAL NOT NULL,
                    lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active', 'idle', 'stale')),
                    pinned INTEGER NOT NULL CHECK (pinned IN (0, 1))
                )
                """)
            try execute("""
                CREATE TABLE runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    initial_session_id TEXT NOT NULL REFERENCES sessions(id),
                    leader_pid INTEGER NOT NULL,
                    leader_start_seconds INTEGER NOT NULL,
                    leader_start_microseconds INTEGER NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    end_reason TEXT,
                    exit_status INTEGER
                )
                """)
            try execute("""
                CREATE TABLE run_sessions (
                    run_id TEXT NOT NULL REFERENCES runs(id),
                    session_id TEXT NOT NULL REFERENCES sessions(id),
                    linked_at REAL NOT NULL,
                    unlinked_at REAL,
                    PRIMARY KEY (run_id, session_id, linked_at)
                )
                """)
            try execute("""
                CREATE TABLE provider_identity_changes (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES sessions(id),
                    previous_id TEXT,
                    new_id TEXT NOT NULL,
                    changed_at REAL NOT NULL
                )
                """)
            try applyVersion2Schema()
            try applyVersion3Schema()
            try execute("PRAGMA user_version = \(SessionCatalog.schemaVersion)")
        }
    }

    /// The chain 1 to 2 to 3 runs in one transaction: a failure (or a crash
    /// before COMMIT) leaves the file at its old version exactly as it was.
    func migrate(from version: Int32) throws {
        try transaction {
            if version < 2 {
                try applyVersion2Schema()
                try migrationFailpoint?(2)
            }
            if version < 3 {
                try applyVersion3Schema()
                try migrationFailpoint?(3)
            }
            try execute("PRAGMA user_version = \(SessionCatalog.schemaVersion)")
        }
    }

    func applyVersion2Schema() throws {
        try execute("""
            CREATE TABLE projects (
                id TEXT PRIMARY KEY NOT NULL,
                path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                collapsed INTEGER NOT NULL DEFAULT 0 CHECK (collapsed IN (0, 1)),
                created_at REAL NOT NULL
            )
            """)
        try execute("ALTER TABLE sessions ADD COLUMN project_id TEXT REFERENCES projects(id)")
        try execute("""
            ALTER TABLE sessions ADD COLUMN title_is_custom INTEGER NOT NULL DEFAULT 0
            CHECK (title_is_custom IN (0, 1))
            """)
        try execute("CREATE INDEX sessions_last_used ON sessions(last_used_at DESC, id DESC)")
        try execute("CREATE INDEX sessions_created ON sessions(created_at, id)")
        try execute("CREATE INDEX sessions_project_created ON sessions(project_id, created_at, id)")
        try execute("CREATE INDEX sessions_lifecycle_used ON sessions(lifecycle, last_used_at)")
        try execute("CREATE INDEX sessions_conversation ON sessions(provider, provider_conversation_id)")
    }

    /// Schema 3: durable deletion records, `stale_since`, app state and the
    /// child-side indexes the delete transaction and the fences rely on. A
    /// `deletions` row has no foreign key (it outlives the `sessions` row) and
    /// never stores a title.
    func applyVersion3Schema() throws {
        try execute("""
            CREATE TABLE deletions (
                session_id TEXT PRIMARY KEY NOT NULL,
                provider TEXT NOT NULL,
                provider_ids TEXT NOT NULL,
                config_dir TEXT,
                working_directory TEXT,
                state TEXT NOT NULL CHECK (
                    state IN ('requested', 'stopping', 'provider_data', 'catalog', 'verifying')
                ),
                requested_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            )
            """)
        try execute("ALTER TABLE sessions ADD COLUMN stale_since REAL")
        try execute("""
            CREATE TABLE app_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
        try execute("CREATE INDEX run_sessions_session ON run_sessions(session_id)")
        try execute("CREATE INDEX runs_initial_session ON runs(initial_session_id)")
        try execute("CREATE INDEX identity_changes_session ON provider_identity_changes(session_id)")
    }

    /// `sessions.last_activity_at`: when the user last really used a session
    /// (start, resume, prompt, finished turn, user Stop). `last_used_at` also
    /// moves on a view and keeps driving retention; this column drives the card
    /// time and the activity order.
    ///
    /// Added to schema 3 on open, deliberately without a `user_version` bump: a
    /// 0.2.1 build refuses any version above 3 and only checks that its own
    /// columns exist, so an extra nullable column and index leave the catalog
    /// readable by it. A row an older build writes meanwhile has NULL here and
    /// reads fall back to `last_used_at` (`SessionCatalog.activityExpression`).
    func ensureActivityColumn() throws {
        let hasColumn = try scalarInt64("""
            SELECT count(*) FROM pragma_table_info('sessions') WHERE name = 'last_activity_at'
            """) == 1
        let hasIndex = try scalarInt64("""
            SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'sessions_last_activity'
            """) == 1
        guard !hasColumn || !hasIndex else { return }
        try transaction {
            // Read again under the write lock: another process may have added it meanwhile.
            let added = try scalarInt64("""
                SELECT count(*) FROM pragma_table_info('sessions') WHERE name = 'last_activity_at'
                """) == 1
            if !added {
                try execute("ALTER TABLE sessions ADD COLUMN last_activity_at REAL")
                try execute("UPDATE sessions SET last_activity_at = last_used_at WHERE last_activity_at IS NULL")
            }
            try execute("""
                CREATE INDEX IF NOT EXISTS sessions_last_activity
                ON sessions(COALESCE(last_activity_at, last_used_at) DESC, id DESC)
                """)
        }
    }

    /// `sessions.ticket_key` and `sessions.opened_by` (D-40): the ticket an agent named when it
    /// asked for the session, and the session that asked. Added to schema 3 on open exactly like
    /// `last_activity_at`: two nullable columns, no `user_version` bump, so a 0.3.0 build (which
    /// names its own columns in every statement) still opens and writes the catalog; rows it
    /// writes meanwhile read as NULL here.
    func ensureOriginColumns() throws {
        func present(_ name: String) throws -> Bool {
            try scalarInt64("SELECT count(*) FROM pragma_table_info('sessions') WHERE name = '\(name)'") == 1
        }
        guard try !present("ticket_key") || !present("opened_by") else { return }
        try transaction {
            // Read again under the write lock: another process may have added them meanwhile.
            if try !present("ticket_key") { try execute("ALTER TABLE sessions ADD COLUMN ticket_key TEXT") }
            if try !present("opened_by") { try execute("ALTER TABLE sessions ADD COLUMN opened_by TEXT") }
        }
    }

    func validateSchema() throws {
        let tableCount = try scalarInt64("""
            SELECT count(*) FROM sqlite_master
            WHERE type = 'table' AND name IN (
                'sessions', 'runs', 'run_sessions', 'provider_identity_changes', 'projects',
                'deletions', 'app_state'
            )
            """)
        guard tableCount == 7 else {
            throw SessionCatalogError.invalidRow("schema version 3 is missing required tables")
        }
        let columns = try scalarInt64("""
            SELECT count(*) FROM pragma_table_info('sessions')
            WHERE name IN ('project_id', 'title_is_custom', 'stale_since')
            """)
        guard columns == 3 else {
            throw SessionCatalogError.invalidRow("schema version 3 is missing session columns")
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Truncating checkpoint: the WAL is emptied into the main file, so bytes
    /// removed by a delete are gone from both. Fails when a reader blocks it.
    func checkpointTruncate() throws {
        try withStatement("PRAGMA wal_checkpoint(TRUNCATE)") { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw error(operation: "checkpoint", code: result) }
            guard sqlite3_column_int(statement, 0) == 0 else {
                throw SessionCatalogError.sqlite(operation: "checkpoint", code: SQLITE_BUSY,
                                                 message: "checkpoint was blocked by another connection")
            }
        }
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw SessionCatalogError.sqlite(operation: "execute", code: result, message: detail)
        }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw error(operation: "prepare", code: result)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw error(operation: "bind", code: result) }
    }

    func stepDone(_ statement: OpaquePointer, operation: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw error(operation: operation, code: result) }
    }

    func requireDone(_ result: Int32, operation: String) throws {
        guard result == SQLITE_DONE else {
            throw error(operation: operation, code: result)
        }
    }

    func text(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard let value = optionalText(statement, column: column) else {
            throw SessionCatalogError.invalidRow("column \(column) is null")
        }
        return value
    }

    func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    func optionalDouble(_ statement: OpaquePointer, column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, column)
    }

    func optionalInt32(_ statement: OpaquePointer, column: Int32) -> Int32? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_int(statement, column)
    }

    func scalarInt64(_ sql: String) throws -> Int64 {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw error(operation: "read scalar", code: sqlite3_errcode(handle))
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func scalarText(_ sql: String) throws -> String {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw error(operation: "read scalar", code: sqlite3_errcode(handle))
            }
            return try text(statement, column: 0)
        }
    }

    func error(operation: String, code: Int32) -> SessionCatalogError {
        .sqlite(operation: operation, code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
