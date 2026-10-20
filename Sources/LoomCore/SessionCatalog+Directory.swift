import Foundation
import SQLite3

/// One row of the session directory's read: the catalog record and the name of its project.
public struct CatalogDirectoryRow: Equatable, Sendable {
    public let record: CatalogSession
    /// The project's name; nil for a session without a project.
    public let projectName: String?
}

extension SessionCatalog {
    /// The sessions the directory lists, newest activity first, in one bounded query: the listed predicate (no side chat,
    /// nothing being deleted), no synthetic session, the project's name joined in. `project` limits the read to one project,
    /// `excluding` leaves sessions out. At most `limit` rows (rows the catalog cannot decode do not count).
    public func directoryRows(project: UUID?, excluding: Set<UUID>, limit: Int) throws -> [CatalogDirectoryRow] {
        guard limit > 0 else { return [] }
        var conditions = [Self.listed, "s.provider <> '\(ManagedSession.Provider.synthetic.rawValue)'"]
        var bindings: [String] = []
        if let project {
            conditions.append("s.project_id = ?")
            bindings.append(project.uuidString)
        }
        if !excluding.isEmpty {
            conditions.append("s.id NOT IN (\(Array(repeating: "?", count: excluding.count).joined(separator: ",")))")
            bindings += excluding.map(\.uuidString)
        }
        let sql = """
            SELECT \(Self.sessionColumns), p.name FROM sessions s
            LEFT JOIN projects p ON p.id = s.project_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(Self.activityExpression) DESC, s.id DESC
            """
        return try database.withStatement(sql) { statement in
            for (offset, value) in bindings.enumerated() {
                try database.bind(value, at: Int32(offset + 1), to: statement)
            }
            // No SQL LIMIT, as the paged reads: undecodable rows do not count toward the limit.
            var rows: [CatalogDirectoryRow] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                if let record = try decodeSessionOrSkip(statement) {
                    rows.append(CatalogDirectoryRow(
                        record: record,
                        projectName: database.optionalText(statement, column: Self.sessionColumnCount)))
                    if rows.count >= limit { return rows }
                }
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "read directory sessions")
            return rows
        }
    }
}
