import Foundation
import SQLite3

extension SessionCatalog {
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
        case .recentActivity: column = Self.activityExpression; direction = "DESC"; comparison = "<"
        case .creation: column = "s.created_at"; direction = "ASC"; comparison = ">"
        }
        if let cursor {
            conditions.append("(\(column) \(comparison) ? OR (\(column) = ? AND s.id \(comparison) ?))")
            bindings.append((nil, cursor.timestamp))
            bindings.append((nil, cursor.timestamp))
            bindings.append((cursor.id, nil))
        }
        conditions.append(Self.notDeleting)
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT \(Self.sessionColumns) FROM sessions s
            LEFT JOIN projects p ON p.id = s.project_id
            \(whereClause)
            ORDER BY \(column) \(direction), s.id \(direction)
            """
        return try database.withStatement(sql) { statement in
            var index: Int32 = 1
            for (text, number) in bindings {
                if let text { try database.bind(text, at: index, to: statement) }
                else if let number { sqlite3_bind_double(statement, index, number) }
                index += 1
            }
            // No SQL LIMIT: undecodable rows do not count toward the page, so
            // the scan stops once one row beyond the page proves there is more.
            var rows: [CatalogSession] = []
            var skipped = 0
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                if let session = try decodeSessionOrSkip(statement) { rows.append(session) }
                else { skipped += 1 }
                if rows.count > limit { break }
                stepResult = sqlite3_step(statement)
            }
            if stepResult != SQLITE_ROW { try database.requireDone(stepResult, operation: "read session page") }
            guard rows.count > limit else {
                return CatalogPage(sessions: rows, next: nil, skippedRowCount: skipped)
            }
            rows.removeLast()
            let last = rows[rows.count - 1]
            let timestamp = query.order == .recentActivity ? last.lastActivityAt : last.createdAt
            return CatalogPage(
                sessions: rows,
                next: CatalogCursor(timestamp: timestamp.timeIntervalSince1970,
                                    id: last.session.id.uuidString),
                skippedRowCount: skipped
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
                    if let session = try decodeSessionOrSkip(statement) { rows.append(session) }
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
            "SELECT MIN(s.last_used_at) FROM sessions s WHERE s.lifecycle = ? AND \(Self.notDeleting)"
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
}
