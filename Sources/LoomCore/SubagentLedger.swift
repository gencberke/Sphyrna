import Foundation

/// One subagent a Claude session runs (D-39: shown under the session's card). Built from the
/// `SubagentStart` / `SubagentStop` hooks of the run's own conversation, the subagent's
/// `meta.json` (description, foreground or background, depth) and, for a background subagent
/// whose start was missed, `Stop.background_tasks`. Claude reports neither success nor failure.
public struct SubagentRecord: Equatable, Sendable, Identifiable {
    /// Claude's `agent_id`.
    public let id: String
    public var agentType: String
    /// The short description the parent gave the subagent; nil until `meta.json` is read.
    public var description: String?
    public var isBackground: Bool
    /// 1 for a subagent of the session itself, 2 for one a subagent started, and so on.
    public var depth: Int
    public var startedAt: Date
    public var endedAt: Date?

    public var isRunning: Bool { endedAt == nil }

    public init(id: String, agentType: String, description: String? = nil, isBackground: Bool = false,
                depth: Int = 1, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.agentType = agentType
        self.description = description
        self.isBackground = isBackground
        self.depth = depth
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// A running background subagent as `Stop.background_tasks[]` lists it.
public struct BackgroundSubagentTask: Equatable, Sendable {
    public let id: String
    public let agentType: String
    public let description: String?

    static func parse(_ value: Any?) -> [BackgroundSubagentTask] {
        guard let tasks = value as? [[String: Any]] else { return [] }
        return tasks.compactMap { task in
            guard task["type"] as? String == "subagent", task["status"] as? String == "running",
                  let id = task["id"] as? String, SubagentMeta.isValidAgentID(id) else { return nil }
            return BackgroundSubagentTask(
                id: id, agentType: (task["agent_type"] as? String) ?? "",
                description: SubagentMeta.cleaned(task["description"] as? String))
        }
    }
}

/// What Claude writes next to a subagent's transcript:
/// `<config>/projects/<slug>/<sessionId>/subagents/agent-<id>.meta.json`, about 25 ms after
/// `SubagentStart`. Only these fields are read.
public struct SubagentMeta: Equatable, Sendable {
    public var agentType: String?
    public var description: String?
    public var depth: Int?
    public var isBackground: Bool?

    static let maximumDescriptionLength = 200
    static let maximumFileByteCount = 64 * 1024

    public init(agentType: String? = nil, description: String? = nil, depth: Int? = nil, isBackground: Bool? = nil) {
        self.agentType = agentType
        self.description = description
        self.depth = depth
        self.isBackground = isBackground
    }

    /// Claude's ids are short alphanumeric strings; anything else never becomes part of a path.
    static func isValidAgentID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80
            && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
                || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    /// One line, trimmed and bounded; nil when nothing is left.
    static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maximumDescriptionLength))
    }

    public static func parse(_ data: Data) -> SubagentMeta? {
        guard data.count <= maximumFileByteCount,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = (object["agentType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let depth = (object["spawnDepth"] as? Int).map { max(1, min($0, 16)) }
        let shape = object["requestShape"] as? String
        return SubagentMeta(
            agentType: type, description: cleaned(object["description"] as? String), depth: depth,
            isBackground: shape.map { $0 == "background" })
    }

    /// Where the meta file of `agentID` lives, from the hook payload's paths. The subagent's own
    /// transcript path (`…/subagents/agent-<id>.jsonl`, `SubagentStop`) is used when present;
    /// otherwise the parent transcript (`…/<sessionId>.jsonl`) names the directory.
    static func fileURL(agentID: String, transcriptPath: String?, agentTranscriptPath: String?) -> URL? {
        guard isValidAgentID(agentID) else { return nil }
        let name = "agent-\(agentID)"
        func absolute(_ path: String?) -> URL? {
            guard let path, path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return url
        }
        if let own = absolute(agentTranscriptPath), own.deletingPathExtension().lastPathComponent == name {
            return own.deletingLastPathComponent().appendingPathComponent("\(name).meta.json")
        }
        guard let parent = absolute(transcriptPath), parent.pathExtension == "jsonl" else { return nil }
        return parent.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("\(name).meta.json")
    }

    /// A short read of the file; nil while it does not exist yet or is not what is expected.
    public static func read(_ url: URL) -> SubagentMeta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileByteCount + 1) else { return nil }
        return parse(data)
    }
}

