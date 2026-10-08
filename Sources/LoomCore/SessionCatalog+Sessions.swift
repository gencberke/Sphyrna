import Foundation
import SQLite3

extension SessionCatalog {
    public func insertSession(_ session: ManagedSession, title: String? = nil,
                              createdAt: Date = Date(), lastUsedAt: Date = Date(),
                              lifecycle: SessionLifecycle = .active,
                              pinned: Bool = false, projectID: UUID? = nil,
                              staleSince: Date? = nil, lastActivityAt: Date? = nil) throws {
        try insertSessionRow(
            session, title: title, createdAt: createdAt, lastUsedAt: lastUsedAt,
            lifecycle: lifecycle, pinned: pinned, projectID: projectID, staleSince: staleSince,
            lastActivityAt: lastActivityAt
        )
    }

    /// Every conversation without a pending deletion. Undecodable rows are
    /// skipped and counted (`skippedRowCount`).
    public func sessions() throws -> [CatalogSession] {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s
            WHERE \(Self.notDeleting) ORDER BY s.created_at, s.id
            """) { statement in
            var result: [CatalogSession] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                if let session = try decodeSessionOrSkip(statement) { result.append(session) }
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read sessions")
            return result
        }
    }

    public func session(id: UUID) throws -> CatalogSession? {
        try readSession(where: "s.id = ?", value: id.uuidString)
    }

    public func session(provider: ManagedSession.Provider,
                        conversationID: String) throws -> CatalogSession? {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s
            WHERE s.provider = ? AND s.provider_conversation_id = ?
            ORDER BY s.created_at DESC LIMIT 1
            """) { statement in
            try database.bind(provider.rawValue, at: 1, to: statement)
            try database.bind(conversationID, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeSession(statement)
        }
    }

