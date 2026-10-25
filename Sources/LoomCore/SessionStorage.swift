import Foundation

/// One of Sphyrna's sessions as Settings → Sessions → Storage lists it: what deleting it would remove from Claude's profile
/// (the deletion allowlist's dry run, `ClaudeDataInventory`), so the size shown is the size a Delete frees.
public struct SessionStorageRow: Sendable, Equatable, Identifiable {
    public var id: UUID { record.session.id }
    public let record: CatalogSession
    /// Nil when the dry run could not be made for it.
    public let byteCount: Int64?
    public let fileCount: Int?
    /// A live run holds it: listed, never deleted from here.
    public let isRunning: Bool

    public init(record: CatalogSession, byteCount: Int64?, fileCount: Int?, isRunning: Bool) {
        self.record = record
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.isRunning = isRunning
    }
}

/// Settings → Sessions → Storage: every deletable session, largest first, and the profile's whole `projects` folder for
/// context (transcripts of sessions started outside Sphyrna included).
public struct SessionStorageReport: Sendable, Equatable {
    public let generatedAt: Date
    public let rows: [SessionStorageRow]
    /// The Claude profile the sizes are in; nil when no session could be measured.
    public let configDirectory: String?
    /// Bytes of `<profile>/projects`; nil when it is absent or cannot be opened safely.
    public let projectsFolderBytes: Int64?

    public init(generatedAt: Date, rows: [SessionStorageRow], configDirectory: String?, projectsFolderBytes: Int64?) {
        self.generatedAt = generatedAt
        // Largest first; among equal sizes the most recently used first.
        self.rows = rows.sorted { ($0.byteCount ?? -1, $0.record.lastUsedAt) > ($1.byteCount ?? -1, $1.record.lastUsedAt) }
        self.configDirectory = configDirectory
        self.projectsFolderBytes = projectsFolderBytes
    }

    public var totalBytes: Int64 { rows.reduce(0) { $0 + ($1.byteCount ?? 0) } }
}
