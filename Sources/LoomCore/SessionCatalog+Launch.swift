import Foundation
import SQLite3

/// A session's launch choices and owning face (V16), runtime-owned. The runtime writes the choices when it starts a
/// session and whenever a live change of mode, model or effort succeeds; every spawn of the session, in either face,
/// reads them here. The UI keeps no copy of its own.
extension SessionCatalog {
    /// The stored mode, model and effort; all nil for a session Loom never recorded any for.
    public func launchChoices(sessionID: UUID) throws -> ClaudeLaunchChoices {
        try database.withStatement(
            "SELECT permission_mode, model, effort FROM sessions WHERE id = ?"
        ) { statement in
            try database.bind(sessionID.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return ClaudeLaunchChoices() }
            return ClaudeLaunchChoices(
                permissionMode: database.optionalText(statement, column: 0),
                model: database.optionalText(statement, column: 1),
                effort: database.optionalText(statement, column: 2)
            )
        }
    }

    /// Records the choices that are set; one that is nil keeps its stored value. The session's project remembers them for its
    /// next session (`lastUsedLaunchChoices`): a start and a live change of mode, model or effort count alike.
    /// `rememberingInProject` false keeps a session an agent opened out of that memory (Q3, D-103).
    public func recordLaunchChoices(_ choices: ClaudeLaunchChoices, sessionID: UUID,
                                    rememberingInProject: Bool = true) throws {
        guard !choices.isEmpty else { return }
        try database.transaction {
            try database.withStatement("""
                UPDATE sessions SET permission_mode = COALESCE(?, permission_mode), model = COALESCE(?, model),
                    effort = COALESCE(?, effort)
                WHERE id = ?
                """) { statement in
                try database.bind(choices.permissionMode, at: 1, to: statement)
                try database.bind(choices.model, at: 2, to: statement)
                try database.bind(choices.effort, at: 3, to: statement)
                try database.bind(sessionID.uuidString, at: 4, to: statement)
                try database.stepDone(statement, operation: "record launch choices")
            }
            guard rememberingInProject else { return }
            // A session this catalog does not have remembers nothing.
            let key: String? = try database.withStatement("SELECT project_id FROM sessions WHERE id = ?") { statement in
                try database.bind(sessionID.uuidString, at: 1, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return database.optionalText(statement, column: 0) ?? Self.noProjectKey
            }
            guard let key else { return }
            var all = try storedLastUsed()
            let updated = choices.remembered(over: all[key])
            guard !updated.isEmpty, updated != all[key] else { return }
            all[key] = updated
            try storeLastUsed(all)
        }
    }

    /// The stored model of each given session that has one (the sidebar's cards, RESCUE C3): one query per 500 sessions.
    /// A session without a stored model, or one this catalog does not have, is left out.
    public func launchModels(sessionIDs: [UUID]) throws -> [UUID: String] {
        var result: [UUID: String] = [:]
        var start = 0
        while start < sessionIDs.count {
            let chunk = Array(sessionIDs[start..<min(start + 500, sessionIDs.count)])
            start += chunk.count
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try database.withStatement("SELECT id, model FROM sessions WHERE model IS NOT NULL AND id IN (\(marks))") { statement in
                for (offset, id) in chunk.enumerated() {
                    try database.bind(id.uuidString, at: Int32(offset + 1), to: statement)
                }
                var step = sqlite3_step(statement)
                while step == SQLITE_ROW {
                    if let id = UUID(uuidString: try database.text(statement, column: 0)),
                       let model = database.optionalText(statement, column: 1), !model.isEmpty {
                        result[id] = model
                    }
                    step = sqlite3_step(statement)
                }
                try database.requireDone(step, operation: "read launch models")
            }
        }
        return result
    }

    /// The key of the sessions that belong to no project in `lastUsedLaunchChoices`.
    public static let noProjectKey = "none"
    private static let lastUsedKey = "launch.last-used"

    /// The mode, model and effort each project's next session starts with unless the draft says otherwise: what its newest
    /// start or live change set (Full access excepted). Keyed by the project id, `noProjectKey` for sessions with none.
    public func lastUsedLaunchChoices() throws -> [String: ClaudeLaunchChoices] {
        try storedLastUsed()
    }

    private func storedLastUsed() throws -> [String: ClaudeLaunchChoices] {
        guard let text = try appState(Self.lastUsedKey), let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: ClaudeLaunchChoices].self, from: data) else { return [:] }
        return decoded
    }

    private func storeLastUsed(_ all: [String: ClaudeLaunchChoices]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try setAppState(Self.lastUsedKey, to: String(decoding: try encoder.encode(all), as: UTF8.self))
    }

    /// The one-time copy of what the older new-session file remembered per project: a project the catalog already
    /// remembers something for keeps it. Returns how many projects took choices.
    @discardableResult
    public func importLastUsedLaunchChoices(_ entries: [String: ClaudeLaunchChoices]) throws -> Int {
        try database.transaction {
            var all = try storedLastUsed()
            var count = 0
            for (key, choices) in entries where all[key] == nil {
                let kept = choices.remembered(over: nil)
                guard !kept.isEmpty else { continue }
                all[key] = kept
                count += 1
            }
            if count > 0 { try storeLastUsed(all) }
            return count
        }
    }

    /// Copies choices recorded elsewhere (the UI's older `launched` list) into sessions that have none stored yet.
    /// A session with any stored choice is left alone, so running it again changes nothing. Returns how many rows
    /// took choices.
    @discardableResult
    public func importLaunchChoices(_ entries: [UUID: ClaudeLaunchChoices]) throws -> Int {
        let wanted = entries.filter { !$0.value.isEmpty }
        guard !wanted.isEmpty else { return 0 }
        return try database.transaction {
            var count = 0
            for (id, choices) in wanted {
                try database.withStatement("""
                    UPDATE sessions SET permission_mode = ?, model = ?, effort = ?
                    WHERE id = ? AND permission_mode IS NULL AND model IS NULL AND effort IS NULL
                    """) { statement in
                    try database.bind(choices.permissionMode, at: 1, to: statement)
                    try database.bind(choices.model, at: 2, to: statement)
                    try database.bind(choices.effort, at: 3, to: statement)
                    try database.bind(id.uuidString, at: 4, to: statement)
                    try database.stepDone(statement, operation: "import launch choices")
                    count += Int(sqlite3_changes(database.handle))
                }
            }
            return count
        }
    }

    /// A run moved from one card to another (`/clear`, a fork): the destination takes the source's choices where it
    /// has none of its own, and the run's endpoint.
    public func carryLaunchState(from source: UUID, to destination: UUID, endpoint: RunEndpointKind) throws {
        try database.withStatement("""
            UPDATE sessions SET
                permission_mode = COALESCE(permission_mode, (SELECT permission_mode FROM sessions WHERE id = ?1)),
                model = COALESCE(model, (SELECT model FROM sessions WHERE id = ?1)),
                effort = COALESCE(effort, (SELECT effort FROM sessions WHERE id = ?1)),
                run_endpoint = ?2
            WHERE id = ?3
            """) { statement in
            try database.bind(source.uuidString, at: 1, to: statement)
            try database.bind(endpoint.rawValue, at: 2, to: statement)
            try database.bind(destination.uuidString, at: 3, to: statement)
            try database.stepDone(statement, operation: "carry launch state")
        }
    }

    public func setRunEndpoint(_ kind: RunEndpointKind, sessionID: UUID) throws {
        try database.withStatement("UPDATE sessions SET run_endpoint = ? WHERE id = ?") { statement in
            try database.bind(kind.rawValue, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "record run endpoint")
        }
    }
}

extension SessionCatalog {
    /// Sets the session's recorded model back to `model` (nil: none recorded). `recordLaunchChoices` cannot do this: it keeps
    /// a stored value where the new one is nil. Used when a pick that was recorded early did not reach the CLI.
    public func setLaunchModel(_ model: String?, sessionID: UUID) throws {
        try database.withStatement("UPDATE sessions SET model = ? WHERE id = ?") { statement in
            try database.bind(model, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "set launch model")
        }
    }

    /// Forgets the session's recorded effort: a model without effort levels must not be started with `--effort` (the merge in
    /// `recordLaunchChoices` cannot clear a value).
    public func clearLaunchEffort(sessionID: UUID) throws {
        try database.withStatement("UPDATE sessions SET effort = NULL WHERE id = ?") { statement in
            try database.bind(sessionID.uuidString, at: 1, to: statement)
            try database.stepDone(statement, operation: "clear launch effort")
        }
    }
}
