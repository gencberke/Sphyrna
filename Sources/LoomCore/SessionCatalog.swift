import Foundation
import SQLite3

public enum SessionLifecycle: String, Codable, Sendable {
    case active
    case idle
    case stale
}

public enum ManagedRunEndReason: String, Codable, Sendable {
    case requested
    case idle
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
    public let projectID: UUID?
    /// True when the user renamed the conversation; terminal title events must
    /// not overwrite a custom title.
    public let titleIsCustom: Bool

    public init(
        session: ManagedSession, title: String?, createdAt: Date, lastUsedAt: Date,
        lifecycle: SessionLifecycle, pinned: Bool, projectID: UUID? = nil,
        titleIsCustom: Bool = false
    ) {
        self.session = session
        self.title = title
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lifecycle = lifecycle
        self.pinned = pinned
        self.projectID = projectID
        self.titleIsCustom = titleIsCustom
    }
}

/// A user-added folder that groups conversations. Removing a project never
/// touches the folder's files.
public struct CatalogProject: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let name: String
    public let sortOrder: Int
    public let collapsed: Bool
    public let createdAt: Date
}

public struct CatalogAddedProject: Equatable, Sendable {
    public let project: CatalogProject
    /// True when the same standardized path was already in the catalog.
    public let alreadyPresent: Bool
}

public enum CatalogScope: Equatable, Sendable {
    case all
    case project(UUID)
    case unassigned
}

public enum CatalogOrder: Equatable, Sendable {
    /// Newest use first (activity view).
    case recentActivity
    /// Creation order, oldest first (project view; selection never moves a row).
    case creation
}

public struct CatalogQuery: Equatable, Sendable {
    public static let maxPageSize = 100

    public var scope: CatalogScope
    public var order: CatalogOrder
    public var search: String
    public var limit: Int

    public init(scope: CatalogScope = .all, order: CatalogOrder = .recentActivity,
                search: String = "", limit: Int = CatalogQuery.maxPageSize) {
        self.scope = scope
        self.order = order
        self.search = search
        self.limit = limit
    }
}

/// Keyset position; stable while rows are added or renamed between pages.
public struct CatalogCursor: Equatable, Sendable {
    let timestamp: Double
    let id: String
}

public struct CatalogPage: Equatable, Sendable {
    public let sessions: [CatalogSession]
    /// Nil when this page reached the end of the query.
    public let next: CatalogCursor?
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

public struct CatalogRunSessionLink: Equatable, Sendable {
    public let runID: UUID
    public let sessionID: UUID
    public let linkedAt: Date
    public let unlinkedAt: Date?
}

public enum SessionCatalogError: Error, CustomStringConvertible, Sendable {
    case sqlite(operation: String, code: Int32, message: String)
    case unsupportedSchema(Int32)
    case foreignDatabase(applicationID: Int32)
    case invalidRow(String)
    case projectNotFound(UUID)
    case projectNotEmpty(UUID)
    case projectPathNotDirectory(String)

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
        case let .projectNotFound(id):
            "Project not found: \(id)"
        case let .projectNotEmpty(id):
            "Project still has conversations and cannot be removed: \(id)"
        case let .projectPathNotDirectory(path):
            "Project path is not an existing folder: \(path)"
        }
    }
}

