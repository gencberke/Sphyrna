import Foundation
import Testing
@testable import LoomCore

/// All files below are synthetic examples of P0's recorded rollout layout and schema.
@Suite struct CodexRolloutReaderTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-reader-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ home: URL, id: String, headerID: String? = nil, body: String = "") throws -> URL {
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(headerID ?? id)\",\"cwd\":\"/fixture\"}}\n"
        try (header + body).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func findsOnlyTheExactRecordedUUIDInsideTheConfiguredHome() throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        let wanted = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let exact = try write(home, id: wanted)
        _ = try write(home, id: other)
        let found = CodexRolloutLocator.locate(sessionIDs: [wanted], home: home)
        #expect(found.complete)
        #expect(found.files[wanted]?.path == exact.path)
        #expect(found.files.count == 1)
        #expect(CodexRolloutLocator.locate(sessionIDs: [String(wanted.prefix(8))], home: home).files.isEmpty)
        let elsewhere = try root()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        #expect(CodexRolloutLocator.locate(sessionIDs: [wanted], home: elsewhere).files.isEmpty)
    }

    @Test func refusesHeaderMismatchAndReportsAnExhaustedDiscoveryBudget() throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        let wanted = UUID().uuidString.lowercased()
        _ = try write(home, id: wanted, headerID: UUID().uuidString)
        #expect(CodexRolloutLocator.locate(sessionIDs: [wanted], home: home).files.isEmpty)
        let exhausted = CodexRolloutLocator.locate(sessionIDs: [wanted], home: home, maximumEntries: 1)
        #expect(!exhausted.complete)
    }

    @Test func onlyKnownAssistantMessagePhasesAreShownAsTranscriptText() {
        func message(_ phase: Any?) -> [String: Any] {
            var payload: [String: Any] = ["type": "message", "role": "assistant",
                                           "content": [["type": "output_text", "text": "answer"]]]
            if let phase { payload["phase"] = phase }
            return ["type": "response_item", "payload": payload]
        }
        for phase in ["commentary", "partial_answer", "final_answer"] {
            #expect(CodexRolloutText.message(in: message(phase))?.text == "answer")
        }
        #expect(CodexRolloutText.message(in: message(nil))?.text == "answer", "legacy records omit phase")
        #expect(CodexRolloutText.message(in: message(NSNull()))?.text == "answer", "legacy phase can also be null")
        #expect(CodexRolloutText.message(in: message("future_phase")) == nil)
        #expect(CodexRolloutText.message(in: message(42)) == nil)
        #expect(CodexRolloutText.message(in: ["type": "response_item", "payload": ["type": "reasoning", "content":
            [["type": "reasoning_text", "text": "private reasoning"]]]]) == nil)
    }

    @Test func tailPagesAreBoundedAndIgnoreAnUnfinishedLastLine() throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let file = try write(home, id: id, body: String(repeating: "x", count: 64 * 1024)
                             + "\n{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}}\n"
                             + "{\"type\":\"unfinished\"")
        let reader = try #require(CodexRolloutReader(file: CodexRolloutFile(path: file.path, sessionID: id)))
        defer { reader.close() }
        let page = reader.readBackward(pageBytes: 1024, maximumLineBytes: 512)
        let texts = page.records.compactMap(\.bytes).compactMap(CodexRolloutText.message(in:))
        #expect(texts.map(\.text) == ["answer"])
        #expect(!page.reachedStart)
        #expect(page.startOffset >= UInt64((try Data(contentsOf: file)).count - 1024))
        #expect(reader.bytesRead <= 1_025)
    }
}
