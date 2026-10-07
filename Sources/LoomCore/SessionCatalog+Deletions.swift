import Foundation
import SQLite3

/// Order of a conversation deletion; each step is idempotent and persisted
/// before it runs (CP4 state machine). Raw values are the stored text.
public enum CatalogDeletionState: String, Sendable, CaseIterable {
    case requested
    case stopping
    case providerData = "provider_data"
    case catalog
    case verifying

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// What a deletion needs to resume after a restart. No title and no content.
public struct CatalogDeletionPlan: Equatable, Sendable {
    public let provider: ManagedSession.Provider
    public let providerIDs: [String]
    public let configDirectory: String?
    public let workingDirectory: String?

    public init(provider: ManagedSession.Provider, providerIDs: [String],
                configDirectory: String?, workingDirectory: String?) {
        self.provider = provider
        self.providerIDs = providerIDs
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
    }
}

/// A recorded failure: a category and at most a file basename, never a path,
/// a title or conversation content.
public struct CatalogDeletionFailure: Equatable, Sendable {
    public let category: String
    public let fileName: String?

    public init(category: String, file: String? = nil) {
        self.category = Self.sanitized(category)
        self.fileName = file.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
    }

    var stored: String {
        fileName.map { "\(category): \($0)" } ?? category
    }

    private static func sanitized(_ raw: String) -> String {
        let text = String(raw.lowercased().unicodeScalars.prefix(40).map { scalar -> Character in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar))
                               || scalar == "_" || scalar == "-")
                ? Character(scalar) : "-"
        })
        return text.isEmpty ? "unknown" : text
    }
}

public struct CatalogDeletion: Equatable, Sendable {
    public let sessionID: UUID
    public let plan: CatalogDeletionPlan
    public let state: CatalogDeletionState
    public let requestedAt: Date
    public let updatedAt: Date
    public let attempts: Int
    public let lastError: String?
}

extension SessionCatalog {
    // MARK: Deletion records

    /// Records the intent to delete. From now on the fences refuse the id.
    /// Refuses when a record already exists or the conversation is unknown.
    public func beginDeletion(sessionID: UUID, plan: CatalogDeletionPlan,
                              at date: Date = Date()) throws {
        let ids = try Self.encode(providerIDs: plan.providerIDs)
        try database.transaction {
            guard try sessionExists(sessionID) else {
                throw SessionCatalogError.invalidRow("begin deletion: session \(sessionID) does not exist")
            }
            guard try readDeletion(sessionID) == nil else {
                throw SessionCatalogError.deletionAlreadyRequested(sessionID)
            }
            try database.withStatement("""
                INSERT INTO deletions (
                    session_id, provider, provider_ids, config_dir, working_directory,
                    state, requested_at, updated_at, attempts, last_error
                ) VALUES (?, ?, ?, ?, ?, 'requested', ?, ?, 0, NULL)
                """) { statement in
                try database.bind(sessionID.uuidString, at: 1, to: statement)
                try database.bind(plan.provider.rawValue, at: 2, to: statement)
                try database.bind(ids, at: 3, to: statement)
                try database.bind(plan.configDirectory, at: 4, to: statement)
                try database.bind(plan.workingDirectory, at: 5, to: statement)
                sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
                sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
                try database.stepDone(statement, operation: "begin deletion")
            }
        }
    }

