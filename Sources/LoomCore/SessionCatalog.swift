import Foundation
import SQLite3

public enum SessionLifecycle: String, Codable, Sendable {
    case active
    case idle
    case stale
}

public enum ManagedRunEndReason: String, Codable, Sendable {
    case requested
    case applicationQuit
    case processExited
}

public struct CatalogSession: Equatable, Sendable {
    public let session: ManagedSession
    public let title: String?
    public let createdAt: Date
    public let lastUsedAt: Date
    public let lifecycle: SessionLifecycle
    public let pinned: Bool
}

public struct CatalogRun: Equatable, Sendable {
    public let id: UUID
    public let initialSessionID: UUID
    public let leader: ProcessIdentity
    public let startedAt: Date
    public let endedAt: Date?
    public let endReason: ManagedRunEndReason?
    public let exitStatus: Int32?
}

public enum SessionCatalogError: Error, CustomStringConvertible, Sendable {
    case sqlite(operation: String, code: Int32, message: String)
    case unsupportedSchema(Int32)
    case foreignDatabase(applicationID: Int32)
    case invalidRow(String)

    public var description: String {
        switch self {
        case let .sqlite(operation, code, message):
            "Catalog \(operation) failed: \(message) (\(code))"
        case let .unsupportedSchema(version):
            "Catalog schema version \(version) is newer than this Loom build supports"
        case let .foreignDatabase(applicationID):
            "Catalog path contains a non-Loom SQLite database (application_id \(applicationID))"
        case let .invalidRow(detail):
            "Catalog contains an invalid row: \(detail)"
        }
    }
}

