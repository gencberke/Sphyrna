import Foundation

/// One line of a diff as drawn: its kind, the line numbers it has on each side, and its text without the prefix.
public struct DiffRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
        /// Git's "\ No newline at end of file".
        case note
    }

    public var kind: Kind
    /// The line's number in the old file; nil for an added line, a note, or a hunk without line numbers.
    public var oldNumber: Int?
    /// The line's number in the new file; nil for a removed line, a note, or a hunk without line numbers.
    public var newNumber: Int?
    public var text: String

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

/// One hunk of a unified diff: Claude's `structuredPatch` entry and a hunk of `git diff` have this shape. `lines`
/// keep their one-character prefix (" " context, "+" added, "-" removed, "\" a note about the previous line).
public struct DiffHunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]
    /// False for lines that have no place in a file's line count (a notebook cell's source): the rows carry no numbers.
    public var isNumbered: Bool

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String], isNumbered: Bool = true) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
        self.isNumbered = isNumbered
    }

    public var added: Int { lines.reduce(0) { $0 + ($1.hasPrefix("+") ? 1 : 0) } }
    public var removed: Int { lines.reduce(0) { $0 + ($1.hasPrefix("-") ? 1 : 0) } }

    /// "@@ -42,6 +42,9 @@", as git writes a hunk's header.
    public var header: String {
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        return "@@ -\(range(oldStart, oldLines)) +\(range(newStart, newLines)) @@"
    }

    /// The rows of the hunk, numbered on each side: a context line has both numbers, an added line the new one, a removed
    /// line the old one.
    public var rows: [DiffRow] {
        var old = oldStart
        var new = newStart
        var rows: [DiffRow] = []
        rows.reserveCapacity(lines.count)
        for line in lines {
            let text = String(line.dropFirst())
            switch line.first {
            case "+":
                rows.append(DiffRow(kind: .added, oldNumber: nil, newNumber: isNumbered ? new : nil, text: text))
                new += 1
            case "-":
                rows.append(DiffRow(kind: .removed, oldNumber: isNumbered ? old : nil, newNumber: nil, text: text))
                old += 1
            case "\\":
                rows.append(DiffRow(kind: .note, oldNumber: nil, newNumber: nil, text: text))
            default:
                rows.append(DiffRow(kind: .context, oldNumber: isNumbered ? old : nil, newNumber: isNumbered ? new : nil,
                                    text: text))
                old += 1
                new += 1
            }
        }
        return rows
    }
}

/// Reads the text `git diff` prints for one file.
public enum UnifiedDiff {
    public struct Parsed: Equatable, Sendable {
        public var hunks: [DiffHunk]
        public var isBinary: Bool
    }

    /// The hunks of one file's diff. The header lines before the first hunk are skipped; a "Binary files … differ" or
    /// "GIT binary patch" line marks a binary file. A hunk ends when its line counts are used up, so a removed line that
    /// starts with "--" is not taken for the next file's header.
    public static func parse(_ text: String) -> Parsed {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var hunks: [DiffHunk] = []
        var isBinary = false
        var index = 0
        while index < all.count {
            let line = all[index]
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
                index += 1
                continue
            }
            guard let header = parseHeader(line) else {
                index += 1
                continue
            }
            index += 1
            var oldLeft = header.oldLines
            var newLeft = header.newLines
            var lines: [String] = []
            while index < all.count {
                let body = all[index]
                if oldLeft <= 0, newLeft <= 0 {
                    // Only a "\ No newline" note can follow the last counted line.
                    guard body.hasPrefix("\\") else { break }
                    lines.append(String(body))
                    index += 1
                    continue
                }
                switch body.first {
                case "+": newLeft -= 1
                case "-": oldLeft -= 1
                case "\\": break
                default:
                    // A context line; git may print a blank one as an empty line.
                    oldLeft -= 1
                    newLeft -= 1
                }
                lines.append(body.isEmpty ? " " : String(body))
                index += 1
            }
            hunks.append(DiffHunk(oldStart: header.oldStart, oldLines: header.oldLines,
                                  newStart: header.newStart, newLines: header.newLines, lines: lines))
        }
        return Parsed(hunks: hunks, isBinary: isBinary && hunks.isEmpty)
    }

    private static func parseHeader(_ line: Substring) -> (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)? {
        guard line.hasPrefix("@@ -") else { return nil }
        let parts = line.dropFirst(3).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+") else { return nil }
        func range(_ text: Substring) -> (Int, Int)? {
            let pair = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = pair.first.flatMap({ Int($0) }) else { return nil }
            if pair.count == 1 { return (start, 1) }
            guard pair.count == 2, let count = Int(pair[1]) else { return nil }
            return (start, count)
        }
        guard let old = range(parts[0]), let new = range(parts[1]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }
}