/// The subagents of one run's conversation, and the rules that keep the list true:
/// - `SubagentStart` adds a running record; a stop finishes it. Finished is final, so a stop that
///   arrives before its start (the hooks are separate processes) is not undone by the start.
/// - Claude's internal agents stop with an empty `agent_type` and never start: ignored.
/// - A background subagent that `Stop.background_tasks` lists as running and Loom never saw start is
///   added as running. A background subagent's own `SubagentStop` lists itself as running, so that list
///   never ends anything; only the stop hook does, except that the parent's `Stop` ends a running
///   foreground record whose stop hook was lost (`turnEnded`).
/// - The user's next real prompt drops the finished records; a harness hand-back is not that prompt.
/// - Bounded: at most `maximumFinished` finished and `maximumRunning` running records are kept.
public struct SubagentLedger: Equatable, Sendable {
    public static let maximumFinished = 20
    public static let maximumRunning = 50

    /// In the order the subagents were first seen.
    public private(set) var records: [SubagentRecord] = []
    /// Ids that finished, kept after their records are dropped so a late event or a stale
    /// `Stop` list cannot bring one back as a running record. Bounded.
    private var ended: [String] = []
    private static let maximumEnded = 200

    public init() {}

    mutating func apply(_ event: ClaudeHookEvent, at date: Date) {
        guard let id = event.agentID, SubagentMeta.isValidAgentID(id) else { return }
        switch event.kind {
        case let .subagentStart(type):
            if let index = index(of: id) {
                if records[index].agentType.isEmpty, !type.isEmpty { records[index].agentType = type }
                return
            }
            guard !type.isEmpty, !ended.contains(id) else { return }
            records.append(SubagentRecord(id: id, agentType: type, startedAt: date))
            trim()
        case let .subagentStop(type):
            if let index = index(of: id) {
                if records[index].endedAt == nil { records[index].endedAt = date; noteEnded(id) }
                if records[index].agentType.isEmpty, !type.isEmpty { records[index].agentType = type }
                return
            }
            guard !type.isEmpty, !ended.contains(id) else { return }
            records.append(SubagentRecord(id: id, agentType: type, startedAt: date, endedAt: date))
            noteEnded(id)
            trim()
        default: break
        }
    }

    /// The parent conversation's `Stop`: a foreground subagent cannot outlive the turn (the Agent tool call
    /// blocks it), so a running record that this Stop does not list and that is not known to be background
    /// lost its `SubagentStop` hook and ends now. A known-background record that is not listed stays running
    /// (what an unlisted background subagent means is not verified). The ended id is remembered, so a late
    /// real stop changes nothing.
    mutating func turnEnded(listing tasks: [BackgroundSubagentTask], at date: Date) {
        noteBackground(tasks, at: date)
        for index in records.indices where records[index].isRunning && !records[index].isBackground {
            records[index].endedAt = date
            noteEnded(records[index].id)
        }
        trim()
    }

    mutating func noteBackground(_ tasks: [BackgroundSubagentTask], at date: Date) {
        for task in tasks {
            if let index = index(of: task.id) {
                if records[index].description == nil { records[index].description = task.description }
                if records[index].isRunning { records[index].isBackground = true }
                continue
            }
            guard !task.agentType.isEmpty, !ended.contains(task.id) else { continue }
            records.append(SubagentRecord(
                id: task.id, agentType: task.agentType, description: task.description,
                isBackground: true, startedAt: date))
        }
        trim()
    }

    /// True when `meta` changed the record.
    mutating func apply(_ meta: SubagentMeta, to id: String) -> Bool {
        guard let index = index(of: id) else { return false }
        var record = records[index]
        if let type = meta.agentType, record.agentType.isEmpty { record.agentType = type }
        if let description = meta.description { record.description = description }
        if let depth = meta.depth { record.depth = depth }
        if let background = meta.isBackground { record.isBackground = background }
        guard record != records[index] else { return false }
        records[index] = record
        return true
    }

    mutating func clearFinished() { records.removeAll { !$0.isRunning } }

    private func index(of id: String) -> Int? { records.firstIndex { $0.id == id } }

    private mutating func noteEnded(_ id: String) {
        ended.append(id)
        if ended.count > Self.maximumEnded { ended.removeFirst(ended.count - Self.maximumEnded) }
    }

    private mutating func trim() {
        let finished = records.filter { !$0.isRunning }.count
        if finished > Self.maximumFinished {
            var drop = finished - Self.maximumFinished
            records.removeAll { record in
                guard drop > 0, !record.isRunning else { return false }
                drop -= 1
                return true
            }
        }
        let running = records.filter(\.isRunning).count
        if running > Self.maximumRunning {
            var drop = running - Self.maximumRunning
            records.removeAll { record in
                guard drop > 0, record.isRunning else { return false }
                drop -= 1
                return true
            }
        }
    }
}
