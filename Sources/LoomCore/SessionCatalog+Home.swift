import Foundation
import SQLite3

/// A session whose latest run was ended by Quit (`ManagedRunEndReason.applicationQuit`): what Home's
/// Continue list offers to resume.
public struct CatalogQuitRun: Equatable, Sendable {
    public let session: CatalogSession
    public let runID: UUID
    /// When the run was last known to be doing something: its end, or the session's last real use when that
    /// was earlier (never before the run began). A run an earlier Loom left open is closed at the next launch,
    /// so its recorded end says when Loom came back, not when the run stopped; the session's last use is the
    /// closest the catalog holds.
    public let endedAt: Date

    public init(session: CatalogSession, runID: UUID, endedAt: Date) {
        self.session = session
        self.runID = runID
        self.endedAt = endedAt
    }
}

/// The reads behind Home (V05). Each is one bounded query over what the catalog already records; nothing
/// is written and no schema changes, so a catalog an older build wrote reads the same way.
extension SessionCatalog {
    /// The sessions whose latest run was ended by Quit, newest end first.
    ///
    /// The end reason is `runs.end_reason`, written by `finishRun` since schema 1: `requested` for the
    /// user's Stop, `idle` for an idle stop, `processExited` for a run that ended by itself and
    /// `applicationQuit` for Loom's Quit. A run an earlier Loom left open (a crash, a Force Quit) is
    /// closed as `applicationQuit` at the next launch (`closeAbandonedRuns`), so those count too: Quit and
    /// crash are one list, as the concept has it.
    ///
    /// A session appears while no later run of it exists: resuming it (a new run), or any later stop,
    /// takes it off. The run is attributed to the session the run served at its end (the link that was
    /// never closed), so a run that moved to another session in-TUI (`/resume`) counts for the last one.
    /// A session being deleted never appears.
    ///
    /// The time of a run is `runLastActive`, so a crash found days later reads as the day it happened, and
    /// the window and the order follow it.
    /// - Parameters:
    ///   - since: runs last active before this are not offered any more.
    ///   - limit: at most this many sessions (at least one).
    public func sessionsEndedByQuit(since: Date, limit: Int) throws -> [CatalogQuitRun] {
        try database.withStatement("""
            SELECT \(Self.sessionColumns), \(Self.runLastActive), r.id
            FROM runs r
            JOIN run_sessions l ON l.run_id = r.id AND l.unlinked_at IS NULL
            JOIN sessions s ON s.id = l.session_id
            WHERE r.end_reason = ? AND r.ended_at IS NOT NULL AND \(Self.runLastActive) >= ?
              AND \(Self.notDeleting)
              AND NOT EXISTS (
                  SELECT 1 FROM run_sessions later_link
                  JOIN runs later ON later.id = later_link.run_id
                  WHERE later_link.session_id = s.id AND later.id != r.id
                    AND (later.started_at > r.started_at
                         OR (later.started_at = r.started_at AND later.id > r.id)))
            ORDER BY \(Self.runLastActive) DESC, s.id DESC
            """) { statement in
            try database.bind(ManagedRunEndReason.applicationQuit.rawValue, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            let cap = max(1, limit)
            var result: [CatalogQuitRun] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW, result.count < cap {
                // An undecodable row is skipped and counted, like every other list read.
                if let session = try decodeSessionOrSkip(statement),
                   let runID = UUID(uuidString: try database.text(statement, column: Self.quitRunIDColumn)) {
                    result.append(CatalogQuitRun(
                        session: session, runID: runID,
                        endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, Self.quitRunEndedColumn))))
                }
                stepResult = sqlite3_step(statement)
            }
            if stepResult != SQLITE_ROW { try database.requireDone(stepResult, operation: "read sessions ended by quit") }
            return result
        }
    }

    /// The end of a run as Home tells it: the recorded end, or the session's last use when that is earlier,
    /// but not before the run began. No schema change: both columns exist since schema 1.
    private static let runLastActive = "MIN(r.ended_at, MAX(\(activityExpression), r.started_at))"

    /// The columns after `sessionColumns` in `sessionsEndedByQuit`'s rows.
    private static let quitRunEndedColumn: Int32 = 15
    private static let quitRunIDColumn: Int32 = 16

    /// How many sessions were really used since `date` (start, prompt, finished turn): Home's "Today".
    public func sessionCount(activeSince date: Date) throws -> Int {
        try database.withStatement("""
            SELECT count(*) FROM sessions s WHERE \(Self.activityExpression) >= ? AND \(Self.notDeleting)
            """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SessionCatalogError.invalidRow("session count returned no row")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// The project of the most recently used session that has one: where Home's start box begins.
    public func lastUsedProjectID() throws -> UUID? {
        try database.withStatement("""
            SELECT s.project_id FROM sessions s JOIN projects p ON p.id = s.project_id
            WHERE \(Self.notDeleting)
            ORDER BY \(Self.activityExpression) DESC, s.id DESC LIMIT 1
            """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return database.optionalText(statement, column: 0).flatMap(UUID.init(uuidString:))
        }
    }
}
