import Foundation

/// A warning on one file of the rewind sheet (V21): the file may hold changes Claude did not make, and the rewind restores
/// Claude's tracked copy over them without a word (S8 Q5). The marks warn; the safety is Loom's copy.
public enum RewindFileMark: Equatable, Sendable {
    /// The file was modified more than `RewindOutsideChange.tolerance` after Claude's last edit of it.
    case changedSinceClaude
    /// The file is gone now; the rewind would bring it back.
    case deletedSinceClaude
    /// Claude's last edit of the file was not found inside the scan's bound (or has no time).
    case couldNotCheck

    public var text: String {
        switch self {
        case .changedSinceClaude: "Changed since Claude's last edit"
        case .deletedSinceClaude: "Deleted since Claude's last edit"
        case .couldNotCheck: "Could not check"
        }
    }
}

/// Compares the files a dry run lists with Claude's own edit records (V20's scan of the whole session): a file that was
/// modified after Claude last wrote it was changed outside Claude.
public enum RewindOutsideChange {
    /// The gap between a tool writing the file and its record being timestamped.
    public static let tolerance: TimeInterval = 2

    /// A file as the disk has it now.
    public struct FileState: Equatable, Sendable {
        public var exists: Bool
        public var modified: Date?

        public init(exists: Bool, modified: Date? = nil) {
            self.exists = exists
            self.modified = modified
        }
    }

    /// The marks of `files` (absolute paths, as the dry run lists them); a file with no mark is as Claude left it. Paths
    /// are compared without the `/private` prefix of `/tmp` and `/var`, as the Changes tab does.
    public static func marks(files: [String], scan: EditScanResult, state: (String) -> FileState) -> [String: RewindFileMark] {
        var lastEdits: [String: Date] = [:]
        for file in scan.files {
            if let time = file.lastEdit?.timestamp { lastEdits[EditScan.withoutPrivatePrefix(file.path)] = time }
        }
        var marks: [String: RewindFileMark] = [:]
        for path in files {
            guard let edited = lastEdits[EditScan.withoutPrivatePrefix(path)] else {
                marks[path] = .couldNotCheck
                continue
            }
            let now = state(path)
            if !now.exists {
                marks[path] = .deletedSinceClaude
            } else if let modified = now.modified, modified.timeIntervalSince(edited) > tolerance {
                marks[path] = .changedSinceClaude
            }
        }
        return marks
    }
}
