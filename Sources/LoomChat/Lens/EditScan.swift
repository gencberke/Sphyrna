import Foundation
import LoomCore

/// A file a turn changed, with its line counts: the changed-files card's line, shortened to the session's folder.
public struct ChangedFile: Equatable, Sendable {
    public var path: String
    public var added: Int
    public var removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

/// One successful edit-tool call of the main session, read from its transcript: the call (`Write`, `Edit`, `MultiEdit` or
/// `NotebookEdit`), and the hunks of its result's `structuredPatch` (a created file's `content` is one added hunk).
public struct EditRecord: Equatable, Sendable {
    public var toolName: String
    public var toolUseID: String
    /// When the result was written (the call's own record when the result has none).
    public var timestamp: Date?
    /// The file, as the tool named it: an absolute path.
    public var path: String
    public var hunks: [DiffHunk]
    /// A Write that made the file.
    public var isCreate: Bool

    public var added: Int { hunks.reduce(0) { $0 + $1.added } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.removed } }

    public init(toolName: String, toolUseID: String, timestamp: Date?, path: String, hunks: [DiffHunk], isCreate: Bool) {
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.timestamp = timestamp
        self.path = path
        self.hunks = hunks
        self.isCreate = isCreate
    }
}

/// A file with every edit the scan found, oldest first.
public struct EditedFile: Equatable, Sendable {
    public var path: String
    public var edits: [EditRecord]

    public var added: Int { edits.reduce(0) { $0 + $1.added } }
    public var removed: Int { edits.reduce(0) { $0 + $1.removed } }
    /// The hunks of every edit, in the order Claude made them.
    public var hunks: [DiffHunk] { edits.flatMap(\.hunks) }
    /// Claude's last edit of the file (what a rewind of the file starts from).
    public var lastEdit: EditRecord? { edits.last }
}

public struct EditScanResult: Equatable, Sendable {
    /// In the order of each file's first edit.
    public var files: [EditedFile]
    /// The byte bound ended the read before the scope was complete: older edits were not read.
    public var truncated: Bool
    /// How far back the read went.
    public var bytesCovered: Int

    public static let empty = EditScanResult(files: [], truncated: false, bytesCovered: 0)
}

/// Claude's own file edits, read from the main session's transcript (V20). A read goes backward from the end of the file
/// in pages, through `ClaudeTranscriptReader`, and ends at the newest human prompt (`lastTurn`), at the start of the file
/// (`wholeSession`) or at the byte bound, whichever comes first. The live model keeps counts only, so it is not a source of
/// hunks. Edits made by shell commands or by subagents (their own transcripts) are not here: git sees them.
public enum EditScan {
    public enum Scope: Sendable, Equatable {
        /// Everything after the newest human prompt (typed, or sent by Loom), up to now.
        case lastTurn
        case wholeSession
    }

    /// 64 MiB of transcript.
    public static let defaultByteLimit = 64 * 1024 * 1024

