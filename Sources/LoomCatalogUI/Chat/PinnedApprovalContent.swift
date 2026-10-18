import Foundation
import LoomChat
import LoomCore

/// What an approval card shows of a `can_use_tool` request (CHAT-SPEC → Approvals): the kind, the full command or a diff
/// summary in mono, Claude's own words first and the CLI's reason second (S1 §D11), and the subagent that asked.
struct PinnedApprovalContent: Equatable {
    enum Kind: Equatable {
        case command
        case fileEdit
        case fileRead
        case web
        case mcp(server: String?, tool: String)
        case other
    }

    struct Line: Equatable {
        enum Tone: Equatable { case plain, added, removed, meta }
        var text: String
        var tone: Tone
    }

    var kind: Kind
    /// "Allow this command?"
    var title: String
    /// "Command", "File edit", "File read", "Web", "docs · search", else the tool.
    var kindLabel: String
    var lines: [Line]
    /// Claude's own words (`description`).
    var claudeSays: String?
    /// The CLI's reason (`decision_reason`), when it adds something.
    var reason: String?
    /// "From explorer · Map the fake module".
    var agentLine: String?

    /// The card's mono block is bounded: at most this many lines, this many characters in a line and this many in all. What
    /// is cut ends in a line that says so ("… 12 more lines"), so a command or a file of any size builds a small card.
    static let maximumLines = 400
    static let maximumLineCharacters = 600
    static let maximumCharacters = 40_000

    /// Collects the mono lines of a card within the bounds above. Text is split lazily and only as far as the bounds reach.
    struct Block {
        private(set) var lines: [Line] = []
        private var characters = 0
        private(set) var cut = false

        var isFull: Bool { cut || lines.count >= PinnedApprovalContent.maximumLines }

        mutating func add(_ text: String, _ tone: Line.Tone, prefix: String = "") {
            guard !text.isEmpty else { return }
            for piece in text.lazy.split(separator: "\n", omittingEmptySubsequences: false) {
                guard !isFull else { cut = true; return }
                let head = piece.prefix(PinnedApprovalContent.maximumLineCharacters)
                var line = String(head)
                if head.endIndex != piece.endIndex { line += "\u{2026}" }
                characters += line.count
                lines.append(Line(text: prefix + line, tone: tone))
                if characters >= PinnedApprovalContent.maximumCharacters { cut = true; return }
            }
        }

        mutating func add(line: Line) {
            guard !isFull else { cut = true; return }
            lines.append(line)
        }

        /// The finished lines; a cut adds the visible mark.
        func finished() -> [Line] {
            cut ? lines + [Line(text: "\u{2026} the rest is not shown", tone: .meta)] : lines
        }
    }

    static func make(_ pending: ChatPendingRequest) -> PinnedApprovalContent {
        let request = pending.request
        let name = request.toolName
        let input = request.input
        let kind: Kind
        var block = Block()
        switch name {
        case "Bash", "PowerShell":
            kind = .command
            block.add(input["command"]?.string ?? "", .plain)
        case "Edit":
            kind = .fileEdit
            block.add(line: path(input))
            diff(old: input["old_string"]?.string, new: input["new_string"]?.string, into: &block)
        case "MultiEdit":
            kind = .fileEdit
            block.add(line: path(input))
            for edit in input["edits"]?.array ?? [] {
                diff(old: edit["old_string"]?.string, new: edit["new_string"]?.string, into: &block)
                if block.isFull { break }
            }
        case "Write":
            kind = .fileEdit
            let content = input["content"]?.string ?? ""
            // Counted once (the content is built once per request), without splitting it.
            let count = content.isEmpty ? 0 : content.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
            block.add(line: path(input))
            block.add(line: Line(text: "New or replaced file \u{00B7} \(count) line\(count == 1 ? "" : "s")", tone: .meta))
            block.add(content, .added, prefix: "+ ")
        case "NotebookEdit":
            kind = .fileEdit
            block.add(line: Line(text: input["notebook_path"]?.string ?? "", tone: .meta))
            block.add(input["new_source"]?.string ?? "", .added, prefix: "+ ")
        case "Read", "NotebookRead":
            kind = .fileRead
            block.add(line: Line(text: String((input["file_path"]?.string ?? input["notebook_path"]?.string ?? "").prefix(Self.maximumLineCharacters)), tone: .plain))
        case "Glob", "Grep", "LS":
            kind = .fileRead
            for key in ["pattern", "path", "glob"] {
                if let value = input[key]?.string, !value.isEmpty { block.add("\(key): \(value.prefix(Self.maximumLineCharacters))", .plain) }
            }
        case "WebFetch":
            kind = .web
            block.add(input["url"]?.string ?? "", .plain)
            if let prompt = input["prompt"]?.string, !prompt.isEmpty { block.add(prompt, .meta) }
        case "WebSearch":
            kind = .web
            block.add(input["query"]?.string ?? "", .plain)
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                kind = .mcp(server: request.mcpServerName ?? parts.first, tool: parts.dropFirst().joined(separator: "__"))
            } else {
                kind = .other
            }
            fields(of: input, into: &block)
        }
        var lines = block.finished()
        if lines.isEmpty { lines = [Line(text: name, tone: .meta)] }

        let who = request.description.flatMap { StatusReason.oneLine($0, limit: 400) }
        let why = request.decisionReason.flatMap { StatusReason.oneLine($0, limit: 400) }
        return PinnedApprovalContent(
            kind: kind, title: title(forTool: name), kindLabel: label(kind, request: request), lines: lines,
            claudeSays: who, reason: why == who ? nil : why, agentLine: agentLine(pending.agent))
    }

    /// The card's question for a tool, by name (a settled request keeps the name, not its input).
    static func title(forTool name: String) -> String {
        switch name {
        case "Bash", "PowerShell": "Allow this command?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Allow this edit?"
        case "Read", "NotebookRead", "Glob", "Grep", "LS": "Allow this read?"
        case "WebFetch", "WebSearch": "Allow this web request?"
        default: "Allow this tool?"
        }
    }

    private static func label(_ kind: Kind, request: ToolPermissionRequest) -> String {
        switch kind {
        case .command: "Command"
        case .fileEdit: "File edit"
        case .fileRead: "File read"
        case .web: "Web"
        case let .mcp(server, tool): [server, tool].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .other: request.displayName ?? request.toolName
        }
    }

    private static func agentLine(_ agent: ChatRequestAgent?) -> String? {
        guard let agent else { return nil }
        let name = agent.name
        guard let description = agent.description, !description.isEmpty, description != name else { return "From \(name)" }
        return "From \(name) · \(description)"
    }

    private static func path(_ input: JSONValue) -> Line {
        Line(text: String((input["file_path"]?.string ?? input["path"]?.string ?? "").prefix(maximumLineCharacters)), tone: .meta)
    }

    private static func diff(old: String?, new: String?, into block: inout Block) {
        block.add(old ?? "", .removed, prefix: "- ")
        block.add(new ?? "", .added, prefix: "+ ")
    }

    /// `key: value` for each field of an input the card has no special layout for.
    private static func fields(of input: JSONValue, into block: inout Block) {
        guard let object = input.object else { return }
        for key in object.keys.sorted() {
            guard !block.isFull else { return }
            let value = object[key]
            let text: String
            if let string = value?.string { text = String(string.prefix(1_000)) } else { text = String((value?.serializedString ?? "").prefix(1_000)) }
            let flat = StatusReason.oneLine(text, limit: 300) ?? ""
            block.add(line: Line(text: "\(key): \(flat)", tone: .plain))
        }
    }
}
