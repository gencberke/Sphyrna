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
    /// When the row became stale (`last use + staleAfter` at classification).
    /// Nil means unknown (a row classified before schema 3, or not stale);
    /// the cleanup planner derives it then.
    public let staleSince: Date?
    /// When the user last really used the session (start, resume, prompt,
    /// finished turn, user Stop). Unlike `lastUsedAt`, a view never moves it;
    /// the card time and the activity order read this one.
    public let lastActivityAt: Date
    /// The ticket an agent named when it asked for this session to be opened (D-40); nil otherwise.
    public let ticketKey: String?
    /// The session whose agent asked for this one to be opened (D-40); nil for a session the user started.
    public let openedBy: UUID?

    public init(
        session: ManagedSession, title: String?, createdAt: Date, lastUsedAt: Date,
        lifecycle: SessionLifecycle, pinned: Bool, projectID: UUID? = nil,
        titleIsCustom: Bool = false, staleSince: Date? = nil, lastActivityAt: Date? = nil,
        ticketKey: String? = nil, openedBy: UUID? = nil
    ) {
        self.ticketKey = ticketKey
        self.openedBy = openedBy
        self.lastActivityAt = lastActivityAt ?? lastUsedAt
        self.session = session
        self.title = title
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lifecycle = lifecycle
        self.pinned = pinned
        self.projectID = projectID
        self.titleIsCustom = titleIsCustom
        self.staleSince = staleSince
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
    /// Creation order, newest first (project view; selection never moves a row).
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
    /// Rows this page's scan met but could not decode (unknown provider or
    /// malformed identity). They are skipped, never written or deleted; the
    /// next page's scan can meet the same rows again.
    public let skippedRowCount: Int

    init(sessions: [CatalogSession], next: CatalogCursor?, skippedRowCount: Int = 0) {
        self.sessions = sessions
        self.next = next
        self.skippedRowCount = skippedRowCount
    }
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
    /// The conversation has a `deletions` row: no start, resume or use is allowed.
    case deletionPending(UUID)
    case deletionAlreadyRequested(UUID)

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
            "Project still has sessions and cannot be removed: \(id)"
        case let .projectPathNotDirectory(path):
            "Project path is not an existing folder: \(path)"
        case let .deletionPending(id):
            "Session is being deleted: \(id)"
        case let .deletionAlreadyRequested(id):
            "A deletion is already recorded for session: \(id)"
        }
    }
}

