import Foundation
import SQLite3

extension SessionCatalog {
    public func startRun(_ run: ManagedRun, sessionID: UUID) throws {
        try database.transaction {
            try requireNotDeleting(sessionID)
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

    /// Atomically moves a live PTY run to a newly-created durable conversation.
    /// The old conversation remains in the catalog and becomes idle history.
    public func transitionRun(
        _ runID: UUID, from oldSessionID: UUID,
        to newSession: ManagedSession, at date: Date = Date()
    ) throws {
        try database.transaction {
            try requireActiveLink(runID: runID, sessionID: oldSessionID)
            // The new conversation runs in the same working directory, so it
            // stays in the source's project (a projectless source stays projectless).
            let projectID: UUID? = try database.withStatement(
                "SELECT project_id FROM sessions WHERE id = ?"
            ) { statement in
                try database.bind(oldSessionID.uuidString, at: 1, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return database.optionalText(statement, column: 0).flatMap(UUID.init(uuidString:))
            }
            try insertSessionRow(
                newSession, title: nil, createdAt: date, lastUsedAt: date,
                lifecycle: .active, pinned: false, projectID: projectID
            )
            try closeAndInsertRunLink(
                runID: runID, oldSessionID: oldSessionID,
                newSessionID: newSession.id, at: date
            )
        }
    }

    /// Atomically moves a live run back to an existing durable conversation.
    public func transitionRun(
        _ runID: UUID, from oldSessionID: UUID,
        toExistingSessionID newSessionID: UUID, at date: Date = Date()
    ) throws {
        try existingRunTransitionFailpoint?()
        try database.transaction {
            try requireActiveLink(runID: runID, sessionID: oldSessionID)
            try requireNotDeleting(newSessionID)
            guard try sessionExists(newSessionID) else {
                throw SessionCatalogError.invalidRow("session \(newSessionID) does not exist")
            }
            try closeAndInsertRunLink(
                runID: runID, oldSessionID: oldSessionID,
                newSessionID: newSessionID, at: date
            )
        }
    }

    public func runSessionLinks(runID: UUID? = nil) throws -> [CatalogRunSessionLink] {
        let sql: String
        if runID == nil {
            sql = """
                SELECT run_id, session_id, linked_at, unlinked_at
                FROM run_sessions ORDER BY linked_at, session_id
                """
        } else {
            sql = """
                SELECT run_id, session_id, linked_at, unlinked_at
                FROM run_sessions WHERE run_id = ? ORDER BY linked_at, session_id
                """
        }
        return try database.withStatement(sql) { statement in
            if let runID { try database.bind(runID.uuidString, at: 1, to: statement) }
            var links: [CatalogRunSessionLink] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let storedRunID = UUID(uuidString: try database.text(statement, column: 0)),
                      let sessionID = UUID(uuidString: try database.text(statement, column: 1)) else {
                    throw SessionCatalogError.invalidRow("invalid run/session link identity")
                }
                links.append(CatalogRunSessionLink(
                    runID: storedRunID, sessionID: sessionID,
                    linkedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    unlinkedAt: database.optionalDouble(statement, column: 3)
                        .map(Date.init(timeIntervalSince1970:))
                ))
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read run session links")
            return links
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
