import Darwin
import Foundation

/// One thing a subagent's transcript shows (FB4-5). Every string is clipped when the line is parsed, so
/// an entry is small whatever the file holds.
public enum SubagentTranscriptEntry: Equatable, Sendable {
    /// What the parent asked the subagent to do (the first user line).
    case brief(String)
    /// The agent's own words.
    case text(String)
    /// A tool call with its main argument (a command's first line, a path, a pattern, a URL).
    case toolCall(name: String, argument: String)
    /// A tool's answer: its first lines (the view shows three and keeps the rest behind a click), how many lines it had, and
    /// whether it failed.
    case toolResult(lines: [String], lineCount: Int, isError: Bool)
    /// A line of the file over the reader's bound: it is named instead of dropped (FB6-18).
    case tooLong
    /// "Thought for Ns": Claude writes only the duration, never the thinking text.
    case thought(milliseconds: Int?)
}

/// Turns one line of a subagent transcript into zero or more entries. The format is private to Claude Code
/// and drifts, so anything unexpected yields nothing. Of the three line types (`assistant`, `user`,
/// `attachment`) the attachments are skipped on a byte test before any decoding, and the bulky duplicates
/// of tool data (`toolUseResult`, `wireToolInputs`, `serverClassifierContext`, `wireIngestContext`) are
/// never decoded: the wire types below do not name them.
public struct SubagentTranscriptParser: Sendable {
    public static let defaultMaximumStringBytes = 4 * 1024
    /// The agent's own words are cut later than a tool's input or output, so a final report is whole (FB6-18).
    public static let defaultMaximumTextBytes = 64 * 1024
    /// How many lines of a tool result an entry keeps; the rest of the 4 KiB is behind a click.
    public static let maximumResultLines = 40

    private let decoder = JSONDecoder()
    let maximumStringBytes: Int
    let maximumTextBytes: Int

    public init(maximumStringBytes: Int = Self.defaultMaximumStringBytes,
                maximumTextBytes: Int = Self.defaultMaximumTextBytes) {
        self.maximumStringBytes = maximumStringBytes
        self.maximumTextBytes = max(maximumTextBytes, maximumStringBytes)
    }

    public func parse(_ line: UnsafeRawBufferPointer) -> [SubagentTranscriptEntry] {
        guard let base = line.baseAddress, line.count > 0 else { return [] }
        guard !Self.contains(base, line.count, #""type":"attachment""#) else { return [] }
        guard let wire = try? decoder.decode(Line.self, from: Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none))
        else { return [] }
        switch wire.type {
        case "assistant": return assistantEntries(wire)
        case "user": return userEntries(wire)
        default: return []
        }
    }

