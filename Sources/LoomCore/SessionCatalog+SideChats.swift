import Foundation
import SQLite3

/// Side chats (V22): the cards of forks, kept apart from every list. A side chat is a real session row (resumable, deletable
/// through the verified path) whose `parent_session_id` is the Loom id of the session it was forked from. Lists, counts and
/// searches leave it out (`SessionCatalog.listed`); the queries here are how the runtime and the Side tab find it.
extension SessionCatalog {
    /// The side chats of one session, oldest first. A side chat whose deletion has begun is not listed, unless
    /// `includingDeleting` (the cascade of a deletion retries it).
    public func sideChats(of parent: UUID, includingDeleting: Bool = false) throws -> [CatalogSession] {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s
            WHERE s.parent_session_id = ? AND \(includingDeleting ? "1" : Self.notDeleting) ORDER BY s.created_at, s.id
            """) { statement in
            try database.bind(parent.uuidString, at: 1, to: statement)
            return try sideChatRows(statement, operation: "read side chats")
        }
    }

    /// The side chats of every session of a project, for removing it. Rows whose deletion has begun are included: a
    /// deletion that did not finish is retried by the same path.
    public func sideChats(inProject projectID: UUID) throws -> [CatalogSession] {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s
            WHERE s.parent_session_id IS NOT NULL AND s.project_id = ? ORDER BY s.created_at, s.id
            """) { statement in
            try database.bind(projectID.uuidString, at: 1, to: statement)
            return try sideChatRows(statement, operation: "read a project's side chats")
        }
    }

    /// The provider conversation ids of every side chat: what the usage index is given, so a record read from a side chat's file
    /// never takes a message its parent holds.
    public func sideChatProviderIDs() throws -> Set<String> {
        try database.withStatement("""
            SELECT s.provider_conversation_id FROM sessions s
            WHERE s.parent_session_id IS NOT NULL AND s.provider_conversation_id IS NOT NULL
            """) { statement in
            var ids: Set<String> = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if let id = database.optionalText(statement, column: 0) { ids.insert(id) }
                step = sqlite3_step(statement)
            }
            try database.requireDone(step, operation: "read side chat provider ids")
            return ids
        }
    }

    /// How many side chats a session has (a deletion's sheet says so).
    public func sideChatCount(of parent: UUID) throws -> Int {
        try database.withStatement("""
            SELECT count(*) FROM sessions s WHERE s.parent_session_id = ? AND \(Self.notDeleting)
            """) { statement in
            try database.bind(parent.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func sideChatRows(_ statement: OpaquePointer, operation: String) throws -> [CatalogSession] {
        var rows: [CatalogSession] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let row = try decodeSessionOrSkip(statement) { rows.append(row) }
            step = sqlite3_step(statement)
        }
        try database.requireDone(step, operation: operation)
        return rows
    }

    /// The uuid of the side chat's first user message, written when it is sent. Written once: a later send never replaces it.
    public func setSideFirstUUID(_ uuid: String, sessionID: UUID) throws {
        try database.withStatement("""
            UPDATE sessions SET side_first_uuid = ? WHERE id = ? AND parent_session_id IS NOT NULL AND side_first_uuid IS NULL
            """) { statement in
            try database.bind(uuid, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "record side chat first message")
        }
    }

    /// The side chat's title: the first line of its first question, never custom (a rename still wins), never generated. Written
    /// once: a later question does not retitle it.
    public func setSideChatTitle(_ title: String, sessionID: UUID) throws {
        guard let normalized = Self.normalizedTitle(title) else { return }
        try database.withStatement("""
            UPDATE sessions SET title = ? WHERE id = ? AND parent_session_id IS NOT NULL AND title_is_custom = 0 AND title IS NULL
            """) { statement in
            try database.bind(normalized, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "record side chat title")
        }
    }

    /// The choices a side chat's card starts with. Not `recordLaunchChoices`: that would make the project remember a side chat's
    /// mode (`default`) as its next session's.
    public func recordSideChatChoices(_ choices: ClaudeLaunchChoices, sessionID: UUID) throws {
        try database.withStatement("""
            UPDATE sessions SET permission_mode = ?, model = ?, effort = ? WHERE id = ? AND parent_session_id IS NOT NULL
            """) { statement in
            try database.bind(choices.permissionMode, at: 1, to: statement)
            try database.bind(choices.model, at: 2, to: statement)
            try database.bind(choices.effort, at: 3, to: statement)
            try database.bind(sessionID.uuidString, at: 4, to: statement)
            try database.stepDone(statement, operation: "record side chat choices")
        }
    }
}
