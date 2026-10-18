import Foundation

/// The project's CLAUDE.md as the page shows it: read-only, the first part of the file.
struct ProjectInstructions: Equatable, Sendable {
    /// The file's path relative to the project folder.
    let name: String
    let blocks: [MarkdownBlock]
    /// The file's size on disk.
    let byteCount: Int
    /// The file has more than what was read.
    let truncated: Bool
    /// The number of lines when the whole file was read.
    let lineCount: Int?
    let modified: Date?
}

/// Reads `CLAUDE.md` from the project folder (or `.claude/CLAUDE.md`, the other place Claude Code looks), at
/// most `maxBytes` of it, when the project page opens. A link is followed (many projects point CLAUDE.md at
/// AGENTS.md), but only a regular file is read.
enum ProjectInstructionsReader {
    static let maxBytes = 32 * 1024
    static let candidates = ["CLAUDE.md", ".claude/CLAUDE.md"]

    static func read(folder: String) -> ProjectInstructions? {
        for name in candidates {
            let path = (folder as NSString).appendingPathComponent(name)
            if let found = read(path: path, name: name) { return found }
        }
        return nil
    }

    private static func read(path: String, name: String) -> ProjectInstructions? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else { return nil }
        let truncated = data.count > maxBytes
        var text = String(decoding: truncated ? data.prefix(maxBytes) : data, as: UTF8.self)
        if truncated {
            // Cut at a line end, so a block is never split in the middle of a character or a word.
            if let end = text.lastIndex(of: "\n") { text = String(text[..<end]) }
        }
        // The whole file only when nothing was cut: newlines, plus the last line when it has none.
        let lines = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } + (text.isEmpty || text.utf8.last == 0x0A ? 0 : 1)
        return ProjectInstructions(
            name: name, blocks: ChatMarkdown.parse(text), byteCount: Int(info.st_size), truncated: truncated,
            lineCount: truncated ? nil : lines,
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }
}
