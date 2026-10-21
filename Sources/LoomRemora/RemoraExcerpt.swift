import Darwin
import Foundation
import LoomChat
import LoomCore

/// The tail of one Claude session, as a pack carries it: the last turns' user and assistant text, each tool call cut to
/// one line, and the files the session touched. Everything here is data written by other people and programs.
struct RemoraExcerpt: Equatable, Sendable {
    /// Chronological. One entry is one user prompt, one piece of assistant text or one tool call.
    var entries: [String]
    /// Files edited or written in the part read, newest first.
    var filesTouched: [String]
    /// The session's first real prompt, when the tail does not reach it.
    var firstPrompt: String?
    /// The excerpt starts at the first line of the transcript (nothing earlier exists).
    var startsAtBeginning: Bool

    var isEmpty: Bool { entries.isEmpty }

    /// The newest entries that fit in `bytes`, the oldest of them cut to the room that is left (when at least 120 bytes
    /// are); whether older ones were left out.
    func tail(withinBytes bytes: Int) -> (entries: [String], cut: Bool) {
        var kept: [String] = []
        var used = 0
        var index = entries.count
        while index > 0 {
            let entry = entries[index - 1]
            let size = entry.utf8.count + 1
            if used + size <= bytes {
                kept.append(entry)
                used += size
                index -= 1
                continue
            }
            let room = bytes - used
            if kept.isEmpty || room >= 120 { kept.append(clip(entry, toBytes: max(16, room - 1))) ; index -= 1 }
            break
        }
        return (kept.reversed(), index > 0 || !startsAtBeginning)
    }
}

/// Reads an excerpt off a transcript file: bounded backward pages from the end, never the whole file, no line over
/// the cap, and a bounded head read for the first prompt (spike S10: the first `user` record with a `promptId` and a
/// text block, within the first 64 KiB). Runs off the main actor (the caller is `@concurrent`).
enum RemoraTranscriptReading {
    static let pageBytes = 128 * 1024
    static let maxPages = 6
    static let maxLineBytes = 256 * 1024
    static let headBytes = 64 * 1024
    /// Text kept per session, before the pack's budget shortens it further.
    static let textBytes = 6 * 1024

    static let promptBytes = 1_200
    static let answerBytes = 1_500
    static let callBytes = 160
    static let firstPromptBytes = 400
    static let maxFiles = 12

    /// Nil when the file cannot be opened. A readable file with no usable turns is an empty excerpt.
    static func read(_ file: ClaudeTranscriptFile, textBytes: Int = textBytes) -> RemoraExcerpt? {
        guard let reader = ClaudeTranscriptReader(file: file) else { return nil }
        defer { reader.close() }
        var newestFirst: [String] = []
        var files: [String] = []
        var used = 0
        var full = false
        var reachedStart = false
        pages: for _ in 0..<maxPages {
            let page = reader.readBackward(pageBytes: pageBytes, maximumLineBytes: maxLineBytes)
            for record in page.records.reversed() {
                guard let bytes = record.bytes else { continue }
                for item in items(in: bytes).reversed() {
                    let room = textBytes - used
                    if room <= 0 { full = true; break pages }
                    var text = item.text
                    if text.utf8.count + 1 > room {
                        // The entry that crosses the bound is kept cut when there is room for a useful part, else it ends the read.
                        if room < 200, !newestFirst.isEmpty { full = true; break pages }
                        text = clip(text, toBytes: room - 1)
                        full = true
                    }
                    newestFirst.append(text)
                    used += text.utf8.count + 1
                    if let path = item.file, !files.contains(path), files.count < maxFiles { files.append(path) }
                    if full { break pages }
                }
            }
            reachedStart = page.reachedStart
            if reachedStart { break }
        }
        let beginning = reachedStart && !full
        return RemoraExcerpt(entries: newestFirst.reversed(), filesTouched: files,
                             firstPrompt: beginning ? nil : firstPrompt(of: file), startsAtBeginning: beginning)
    }

    // MARK: Lines

    struct Item {
        var text: String
        var file: String?
    }