    public func parse(_ line: String) -> [SubagentTranscriptEntry] {
        var copy = line
        return copy.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    // MARK: Entries

    private func assistantEntries(_ wire: Line) -> [SubagentTranscriptEntry] {
        guard case let .blocks(blocks)? = wire.message?.content else { return [] }
        var entries: [SubagentTranscriptEntry] = []
        for block in blocks.compactMap(\.value) {
            switch block.type {
            case "text":
                if let text = block.text, !text.allSatisfy(\.isWhitespace) { entries.append(.text(clipped(text, to: maximumTextBytes))) }
            case "tool_use":
                let name = clipped(block.name ?? "Tool")
                entries.append(.toolCall(name: name, argument: clipped(Self.argument(tool: name, input: block.input?.fields ?? [:]))))
            case "thinking":
                entries.append(.thought(milliseconds: wire.thinkingDurationMs.map { Int($0.rounded()) }))
            default: break
            }
        }
        return entries
    }

    private func userEntries(_ wire: Line) -> [SubagentTranscriptEntry] {
        switch wire.message?.content {
        case let .text(text)?:
            return text.allSatisfy(\.isWhitespace) ? [] : [.brief(clipped(text))]
        case let .blocks(blocks)?:
            var entries: [SubagentTranscriptEntry] = []
            for block in blocks.compactMap(\.value) {
                switch block.type {
                case "tool_result":
                    let text = block.content?.text ?? ""
                    entries.append(.toolResult(
                        lines: Self.leadingLines(of: clipped(text), limit: Self.maximumResultLines),
                        lineCount: Self.lineCount(of: text), isError: block.isError ?? false))
                case "text":
                    if let text = block.text, !text.allSatisfy(\.isWhitespace) { entries.append(.brief(clipped(text))) }
                default: break
                }
            }
            return entries
        case nil: return []
        }
    }

    // MARK: Text rules

    /// The main argument of a tool call: the one thing that says what it does.
    static func argument(tool: String, input: [String: String]) -> String {
        func first(_ keys: String...) -> String? { keys.lazy.compactMap { input[$0] }.first { !$0.isEmpty } }
        let chosen: String?
        switch tool {
        case "Bash": chosen = first("command")
        case "Read":
            // The file and, when the call asked for a part, its range.
            if let path = first("file_path", "path"), let offset = input["offset"].flatMap(Int.init), offset > 0 {
                let end = input["limit"].flatMap(Int.init).map { offset + max($0, 1) - 1 }
                chosen = path + " (lines " + String(offset) + (end.map { "–" + String($0) } ?? "–") + ")"
            } else {
                chosen = first("file_path", "path")
            }
        case "Edit", "MultiEdit", "Write": chosen = first("file_path", "path")
        case "NotebookEdit": chosen = first("notebook_path", "file_path")
        case "Grep", "Glob": chosen = first("pattern")
        case "WebFetch": chosen = first("url")
        case "WebSearch": chosen = first("query")
        case "Agent", "Task": chosen = first("description")
        default:
            // Any other tool: the first short text field. Dictionary order is not the file's, so by name.
            chosen = input.keys.sorted().compactMap { input[$0] }.first { !$0.isEmpty && $0.utf8.count <= 200 && Int($0) == nil }
        }
        return firstLine(of: chosen ?? "")
    }

    static func firstLine(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// The first `limit` non-blank-leading lines of `text`, each without trailing spaces; none for an empty text.
    static func leadingLines(of text: String, limit: Int) -> [String] {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.replacingOccurrences(of: "\r", with: "")
            if lines.isEmpty && trimmed.allSatisfy(\.isWhitespace) { continue }
            lines.append(String(trimmed.reversed().drop { $0 == " " || $0 == "\t" }.reversed()))
            if lines.count == limit { break }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    static func lineCount(of text: String) -> Int {
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A { newlines += 1 }
        if text.isEmpty { return 0 }
        return text.utf8.last == 0x0A ? newlines : newlines + 1
    }

    /// At most `maximumStringBytes` of UTF-8, cut on a character boundary, with an ellipsis when cut.
    func clipped(_ text: String) -> String { clipped(text, to: maximumStringBytes) }

    func clipped(_ text: String, to limit: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: limit)
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 { end = utf8.index(before: end) }
        return String(text[..<end]) + "…"
    }

    private static func contains(_ base: UnsafeRawPointer, _ count: Int, _ needle: StaticString) -> Bool {
        memmem(base, count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    // MARK: Wire shapes

    private struct Line: Decodable {
        let type: String?
        let message: Message?
        let thinkingDurationMs: Double?
    }

    private struct Message: Decodable {
        let content: Content?
    }

    /// `message.content` is a string (the brief) or a list of blocks.
    private enum Content: Decodable {
        case text(String)
        case blocks([Lossy<Block>])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([Lossy<Block>].self))
            }
        }
    }

    /// A block that cannot be read is dropped; it never spoils the line.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Block: Decodable {
        let type: String?
        let text: String?
        let name: String?
        let input: ToolInput?
        let content: ResultContent?
        let isError: Bool?

        enum CodingKeys: String, CodingKey { case type, text, name, input, content, isError = "is_error" }
    }

    /// A tool call's input: its string fields, which a main argument is made of, and its whole numbers (a Read's `offset` and
    /// `limit`), as text.
    private struct ToolInput: Decodable {
        let fields: [String: String]

        init(from decoder: any Decoder) throws {
            var fields: [String: String] = [:]
            if let container = try? decoder.container(keyedBy: AnyKey.self) {
                for key in container.allKeys {
                    if let value = try? container.decode(String.self, forKey: key) {
                        fields[key.stringValue] = value
                    } else if let number = try? container.decode(Int.self, forKey: key) {
                        fields[key.stringValue] = String(number)
                    }
                }
            }
            self.fields = fields
        }
    }

    /// A tool result's content: a string, or a list of parts of which the text ones count.
    private struct ResultContent: Decodable {
        let text: String

        private struct Part: Decodable { let type: String?; let text: String? }

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.singleValueContainer() else { text = ""; return }
            if let text = try? container.decode(String.self) {
                self.text = text
            } else if let parts = try? container.decode([Lossy<Part>].self) {
                text = parts.compactMap(\.value).compactMap { $0.type == "text" || $0.type == nil ? $0.text : nil }
                    .joined(separator: "\n")
            } else {
                text = ""
            }
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
