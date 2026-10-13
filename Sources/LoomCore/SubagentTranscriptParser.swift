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
    /// A tool's answer: its first line, how many lines it had, and whether it failed.
    case toolResult(firstLine: String, lineCount: Int, isError: Bool)
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

    private let decoder = JSONDecoder()
    let maximumStringBytes: Int

    public init(maximumStringBytes: Int = Self.defaultMaximumStringBytes) {
        self.maximumStringBytes = maximumStringBytes
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
                if let text = block.text, !text.allSatisfy(\.isWhitespace) { entries.append(.text(clipped(text))) }
            case "tool_use":
                let name = clipped(block.name ?? "Tool")
                entries.append(.toolCall(name: name, argument: clipped(Self.argument(tool: name, input: block.input?.strings ?? [:]))))
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
                        firstLine: clipped(Self.firstLine(of: text)), lineCount: Self.lineCount(of: text),
                        isError: block.isError ?? false))
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
        case "Read", "Edit", "MultiEdit", "Write": chosen = first("file_path", "path")
        case "NotebookEdit": chosen = first("notebook_path", "file_path")
        case "Grep", "Glob": chosen = first("pattern")
        case "WebFetch": chosen = first("url")
        case "WebSearch": chosen = first("query")
        case "Agent", "Task": chosen = first("description")
        default:
            // Any other tool: the first short text field. Dictionary order is not the file's, so by name.
            chosen = input.keys.sorted().compactMap { input[$0] }.first { !$0.isEmpty && $0.utf8.count <= 200 }
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

    static func lineCount(of text: String) -> Int {
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A { newlines += 1 }
        if text.isEmpty { return 0 }
        return text.utf8.last == 0x0A ? newlines : newlines + 1
    }

    /// At most `maximumStringBytes` of UTF-8, cut on a character boundary, with an ellipsis when cut.
    func clipped(_ text: String) -> String {
        let utf8 = text.utf8
        guard utf8.count > maximumStringBytes else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: maximumStringBytes)
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

    /// A tool call's input: only its string fields, which are all a main argument is made of.
    private struct ToolInput: Decodable {
        let strings: [String: String]

        init(from decoder: any Decoder) throws {
            var strings: [String: String] = [:]
            if let container = try? decoder.container(keyedBy: AnyKey.self) {
                for key in container.allKeys {
                    if let value = try? container.decode(String.self, forKey: key) { strings[key.stringValue] = value }
                }
            }
            self.strings = strings
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
