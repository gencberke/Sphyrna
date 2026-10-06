import Foundation
import SQLite3

final class CatalogDatabase: @unchecked Sendable {
    static let applicationID: Int32 = 1_280_266_061 // ASCII "LOOM"
    let handle: OpaquePointer
    private let migrationFailpoint: (() throws -> Void)?

    init(url: URL, migrationFailpoint: (() throws -> Void)? = nil) throws {
        self.migrationFailpoint = migrationFailpoint
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
        else if version == 1 { try migrateToVersion2() }
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
            try execute("PRAGMA user_version = \(SessionCatalog.schemaVersion)")
        }
    }

    /// Schema 1 to 2 in one transaction: a failure (or a crash before COMMIT)
    /// leaves the version 1 file exactly as it was.
    func migrateToVersion2() throws {
        try transaction {
            try applyVersion2Schema()
            try migrationFailpoint?()
            try execute("PRAGMA user_version = 2")
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

    func validateSchema() throws {
        let tableCount = try scalarInt64("""
            SELECT count(*) FROM sqlite_master
            WHERE type = 'table' AND name IN (
                'sessions', 'runs', 'run_sessions', 'provider_identity_changes', 'projects'
            )
            """)
        guard tableCount == 5 else {
            throw SessionCatalogError.invalidRow("schema version 2 is missing required tables")
        }
        let columns = try scalarInt64("""
            SELECT count(*) FROM pragma_table_info('sessions')
            WHERE name IN ('project_id', 'title_is_custom')
            """)
        guard columns == 2 else {
            throw SessionCatalogError.invalidRow("schema version 2 is missing session columns")
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
