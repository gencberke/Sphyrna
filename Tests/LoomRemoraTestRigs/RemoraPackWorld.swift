import Foundation
import LoomCore
@testable import LoomRemora
import LoomTestSupport

/// A synthetic workspace for pack tests: a temporary `projects` folder with transcript files and the session summaries that
/// point at them. Nothing here reads or writes a real profile.
final class RemoraPackWorld: @unchecked Sendable {
    let root: URL
    var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
    private(set) var summaries: [SessionSummary] = []
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remora-pack-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// `minutesAgo` is relative to `base`.
    @discardableResult
    func add(title: String?, project: (id: UUID, name: String)? = nil, minutesAgo: Double, harness: SessionHarness = .claude,
             state: SessionStateWord = .idle, lines: [String]? = nil) throws -> SessionSummary {
        let id = UUID()
        let summary = SessionSummary(id: id, harness: harness, title: title, projectID: project?.id, projectName: project?.name,
                                     state: state, face: nil, lastActivityAt: base.addingTimeInterval(-minutesAgo * 60))
        if let lines {
            let folder = projects.appendingPathComponent("-work-\(project?.name ?? "none")", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(
                to: folder.appendingPathComponent("\(id.uuidString).jsonl"), atomically: true, encoding: .utf8)
        }
        summaries.append(summary)
        return summary
    }

    /// The session's state changes (its transcript stays as it was).
    func set(_ id: UUID, state: SessionStateWord, lastActivityAt: Date? = nil) {
        summaries = summaries.map { old in
            old.id == id ? SessionSummary(id: old.id, harness: old.harness, title: old.title, projectID: old.projectID,
                                          projectName: old.projectName, state: state, face: old.face,
                                          lastActivityAt: lastActivityAt ?? old.lastActivityAt) : old
        }
    }

    func builder(limits: RemoraPackLimits = .standard) -> RemoraPackBuilder {
        let all = summaries
        let projects = projects
        return RemoraPackBuilder(
            sessions: { query in
                all.filter { query.project == nil || $0.projectID == query.project }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(query.limit).map { $0 }
            },
            transcript: { summary in
                ClaudeTranscriptLocator.locate(sessionID: summary.id.uuidString, projectsDirectory: projects)
            },
            limits: limits)
    }

    func build(_ request: RemoraPackRequest, builder: RemoraPackBuilder? = nil, settings: RemoraPackSettings = RemoraPackSettings(),
               memory: RemoraMemoryShare = RemoraMemoryShare(), at offset: TimeInterval = 0,
               usage: RemoraUsage.Day? = nil) async throws -> RemoraPack {
        try await (builder ?? self.builder()).build(
            request, settings: settings, memory: memory, today: usage ?? RemoraUsage().today, now: base.addingTimeInterval(offset),
            timeZone: TimeZone(identifier: "Europe/Istanbul")!)
    }

    // MARK: Transcript lines

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func user(_ text: String, promptID: String? = "p-1", extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": "user", "uuid": UUID().uuidString, "isSidechain": false,
                                     "message": ["role": "user", "content": text]]
        if let promptID { object["promptId"] = promptID }
        object.merge(extra) { _, new in new }
        return json(object)
    }

    static func toolResult(_ text: String) -> String {
        json(["type": "user", "uuid": UUID().uuidString, "isSidechain": false,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": text]]]])
    }

    static func assistant(_ text: String? = nil, tool: (name: String, input: [String: Any])? = nil, extra: [String: Any] = [:]) -> String {
        var content: [[String: Any]] = []
        if let text { content.append(["type": "text", "text": text]) }
        if let tool { content.append(["type": "tool_use", "id": "t1", "name": tool.name, "input": tool.input]) }
        var object: [String: Any] = ["type": "assistant", "uuid": UUID().uuidString, "isSidechain": false,
                                     "message": ["id": "m-\(UUID().uuidString)", "role": "assistant", "model": "claude-sonnet-4",
                                                 "content": content]]
        object.merge(extra) { _, new in new }
        return json(object)
    }

    /// A long, plain conversation: `turns` rounds of a prompt and an answer of about `width` characters each.
    static func conversation(turns: Int, width: Int = 600, topic: String = "topic") -> [String] {
        var lines: [String] = []
        for turn in 0..<turns {
            lines.append(user("Turn \(turn) of \(topic): " + String(repeating: "question ", count: width / 9), promptID: "p-\(turn)"))
            lines.append(assistant("Answer \(turn) of \(topic): " + String(repeating: "detail ", count: width / 7)))
            lines.append(assistant(tool: ("Bash", ["command": "swift test --filter \(topic)\(turn)"])))
            lines.append(toolResult(String(repeating: "x", count: 3_000)))
        }
        return lines
    }
}