/// Serialized durable metadata store. It never stores conversation content.
public actor SessionCatalog {
    public static let schemaVersion: Int32 = 1
    private let database: CatalogDatabase

    public init(url: URL) throws {
        database = try CatalogDatabase(url: url)
    }

    public func insertSession(_ session: ManagedSession, title: String? = nil,
                              createdAt: Date = Date(), lastUsedAt: Date = Date(),
                              lifecycle: SessionLifecycle = .active,
                              pinned: Bool = false) throws {
        try database.withStatement("""
            INSERT INTO sessions (
                id, provider, provider_conversation_id, working_directory, title,
                created_at, last_used_at, lifecycle, pinned
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            try database.bind(session.id.uuidString, at: 1, to: statement)
            try database.bind(session.provider.rawValue, at: 2, to: statement)
            try database.bind(session.providerConversationID, at: 3, to: statement)
            try database.bind(session.workingDirectory, at: 4, to: statement)
            try database.bind(title, at: 5, to: statement)
            sqlite3_bind_double(statement, 6, createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, lastUsedAt.timeIntervalSince1970)
            try database.bind(lifecycle.rawValue, at: 8, to: statement)
            sqlite3_bind_int(statement, 9, pinned ? 1 : 0)
            try database.stepDone(statement, operation: "insert session")
        }
    }

    public func sessions() throws -> [CatalogSession] {
        try database.withStatement("""
            SELECT id, provider, provider_conversation_id, working_directory, title,
                   created_at, last_used_at, lifecycle, pinned
            FROM sessions ORDER BY created_at, id
            """) { statement in
            var result: [CatalogSession] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let id = UUID(uuidString: try database.text(statement, column: 0)),
                      let provider = ManagedSession.Provider(rawValue: try database.text(statement, column: 1)),
                      let lifecycle = SessionLifecycle(rawValue: try database.text(statement, column: 7)) else {
                    throw SessionCatalogError.invalidRow("unknown session identity, provider, or lifecycle")
                }
                let session = ManagedSession(
                    id: id, provider: provider,
                    providerConversationID: database.optionalText(statement, column: 2),
                    workingDirectory: try database.text(statement, column: 3)
                )
                result.append(CatalogSession(
                    session: session,
                    title: database.optionalText(statement, column: 4),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    lifecycle: lifecycle,
                    pinned: sqlite3_column_int(statement, 8) != 0
                ))
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read sessions")
            return result
        }
    }

    public func updateProviderConversationID(sessionID: UUID, newID: String,
                                             changedAt: Date = Date()) throws {
        try database.transaction {
            let previous: String? = try database.withStatement(
                "SELECT provider_conversation_id FROM sessions WHERE id = ?"
            ) { statement in
                try database.bind(sessionID.uuidString, at: 1, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw SessionCatalogError.invalidRow("session \(sessionID) does not exist")
                }
                return database.optionalText(statement, column: 0)
            }
            try database.withStatement("""
                INSERT INTO provider_identity_changes (
                    session_id, previous_id, new_id, changed_at
                ) VALUES (?, ?, ?, ?)
                """) { statement in
                try database.bind(sessionID.uuidString, at: 1, to: statement)
                try database.bind(previous, at: 2, to: statement)
                try database.bind(newID, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, changedAt.timeIntervalSince1970)
                try database.stepDone(statement, operation: "record provider identity")
            }
            try database.withStatement(
                "UPDATE sessions SET provider_conversation_id = ? WHERE id = ?"
            ) { statement in
                try database.bind(newID, at: 1, to: statement)
                try database.bind(sessionID.uuidString, at: 2, to: statement)
                try database.stepDone(statement, operation: "update provider identity")
            }
        }
    }

    public func startRun(_ run: ManagedRun, sessionID: UUID) throws {
        try database.transaction {
            try database.withStatement("""
                INSERT INTO runs (
                    id, initial_session_id, leader_pid, leader_start_seconds,
                    leader_start_microseconds, started_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """) { statement in
                try database.bind(run.id.uuidString, at: 1, to: statement)
                try database.bind(sessionID.uuidString, at: 2, to: statement)
                sqlite3_bind_int(statement, 3, run.leader.pid)
                sqlite3_bind_int64(statement, 4, run.leader.startSeconds)
                sqlite3_bind_int64(statement, 5, run.leader.startMicroseconds)
                sqlite3_bind_double(statement, 6, run.startedAt.timeIntervalSince1970)
                try database.stepDone(statement, operation: "insert run")
            }
            try database.withStatement("""
                INSERT INTO run_sessions (run_id, session_id, linked_at)
                VALUES (?, ?, ?)
                """) { statement in
                try database.bind(run.id.uuidString, at: 1, to: statement)
                try database.bind(sessionID.uuidString, at: 2, to: statement)
                sqlite3_bind_double(statement, 3, run.startedAt.timeIntervalSince1970)
                try database.stepDone(statement, operation: "link run session")
            }
        }
    }

    public func finishRun(_ runID: UUID, endedAt: Date = Date(),
                          reason: ManagedRunEndReason,
                          exitStatus: Int32?) throws {
        try database.withStatement("""
            UPDATE runs SET ended_at = ?, end_reason = ?, exit_status = ?
            WHERE id = ? AND ended_at IS NULL
            """) { statement in
            sqlite3_bind_double(statement, 1, endedAt.timeIntervalSince1970)
            try database.bind(reason.rawValue, at: 2, to: statement)
            if let exitStatus { sqlite3_bind_int(statement, 3, exitStatus) }
            else { sqlite3_bind_null(statement, 3) }
            try database.bind(runID.uuidString, at: 4, to: statement)
            try database.stepDone(statement, operation: "finish run")
        }
        if sqlite3_changes(database.handle) == 1 { return }
        let exists = try database.withStatement("SELECT 1 FROM runs WHERE id = ?") { statement in
            try database.bind(runID.uuidString, at: 1, to: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
        guard exists else { throw SessionCatalogError.invalidRow("run \(runID) does not exist") }
    }

    public func runs() throws -> [CatalogRun] {
        try database.withStatement("""
            SELECT id, initial_session_id, leader_pid, leader_start_seconds,
                   leader_start_microseconds, started_at, ended_at, end_reason, exit_status
            FROM runs ORDER BY started_at, id
            """) { statement in
            var result: [CatalogRun] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let id = UUID(uuidString: try database.text(statement, column: 0)),
                      let sessionID = UUID(uuidString: try database.text(statement, column: 1)) else {
                    throw SessionCatalogError.invalidRow("unknown run or session identity")
                }
                let reasonText = database.optionalText(statement, column: 7)
                let reason = try reasonText.map {
                    guard let value = ManagedRunEndReason(rawValue: $0) else {
                        throw SessionCatalogError.invalidRow("unknown run end reason \($0)")
                    }
                    return value
                }
                result.append(CatalogRun(
                    id: id, initialSessionID: sessionID,
                    leader: ProcessIdentity(
                        pid: sqlite3_column_int(statement, 2),
                        startSeconds: sqlite3_column_int64(statement, 3),
                        startMicroseconds: sqlite3_column_int64(statement, 4)
                    ),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    endedAt: database.optionalDouble(statement, column: 6).map(Date.init(timeIntervalSince1970:)),
                    endReason: reason,
                    exitStatus: database.optionalInt32(statement, column: 8)
                ))
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read runs")
            return result
        }
    }
}

private final class CatalogDatabase: @unchecked Sendable {
    static let applicationID: Int32 = 1_280_266_061 // ASCII "LOOM"
    let handle: OpaquePointer

    init(url: URL) throws {
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
            try execute("PRAGMA user_version = \(SessionCatalog.schemaVersion)")
        }
    }

    func validateSchema() throws {
        let tableCount = try scalarInt64("""
            SELECT count(*) FROM sqlite_master
            WHERE type = 'table' AND name IN (
                'sessions', 'runs', 'run_sessions', 'provider_identity_changes'
            )
            """)
        guard tableCount == 4 else {
            throw SessionCatalogError.invalidRow("schema version 1 is missing required tables")
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
