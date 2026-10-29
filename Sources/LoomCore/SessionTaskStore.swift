import Darwin
import Foundation
import SQLite3

/// Private task-only SQLite store. The coordinator is its sole owner; each
/// compound mutation is committed before the host is allowed to perform work.
final class SessionTaskStore {
    // No accepted receipt or result is evicted. These per-task row and encoded
    // byte ceilings bound retained content; Stop has a small separate reserve
    // so ordinary request saturation does not prevent revoking live work.
    private static let maximumRounds = 32
    private static let maximumEvents = 64
    private static let maximumOperations = 128
    private static let stopOperationReserve = 16
    private static let maximumTaskBytes = 64 * 1_024
    private static let maximumPayloadRowBytes = 128 * 1_024
    private static let maximumOperationBytes = 8 * 1_024
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
    private struct StoredManagedScope: Codable {
        let binding: ManagedTaskScopeBinding
        var verifiedStopped: Bool
    }
    private struct StoredManagedLaunch: Codable {
        /// `notAdmitted`: the attempt ended while it was `opening`, so its provider was never sent SPAWN (the admission
        /// rule: every managed SPAWN follows a committed `scoped`). Unlike `noEffect` it says nothing of a scope host the
        /// attempt may have started; that host's cleanup is the supervisor's and previous-run recovery's to verify.
        enum Phase: String, Codable { case unstarted, opening, scoped, noEffect, notAdmitted }
        let childID: UUID
        var phase: Phase
        var runID: UUID? = nil
        var generation: UUID? = nil
        var roundID: UUID? = nil
        var operationID: UUID? = nil
        /// The app process that moved the launch to `opening`, its boot, and the admission rule it followed. A record
        /// without them (an older build) is never settled as not admitted.
        var owner: ProcessIdentity? = nil
        var ownerBoot: String? = nil
        var admissionRule: Int? = nil
    }

