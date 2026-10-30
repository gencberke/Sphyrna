import Foundation
import Testing
@testable import LoomCore

/// A refresh looks a rollout up once: a file that only grew is read again at the path already found.
@Suite struct CodexUsageIndexLookupTests {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    private func usage(_ total: Int, last: Int) -> [String: Any] {
        func counts(_ input: Int) -> [String: Int] {
            ["input_tokens": input, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
             "output_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": input]
        }
        return ["type": "event_msg", "timestamp": "2026-10-28T19:24:03.915Z", "payload": ["type": "token_count", "info":
            ["total_token_usage": counts(total), "last_token_usage": counts(last), "model_context_window": 1_000]]]
    }

    @Test func aFileThatOnlyGrewIsReadAgainWithoutALookup() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-lookup-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
        let header = try line(["type": "session_meta", "payload": ["id": id, "cwd": "/fixture"]])
            + line(["type": "turn_context", "payload": ["model": "gpt-test"]])
        try (header + line(usage(100, last: 100))).write(to: file, atomically: true, encoding: .utf8)
        let index = CodexUsageIndex(home: home)
        #expect(try await index.refresh(sessionIDs: [id]).sessions[id]?.total.total == 100)
        #expect(await index.locatedIDs == 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(try line(usage(250, last: 150)).utf8))
        try handle.close()
        let grown = try await index.refresh(sessionIDs: [id])
        #expect(grown.complete)
        #expect(grown.sessions[id]?.total.total == 250)
        #expect(await index.locatedIDs == 1, "the grown file was read at its known path")

        // A replaced file (another inode) is looked up again.
        try (header + line(usage(40, last: 40))).write(to: file, atomically: true, encoding: .utf8)
        let replaced = try await index.refresh(sessionIDs: [id])
        #expect(replaced.sessions[id]?.total.total == 40)
        #expect(await index.locatedIDs == 2)
    }
}