/// Serialized durable metadata store. It never stores conversation content.
public actor SessionCatalog {
    public static let schemaVersion: Int32 = 3
    public static let maxTitleLength = 160
    static let sessionColumns = """
        s.id, s.provider, s.provider_conversation_id, s.working_directory, s.title,
        s.created_at, s.last_used_at, s.lifecycle, s.pinned, s.project_id, s.title_is_custom,
        s.stale_since, \(activityExpression), s.ticket_key, s.opened_by
        """
    /// A row an older build wrote has no activity time yet: it reads as its use time.
    static let activityExpression = "COALESCE(s.last_activity_at, s.last_used_at)"
    /// Excludes conversations with a `deletions` row (fence); `s` is the sessions alias.
    static let notDeleting = "NOT EXISTS (SELECT 1 FROM deletions d WHERE d.session_id = s.id)"
    let database: CatalogDatabase
    var existingRunTransitionFailpoint: (@Sendable () throws -> Void)?
    /// Rows decoded so far; lets tests prove a state change does not rescan the catalog.
    private(set) var decodedSessionRows = 0
    /// Raw ids of rows that could not be decoded, met by a list or load path.
    private var skippedRowIDs: Set<String> = []
    var deleteRowsFailpoint: (@Sendable () throws -> Void)?

    /// Distinct undecodable `sessions` rows met so far by `sessions()`,
    /// `sessions(ids:)` and `sessionPage` (for later UI or evidence). Such
    /// rows are skipped and never written or deleted.
    public var skippedRowCount: Int { skippedRowIDs.count }

    public init(url: URL) throws {
        database = try CatalogDatabase(url: url)
    }

    /// Test seam: runs inside the migration transaction, after the DDL and
    /// before COMMIT, so a thrown error exercises the real rollback.
    init(url: URL, migrationFailpoint: @escaping () throws -> Void) throws {
        database = try CatalogDatabase(url: url, migrationFailpoint: migrationFailpoint)
    }

    /// Same, called after the DDL of each target version (2, then 3).
    init(url: URL, versionedMigrationFailpoint: @escaping (Int32) throws -> Void) throws {
        database = try CatalogDatabase(url: url, versionedMigrationFailpoint: versionedMigrationFailpoint)
    }

    /// Test seam inside the delete transaction, after the row deletes and
    /// before COMMIT.
    init(url: URL, deleteRowsFailpoint: @escaping @Sendable () throws -> Void) throws {
        database = try CatalogDatabase(url: url)
        self.deleteRowsFailpoint = deleteRowsFailpoint
    }

    /// Test seam at the existing-target transaction boundary, after the
    /// supervisor has selected its destination and before the durable commit.
    init(url: URL, existingRunTransitionFailpoint: @escaping @Sendable () throws -> Void) throws {
        database = try CatalogDatabase(url: url)
        self.existingRunTransitionFailpoint = existingRunTransitionFailpoint
    }

    func project(where predicate: String, value: String) throws -> CatalogProject? {
        try database.withStatement("""
            SELECT id, path, name, sort_order, collapsed, created_at
            FROM projects WHERE \(predicate) LIMIT 1
            """) { statement in
            try database.bind(value, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeProject(statement)
        }
    }

    func decodeProject(_ statement: OpaquePointer) throws -> CatalogProject {
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

    func readSession(where predicate: String, value: String) throws -> CatalogSession? {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s WHERE \(predicate) LIMIT 1
            """) { statement in
            try database.bind(value, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeSession(statement)
        }
    }

    /// List and load paths: an undecodable row is counted and skipped instead
    /// of failing the whole read. Only invalid content is skipped; SQLite
    /// errors still propagate.
    func decodeSessionOrSkip(_ statement: OpaquePointer) throws -> CatalogSession? {
        do {
            return try decodeSession(statement)
        } catch SessionCatalogError.invalidRow {
            skippedRowIDs.insert(database.optionalText(statement, column: 0) ?? "")
            return nil
        }
    }

    func decodeSession(_ statement: OpaquePointer) throws -> CatalogSession {
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
            titleIsCustom: sqlite3_column_int(statement, 10) != 0,
            staleSince: database.optionalDouble(statement, column: 11).map(Date.init(timeIntervalSince1970:)),
            lastActivityAt: database.optionalDouble(statement, column: 12).map(Date.init(timeIntervalSince1970:)),
            ticketKey: database.optionalText(statement, column: 13),
            // A requester id that does not parse is dropped, never a reason to skip the row.
            openedBy: database.optionalText(statement, column: 14).flatMap(UUID.init(uuidString:))
        )
    }

    func insertSessionRow(
        _ session: ManagedSession, title: String?, createdAt: Date,
        lastUsedAt: Date, lifecycle: SessionLifecycle, pinned: Bool,
        projectID: UUID? = nil, staleSince: Date? = nil, lastActivityAt: Date? = nil,
        titleIsCustom: Bool = false, ticketKey: String? = nil, openedBy: UUID? = nil
    ) throws {
        try database.withStatement("""
            INSERT INTO sessions (
                id, provider, provider_conversation_id, working_directory, title,
                created_at, last_used_at, lifecycle, pinned, project_id, stale_since,
                last_activity_at, title_is_custom, ticket_key, opened_by
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            if let staleSince { sqlite3_bind_double(statement, 11, staleSince.timeIntervalSince1970) }
            else { sqlite3_bind_null(statement, 11) }
            sqlite3_bind_double(statement, 12, (lastActivityAt ?? lastUsedAt).timeIntervalSince1970)
            sqlite3_bind_int(statement, 13, titleIsCustom ? 1 : 0)
            try database.bind(ticketKey, at: 14, to: statement)
            try database.bind(openedBy?.uuidString, at: 15, to: statement)
            try database.stepDone(statement, operation: "insert session")
        }
    }

    func requireActiveLink(runID: UUID, sessionID: UUID) throws {
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

    func sessionExists(_ sessionID: UUID) throws -> Bool {
        try database.withStatement("SELECT 1 FROM sessions WHERE id = ?") { statement in
            try database.bind(sessionID.uuidString, at: 1, to: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func closeAndInsertRunLink(
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
            "UPDATE sessions SET lifecycle = 'idle', stale_since = NULL WHERE id = ?"
        ) { statement in
            try database.bind(oldSessionID.uuidString, at: 1, to: statement)
            try database.stepDone(statement, operation: "idle previous session")
        }
        try database.withStatement(
            "UPDATE sessions SET lifecycle = 'active', stale_since = NULL WHERE id = ?"
        ) { statement in
            try database.bind(newSessionID.uuidString, at: 1, to: statement)
            try database.stepDone(statement, operation: "activate replacement session")
        }
    }

    func requireChangedSession(_ sessionID: UUID, operation: String) throws {
        guard sqlite3_changes(database.handle) == 1 else {
            throw SessionCatalogError.invalidRow("\(operation): session \(sessionID) does not exist")
        }
    }
}
