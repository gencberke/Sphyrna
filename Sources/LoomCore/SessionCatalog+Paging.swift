import Foundation
import SQLite3

/// A search read for every list at once (`SessionCatalog.searchSessions`).
public struct CatalogSearchResult: Sendable {
    /// Matches, newest first in the requested order.
    public let sessions: [CatalogSession]
    /// Activity order: where the next page of the whole result starts; nil when it is complete.
    public let next: CatalogCursor?
    /// Creation order: where each project's (nil: no project) next page starts. Absent when its matches are complete.
    public let nextByProject: [UUID?: CatalogCursor]
}

extension CatalogCursor {
    /// Whether the session sorts at or before this cursor in activity order (newest first, ties by id
    /// descending), that is inside the rows a list loaded down to the cursor holds.
    public func coversActivity(of session: CatalogSession) -> Bool {
        let time = session.lastActivityAt.timeIntervalSince1970
        return time > timestamp || (time == timestamp && session.session.id.uuidString >= id)
    }
}

extension SessionCatalog {
    // MARK: Paged queries

    /// One keyset page (at most `CatalogQuery.maxPageSize` rows). Search,
    /// order and scope are part of the SQL; nothing is filtered afterwards.
    public func sessionPage(_ query: CatalogQuery, after cursor: CatalogCursor? = nil) throws -> CatalogPage {
        try readPage(query, after: cursor, limit: min(max(1, query.limit), CatalogQuery.maxPageSize))
    }

    /// The scope and search conditions of a query with their bindings, shared by every list read.
    private func conditions(for query: CatalogQuery) -> (sql: [String], bindings: [(String?, Double?)]) {
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
        return (conditions, bindings)
    }

    private func readPage(_ query: CatalogQuery, after cursor: CatalogCursor?, limit: Int,
                          cancellable: Bool = false) throws -> CatalogPage {
        var (conditions, bindings) = conditions(for: query)
        let column: String
        let direction: String
        let comparison: String
        switch query.order {
        case .recentActivity: column = Self.activityExpression; direction = "DESC"; comparison = "<"
        case .creation: column = "s.created_at"; direction = "DESC"; comparison = "<"
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
            var steps = 0
            while stepResult == SQLITE_ROW {
                if let session = try decodeSessionOrSkip(statement) { rows.append(session) }
                else { skipped += 1 }
                if rows.count > limit { break }
                steps += 1
                if cancellable, steps % Self.cancellationCheckInterval == 0 { try Task.checkCancellation() }
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

    // MARK: Search over the whole catalog

    /// Rows between two looks at the caller's cancellation while a result is read.
    private static let cancellationCheckInterval = 32
    /// The most rows one search result holds, whatever the page size (a broad term over a huge catalog).
    public static let maxSearchResultRows = 5_000

    /// One query for a settled search. The result is read for every list at once and grouped by the caller.
    /// - `.recentActivity`: the first `groupLimit` matches of the whole catalog in activity order, with the
    ///   cursor of the next page, exactly what the activity list's own first page holds.
    /// - `.creation`: the first `groupLimit` matches of *each* project (and of the sessions without a
    ///   project) in creation order, merged newest first, with each group's cursor where more exist. Every
    ///   project with a match shows up, however many matches the others have.
    /// A caller whose task is cancelled gets `CancellationError` instead of the scan: a newer keystroke
    /// does not wait for an older one.
    public func searchSessions(search: String, order: CatalogOrder, groupLimit: Int,
                               rowCap: Int = SessionCatalog.maxSearchResultRows) throws -> CatalogSearchResult {
        try Task.checkCancellation()
        let limit = min(max(1, groupLimit), Self.maxSearchResultRows)
        switch order {
        case .recentActivity:
            let page = try readPage(CatalogQuery(scope: .all, order: .recentActivity, search: search),
                                    after: nil, limit: limit, cancellable: true)
            return CatalogSearchResult(sessions: page.sessions, next: page.next, nextByProject: [:])
        case .creation:
            return try searchByProject(search: search, limit: limit, rowCap: max(1, rowCap))
        }
    }

    private func searchByProject(search: String, limit: Int, rowCap: Int) throws -> CatalogSearchResult {
        var (conditions, bindings) = conditions(for: CatalogQuery(scope: .all, order: .creation, search: search))
        conditions.append(Self.notDeleting)
        let sql = """
            SELECT * FROM (
                SELECT \(Self.sessionColumns),
                       ROW_NUMBER() OVER (PARTITION BY s.project_id ORDER BY s.created_at DESC, s.id DESC) AS loom_rank
                FROM sessions s
                LEFT JOIN projects p ON p.id = s.project_id
                WHERE \(conditions.joined(separator: " AND "))
            ) WHERE loom_rank <= ? ORDER BY created_at DESC, id DESC LIMIT ?
            """
        bindings.append((nil, Double(limit + 1))) // one row beyond a group proves it has more
        return try database.withStatement(sql) { statement in
            var index: Int32 = 1
            for (text, number) in bindings {
                if let text { try database.bind(text, at: index, to: statement) }
                else if let number { sqlite3_bind_double(statement, index, number) }
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(rowCap))
            var rows: [CatalogSession] = []
            var counts: [UUID?: Int] = [:]
            var more: Set<UUID?> = []
            var stepResult = sqlite3_step(statement)
            var steps = 0
            while stepResult == SQLITE_ROW {
                steps += 1
                if steps % Self.cancellationCheckInterval == 0 { try Task.checkCancellation() }
                if let session = try decodeSessionOrSkip(statement) {
                    let group = session.projectID
                    if counts[group, default: 0] < limit {
                        counts[group, default: 0] += 1
                        rows.append(session)
                    } else {
                        more.insert(group)
                    }
                }
                stepResult = sqlite3_step(statement)
            }
            try database.requireDone(stepResult, operation: "search sessions")
            // A result cut at the overall cap may have left out rows of any group: each can have more.
            let capped = steps >= rowCap
            var next: [UUID?: CatalogCursor] = [:]
            for group in capped ? Set(counts.keys) : more {
                guard let last = rows.last(where: { $0.projectID == group }) else { continue }
                next[group] = CatalogCursor(timestamp: last.createdAt.timeIntervalSince1970,
                                            id: last.session.id.uuidString)
            }
            return CatalogSearchResult(sessions: rows, next: nil, nextByProject: next)
        }
    }

    /// One session as the lists read it: nil when it does not exist or is being deleted (a list never shows it).
    public func listedSession(id: UUID) throws -> CatalogSession? {
        try database.withStatement("""
            SELECT \(Self.sessionColumns) FROM sessions s WHERE s.id = ? AND \(Self.notDeleting) LIMIT 1
            """) { statement in
            try database.bind(id.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeSession(statement)
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

    static func escapeLike(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