    /// The entries one transcript line gives, in order: none for anything that is not a human prompt or a main-thread
    /// assistant record.
    static func items(in line: Data) -> [Item] {
        guard mentions(line, "\"user\"") || mentions(line, "\"assistant\""),
              let json = try? JSONDecoder().decode(JSONValue.self, from: line) else { return [] }
        switch StreamMessage(json: json) {
        case let .user(message):
            guard let prompt = humanPromptText(message) else { return [] }
            return [Item(text: "user: " + clip(RemoraSecretMask.mask(prompt), toBytes: promptBytes))]
        case let .assistant(message):
            guard message.parentToolUseID == nil, !message.isSidechain, !message.isSynthetic else { return [] }
            var result: [Item] = []
            for block in message.content {
                switch block {
                case let .text(text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { result.append(Item(text: "assistant: " + clip(RemoraSecretMask.mask(trimmed), toBytes: answerBytes))) }
                case let .toolUse(call):
                    result.append(Item(text: "tool: " + oneLine(of: call), file: touchedFile(of: call)))
                default:
                    break
                }
            }
            return result
        default:
            return []
        }
    }

    /// The same rule as `TranscriptLens.isHumanPrompt` (LoomChat, internal there): a user record of the main thread that
    /// is not a tool result, not a meta record, with origin human or absent, and not a wrapper or a notice. A slash
    /// command reads as the command and its arguments.
    static func humanPromptText(_ message: UserMessage) -> String? {
        guard message.parentToolUseID == nil, !message.isSidechain, !message.isMeta, !message.hasToolResult else { return nil }
        if let origin = message.originKind, origin != "human" { return nil }
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("[Request interrupted by user") { return nil }
        for wrapper in ["<local-command-", "<system-reminder>", "<task-notification", "<bash-stdout>", "<bash-stderr>"]
        where text.hasPrefix(wrapper) { return nil }
        if text.hasPrefix("<command-name>") {
            let name = tag("command-name", in: text) ?? ""
            if name.isEmpty || name == "/exit" { return nil }
            let arguments = tag("command-args", in: text) ?? ""
            return arguments.isEmpty ? name : name + " " + arguments
        }
        if text.hasPrefix("<bash-input>") { return "!" + (tag("bash-input", in: text) ?? "") }
        return text
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tool call cut to one line: its name and the one argument that says what it did.
    static func oneLine(of call: ToolUseBlock) -> String {
        let input = call.input
        let argument: String? = switch call.name {
        case "Bash": input["command"]?.string
        case "Read", "Edit", "Write", "MultiEdit": input["file_path"]?.string
        case "NotebookEdit": input["notebook_path"]?.string
        case "Grep", "Glob": input["pattern"]?.string
        case "WebFetch": input["url"]?.string
        case "WebSearch": input["query"]?.string
        case "Task", "Agent": input["description"]?.string
        default: input.object?.sorted { $0.key < $1.key }.lazy.compactMap { $0.value.string }.first
        }
        // Masked before it is cut: a cut must not leave half of a secret.
        let first = argument.map(RemoraSecretMask.mask)?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? call.name : clip(call.name + " " + first, toBytes: callBytes)
    }

    private static func touchedFile(of call: ToolUseBlock) -> String? {
        switch call.name {
        case "Edit", "Write", "MultiEdit": call.input["file_path"]?.string.map { clip(RemoraSecretMask.mask($0), toBytes: callBytes) }
        case "NotebookEdit": call.input["notebook_path"]?.string.map { clip(RemoraSecretMask.mask($0), toBytes: callBytes) }
        default: nil
        }
    }

    // MARK: Head

    /// The first real prompt: the first `user` record with a `promptId` and a human text, within the first 64 KiB.
    static func firstPrompt(of file: ClaudeTranscriptFile) -> String? {
        guard let descriptor = openOwnRegularFile(file.path) else { return nil }
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: headBytes)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, headBytes, 0) }
        guard count > 0 else { return nil }
        var region = Array(buffer.prefix(count))
        // A full read ends inside a line; that line is not whole.
        if count == headBytes, let lastNewline = region.lastIndex(of: 0x0A) { region = Array(region[...lastNewline]) }
        for line in region.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let data = Data(line)
            guard mentions(data, "\"promptId\""), mentions(data, "\"user\""),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  json["promptId"]?.string != nil, case let .user(message) = StreamMessage(json: json),
                  let text = humanPromptText(message) else { continue }
            return clip(RemoraSecretMask.mask(text), toBytes: firstPromptBytes)
        }
        return nil
    }

    // MARK: Helpers

    private static func mentions(_ data: Data, _ needle: StaticString) -> Bool {
        data.withUnsafeBytes { buffer in
            memmem(buffer.baseAddress, buffer.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
        }
    }
}

/// `text` cut to `bytes` of UTF-8 on a character boundary, with an ellipsis.
func clip(_ text: String, toBytes bytes: Int) -> String {
    guard text.utf8.count > bytes else { return text }
    var result = ""
    var used = 0
    for character in text {
        let size = String(character).utf8.count
        if used + size > max(0, bytes - 3) { break }
        result.append(character)
        used += size
    }
    return result + "\u{2026}"
}
