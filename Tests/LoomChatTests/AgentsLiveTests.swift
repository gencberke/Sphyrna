import Foundation
import LoomCore
import Testing
@testable import LoomChat
import LoomTestSupport
@testable import LoomChatTestRigs

// V23, Agents live, on the chat side: the hub's agent field, which Agent calls of a transcript have a result (a stopped
// session's "Interrupted"), and the newest words of a running subagent.

struct AgentCallScanTests {
    private struct Tree {
        let root: URL
        var url: URL { root.appendingPathComponent("projects/-tmp-work/sess1.jsonl") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-agentscan-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-work"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func write(_ lines: [String]) throws -> ClaudeTranscriptFile {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return try #require(ClaudeTranscriptLocator.locate(sessionID: "sess1", configDirectory: root))
        }
    }

    private static func call(_ id: String, _ name: String = "Agent", sidechain: Bool = false) -> String {
        Fixture.line(["type": "assistant", "uuid": .string("a-" + id), "sessionId": "sess1", "isSidechain": .bool(sidechain),
                      "message": ["id": .string("m-" + id), "role": "assistant", "model": "claude-opus-5-5",
                                  "content": [Fixture.toolUse(id, name, ["description": "d", "subagent_type": "Explore", "prompt": "p"])]]])
    }

    private static func result(_ id: String, sidechain: Bool = false) -> String {
        Fixture.line(["type": "user", "uuid": .string("r-" + id), "sessionId": "sess1", "isSidechain": .bool(sidechain),
                      "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": "ok"]]]])
    }

    @Test func aCallWithoutAResultIsUnansweredAndOneWithAResultIsNot() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let file = try tree.write([
            Self.call("toolu_done"), Self.result("toolu_done"),
            Self.call("toolu_cut"),
            Self.call("toolu_task", "Task"), Self.result("toolu_task"),
            Self.call("toolu_unrelated", "Bash"),
        ])
        let outcome = AgentCallScan.scan(file: file, wanting: ["toolu_done", "toolu_cut", "toolu_task", "toolu_unrelated", "toolu_gone"])
        // The join is the id; a call of another tool, and an id the transcript never names, are not Agent calls found.
        #expect(outcome.calls == ["toolu_done", "toolu_cut", "toolu_task"])
        #expect(outcome.unanswered == ["toolu_cut"])
    }

    @Test func aSubagentsOwnRecordsAreNotTheMainSessionsCallsOrResults() throws {
        let tree = try Tree()
        defer { tree.remove() }
        // A result written on a subagent's thread does not answer the main thread's call.
        let file = try tree.write([Self.call("toolu_a"), Self.result("toolu_a", sidechain: true), Self.call("toolu_b", sidechain: true)])
        let outcome = AgentCallScan.scan(file: file, wanting: ["toolu_a", "toolu_b"])
        #expect(outcome.calls == ["toolu_a"] && outcome.unanswered == ["toolu_a"])
    }

    @Test func theReadStopsAtTheByteBoundAndAnOlderCallIsNotJudged() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let filler = (0..<200).map { _ in Fixture.line(["type": "system", "subtype": "x", "padding": .string(String(repeating: "p", count: 400))]) }
        // The old call lies before 200 lines of filler; the read covers only the tail.
        let file = try tree.write([Self.call("toolu_old")] + filler + [Self.call("toolu_new"), Self.result("toolu_new")])
        let bounded = AgentCallScan.scan(file: file, wanting: ["toolu_old", "toolu_new"], byteLimit: 10_000, pageBytes: 4_000)
        #expect(bounded.calls == ["toolu_new"] && bounded.unanswered.isEmpty)
        let whole = AgentCallScan.scan(file: file, wanting: ["toolu_old", "toolu_new"])
        #expect(whole.calls == ["toolu_old", "toolu_new"] && whole.unanswered == ["toolu_old"])
        // Nothing wanted, nothing read.
        #expect(AgentCallScan.scan(file: file, wanting: []) == AgentCallScan.Result())
    }
}
