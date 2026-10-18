import Foundation
import LoomChat
import LoomCore

/// What a tool call is, for the work rows: its kind (for the group summaries), its label and its glyph. Pure functions
/// of the call, so the labels are unit-tested. The kinds, their ranks and the summary sentence follow T3 Code
/// (MIT, Copyright 2026 T3 Tools Inc.): packages/client-runtime/src/work-log/presentation.ts (`summarizeWorkGroup`);
/// no code is copied.
enum ChatWork {
    enum Kind: Equatable {
        case command, edit, agent, read, search, web, other

        /// Commands, edits and agents rank 0, reads, searches and web 1, the rest 2.
        var rank: Int {
            switch self {
            case .command, .edit, .agent: 0
            case .read, .search, .web: 1
            case .other: 2
            }
        }
    }

    struct Label: Equatable {
        var kind: Kind
        /// SF Symbol name.
        var symbol: String
        /// Past form: "Read", "Ran", "Edited".
        var verb: String
        /// Present form, while the tool runs.
        var verbRunning: String
        /// The subject: a path, a command, a pattern.
        var subject: String
        /// The subject is code or a path and draws in mono.
        var mono: Bool
    }

    /// Hidden from the stream: TodoWrite is the Tasks line's data, never a row.
    static func isHidden(_ call: ToolCall) -> Bool { call.name == "TodoWrite" }

