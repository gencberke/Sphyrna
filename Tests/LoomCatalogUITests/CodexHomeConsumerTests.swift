import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite struct CodexHomeConsumerTests {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    @Test func finishedFallbackReadsTheCurrentProfileAndDoesNotReplaceAMeaningfulReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-home-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        func home(_ name: String, answer: String) throws -> URL {
            let home = root.appendingPathComponent(name, isDirectory: true)
            let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
            let rows: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": id, "cwd": root.path]],
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content":
                    [["type": "input_text", "text": "Fix it"]]]],
                ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content":
                    [["type": "output_text", "text": answer]]]],
            ]
            try rows.map(line).joined().write(to: file, atomically: true, encoding: .utf8)
            return home
        }
        let first = try home("a", answer: "First answer")
        let second = try home("b", answer: "Second answer")
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .codex, providerConversationID: id, workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Codex", createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui.json")))
        defer { model.stop() }
        await model.start()
        model.select(session.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.selectedRow == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let row = try #require(model.selectedRow)
        let entry = HomeEntry(id: session.id, title: "Codex", projectName: nil, tone: nil, provider: .codex,
                              indicator: .unviewedCompletion, reason: nil, lastActivityAt: row.record.lastActivityAt,
                              allowsTranscriptFallback: true)
        model.setCodexConfigDirectory(first)
        let firstKey = try #require(model.homeTranscriptKey(for: entry))
        #expect(await model.homeTranscriptFallback(for: entry, key: firstKey) == "Codex: First answer")
        model.setCodexConfigDirectory(second)
        #expect(await model.homeTranscriptFallback(for: entry, key: firstKey) == nil)
        let secondKey = try #require(model.homeTranscriptKey(for: entry))
        #expect(firstKey != secondKey)
        #expect(await model.homeTranscriptFallback(for: entry, key: secondKey) == "Codex: Second answer")
        let meaningful = HomeEntry(id: session.id, title: "Claude", projectName: nil, tone: nil, provider: .claude,
                                   indicator: .unviewedCompletion, reason: SessionReasonLine(text: "Tests passed"),
                                   lastActivityAt: row.record.lastActivityAt)
        #expect(meaningful.line == "Tests passed")
        #expect(meaningful.displayedLine(fallback: "Claude: Another line") == "Tests passed")
        #expect(model.homeTranscriptKey(for: meaningful) == nil)
        #expect(HomeEntry.allowsFallback(indicator: .unviewedCompletion, reason: nil))
        #expect(HomeEntry.allowsFallback(indicator: .unviewedCompletion, reason: StatusReason(.turnDone)))
        #expect(!HomeEntry.allowsFallback(indicator: .unviewedCompletion, reason: StatusReason(.turnDone, detail: "Tests passed")))
        #expect(!HomeEntry.allowsFallback(indicator: .unviewedCompletion,
                                         reason: StatusReason(.turnDone, work: BackgroundWork(scheduled: 1))))
        #expect(!HomeEntry.allowsFallback(indicator: .failed(nil), reason: nil))
    }
}