/// Serialized durable metadata store. It never stores conversation content.
public actor SessionCatalog {
    public static let schemaVersion: Int32 = 2
    public static let maxTitleLength = 160
    private static let sessionColumns = """
        s.id, s.provider, s.provider_conversation_id, s.working_directory, s.title,
        s.created_at, s.last_used_at, s.lifecycle, s.pinned, s.project_id, s.title_is_custom
        """
    private let database: CatalogDatabase
    private var existingRunTransitionFailpoint: (@Sendable () throws -> Void)?
    /// Rows decoded so far; lets tests prove a state change does not rescan the catalog.
    private(set) var decodedSessionRows = 0

    public init(url: URL) throws {
        database = try CatalogDatabase(url: url)
    }

    /// Test seam: runs inside the schema 1 to 2 transaction, after the DDL and
    /// before COMMIT, so a thrown error exercises the real rollback.
    init(url: URL, migrationFailpoint: @escaping () throws -> Void) throws {
        database = try CatalogDatabase(url: url, migrationFailpoint: migrationFailpoint)
    }

    /// Test seam at the existing-target transaction boundary, after the
    /// supervisor has selected its destination and before the durable commit.
    init(url: URL, existingRunTransitionFailpoint: @escaping @Sendable () throws -> Void) throws {
        database = try CatalogDatabase(url: url)
        self.existingRunTransitionFailpoint = existingRunTransitionFailpoint
    }

    public func insertSession(_ session: ManagedSession, title: String? = nil,
                              createdAt: Date = Date(), lastUsedAt: Date = Date(),
                              lifecycle: SessionLifecycle = .active,
                              pinned: Bool = false, projectID: UUID? = nil) throws {
        try insertSessionRow(
            session, title: title, createdAt: createdAt, lastUsedAt: lastUsedAt,
            lifecycle: lifecycle, pinned: pinned, projectID: projectID
        )
    }

    public func sessions() throws -> [CatalogSession] {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s ORDER BY s.created_at, s.id
            """) { statement in
            var result: [CatalogSession] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                result.append(try decodeSession(statement))
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
    /// merely viewing history must not make it look live again.
    public func markUsed(sessionID: UUID, at date: Date = Date(),
                         reactivate: Bool = false) throws {
        try database.withStatement("""
            UPDATE sessions
            SET last_used_at = ?,
                lifecycle = CASE
                    WHEN lifecycle IN ('stale', 'idle') AND ? = 0 THEN lifecycle
                    ELSE 'active'
                END
            WHERE id = ?
            """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, reactivate ? 1 : 0)
            try database.bind(sessionID.uuidString, at: 3, to: statement)
            try database.stepDone(statement, operation: "mark session used")
        }
        try requireChangedSession(sessionID, operation: "mark session used")
    }

    public func updateLifecycle(sessionID: UUID, lifecycle: SessionLifecycle) throws {
        try database.withStatement(
            "UPDATE sessions SET lifecycle = ? WHERE id = ?"
        ) { statement in
            try database.bind(lifecycle.rawValue, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "update session lifecycle")
        }
        try requireChangedSession(sessionID, operation: "update session lifecycle")
    }

    /// Classifies conversations by time since last use (contract section 5),
    /// not by how they ended: idle ones and ones that ended by Stop, Quit or
    /// `/exit` (still `active` in the catalog) both qualify. A conversation
    /// with a live run (`running`) is never stale however old its last prompt.
    @discardableResult
    public func classifyStale(before cutoff: Date, excluding running: Set<UUID> = []) throws -> [UUID] {
        let excluded = Self.jsonIDList(running)
        let candidates: [UUID] = try database.withStatement("""
            SELECT id FROM sessions
            WHERE lifecycle IN ('idle', 'active') AND last_used_at < ?
              AND id NOT IN (SELECT value FROM json_each(?))
            ORDER BY id
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
            UPDATE sessions SET lifecycle = 'stale'
            WHERE lifecycle IN ('idle', 'active') AND last_used_at < ?
              AND id NOT IN (SELECT value FROM json_each(?))
            """) { statement in
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            try database.bind(excluded, at: 2, to: statement)
            try database.stepDone(statement, operation: "classify stale sessions")
        }
        return candidates
    }

    /// The oldest last-use among conversations that can become stale: idle
    /// ones and active ones without a live run.
    public func oldestStaleCandidate(excluding running: Set<UUID> = []) throws -> Date? {
        try database.withStatement("""
            SELECT MIN(last_used_at) FROM sessions
            WHERE lifecycle IN ('idle', 'active')
              AND id NOT IN (SELECT value FROM json_each(?))
            """) { statement in
            try database.bind(Self.jsonIDList(running), at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return database.optionalDouble(statement, column: 0).map(Date.init(timeIntervalSince1970:))
        }
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

    // MARK: Projects

    public func projects() throws -> [CatalogProject] {
        try database.withStatement("""
            SELECT id, path, name, sort_order, collapsed, created_at
            FROM projects ORDER BY sort_order, id
            """) { statement in
            var result: [CatalogProject] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                result.append(try decodeProject(statement))
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read projects")
            return result
        }
    }

    /// Adds a folder. The path is standardized (symlinks resolved, no trailing
    /// slash), so the same folder cannot be added twice; a repeat returns the
    /// existing project.
    public func addProject(path: String, at date: Date = Date()) throws -> CatalogAddedProject {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionCatalogError.projectPathNotDirectory(standardized)
        }
        return try database.transaction {
            if let existing = try project(where: "path = ?", value: standardized) {
                return CatalogAddedProject(project: existing, alreadyPresent: true)
            }
            let next = try database.scalarInt64("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM projects")
            let id = UUID()
            let name = URL(fileURLWithPath: standardized).lastPathComponent
            try database.withStatement("""
                INSERT INTO projects (id, path, name, sort_order, collapsed, created_at)
                VALUES (?, ?, ?, ?, 0, ?)
                """) { statement in
                try database.bind(id.uuidString, at: 1, to: statement)
                try database.bind(standardized, at: 2, to: statement)
                try database.bind(name.isEmpty ? standardized : name, at: 3, to: statement)
                sqlite3_bind_int64(statement, 4, next)
                sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
                try database.stepDone(statement, operation: "insert project")
            }
            guard let created = try project(where: "id = ?", value: id.uuidString) else {
                throw SessionCatalogError.projectNotFound(id)
            }
            return CatalogAddedProject(project: created, alreadyPresent: false)
        }
    }

    /// Only an empty project can be removed. Conversations stay untouched and
    /// the folder on disk is never deleted.
    public func removeProject(id: UUID) throws {
        try database.transaction {
            let count = try database.withStatement(
                "SELECT count(*) FROM sessions WHERE project_id = ?"
            ) { statement in
                try database.bind(id.uuidString, at: 1, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return Int64(0) }
                return sqlite3_column_int64(statement, 0)
            }
            guard count == 0 else { throw SessionCatalogError.projectNotEmpty(id) }
            try database.withStatement("DELETE FROM projects WHERE id = ?") { statement in
                try database.bind(id.uuidString, at: 1, to: statement)
                try database.stepDone(statement, operation: "remove project")
            }
            guard sqlite3_changes(database.handle) == 1 else {
                throw SessionCatalogError.projectNotFound(id)
            }
        }
    }

    /// Moves a project to a zero-based position and rewrites the dense order.
    public func moveProject(id: UUID, toIndex: Int) throws {
        try database.transaction {
            var ids: [String] = try database.withStatement(
                "SELECT id FROM projects ORDER BY sort_order, id"
            ) { statement in
                var result: [String] = []
                var stepResult = sqlite3_step(statement)
                while stepResult == SQLITE_ROW {
                    result.append(try database.text(statement, column: 0))
                    stepResult = sqlite3_step(statement)
                }
                try database.requireDone(stepResult, operation: "read project order")
                return result
            }
            guard let from = ids.firstIndex(of: id.uuidString) else {
                throw SessionCatalogError.projectNotFound(id)
            }
            let moved = ids.remove(at: from)
            ids.insert(moved, at: min(max(0, toIndex), ids.count))
            for (order, projectID) in ids.enumerated() {
                try database.withStatement(
                    "UPDATE projects SET sort_order = ? WHERE id = ? AND sort_order <> ?"
                ) { statement in
                    sqlite3_bind_int64(statement, 1, Int64(order))
                    try database.bind(projectID, at: 2, to: statement)
                    sqlite3_bind_int64(statement, 3, Int64(order))
                    try database.stepDone(statement, operation: "reorder project")
                }
            }
        }
    }

    public func setProjectCollapsed(id: UUID, collapsed: Bool) throws {
        try database.withStatement(
            "UPDATE projects SET collapsed = ? WHERE id = ?"
        ) { statement in
            sqlite3_bind_int(statement, 1, collapsed ? 1 : 0)
            try database.bind(id.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "update project collapsed")
        }
        guard sqlite3_changes(database.handle) == 1 else {
            throw SessionCatalogError.projectNotFound(id)
        }
    }

    /// Conversation count per project (nil key: no project), from one grouped scan.
    public func sessionCounts() throws -> [UUID?: Int] {
        try database.withStatement(
            "SELECT project_id, count(*) FROM sessions GROUP BY project_id"
        ) { statement in
            var result: [UUID?: Int] = [:]
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                let key = database.optionalText(statement, column: 0).flatMap(UUID.init(uuidString:))
                result[key] = Int(sqlite3_column_int64(statement, 1))
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "count sessions")
            return result
        }
    }

    // MARK: Titles

    /// User rename: marks the title custom so terminal title events cannot
    /// replace it. An empty title returns the row to automatic titles.
    @discardableResult
    public func renameSession(sessionID: UUID, to title: String) throws -> String? {
        let normalized = Self.normalizedTitle(title)
        try database.withStatement("""
            UPDATE sessions SET title = ?, title_is_custom = ? WHERE id = ?
            """) { statement in
            try database.bind(normalized, at: 1, to: statement)
            sqlite3_bind_int(statement, 2, normalized == nil ? 0 : 1)
            try database.bind(sessionID.uuidString, at: 3, to: statement)
            try database.stepDone(statement, operation: "rename session")
        }
        try requireChangedSession(sessionID, operation: "rename session")
        return normalized
    }

    /// A title announced by the terminal or provider. Ignored (returns false)
    /// while the user's custom title is set.
    @discardableResult
    public func recordTerminalTitle(sessionID: UUID, title: String) throws -> Bool {
        guard let normalized = Self.normalizedTitle(Self.strippingStatusGlyph(title)) else { return false }
        // An unchanged value is not a write, so "changed" is accurate and a
        // provider that repaints its title every second costs nothing.
        try database.withStatement("""
            UPDATE sessions SET title = ? WHERE id = ? AND title_is_custom = 0 AND title IS NOT ?
            """) { statement in
            try database.bind(normalized, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.bind(normalized, at: 3, to: statement)
            try database.stepDone(statement, operation: "record terminal title")
        }
        return sqlite3_changes(database.handle) == 1
    }

    /// Claude Code prefixes its terminal title with a status glyph that
    /// alternates while it works (`◐`/`◑`, or a braille spinner) and `✳` when
    /// it is quiet. Only that narrow known set is removed, never other emoji.
    static func strippingStatusGlyph(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first, isStatusGlyph(first) else { return raw }
        let rest = trimmed.unicodeScalars.dropFirst()
        guard rest.first.map({ $0 == " " }) ?? true else { return raw }
        return String(String.UnicodeScalarView(rest))
    }

    private static func isStatusGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x25D0...0x25D3, 0x2733, 0x2800...0x28FF: true
        default: false
        }
    }

    static func normalizedTitle(_ raw: String) -> String? {
        let flattened = raw.unicodeScalars.map {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                ? " " : Character($0)
        }
        let trimmed = String(flattened).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTitleLength))
    }

    // MARK: Paged queries

    /// One keyset page (at most `CatalogQuery.maxPageSize` rows). Search,
    /// order and scope are part of the SQL; nothing is filtered afterwards.
    public func sessionPage(_ query: CatalogQuery, after cursor: CatalogCursor? = nil) throws -> CatalogPage {
        let limit = min(max(1, query.limit), CatalogQuery.maxPageSize)
        var conditions: [String] = []
        var bindings: [(String?, Double?)] = []
        switch query.scope {
        case .all: break
        case let .project(id):
            conditions.append("s.project_id = ?")
            bindings.append((id.uuidString, nil))
        case .unassigned:
            conditions.append("s.project_id IS NULL")
        }
        for term in query.search.split(whereSeparator: \.isWhitespace) {
            let pattern = "%" + Self.escapeLike(Self.fold(String(term))) + "%"
            // SQLite's own LIKE folds ASCII only; loom_fold also handles Turkish and other scripts.
            conditions.append("""
                (loom_fold(s.provider) LIKE ? ESCAPE '\\' OR loom_fold(s.title) LIKE ? ESCAPE '\\'
                 OR loom_fold(p.name) LIKE ? ESCAPE '\\')
                """)
            for _ in 0..<3 { bindings.append((pattern, nil)) }
        }
        let column: String
        let direction: String
        let comparison: String
        switch query.order {
        case .recentActivity: column = "s.last_used_at"; direction = "DESC"; comparison = "<"
        case .creation: column = "s.created_at"; direction = "ASC"; comparison = ">"
        }
        if let cursor {
            conditions.append("(\(column) \(comparison) ? OR (\(column) = ? AND s.id \(comparison) ?))")
            bindings.append((nil, cursor.timestamp))
            bindings.append((nil, cursor.timestamp))
            bindings.append((cursor.id, nil))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT \(Self.sessionColumns) FROM sessions s
            LEFT JOIN projects p ON p.id = s.project_id
            \(whereClause)
            ORDER BY \(column) \(direction), s.id \(direction) LIMIT ?
            """
        return try database.withStatement(sql) { statement in
            var index: Int32 = 1
            for (text, number) in bindings {
                if let text { try database.bind(text, at: index, to: statement) }
                else if let number { sqlite3_bind_double(statement, index, number) }
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(limit + 1))
            var rows: [CatalogSession] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                rows.append(try decodeSession(statement))
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read session page")
            guard rows.count > limit else { return CatalogPage(sessions: rows, next: nil) }
            rows.removeLast()
            let last = rows[rows.count - 1]
            let timestamp = query.order == .recentActivity ? last.lastUsedAt : last.createdAt
            return CatalogPage(
                sessions: rows,
                next: CatalogCursor(timestamp: timestamp.timeIntervalSince1970,
                                    id: last.session.id.uuidString)
            )
        }
    }

    /// Selective read for callers that already know which rows they need.
    public func sessions(ids: [UUID]) throws -> [CatalogSession] {
        var result: [CatalogSession] = []
        for chunk in stride(from: 0, to: ids.count, by: 500) {
            let slice = ids[chunk..<min(chunk + 500, ids.count)]
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            result += try database.withStatement("""
                SELECT \(Self.sessionColumns) FROM sessions s WHERE s.id IN (\(placeholders))
                """) { statement in
                for (offset, id) in slice.enumerated() {
                    try database.bind(id.uuidString, at: Int32(offset + 1), to: statement)
                }
                var rows: [CatalogSession] = []
                var stepResult = sqlite3_step(statement)
                while stepResult == SQLITE_ROW {
                    rows.append(try decodeSession(statement))
                    stepResult = sqlite3_step(statement)
                }
                try database.requireDone(stepResult, operation: "read selected sessions")
                return rows
            }
        }
        return result
    }

    public func oldestLastUsed(lifecycle: SessionLifecycle) throws -> Date? {
        try database.withStatement(
            "SELECT MIN(last_used_at) FROM sessions WHERE lifecycle = ?"
        ) { statement in
            try database.bind(lifecycle.rawValue, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return database.optionalDouble(statement, column: 0).map(Date.init(timeIntervalSince1970:))
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: nil)
    }

    private static func escapeLike(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func project(where predicate: String, value: String) throws -> CatalogProject? {
        try database.withStatement("""
            SELECT id, path, name, sort_order, collapsed, created_at
            FROM projects WHERE \(predicate) LIMIT 1
            """) { statement in
            try database.bind(value, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeProject(statement)
        }
    }

    private func decodeProject(_ statement: OpaquePointer) throws -> CatalogProject {
        guard let id = UUID(uuidString: try database.text(statement, column: 0)) else {
            throw SessionCatalogError.invalidRow("invalid project identity")
        }
        return CatalogProject(
            id: id, path: try database.text(statement, column: 1),
            name: try database.text(statement, column: 2),
            sortOrder: Int(sqlite3_column_int64(statement, 3)),
            collapsed: sqlite3_column_int(statement, 4) != 0,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private func readSession(where predicate: String, value: String) throws -> CatalogSession? {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s WHERE \(predicate) LIMIT 1
            """) { statement in
            try database.bind(value, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeSession(statement)
        }
    }

    private func decodeSession(_ statement: OpaquePointer) throws -> CatalogSession {
        decodedSessionRows &+= 1
        guard let id = UUID(uuidString: try database.text(statement, column: 0)),
              let provider = ManagedSession.Provider(rawValue: try database.text(statement, column: 1)),
              let lifecycle = SessionLifecycle(rawValue: try database.text(statement, column: 7)) else {
            throw SessionCatalogError.invalidRow("unknown session identity, provider, or lifecycle")
        }
        var projectID: UUID?
        if let stored = database.optionalText(statement, column: 9) {
            guard let parsed = UUID(uuidString: stored) else {
                throw SessionCatalogError.invalidRow("invalid session project identity")
            }
            projectID = parsed
        }
        return CatalogSession(
            session: ManagedSession(
                id: id, provider: provider,
                providerConversationID: database.optionalText(statement, column: 2),
                workingDirectory: try database.text(statement, column: 3)
            ),
            title: database.optionalText(statement, column: 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            lifecycle: lifecycle,
            pinned: sqlite3_column_int(statement, 8) != 0,
            projectID: projectID,
            titleIsCustom: sqlite3_column_int(statement, 10) != 0
        )
    }

    private func insertSessionRow(
        _ session: ManagedSession, title: String?, createdAt: Date,
        lastUsedAt: Date, lifecycle: SessionLifecycle, pinned: Bool,
        projectID: UUID? = nil
    ) throws {
        try database.withStatement("""
            INSERT INTO sessions (
                id, provider, provider_conversation_id, working_directory, title,
                created_at, last_used_at, lifecycle, pinned, project_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            try database.bind(projectID?.uuidString, at: 10, to: statement)
            try database.stepDone(statement, operation: "insert session")
        }
    }

    private func requireActiveLink(runID: UUID, sessionID: UUID) throws {
        let linked = try database.withStatement("""
            SELECT 1 FROM run_sessions
            WHERE run_id = ? AND session_id = ? AND unlinked_at IS NULL
            LIMIT 1
            """) { statement in
            try database.bind(runID.uuidString, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
        guard linked else {
            throw SessionCatalogError.invalidRow(
                "run \(runID) is not actively linked to session \(sessionID)"
            )
        }
    }

    private func sessionExists(_ sessionID: UUID) throws -> Bool {
        try database.withStatement("SELECT 1 FROM sessions WHERE id = ?") { statement in
            try database.bind(sessionID.uuidString, at: 1, to: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func closeAndInsertRunLink(
        runID: UUID, oldSessionID: UUID, newSessionID: UUID, at date: Date
    ) throws {
        try database.withStatement("""
            UPDATE run_sessions SET unlinked_at = ?
            WHERE run_id = ? AND session_id = ? AND unlinked_at IS NULL
            """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try database.bind(runID.uuidString, at: 2, to: statement)
            try database.bind(oldSessionID.uuidString, at: 3, to: statement)
            try database.stepDone(statement, operation: "unlink run session")
        }
        try database.withStatement("""
            INSERT INTO run_sessions (run_id, session_id, linked_at)
            VALUES (?, ?, ?)
            """) { statement in
            try database.bind(runID.uuidString, at: 1, to: statement)
            try database.bind(newSessionID.uuidString, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
            try database.stepDone(statement, operation: "link replacement session")
        }
        try database.withStatement(
            "UPDATE sessions SET lifecycle = 'idle' WHERE id = ?"
        ) { statement in
            try database.bind(oldSessionID.uuidString, at: 1, to: statement)
            try database.stepDone(statement, operation: "idle previous session")
        }
        try database.withStatement(
            "UPDATE sessions SET lifecycle = 'active' WHERE id = ?"
        ) { statement in
            try database.bind(newSessionID.uuidString, at: 1, to: statement)
            try database.stepDone(statement, operation: "activate replacement session")
        }
    }

    private func requireChangedSession(_ sessionID: UUID, operation: String) throws {
        guard sqlite3_changes(database.handle) == 1 else {
            throw SessionCatalogError.invalidRow("\(operation): session \(sessionID) does not exist")
        }
    }
}

private final class CatalogDatabase: @unchecked Sendable {
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