    public static func isEditTool(_ name: String) -> Bool { ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name) }

    /// Reads the edits of `scope` from the end of the transcript backward, at most `byteLimit` bytes of it.
    public static func scan(file: ClaudeTranscriptFile, scope: Scope, byteLimit: Int = defaultByteLimit,
                            pageBytes: Int = ClaudeTranscriptReader.defaultPageBytes) -> EditScanResult {
        guard let reader = ClaudeTranscriptReader(file: file) else { return .empty }
        defer { reader.close() }
        let end = reader.historyOffset
        var covered = 0
        var edits: [EditRecord] = []
        var results: [String: PendingResult] = [:]
        var reachedStart = end == 0
        var boundary = false
        while !boundary, covered < byteLimit, reader.historyOffset > 0 {
            let page = reader.readBackward(pageBytes: max(1, min(pageBytes, byteLimit - covered)))
            covered = Int(end - page.startOffset)
            reachedStart = page.reachedStart
            for record in page.records.reversed() {
                guard let bytes = record.bytes, mentionsTools(bytes, scope: scope),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { continue }
                switch StreamMessage(json: value) {
                case let .user(message):
                    guard !message.isSidechain, message.parentToolUseID == nil else { continue }
                    if message.hasToolResult {
                        let blocks = message.content.compactMap { block -> ToolResultBlock? in
                            if case let .toolResult(result) = block { result } else { nil }
                        }
                        // Only the result of one successful call that has an edit's shape is kept (a Read's result
                        // holds a whole file); a call whose result was not kept is skipped when its record comes.
                        guard blocks.count == 1, let id = blocks[0].toolUseID, !blocks[0].isError,
                              let structured = message.toolUseResult, hasEditShape(structured) else { continue }
                        results[id] = PendingResult(structured: structured, timestamp: message.timestamp)
                    } else if scope == .lastTurn, TranscriptLens.isHumanPrompt(message, source: .sessionTranscript) {
                        boundary = true
                    }
                case let .assistant(message):
                    guard !message.isSidechain, message.parentToolUseID == nil else { continue }
                    for case let .toolUse(call) in message.content where isEditTool(call.name) {
                        guard let result = results.removeValue(forKey: call.id),
                              let edit = makeRecord(call: call, result: result, fallbackTime: message.timestamp) else { continue }
                        edits.append(edit)
                    }
                default:
                    break
                }
                if boundary { break }
            }
        }
        // The newest edit was found first; the files are listed in the order of their first edit.
        return EditScanResult(files: files(from: edits.reversed()), truncated: !boundary && !reachedStart, bytesCovered: covered)
    }

    /// A cheap test before a line is decoded: only a line that names a tool call or result, or (for the last turn) a user
    /// record can matter.
    private static func mentionsTools(_ bytes: Data, scope: Scope) -> Bool {
        func mentions(_ needle: StaticString) -> Bool {
            bytes.withUnsafeBytes { buffer in
                memmem(buffer.baseAddress, buffer.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
            }
        }
        return mentions("\"tool_use") || (scope == .lastTurn && mentions("\"user\""))
    }

    private struct PendingResult {
        var structured: JSONValue
        var timestamp: Date?
    }

    private static func hasEditShape(_ result: JSONValue) -> Bool {
        result.object != nil && (result["structuredPatch"] != nil || result["type"]?.string == "create" || result["edit_mode"] != nil)
    }

    /// The edit a successful call made, or nil when the call failed or its result has a shape this reader does not know.
    private static func makeRecord(call: ToolUseBlock, result: PendingResult, fallbackTime: Date?) -> EditRecord? {
        let structured = result.structured
        guard let path = [call.input["file_path"], call.input["notebook_path"], structured["filePath"], structured["notebook_path"]]
            .lazy.compactMap({ $0?.string }).first(where: { $0.hasPrefix("/") }) else { return nil }
        var hunks: [DiffHunk] = []
        var isCreate = false
        if call.name == "NotebookEdit" {
            // A notebook edit has no patch: the cell's new source is shown as added lines, without line numbers.
            guard (structured["error"]?.string ?? "").isEmpty else { return nil }
            if structured["edit_mode"]?.string != "delete",
               let source = structured["new_source"]?.string ?? call.input["new_source"]?.string {
                let lines = splitLines(source)
                if !lines.isEmpty {
                    hunks = [DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count,
                                      lines: lines.map { "+" + $0 }, isNumbered: false)]
                }
            }
        } else if structured["type"]?.string == "create", let content = structured["content"]?.string {
            isCreate = true
            let lines = splitLines(content)
            if !lines.isEmpty {
                hunks = [DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count, lines: lines.map { "+" + $0 })]
            }
        } else if let patch = structured["structuredPatch"]?.array {
            for item in patch {
                guard let hunk = hunk(from: item) else { return nil }
                hunks.append(hunk)
            }
        } else {
            return nil
        }
        return EditRecord(toolName: call.name, toolUseID: call.id, timestamp: result.timestamp ?? fallbackTime, path: path,
                          hunks: hunks, isCreate: isCreate)
    }

    private static func hunk(from json: JSONValue) -> DiffHunk? {
        guard let oldStart = json["oldStart"]?.int, let oldLines = json["oldLines"]?.int,
              let newStart = json["newStart"]?.int, let newLines = json["newLines"]?.int,
              let items = json["lines"]?.array else { return nil }
        var lines: [String] = []
        for item in items {
            guard let line = item.string else { return nil }
            lines.append(line)
        }
        return DiffHunk(oldStart: oldStart, oldLines: oldLines, newStart: newStart, newLines: newLines, lines: lines)
    }

    /// The lines of a text; an empty text has none, and a final newline does not start another.
    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The files of some edits (oldest first), in the order of each file's first edit.
    public static func files(from edits: some Sequence<EditRecord>) -> [EditedFile] {
        var order: [String] = []
        var byPath: [String: EditedFile] = [:]
        for edit in edits {
            if byPath[edit.path] == nil {
                order.append(edit.path)
                byPath[edit.path] = EditedFile(path: edit.path, edits: [])
            }
            byPath[edit.path]?.edits.append(edit)
        }
        return order.compactMap { byPath[$0] }
    }

    // MARK: The changed-files card

    /// The files the live stream's tools changed, with counts from the edit records, in first-edit order. The card under a
    /// turn's answer shows it; paths are shortened to the session's folder.
    public static func changedFiles(in calls: [ToolCall], workingDirectory: String?) -> [ChangedFile] {
        var order: [String] = []
        var totals: [String: (Int, Int)] = [:]
        for call in calls where isEditTool(call.name) && call.status == .succeeded {
            guard let raw = call.input["file_path"]?.string ?? call.input["notebook_path"]?.string else { continue }
            let path = shorten(raw, workingDirectory: workingDirectory)
            if totals[path] == nil { order.append(path) }
            let current = totals[path] ?? (0, 0)
            totals[path] = (current.0 + (call.changes?.added ?? 0), current.1 + (call.changes?.removed ?? 0))
        }
        return order.map { ChangedFile(path: $0, added: totals[$0]?.0 ?? 0, removed: totals[$0]?.1 ?? 0) }
    }

    /// `/private/tmp`, `/private/var` and `/private/etc` are the same places as `/tmp`, `/var` and `/etc`: a session's
    /// folder and a tool's path may spell one of them either way. Pure text, no file access.
    public static func withoutPrivatePrefix(_ path: String) -> String {
        for root in ["/private/tmp", "/private/var", "/private/etc"] where path == root || path.hasPrefix(root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// A path as the user reads it: relative to the session's folder, "~/" below the home folder, else as it is.
    public static func shorten(_ path: String, workingDirectory: String?) -> String {
        if let cwd = workingDirectory, !cwd.isEmpty {
            for (path, cwd) in [(path, cwd), (withoutPrivatePrefix(path), withoutPrivatePrefix(cwd))] {
                let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
                if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            }
        }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
