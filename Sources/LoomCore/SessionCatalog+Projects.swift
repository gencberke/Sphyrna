import Foundation
import SQLite3

extension SessionCatalog {
    // MARK: Projects

    public func projects() throws -> [CatalogProject] {
        try database.withStatement("""
            SELECT \(Self.projectColumns)
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
            let tone = ProjectTone.leastUsed(counts: try database.projectToneCounts())
            let id = UUID()
            let name = URL(fileURLWithPath: standardized).lastPathComponent
            try database.withStatement("""
                INSERT INTO projects (id, path, name, sort_order, collapsed, created_at, color)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """) { statement in
                try database.bind(id.uuidString, at: 1, to: statement)
                try database.bind(standardized, at: 2, to: statement)
                try database.bind(name.isEmpty ? standardized : name, at: 3, to: statement)
                sqlite3_bind_int64(statement, 4, next)
                sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
                try database.bind(tone.rawValue, at: 6, to: statement)
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

    /// Sets a project's colour; nil is None. None is stored, so the project keeps no tone on the
    /// next open (a missing value is what gets a tone).
    public func setProjectTone(id: UUID, tone: ProjectTone?) throws {
        try database.withStatement("UPDATE projects SET color = ? WHERE id = ?") { statement in
            try database.bind(tone?.rawValue ?? ProjectTone.noneValue, at: 1, to: statement)
            try database.bind(id.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "update project color")
        }
        guard sqlite3_changes(database.handle) == 1 else {
            throw SessionCatalogError.projectNotFound(id)
        }
    }

    /// Conversation count per project (nil key: no project), from one grouped scan.
    public func sessionCounts() throws -> [UUID?: Int] {
        try database.withStatement(
            "SELECT s.project_id, count(*) FROM sessions s WHERE \(Self.notDeleting) GROUP BY s.project_id"
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
}