    /// Records a user prompt or deliberate view. Without `reactivate` (a view)
    /// only the use date moves: a stale or idle row keeps its state, because
    /// merely viewing history must not make it look live again, and the
    /// activity time stays (a view is not activity). With `reactivate` (a
    /// prompt, resume) the activity time moves to the event time too.
    /// Refused (`deletionPending`) for a conversation with a `deletions` row.
    /// A row that leaves `stale` loses its `stale_since`.
    public func markUsed(sessionID: UUID, at date: Date = Date(),
                         reactivate: Bool = false) throws {
        try database.withStatement("""
            UPDATE sessions AS s
            SET last_used_at = ?,
                last_activity_at = CASE
                    WHEN ? = 1 THEN ?
                    -- A row an older build inserted has no activity time; freeze its fallback
                    -- (the previous use date) so a view cannot move it.
                    ELSE COALESCE(last_activity_at, last_used_at)
                END,
                lifecycle = CASE
                    WHEN lifecycle IN ('stale', 'idle') AND ? = 0 THEN lifecycle
                    ELSE 'active'
                END,
                stale_since = CASE
                    WHEN lifecycle = 'stale' AND ? = 0 THEN stale_since
                    ELSE NULL
                END
            WHERE id = ? AND \(Self.notDeleting)
            """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, reactivate ? 1 : 0)
            sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
            sqlite3_bind_int(statement, 4, reactivate ? 1 : 0)
            sqlite3_bind_int(statement, 5, reactivate ? 1 : 0)
            try database.bind(sessionID.uuidString, at: 6, to: statement)
            try database.stepDone(statement, operation: "mark session used")
        }
        guard sqlite3_changes(database.handle) == 1 else {
            try requireNotDeleting(sessionID)
            throw SessionCatalogError.invalidRow("mark session used: session \(sessionID) does not exist")
        }
    }

    /// Records real use that is not a prompt (a finished turn, the user's Stop):
    /// the activity time and the use time both take the event time. The
    /// lifecycle is left alone.
    public func markActivity(sessionID: UUID, at date: Date = Date()) throws {
        try database.withStatement("""
            UPDATE sessions AS s
            SET last_activity_at = ?, last_used_at = ?
            WHERE id = ? AND \(Self.notDeleting)
            """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            try database.bind(sessionID.uuidString, at: 3, to: statement)
            try database.stepDone(statement, operation: "mark session activity")
        }
        guard sqlite3_changes(database.handle) == 1 else {
            try requireNotDeleting(sessionID)
            throw SessionCatalogError.invalidRow("mark session activity: session \(sessionID) does not exist")
        }
    }

    public func updateLifecycle(sessionID: UUID, lifecycle: SessionLifecycle) throws {
        try database.withStatement("""
            UPDATE sessions
            SET lifecycle = ?, stale_since = CASE WHEN ? = 'stale' THEN stale_since ELSE NULL END
            WHERE id = ?
            """) { statement in
            try database.bind(lifecycle.rawValue, at: 1, to: statement)
            try database.bind(lifecycle.rawValue, at: 2, to: statement)
            try database.bind(sessionID.uuidString, at: 3, to: statement)
            try database.stepDone(statement, operation: "update session lifecycle")
        }
        try requireChangedSession(sessionID, operation: "update session lifecycle")
    }

    /// Classifies conversations by time since last use (contract section 5),
    /// not by how they ended: idle ones and ones that ended by Stop, Quit or
    /// `/exit` (still `active` in the catalog) both qualify. A conversation
    /// with a live run (`running`) is never stale however old its last prompt,
    /// and one with a pending deletion is left alone. With `staleAfter` the
    /// row records `stale_since = last_used_at + staleAfter`; without it the
    /// value stays NULL (unknown) and the cleanup planner derives it.
    @discardableResult
    public func classifyStale(before cutoff: Date, excluding running: Set<UUID> = [],
                              staleAfter: TimeInterval? = nil) throws -> [UUID] {
        let excluded = Self.jsonIDList(running)
        let candidates: [UUID] = try database.withStatement("""
            SELECT s.id FROM sessions s
            WHERE s.lifecycle IN ('idle', 'active') AND s.last_used_at < ?
              AND s.id NOT IN (SELECT value FROM json_each(?))
              AND \(Self.notDeleting)
            ORDER BY s.id
            """) { statement in
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            try database.bind(excluded, at: 2, to: statement)
            var result: [UUID] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let id = UUID(uuidString: try database.text(statement, column: 0)) else {
                    throw SessionCatalogError.invalidRow("invalid stale session identity")
                }
                result.append(id)
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read stale sessions")
            return result
        }
        guard !candidates.isEmpty else { return [] }
        try database.withStatement("""
            UPDATE sessions AS s
            SET lifecycle = 'stale',
                stale_since = CASE WHEN ? IS NULL THEN NULL ELSE s.last_used_at + ? END
            WHERE s.lifecycle IN ('idle', 'active') AND s.last_used_at < ?
              AND s.id NOT IN (SELECT value FROM json_each(?))
              AND \(Self.notDeleting)
            """) { statement in
            if let staleAfter {
                sqlite3_bind_double(statement, 1, staleAfter)
                sqlite3_bind_double(statement, 2, staleAfter)
            } else {
                sqlite3_bind_null(statement, 1)
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_double(statement, 3, cutoff.timeIntervalSince1970)
            try database.bind(excluded, at: 4, to: statement)
            try database.stepDone(statement, operation: "classify stale sessions")
        }
        return candidates
    }

    /// The oldest last-use among conversations that can become stale: idle
    /// ones and active ones without a live run.
    public func oldestStaleCandidate(excluding running: Set<UUID> = []) throws -> Date? {
        try database.withStatement("""
            SELECT MIN(s.last_used_at) FROM sessions s
            WHERE s.lifecycle IN ('idle', 'active')
              AND s.id NOT IN (SELECT value FROM json_each(?))
              AND \(Self.notDeleting)
            """) { statement in
            try database.bind(Self.jsonIDList(running), at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return database.optionalDouble(statement, column: 0).map(Date.init(timeIntervalSince1970:))
        }
    }

    public func setPinned(_ pinned: Bool, for sessionID: UUID) throws {
        try database.withStatement("UPDATE sessions SET pinned = ? WHERE id = ?") { statement in
            sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "set session pinned")
        }
        try requireChangedSession(sessionID, operation: "set session pinned")
    }

    private static func jsonIDList(_ ids: Set<UUID>) -> String {
        "[" + ids.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "]"
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
}