    static func isEditTool(_ name: String) -> Bool { ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name) }

    static func kind(of call: ToolCall) -> Kind { label(for: call, workingDirectory: nil).kind }

    static func label(for call: ToolCall, workingDirectory: String?) -> Label {
        let input = call.input
        func path(_ keys: String...) -> String {
            for key in keys { if let value = input[key]?.string, !value.isEmpty { return shorten(value, workingDirectory: workingDirectory) } }
            return ""
        }
        switch call.name {
        case "Read", "NotebookRead":
            return Label(kind: .read, symbol: "doc.text", verb: "Read", verbRunning: "Reading", subject: path("file_path", "notebook_path"), mono: true)
        case "Grep":
            let pattern = input["pattern"]?.string ?? ""
            let place = path("path")
            let subject = place.isEmpty ? "\u{201C}\(pattern)\u{201D}" : "\u{201C}\(pattern)\u{201D} in \(place)"
            return Label(kind: .search, symbol: "magnifyingglass", verb: "Searched", verbRunning: "Searching", subject: subject, mono: false)
        case "Glob":
            let pattern = input["pattern"]?.string ?? ""
            let place = path("path")
            let subject = place.isEmpty ? pattern : "\(pattern) in \(place)"
            return Label(kind: .search, symbol: "magnifyingglass", verb: "Searched", verbRunning: "Searching", subject: subject, mono: true)
        case "LS":
            return Label(kind: .search, symbol: "folder", verb: "Listed", verbRunning: "Listing", subject: path("path"), mono: true)
        case "Bash":
            let command = (input["command"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return Label(kind: .command, symbol: "terminal", verb: "Ran", verbRunning: "Running", subject: command.trimmingCharacters(in: .whitespaces), mono: true)
        case "BashOutput":
            return Label(kind: .command, symbol: "terminal", verb: "Read output of", verbRunning: "Reading output of",
                         subject: "a background command", mono: false)
        case "KillShell", "KillBash":
            return Label(kind: .command, symbol: "terminal", verb: "Stopped", verbRunning: "Stopping", subject: "a background command", mono: false)
        case "Edit", "MultiEdit", "NotebookEdit":
            return Label(kind: .edit, symbol: "pencil", verb: "Edited", verbRunning: "Editing", subject: path("file_path", "notebook_path"), mono: true)
        case "Write":
            let created = createdFile(call)
            return Label(kind: .edit, symbol: "square.and.pencil", verb: created ? "Created" : "Edited",
                         verbRunning: "Writing", subject: path("file_path"), mono: true)
        case "WebFetch":
            return Label(kind: .web, symbol: "globe", verb: "Fetched", verbRunning: "Fetching", subject: host(of: input["url"]?.string ?? ""), mono: false)
        case "WebSearch":
            return Label(kind: .web, symbol: "globe", verb: "Searched the web for", verbRunning: "Searching the web for",
                         subject: "\u{201C}\(input["query"]?.string ?? "")\u{201D}", mono: false)
        case "Skill":
            return Label(kind: .other, symbol: "sparkles", verb: "Skill:", verbRunning: "Skill:",
                         subject: input["skill"]?.string ?? input["command"]?.string ?? "", mono: false)
        case "AskUserQuestion":
            return Label(kind: .other, symbol: "questionmark.circle", verb: "Asked", verbRunning: "Asking", subject: "a question", mono: false)
        case "ToolSearch":
            return Label(kind: .search, symbol: "magnifyingglass", verb: "Searched", verbRunning: "Searching",
                         subject: "tools \u{201C}\(input["query"]?.string ?? "")\u{201D}", mono: false)
        default:
            if call.name.hasPrefix("mcp__") {
                let parts = call.name.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? ""
                let tool = parts.dropFirst().joined(separator: "__")
                return Label(kind: .other, symbol: "puzzlepiece.extension", verb: "Used", verbRunning: "Using",
                             subject: tool.isEmpty ? server : "\(server) \u{00B7} \(tool)", mono: false)
            }
            let name = call.name.isEmpty ? "a tool" : call.name
            return Label(kind: .other, symbol: "wrench.and.screwdriver", verb: "Used", verbRunning: "Using", subject: name, mono: false)
        }
    }

    /// A Write that made a new file ("File created successfully"), or one whose result is not in yet.
    static func createdFile(_ call: ToolCall) -> Bool {
        if let text = call.output?.head { return text.contains("created successfully") }
        return call.changes.map { $0.removed == 0 } ?? true
    }

    /// The text of a row: "Edited src/a.py" while it says what it did. Counts are drawn apart (see `changesText`).
    static func sentence(_ label: Label, running: Bool) -> String {
        let verb = running ? label.verbRunning : label.verb
        return label.subject.isEmpty ? verb : verb + " " + label.subject
    }

    // MARK: Paths

    /// `/private/tmp`, `/private/var` and `/private/etc` are the same places as `/tmp`, `/var` and `/etc`: a session's
    /// folder and a tool's path may spell one of them either way. Pure text, no file access.
    static func withoutPrivatePrefix(_ path: String) -> String {
        for root in ["/private/tmp", "/private/var", "/private/etc"] where path == root || path.hasPrefix(root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    static func shorten(_ path: String, workingDirectory: String?) -> String {
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

    static func host(of urlString: String) -> String {
        if let host = URL(string: urlString)?.host(percentEncoded: false), !host.isEmpty { return host }
        return urlString
    }

    // MARK: Groups

    /// "Changed 3 files, ran 2 commands and 4 other actions" (T3's `summarizeWorkGroup`): the two kinds with the best
    /// (rank, first appearance) are named, in order of appearance; the rest is "N other actions".
    static func summary(of calls: [ToolCall], agents: Int = 0, thinkingOnly: Bool = false, capitalized: Bool = true) -> String {
        struct Bucket { var kind: Kind; var first: Int; var count: Int; var paths: Set<String> }
        var buckets: [Bucket] = []
        func note(_ kind: Kind, at position: Int, path: String? = nil) {
            if let i = buckets.firstIndex(where: { $0.kind == kind }) {
                buckets[i].count += 1
                if let path { buckets[i].paths.insert(path) }
            } else {
                buckets.append(Bucket(kind: kind, first: position, count: 1, paths: path.map { [$0] } ?? []))
            }
        }
        var refused = 0
        for (position, call) in calls.enumerated() {
            // Ask refused it: nothing was changed or run, so it is not counted as work.
            if call.status == .refusedInAsk { refused += 1; continue }
            let kind = kind(of: call)
            let path = kind == .edit ? (call.input["file_path"]?.string ?? call.input["notebook_path"]?.string) : nil
            note(kind, at: position, path: path)
        }
        for _ in 0..<agents { note(.agent, at: calls.count) }
        let refusedNote = refused > 0 ? " \u{00B7} \(refused) refused in Ask" : ""
        guard !buckets.isEmpty else {
            if refused > 0 {
                // The lowercase form follows a header that already says "Worked".
                return capitalized ? "Worked" + refusedNote : "\(refused) refused in Ask"
            }
            return thinkingOnly ? (capitalized ? "Thought" : "thought") : (capitalized ? "Worked" : "worked")
        }
        let named = buckets.sorted { ($0.kind.rank, $0.first) < ($1.kind.rank, $1.first) }.prefix(2)
            .sorted { $0.first < $1.first }
        let namedKinds = Set(named.map(\.kind))
        let rest = buckets.filter { !namedKinds.contains($0.kind) }.reduce(0) { $0 + $1.count }
        var phrases = named.map(phrase)
        if rest > 0 { phrases.append("\(rest) other action\(rest == 1 ? "" : "s")") }
        let text: String
        switch phrases.count {
        case 1: text = phrases[0]
        case 2: text = "\(phrases[0]) and \(phrases[1])"
        default: text = phrases.dropLast().joined(separator: ", ") + " and " + phrases[phrases.count - 1]
        }
        return (capitalized ? text.prefix(1).uppercased() + text.dropFirst() : text.prefix(1).lowercased() + text.dropFirst()) + refusedNote

        func phrase(_ bucket: Bucket) -> String {
            switch bucket.kind {
            case .read: return "read \(bucket.count) file\(bucket.count == 1 ? "" : "s")"
            case .edit:
                let files = max(bucket.paths.count, 1)
                return "changed \(files) file\(files == 1 ? "" : "s")"
            case .command: return "ran \(bucket.count) command\(bucket.count == 1 ? "" : "s")"
            case .search: return "searched code \(bucket.count) time\(bucket.count == 1 ? "" : "s")"
            case .web: return "searched the web \(bucket.count) time\(bucket.count == 1 ? "" : "s")"
            case .agent: return "ran \(bucket.count) agent\(bucket.count == 1 ? "" : "s")"
            case .other: return "used \(bucket.count) tool\(bucket.count == 1 ? "" : "s")"
            }
        }
    }

    // MARK: Changed files

    /// The files the tools changed, with counts from the edit records, in first-edit order.
    static func changedFiles(in calls: [ToolCall], workingDirectory: String?) -> [ChangedFile] {
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

    /// The file tree of the card: folders first, single-child folders merged into one line ("src/auth/").
    static func tree(of files: [ChangedFile]) -> [ChangedFileLine] {
        final class Node {
            var children: [String: Node] = [:]
            var order: [String] = []
            var file: ChangedFile?
        }
        let root = Node()
        for file in files {
            var node = root
            var parts = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // A path outside the working folder keeps its root: "/tmp/orbit/", not a folder named "tmp/orbit/".
            if file.path.hasPrefix("/"), !parts.isEmpty { parts[0] = "/" + parts[0] }
            for (position, part) in parts.enumerated() {
                let child: Node
                if let existing = node.children[part] {
                    child = existing
                } else {
                    child = Node()
                    node.children[part] = child
                    node.order.append(part)
                }
                if position == parts.count - 1 { child.file = file }
                node = child
            }
        }
        var lines: [ChangedFileLine] = []
        func totals(_ node: Node) -> (Int, Int) {
            var sum = (node.file?.added ?? 0, node.file?.removed ?? 0)
            for child in node.children.values {
                let value = totals(child)
                sum.0 += value.0
                sum.1 += value.1
            }
            return sum
        }
        func walk(_ node: Node, depth: Int) {
            let folders = node.order.filter { node.children[$0]?.file == nil }.sorted()
            let leaves = node.order.filter { node.children[$0]?.file != nil && node.children[$0]?.children.isEmpty == true }.sorted()
            for name in folders {
                guard var child = node.children[name] else { continue }
                var label = name
                while child.file == nil, child.children.count == 1, let only = child.order.first, let next = child.children[only],
                      next.file == nil {
                    label += "/" + only
                    child = next
                }
                let sum = totals(child)
                lines.append(ChangedFileLine(depth: depth, name: label + "/", isFolder: true, added: sum.0, removed: sum.1))
                walk(child, depth: depth + 1)
            }
            for name in leaves {
                if let file = node.children[name]?.file {
                    lines.append(ChangedFileLine(depth: depth, name: name, isFolder: false, added: file.added, removed: file.removed))
                }
            }
        }
        walk(root, depth: 0)
        return lines
    }

    // MARK: Subagents

    /// The card's detail line: the result when done, otherwise the latest progress; markdown stripped, at most 280 characters.
    /// Made once per source text (a bounded cache), from its first 2,000 characters: the regexes never see a whole result.
    @MainActor
    static func subagentDetail(_ run: SubagentRun) -> String? {
        var source: String?
        switch run.status {
        case .running: source = run.latestProgress
        default: source = run.result?.head ?? run.latestProgress
        }
        // A background agent's immediate result only says it was launched.
        if source?.hasPrefix("Async agent launched") == true { source = run.status == .running ? run.latestProgress : nil }
        guard let source, !source.isEmpty else { return nil }
        let key = "\(run.toolUseID)#\(source.utf8.count)#\(source.prefix(24))" as NSString
        if let cached = detailCache.object(forKey: key) { return cached.value }
        let plain = stripMarkdown(String(source.prefix(2_000)))
        let detail: String? = plain.isEmpty ? nil : (plain.count > 280 ? String(plain.prefix(279)) + "\u{2026}" : plain)
        detailCache.setObject(DetailBox(detail), forKey: key)
        return detail
    }

    private final class DetailBox {
        let value: String?
        init(_ value: String?) { self.value = value }
    }

    @MainActor private static let detailCache: NSCache<NSString, DetailBox> = {
        let cache = NSCache<NSString, DetailBox>()
        cache.countLimit = 500
        return cache
    }()

    static func stripMarkdown(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s*(#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s*)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_`]{1,3}"#, with: "", options: .regularExpression)
        return result.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
