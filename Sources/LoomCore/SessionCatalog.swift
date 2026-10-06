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
    static let sessionColumns = """
        s.id, s.provider, s.provider_conversation_id, s.working_directory, s.title,
        s.created_at, s.last_used_at, s.lifecycle, s.pinned, s.project_id, s.title_is_custom
        """
    let database: CatalogDatabase
    var existingRunTransitionFailpoint: (@Sendable () throws -> Void)?
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
            titleIsCustom: sqlite3_column_int(statement, 10) != 0
        )
    }

    func insertSessionRow(
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

    func requireChangedSession(_ sessionID: UUID, operation: String) throws {
        guard sqlite3_changes(database.handle) == 1 else {
            throw SessionCatalogError.invalidRow("\(operation): session \(sessionID) does not exist")
        }
    }
}