    /// Moves a deletion to `state` (the same state records a retry; going
    /// back is refused). A failure counts an attempt and is stored as a
    /// category plus file basename; no failure clears the last error.
    public func advanceDeletion(sessionID: UUID, to state: CatalogDeletionState,
                                error: CatalogDeletionFailure? = nil,
                                at date: Date = Date()) throws {
        try database.transaction {
            guard let current = try readDeletion(sessionID) else {
                throw SessionCatalogError.invalidRow("advance deletion: no deletion for \(sessionID)")
            }
            guard state.rank >= current.state.rank else {
                throw SessionCatalogError.invalidRow(
                    "advance deletion: \(current.state.rawValue) cannot go back to \(state.rawValue)"
                )
            }
            try database.withStatement("""
                UPDATE deletions
                SET state = ?, updated_at = ?, attempts = attempts + ?, last_error = ?
                WHERE session_id = ?
                """) { statement in
                try database.bind(state.rawValue, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
                sqlite3_bind_int(statement, 3, error == nil ? 0 : 1)
                try database.bind(error?.stored, at: 4, to: statement)
                try database.bind(sessionID.uuidString, at: 5, to: statement)
                try database.stepDone(statement, operation: "advance deletion")
            }
        }
    }

    public func pendingDeletions() throws -> [CatalogDeletion] {
        try database.withStatement("""
            SELECT \(Self.deletionColumns) FROM deletions ORDER BY requested_at, session_id
            """) { statement in
            var result: [CatalogDeletion] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                result.append(try decodeDeletion(statement))
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read deletions")
            return result
        }
    }

    public func deletion(for sessionID: UUID) throws -> CatalogDeletion? {
        try readDeletion(sessionID)
    }

    public func isDeletionPending(_ sessionID: UUID) throws -> Bool {
        try readDeletion(sessionID) != nil
    }

    /// Removes the record once verification passed. Absent is not an error.
    public func finishDeletion(sessionID: UUID) throws {
        try database.withStatement("DELETE FROM deletions WHERE session_id = ?") { statement in
            try database.bind(sessionID.uuidString, at: 1, to: statement)
            try database.stepDone(statement, operation: "finish deletion")
        }
        // The record named the conversation's ids and Claude folder: truncate the WAL so no copy
        // is left. The conversation is already gone, so a reader blocking this only delays the
        // wipe to the next checkpoint instead of failing the deletion.
        try? database.checkpointTruncate()
    }

    // MARK: Row deletion

    /// Removes one conversation from the catalog in one transaction, then
    /// truncates the WAL so no copy of its bytes is left (`secure_delete`
    /// zeroes the freed pages). A run that started from it is repointed to
    /// its earliest remaining linked conversation, or deleted when none
    /// remains (the `/clear` chain). Other conversations are untouched.
    /// Idempotent: returns false when the row was already gone.
    @discardableResult
    public func deleteSessionRows(sessionID: UUID) throws -> Bool {
        let id = sessionID.uuidString
        let removed: Bool = try database.transaction {
            try database.withStatement("DELETE FROM provider_identity_changes WHERE session_id = ?") { statement in
                try database.bind(id, at: 1, to: statement)
                try database.stepDone(statement, operation: "delete identity changes")
            }
            try database.withStatement("""
                UPDATE runs
                SET initial_session_id = (
                    SELECT rs.session_id FROM run_sessions rs
                    WHERE rs.run_id = runs.id AND rs.session_id <> ?1
                    ORDER BY rs.linked_at, rs.session_id LIMIT 1
                )
                WHERE initial_session_id = ?1 AND EXISTS (
                    SELECT 1 FROM run_sessions rs WHERE rs.run_id = runs.id AND rs.session_id <> ?1
                )
                """) { statement in
                try database.bind(id, at: 1, to: statement)
                try database.stepDone(statement, operation: "repoint runs")
            }
            try database.withStatement("DELETE FROM run_sessions WHERE session_id = ?") { statement in
                try database.bind(id, at: 1, to: statement)
                try database.stepDone(statement, operation: "delete run links")
            }
            try database.withStatement("DELETE FROM runs WHERE initial_session_id = ?") { statement in
                try database.bind(id, at: 1, to: statement)
                try database.stepDone(statement, operation: "delete orphan runs")
            }
            try database.withStatement("DELETE FROM sessions WHERE id = ?") { statement in
                try database.bind(id, at: 1, to: statement)
                try database.stepDone(statement, operation: "delete session")
            }
            let deleted = sqlite3_changes(database.handle) == 1
            try deleteRowsFailpoint?()
            return deleted
        }
        try database.checkpointTruncate()
        return removed
    }

    // MARK: Provider identity questions

    /// Every provider id the conversation ever had: its Loom id (a new Claude
    /// start uses it as the provider id), the current provider conversation
    /// id and each id recorded in `provider_identity_changes`.
    public func providerIDs(of sessionID: UUID) throws -> [String] {
        var ids = [sessionID.uuidString]
        try database.withStatement("""
            SELECT provider_conversation_id FROM sessions WHERE id = ?1
            UNION SELECT previous_id FROM provider_identity_changes WHERE session_id = ?1
            UNION SELECT new_id FROM provider_identity_changes WHERE session_id = ?1
            """) { statement in
            try database.bind(sessionID.uuidString, at: 1, to: statement)
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                if let value = database.optionalText(statement, column: 0) { ids.append(value) }
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read provider ids")
        }
        var seen: Set<String> = []
        return (ids.prefix(1) + ids.dropFirst().sorted()).filter { seen.insert($0.lowercased()).inserted }
    }

    /// True when another conversation row uses `id` as its Loom id, its
    /// provider conversation id or in its identity changes. Compared
    /// case-insensitively (Claude writes uppercase Loom ids as file names).
    /// A conversation that itself has a deletion record does not count: its
    /// data is going away too, so a shared id is not a reason to keep the files.
    public func isProviderIDShared(_ id: String, excluding sessionID: UUID) throws -> Bool {
        try database.withStatement("""
            SELECT 1 FROM sessions s
            WHERE s.id <> ?2 AND (lower(s.id) = lower(?1) OR lower(s.provider_conversation_id) = lower(?1))
              AND \(Self.notDeleting)
            UNION ALL
            SELECT 1 FROM provider_identity_changes c
            WHERE c.session_id <> ?2 AND (lower(c.previous_id) = lower(?1) OR lower(c.new_id) = lower(?1))
              AND NOT EXISTS (SELECT 1 FROM deletions d WHERE d.session_id = c.session_id)
            LIMIT 1
            """) { statement in
            try database.bind(id, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    /// True when any recorded deletion (whatever its state) lists `id` among its
    /// provider ids. Late provider events must not recreate such a conversation,
    /// including after its rows are gone and before the record is finished.
    public func isProviderIDPendingDeletion(_ id: String) throws -> Bool {
        try database.withStatement("""
            SELECT 1 FROM deletions d, json_each(d.provider_ids) j WHERE lower(j.value) = lower(?) LIMIT 1
            """) { statement in
            try database.bind(id, at: 1, to: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    // MARK: App state

    public func appState(_ key: String) throws -> String? {
        try database.withStatement("SELECT value FROM app_state WHERE key = ?") { statement in
            try database.bind(key, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try database.text(statement, column: 0)
        }
    }

    public func setAppState(_ key: String, to value: String) throws {
        try database.withStatement("""
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """) { statement in
            try database.bind(key, at: 1, to: statement)
            try database.bind(value, at: 2, to: statement)
            try database.stepDone(statement, operation: "set app state")
        }
    }

    // MARK: Internals

    static let deletionColumns = """
        session_id, provider, provider_ids, config_dir, working_directory,
        state, requested_at, updated_at, attempts, last_error
        """

    func requireNotDeleting(_ sessionID: UUID) throws {
        if try readDeletion(sessionID) != nil {
            throw SessionCatalogError.deletionPending(sessionID)
        }
    }

    func readDeletion(_ sessionID: UUID) throws -> CatalogDeletion? {
        try database.withStatement("""
            SELECT \(Self.deletionColumns) FROM deletions WHERE session_id = ?
            """) { statement in
            try database.bind(sessionID.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeDeletion(statement)
        }
    }

    /// A deletion row is never skipped: a record that cannot be read must
    /// stop recovery loudly instead of leaving an erasure half done.
    func decodeDeletion(_ statement: OpaquePointer) throws -> CatalogDeletion {
        guard let id = UUID(uuidString: try database.text(statement, column: 0)),
              let provider = ManagedSession.Provider(rawValue: try database.text(statement, column: 1)),
              let state = CatalogDeletionState(rawValue: try database.text(statement, column: 5)),
              let ids = try? JSONDecoder().decode(
                [String].self, from: Data(try database.text(statement, column: 2).utf8)
              ) else {
            throw SessionCatalogError.invalidRow("unreadable deletion record")
        }
        return CatalogDeletion(
            sessionID: id,
            plan: CatalogDeletionPlan(
                provider: provider, providerIDs: ids,
                configDirectory: database.optionalText(statement, column: 3),
                workingDirectory: database.optionalText(statement, column: 4)
            ),
            state: state,
            requestedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            attempts: Int(sqlite3_column_int64(statement, 8)),
            lastError: database.optionalText(statement, column: 9)
        )
    }

    private static func encode(providerIDs: [String]) throws -> String {
        guard let text = String(data: try JSONEncoder().encode(providerIDs), encoding: .utf8) else {
            throw SessionCatalogError.invalidRow("provider ids are not encodable")
        }
        return text
    }
}