    /// What settling the launches a gone app left `opening` did: how many, and how many of those have no verified
    /// scope receipt (a scope host the attempt may have started is not known to be gone).
    struct AbandonedLaunches: Equatable {
        var settled = 0
        var cleanupUnverified = 0
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
            try exec("""
                CREATE TABLE IF NOT EXISTS managed_scopes(run TEXT PRIMARY KEY,
                  task TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, body TEXT NOT NULL)
                """)
            try exec("CREATE INDEX IF NOT EXISTS managed_scopes_task ON managed_scopes(task)")
            try exec("""
                CREATE TABLE IF NOT EXISTS managed_launches(task TEXT PRIMARY KEY
                  REFERENCES tasks(id) ON DELETE CASCADE, body TEXT NOT NULL)
                """)
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
            task.parentSessionID.uuidString, task.childSessionID.uuidString,
            try json(task, limit: Self.maximumTaskBytes)])
        let launch = StoredManagedLaunch(childID: task.childSessionID, phase: .unstarted)
        try run("INSERT INTO managed_launches(task,body) VALUES(?,?)",
                [task.id.uuidString, try json(launch, limit: Self.maximumOperationBytes)])
    }

    func save(_ task: SessionTaskProjection) throws {
        try run("UPDATE tasks SET body=? WHERE id=?", [try json(task, limit: Self.maximumTaskBytes), task.id.uuidString])
    }

    func childExists(_ id: UUID) throws -> Bool {
        try exists("SELECT 1 FROM tasks WHERE child=? LIMIT 1", [id.uuidString])
    }

    /// Reserve before opening even the scope host. A settled no-effect
    /// record makes any later launch attempt fail in this same transaction.
    func beginManagedLaunch(taskID: UUID, childID: UUID, runID: UUID, generation: UUID,
                            owner: ManagedLaunchOwner?) throws {
        guard let task = try task(taskID), task.childSessionID == childID, task.childBinding == nil,
              task.lifecycle == .active, let roundID = task.pendingRoundID, let round = try round(roundID),
              round.taskID == taskID, round.phase == .queued || round.phase == .deliveringUnknown,
              var launch = try get("SELECT body FROM managed_launches WHERE task=?", [taskID.uuidString],
                                   as: StoredManagedLaunch.self),
              launch.childID == childID, launch.phase == .unstarted else { throw SessionTaskError.unverified }
        launch.phase = .opening
        launch.runID = runID; launch.generation = generation
        launch.roundID = roundID; launch.operationID = round.operationID
        launch.owner = owner?.process; launch.ownerBoot = owner?.boot
        launch.admissionRule = owner == nil ? nil : ManagedLaunchOwner.admissionRule
        try saveManagedLaunch(launch, taskID: taskID)
    }

    /// The runtime ends an attempt that failed before `scoped`: its provider was never sent SPAWN. Any other phase is
    /// refused, so a caller may ask after every failure.
    func confirmManagedLaunchNotAdmitted(taskID: UUID, childID: UUID, runID: UUID, generation: UUID) throws {
        guard var launch = try get("SELECT body FROM managed_launches WHERE task=?", [taskID.uuidString],
                                   as: StoredManagedLaunch.self),
              launch.childID == childID, launch.phase == .opening,
              launch.runID == runID, launch.generation == generation else { throw SessionTaskError.unverified }
        launch.phase = .notAdmitted
        try saveManagedLaunch(launch, taskID: taskID)
    }

    /// Settles as not admitted every launch left `opening` under the admission rule by an app `isGone` says is no longer
    /// running (its process, or its boot). Rows this build cannot read are left as they are.
    func settleAbandonedManagedLaunches(isGone: (ProcessIdentity, String) -> Bool) throws -> AbandonedLaunches {
        var result = AbandonedLaunches()
        var after = ""
        let page = 256
        while true {
            let rows: [(task: String, body: String)] = try statement(
                "SELECT task,body FROM managed_launches WHERE task>? ORDER BY task LIMIT \(page)", [after]) { stmt in
                var rows: [(task: String, body: String)] = []
                var step = sqlite3_step(stmt)
                while step == SQLITE_ROW {
                    guard let task = sqlite3_column_text(stmt, 0), let body = sqlite3_column_text(stmt, 1) else {
                        throw SessionTaskError.storage
                    }
                    rows.append((String(cString: task), String(cString: body)))
                    step = sqlite3_step(stmt)
                }
                guard step == SQLITE_DONE else { throw SessionTaskError.storage }
                return rows
            }
            for row in rows {
                guard var launch = try? decoder.decode(StoredManagedLaunch.self, from: Data(row.body.utf8)),
                      launch.phase == .opening, launch.admissionRule == ManagedLaunchOwner.admissionRule,
                      let owner = launch.owner, let boot = launch.ownerBoot, isGone(owner, boot) else { continue }
                launch.phase = .notAdmitted
                try run("UPDATE managed_launches SET body=? WHERE task=?",
                        [try json(launch, limit: Self.maximumOperationBytes), row.task])
                result.settled += 1
                let scopes = try list("SELECT body FROM managed_scopes WHERE task=? LIMIT 17", [row.task],
                                      as: StoredManagedScope.self)
                if scopes.isEmpty || !scopes.allSatisfy(\.verifiedStopped) { result.cleanupUnverified += 1 }
            }
            guard rows.count == page, let last = rows.last else { break }
            after = last.task
        }
        return result
    }

    func settleUnstartedManagedLaunch(taskID: UUID, childID: UUID) throws -> Bool {
        guard let task = try task(taskID), task.childSessionID == childID, task.childBinding == nil,
              task.lifecycle == .stopping || task.lifecycle == .stopUnverified,
              var launch = try get("SELECT body FROM managed_launches WHERE task=?", [taskID.uuidString],
                                   as: StoredManagedLaunch.self),
              launch.childID == childID, launch.phase == .unstarted || launch.phase == .noEffect,
              try !exists("SELECT 1 FROM managed_scopes WHERE task=? LIMIT 1", [taskID.uuidString]) else { return false }
        if launch.phase == .unstarted {
            launch.phase = .noEffect
            try saveManagedLaunch(launch, taskID: taskID)
        }
        return true
    }

    /// Only the runtime calls this after it has proved that an opening
    /// attempt never started, or that its empty scope was fully released.
    func confirmManagedLaunchNoEffect(taskID: UUID, childID: UUID, runID: UUID, generation: UUID) throws {
        guard let task = try task(taskID), task.childSessionID == childID, task.childBinding == nil,
              var launch = try get("SELECT body FROM managed_launches WHERE task=?", [taskID.uuidString],
                                   as: StoredManagedLaunch.self),
              launch.childID == childID, launch.phase == .opening,
              launch.runID == runID, launch.generation == generation,
              try !exists("SELECT 1 FROM managed_scopes WHERE task=? LIMIT 1", [taskID.uuidString]) else {
            throw SessionTaskError.unverified
        }
        launch.phase = .noEffect
        try saveManagedLaunch(launch, taskID: taskID)
    }

    private func saveManagedLaunch(_ launch: StoredManagedLaunch, taskID: UUID) throws {
        try run("UPDATE managed_launches SET body=? WHERE task=?",
                [try json(launch, limit: Self.maximumOperationBytes), taskID.uuidString])
    }

    func prepareManagedScope(_ binding: ManagedTaskScopeBinding) throws {
        guard let task = try task(binding.taskID), task.childSessionID == binding.sessionID,
              task.lifecycle == .active,
              var launch = try get("SELECT body FROM managed_launches WHERE task=?", [binding.taskID.uuidString],
                                   as: StoredManagedLaunch.self),
              launch.childID == binding.sessionID, launch.phase == .opening,
              launch.runID == binding.runID, launch.generation == binding.generation,
              task.pendingRoundID == launch.roundID, let roundID = launch.roundID,
              let round = try round(roundID), round.operationID == launch.operationID else { throw SessionTaskError.staleBinding }
        try saveManagedScope(binding, verifiedStopped: false)
        launch.phase = .scoped
        try saveManagedLaunch(launch, taskID: binding.taskID)
    }

    /// Only a supervisor/recovery caller that verified the exact scope empty
    /// invokes this. It can fill the pre-spawn crash window before prepare.
    func verifyManagedScopeStopped(_ binding: ManagedTaskScopeBinding) throws {
        guard let task = try task(binding.taskID), task.childSessionID == binding.sessionID else {
            throw SessionTaskError.staleBinding
        }
        try saveManagedScope(binding, verifiedStopped: true)
    }

    func managedScopeStopped(_ binding: ManagedTaskScopeBinding) throws -> Bool {
        guard let stored = try get("SELECT body FROM managed_scopes WHERE run=?", [binding.runID.uuidString],
                                   as: StoredManagedScope.self) else { return false }
        return stored.binding == binding && stored.verifiedStopped
    }

    func managedChildStopped(taskID: UUID, sessionID: UUID, binding: SessionTaskBinding?) throws -> Bool {
        let rows = try list("SELECT body FROM managed_scopes WHERE task=? LIMIT 17", [taskID.uuidString],
                            as: StoredManagedScope.self)
        if rows.isEmpty, binding == nil,
           let launch = try get("SELECT body FROM managed_launches WHERE task=?", [taskID.uuidString],
                                as: StoredManagedLaunch.self),
           launch.childID == sessionID, launch.phase == .noEffect || launch.phase == .notAdmitted { return true }
        guard !rows.isEmpty, rows.count <= 16, rows.allSatisfy({
            $0.binding.taskID == taskID && $0.binding.sessionID == sessionID && $0.verifiedStopped
        }) else { return false }
        guard let binding else { return true }
        return binding.sessionID == sessionID && rows.contains {
            $0.binding.runID == binding.managedRunID && $0.binding.generation == binding.generation
        }
    }

    private func saveManagedScope(_ binding: ManagedTaskScopeBinding, verifiedStopped: Bool) throws {
        if var stored = try get("SELECT body FROM managed_scopes WHERE run=?", [binding.runID.uuidString],
                                as: StoredManagedScope.self) {
            guard stored.binding == binding else { throw SessionTaskError.conflictingOperation }
            if verifiedStopped && !stored.verifiedStopped {
                stored.verifiedStopped = true
                try run("UPDATE managed_scopes SET body=? WHERE run=?",
                        [try json(stored, limit: Self.maximumOperationBytes), binding.runID.uuidString])
            }
            return
        }
        try requireRoom("managed_scopes", taskID: binding.taskID, maximum: 16)
        let stored = StoredManagedScope(binding: binding, verifiedStopped: verifiedStopped)
        try run("INSERT INTO managed_scopes(run,task,body) VALUES(?,?,?)", [binding.runID.uuidString,
            binding.taskID.uuidString, try json(stored, limit: Self.maximumOperationBytes)])
    }

    func taskForChild(_ id: UUID) throws -> SessionTaskProjection? {
        try get("SELECT body FROM tasks WHERE child=? LIMIT 1", [id.uuidString], as: SessionTaskProjection.self)
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
        try requireRoom("rounds", taskID: round.taskID, maximum: Self.maximumRounds)
        try run("INSERT INTO rounds(id,task,ordinal,body) VALUES(?,?,?,?)", [round.id.uuidString,
            round.taskID.uuidString, String(round.ordinal), try json(round, limit: Self.maximumPayloadRowBytes)])
    }

    func save(_ round: SessionTaskRound) throws {
        try run("UPDATE rounds SET body=? WHERE id=?", [try json(round, limit: Self.maximumPayloadRowBytes), round.id.uuidString])
    }

    func rounds(taskID: UUID, after: Int64, limit: Int) throws -> [SessionTaskRound] {
        try list("SELECT body FROM rounds WHERE task=? AND ordinal>? ORDER BY ordinal LIMIT ?",
                 [taskID.uuidString, String(after), String(limit)], as: SessionTaskRound.self)
    }

    func operation(_ id: UUID) throws -> Operation? {
        try get("SELECT body FROM operations WHERE id=?", [id.uuidString], as: Operation.self)
    }

    func createOperation(_ id: UUID, taskID: UUID, operation: Operation, reserveForStop: Bool = false) throws {
        try requireRoom("operations", taskID: taskID,
                        maximum: Self.maximumOperations + (reserveForStop ? Self.stopOperationReserve : 0))
        try run("INSERT INTO operations(id,task,body) VALUES(?,?,?)", [id.uuidString, taskID.uuidString,
            try json(operation, limit: Self.maximumOperationBytes)])
    }

    func saveOperation(_ id: UUID, operation: Operation) throws {
        try run("UPDATE operations SET body=? WHERE id=?", [try json(operation, limit: Self.maximumOperationBytes), id.uuidString])
    }

    func event(_ id: UUID) throws -> SessionTaskEvent? {
        try get("SELECT body FROM events WHERE id=?", [id.uuidString], as: SessionTaskEvent.self)
    }

    func create(_ event: SessionTaskEvent) throws {
        try requireRoom("events", taskID: event.taskID, maximum: Self.maximumEvents)
        try run("INSERT INTO events(id,task,round,state,body) VALUES(?,?,?,'pending',?)",
                [event.id.uuidString, event.taskID.uuidString, event.roundID.uuidString,
                 try json(event, limit: Self.maximumPayloadRowBytes)])
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

    private func requireRoom(_ table: String, taskID: UUID, maximum: Int) throws {
        // Table names are the three fixed internal names above, never input.
        let count = try statement("SELECT count(*) FROM \(table) WHERE task=?", [taskID.uuidString]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw SessionTaskError.storage }
            return sqlite3_column_int64(stmt, 0)
        }
        guard count < Int64(maximum) else { throw SessionTaskError.capacityExceeded }
    }

    private func json<T: Encodable>(_ value: T, limit: Int) throws -> String {
        let data = try encoder.encode(value)
        guard data.count <= limit else { throw SessionTaskError.capacityExceeded }
        guard let text = String(data: data, encoding: .utf8) else { throw SessionTaskError.storage }
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

/// The app process that moves a managed launch to `opening`, and its boot: what lets a later app tell that the launch's
/// owner is gone. `admissionRule` 1 is the rule every managed provider launch of this build follows: the task commits
/// `scoped` before the provider is sent SPAWN, so a launch still `opening` when its owner is gone never admitted one.
struct ManagedLaunchOwner: Equatable, Sendable {
    static let admissionRule = 1
    let process: ProcessIdentity
    let boot: String

    /// This process, or nil when its identity or the boot cannot be read (its launches are then never settled for it).
    static func current() -> ManagedLaunchOwner? {
        guard let process = ProcessTable.record(pid: getpid())?.identity, let boot = ProcessTable.bootSessionID(),
              !boot.isEmpty else { return nil }
        return ManagedLaunchOwner(process: process, boot: boot)
    }
}
