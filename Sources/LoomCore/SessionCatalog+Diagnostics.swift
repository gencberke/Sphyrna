import Foundation
import SQLite3

extension SessionCatalog {
    /// Row counts and the schema version, for the diagnostics export. Counts only.
    public func diagnosticsCounts() throws -> DiagnosticsSummary.Catalog {
        func count(_ sql: String) throws -> Int { Int(try database.scalarInt64(sql)) }
        return DiagnosticsSummary.Catalog(
            schemaVersion: Int(try database.scalarInt64("PRAGMA user_version")),
            sessions: try count("SELECT count(*) FROM sessions"),
            projects: try count("SELECT count(*) FROM projects"),
            runs: try count("SELECT count(*) FROM runs"),
            openRuns: try count("SELECT count(*) FROM runs WHERE ended_at IS NULL"),
            skippedRows: skippedRowCount,
            pendingDeletions: try count("SELECT count(*) FROM deletions"),
            backups: backupStore.list().count)
    }
}
