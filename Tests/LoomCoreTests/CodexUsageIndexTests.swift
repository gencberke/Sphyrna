import Foundation
import Testing
@testable import LoomCore

@Suite struct CodexUsageIndexTests {
    @Test func unknownMessageCountStillDisplaysTokensWithoutChangingClaudeEmptySemantics() {
        let claude = SessionUsage(main: .init(tokens: UsageTokens(input: 5)))
        let codex = SessionUsage(main: .init(tokens: UsageTokens(input: 5), estimatedCostUSD: nil, messageCountKnown: false),
                                 subagentBreakdownKnown: false)
        #expect(claude.isEmpty)
        #expect(!codex.isEmpty)
        #expect(!codex.total.messageCountKnown)
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }
    private func counts(_ input: Int, _ cache: Int, _ output: Int) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": cache, "cache_write_input_tokens": 0,
         "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": input + output]
    }
    private func event(_ total: [String: Int], _ last: [String: Int]) -> [String: Any] {
        ["type": "event_msg", "timestamp": "2026-10-28T19:24:03.915Z", "payload":
            ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last, "model_context_window": 1_000]]]
    }

    @Test func appendingASecondReadingTailsOnlyNewBytesWithoutDuplicatingUsage() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-index-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
        let first = counts(100, 20, 10)
        let lines = try [line(["type": "session_meta", "payload": ["id": id, "cwd": "/fixture"]]),
                         line(["type": "turn_context", "payload": ["model": "gpt-test"]]), line(event(first, first))]
        try lines.joined().write(to: file, atomically: true, encoding: .utf8)
        let index = CodexUsageIndex(home: home)
        let initial = try await index.refresh(sessionIDs: [id])
        #expect(initial.complete)
        #expect(initial.sessions[id]?.total.total == 110)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let second = counts(250, 50, 30)
        let extra = try line(event(second, counts(150, 30, 20))) + line(event(second, counts(150, 30, 20)))
        try handle.write(contentsOf: Data(extra.utf8))
        try handle.close()
        let updated = try await index.refresh(sessionIDs: [id])
        #expect(updated.complete)
        #expect(updated.sessions[id]?.total.total == 280)
        #expect(updated.sessions[id]?.increments.map(\.tokens.total) == [110, 170])
        let unchanged = try await index.refresh(sessionIDs: [id])
        #expect(unchanged.bytesRead == 0)
        #expect(unchanged.sessions[id] == updated.sessions[id])
    }

    @Test func incompleteTailAndMissingSessionAreNotReportedAsComplete() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-index-partial-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
        try ((try line(["type": "session_meta", "payload": ["id": id, "cwd": "/fixture"]])) + "{unfinished")
            .write(to: file, atomically: true, encoding: .utf8)
        let index = CodexUsageIndex(home: home)
        let partial = try await index.refresh(sessionIDs: [id, UUID().uuidString])
        #expect(!partial.complete)
        #expect(partial.sessions[id]?.hasUsage == false)
        #expect(partial.sessions.count == 1)
    }

    @Test func sessionCacheAndIndexPassAreBoundedAndSayWhenCandidatesAreOmitted() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-index-cap-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let ids = (0...CodexUsageIndex.maximumSessions).map { _ in UUID().uuidString.lowercased() }
        for id in ids {
            let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
            try line(["type": "session_meta", "payload": ["id": id, "cwd": "/fixture"]])
                .write(to: file, atomically: true, encoding: .utf8)
        }
        let report = try await CodexUsageIndex(home: home).refresh(sessionIDs: ids)
        #expect(!report.complete)
        #expect(report.sessionsRequested == CodexUsageIndex.maximumSessions + 1)
        #expect(report.sessions.count == CodexUsageIndex.maximumSessions)
        #expect(report.bytesRead <= CodexUsageIndex.maximumBytes)
    }

}
