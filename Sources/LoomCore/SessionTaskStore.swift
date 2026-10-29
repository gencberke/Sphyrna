import Darwin
import Foundation
import SQLite3

/// Private task-only SQLite store. The coordinator is its sole owner; each
/// compound mutation is committed before the host is allowed to perform work.
final class SessionTaskStore {
    struct Operation: Codable {
        let fingerprint: String
        var receipt: SessionTaskReceipt
        var binding: SessionTaskBinding? = nil
        var epoch: Int64? = nil
    }
    struct EventRow {
        let sequence: Int64
        let event: SessionTaskEvent
    }

    private let db: OpaquePointer
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var dirInfo = stat()
        guard lstat(directory.path, &dirInfo) == 0, dirInfo.st_uid == geteuid(),
              dirInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), dirInfo.st_mode & 0o077 == 0 else {
            throw SessionTaskError.storage
        }
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        if fd >= 0 { close(fd) }
        else if errno == EEXIST {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0 else {
                throw SessionTaskError.storage
            }
        } else { throw SessionTaskError.storage }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw SessionTaskError.storage
        }
        db = connection
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        sqlite3_busy_timeout(db, 2_000)
        do {
            try exec("PRAGMA foreign_keys = ON")
            try exec("PRAGMA secure_delete = ON")
            let appID = try scalar("PRAGMA application_id")
            let version = try scalar("PRAGMA user_version")
            let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            guard (appID == 0 && version == 0 && tables == 0) || (appID == 1_397_608_241 && version == 1) else {
                throw SessionTaskError.storage
            }
            if version == 0 {
                try transaction {
                    try exec("PRAGMA application_id = 1397608241")
                    try exec("""
                        CREATE TABLE tasks(id TEXT PRIMARY KEY, parent TEXT NOT NULL, child TEXT NOT NULL UNIQUE, body TEXT NOT NULL)
                        """)
                    try exec("CREATE INDEX tasks_parent ON tasks(parent, id)")
                    try exec("""
                        CREATE TABLE rounds(id TEXT PRIMARY KEY, task TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                          ordinal INTEGER NOT NULL, body TEXT NOT NULL, UNIQUE(task, ordinal))
                        """)
                    try exec("""
                        CREATE TABLE operations(id TEXT PRIMARY KEY, task TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                          body TEXT NOT NULL)
                        """)
                    try exec("""
                        CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                          task TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, round TEXT NOT NULL,
                          state TEXT NOT NULL, wake_operation TEXT, body TEXT NOT NULL)
                        """)
                    try exec("CREATE INDEX events_page ON events(task, sequence)")
                    try exec("CREATE INDEX events_pending ON events(task, state, sequence)")
                    try exec("PRAGMA user_version = 1")
                }
            }
            // Version-one stores created before this index need it as well:
            // deleting a task cascades to operations by task, not by id.
            try exec("CREATE INDEX IF NOT EXISTS operations_task ON operations(task)")
            guard try scalarText("PRAGMA quick_check") == "ok",
                  try scalarText("PRAGMA journal_mode = WAL").lowercased() == "wal" else { throw SessionTaskError.storage }
            try exec("PRAGMA synchronous = FULL")
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func task(_ id: UUID) throws -> SessionTaskProjection? {
        try get("SELECT body FROM tasks WHERE id=?", [id.uuidString], as: SessionTaskProjection.self)
    }

    func create(_ task: SessionTaskProjection) throws {
        try run("INSERT INTO tasks(id,parent,child,body) VALUES(?,?,?,?)", [task.id.uuidString,
            task.parentSessionID.uuidString, task.childSessionID.uuidString, try json(task)])
    }

    func save(_ task: SessionTaskProjection) throws {
        try run("UPDATE tasks SET body=? WHERE id=?", [try json(task), task.id.uuidString])
    }

    func childExists(_ id: UUID) throws -> Bool {
        try exists("SELECT 1 FROM tasks WHERE child=? LIMIT 1", [id.uuidString])
    }

    func projections(parentSessionID: UUID?, after: UUID?, limit: Int) throws -> [SessionTaskProjection] {
        if let parentSessionID {
            return try list("SELECT body FROM tasks WHERE parent=? AND id>? ORDER BY id LIMIT ?",
                            [parentSessionID.uuidString, after?.uuidString ?? "", String(limit)], as: SessionTaskProjection.self)
        }
        return try list("SELECT body FROM tasks WHERE id>? ORDER BY id LIMIT ?",
                        [after?.uuidString ?? "", String(limit)], as: SessionTaskProjection.self)
    }

    func round(_ id: UUID) throws -> SessionTaskRound? {
        try get("SELECT body FROM rounds WHERE id=?", [id.uuidString], as: SessionTaskRound.self)
    }

    func create(_ round: SessionTaskRound) throws {
        try run("INSERT INTO rounds(id,task,ordinal,body) VALUES(?,?,?,?)", [round.id.uuidString,
            round.taskID.uuidString, String(round.ordinal), try json(round)])
    }

    func save(_ round: SessionTaskRound) throws {
        try run("UPDATE rounds SET body=? WHERE id=?", [try json(round), round.id.uuidString])
    }

    func rounds(taskID: UUID, after: Int64, limit: Int) throws -> [SessionTaskRound] {
        try list("SELECT body FROM rounds WHERE task=? AND ordinal>? ORDER BY ordinal LIMIT ?",
                 [taskID.uuidString, String(after), String(limit)], as: SessionTaskRound.self)
    }

    func operation(_ id: UUID) throws -> Operation? {
        try get("SELECT body FROM operations WHERE id=?", [id.uuidString], as: Operation.self)
    }

    func createOperation(_ id: UUID, taskID: UUID, operation: Operation) throws {
        try run("INSERT INTO operations(id,task,body) VALUES(?,?,?)", [id.uuidString, taskID.uuidString, try json(operation)])
    }

    func saveOperation(_ id: UUID, operation: Operation) throws {
        try run("UPDATE operations SET body=? WHERE id=?", [try json(operation), id.uuidString])
    }

    func event(_ id: UUID) throws -> SessionTaskEvent? {
        try get("SELECT body FROM events WHERE id=?", [id.uuidString], as: SessionTaskEvent.self)
    }

    func create(_ event: SessionTaskEvent) throws {
        try run("INSERT INTO events(id,task,round,state,body) VALUES(?,?,?,'pending',?)",
                [event.id.uuidString, event.taskID.uuidString, event.roundID.uuidString, try json(event)])
    }

    func pendingEventIDs(taskID: UUID, limit: Int) throws -> [UUID] {
        try statement("SELECT id FROM events WHERE task=? AND state='pending' ORDER BY sequence LIMIT ?",
                      [taskID.uuidString, String(limit)]) { stmt in
            var result: [UUID] = []
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                guard let id = sqlite3_column_text(stmt, 0),
                      let eventID = UUID(uuidString: String(cString: id)) else { throw SessionTaskError.storage }
                result.append(eventID)
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { throw SessionTaskError.storage }
            return result
        }
    }

    func events(taskID: UUID, after: Int64, limit: Int) throws -> [EventRow] {
        return try statement("SELECT sequence,body FROM events WHERE task=? AND sequence>? ORDER BY sequence LIMIT ?",
                             [taskID.uuidString, String(after), String(limit)]) { stmt in
            var rows: [EventRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 1),
                      let data = String(cString: raw).data(using: .utf8) else { throw SessionTaskError.storage }
                rows.append(EventRow(sequence: sqlite3_column_int64(stmt, 0),
                                     event: try decoder.decode(SessionTaskEvent.self, from: data)))
            }
            guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw SessionTaskError.storage }
            return rows
        }
    }

    func latestEvents(taskID: UUID, limit: Int) throws -> [SessionTaskEvent] {
        let values = try list("SELECT body FROM events WHERE task=? ORDER BY sequence DESC LIMIT ?",
                              [taskID.uuidString, String(limit)], as: SessionTaskEvent.self)
        return Array(values.reversed())
    }

    func claimEvents(_ ids: [UUID], operationID: UUID) throws {
        for id in ids {
            try run("UPDATE events SET state='claimed',wake_operation=? WHERE id=? AND state='pending'",
                    [operationID.uuidString, id.uuidString])
            guard sqlite3_changes(db) == 1 else { throw SessionTaskError.storage }
        }
    }

    /// A read during a claimed wake stays read even if that wake defers or is
    /// later cleared as unknown. Its operation remains recorded until settled.
    func acknowledgeEvents(_ ids: [UUID], taskID: UUID) throws -> Bool {
        var changed = false
        for id in ids {
            guard let event = try event(id), event.taskID == taskID else { throw SessionTaskError.notFound }
            try run("""
                UPDATE events SET state=CASE state WHEN 'pending' THEN 'read' ELSE 'readClaimed' END
                WHERE id=? AND task=? AND state IN ('pending','claimed')
                """, [id.uuidString, taskID.uuidString])
            changed = changed || sqlite3_changes(db) > 0
        }
        return changed
    }

    func settleEvents(operationID: UUID, delivered: Bool) throws {
        try run("""
                UPDATE events SET state=CASE state WHEN 'readClaimed' THEN 'read' ELSE ? END, wake_operation=NULL
                WHERE wake_operation=? AND state IN ('claimed','readClaimed')
                """,
                [delivered ? "delivered" : "pending", operationID.uuidString])
    }

    func forget(sessionID: UUID) throws {
        try run("DELETE FROM tasks WHERE parent=? OR child=?", [sessionID.uuidString, sessionID.uuidString])
        // secure_delete erases rows; truncating the WAL must be coordinated by
        // the owner at deletion time, and can fail if a reader is still open.
        try statement("PRAGMA wal_checkpoint(TRUNCATE)", []) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int(stmt, 0) == 0 else { throw SessionTaskError.storage }
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else { throw SessionTaskError.storage }
        return text
    }
    private func get<T: Decodable>(_ sql: String, _ values: [String], as type: T.Type) throws -> T? {
        try list(sql, values, as: type).first
    }
    private func list<T: Decodable>(_ sql: String, _ values: [String], as type: T.Type) throws -> [T] {
        try statement(sql, values) { stmt in
            var result: [T] = []
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 0),
                      let data = String(cString: raw).data(using: .utf8) else { throw SessionTaskError.storage }
                result.append(try decoder.decode(type, from: data))
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { throw SessionTaskError.storage }
            return result
        }
    }
    private func exists(_ sql: String, _ values: [String]) throws -> Bool {
        try statement(sql, values) { stmt in
            let step = sqlite3_step(stmt)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw SessionTaskError.storage }
            return step == SQLITE_ROW
        }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        try statement(sql, []) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw SessionTaskError.storage }
            return sqlite3_column_int64(stmt, 0)
        }
    }
    private func scalarText(_ sql: String) throws -> String {
        try statement(sql, []) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw SessionTaskError.storage }
            return String(cString: raw)
        }
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SessionTaskError.storage }
    }
    private func run(_ sql: String, _ values: [String]) throws {
        try statement(sql, values) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SessionTaskError.storage }
        }
    }
    private func statement<T>(_ sql: String, _ values: [String], _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw SessionTaskError.storage }
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(offset + 1), value, -1,
                                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                throw SessionTaskError.storage
            }
        }
        return try body(stmt)
    }
}
