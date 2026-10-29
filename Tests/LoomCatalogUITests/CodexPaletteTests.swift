import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// Synthetic rollout records follow the recorded P0 schema, without provider transcripts.
@Suite struct CodexPaletteTests {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func withTranscript(_ objects: [[String: Any]], kind: HarnessTranscriptKind = .claude,
                                _ body: (PaletteTranscriptFile) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-palette-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rollout.jsonl")
        try (objects.map(line).joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        try body(PaletteTranscriptFile(sessionID: UUID(), path: path.path, title: "Session", project: nil, modified: Date(), kind: kind))
    }

    @Test func searchesOnlyTheWordsFromCodexUserAndAssistantMessages() throws {
        let records: [[String: Any]] = [
            ["type": "response_item", "timestamp": "2026-10-28T19:24:03.915Z", "payload":
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Please fix the amber parser"]]]],
            ["type": "response_item", "payload": ["type": "function_call_output", "output": "amber private tool output"]],
            ["type": "response_item", "payload": ["type": "reasoning", "summary": "amber hidden reasoning"]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content":
                [["type": "output_text", "text": "The amber parser is fixed."]]]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "amber duplicate"]],
        ]
        try withTranscript(records, kind: .codex) { file in
            let outcome = PaletteTranscriptScanner.scan(query: "amber", files: [file], budget: .first, shouldStop: { false })
            #expect(outcome.hits.count == 2)
            #expect(outcome.coverage.linesDecoded == 2, "tool output and reasoning stay outside the JSON decode path")
            #expect(outcome.hits.first?.snippet.role.label == "You")
            #expect(outcome.hits.last?.snippet.role.label == "Codex")
            #expect(outcome.hits.first?.snippet.before == "Please fix the ")
            #expect(outcome.hits.last?.snippet.after == " parser is fixed.")
            #expect(outcome.hits.first?.timestamp != nil)
        }
    }

    @Test func claudeTextAndToolFilteringStayTheSame() throws {
        try withTranscript([
            ["type": "user", "message": ["role": "user", "content": "amber user"]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "amber tool"]]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "amber answer"]]]],
        ]) { file in
            let result = PaletteTranscriptScanner.scan(query: "amber", files: [file], budget: .first, shouldStop: { false })
            #expect(result.hits.count == 2)
            #expect(result.hits.first?.snippet.role.label == "You")
            #expect(result.hits.last?.snippet.role.label == "Claude")
        }
    }

    @Test func aClaudeTranscriptDoesNotTreatCodexShapedRecordsAsClaudeSearchContent() throws {
        try withTranscript([
            ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "amber foreign record"]]]],
        ]) { file in
            let outcome = PaletteTranscriptScanner.scan(query: "amber", files: [file], budget: .first, shouldStop: { false })
            #expect(outcome.hits.isEmpty)
        }
    }

    @Test func aCodexRolloutDoesNotTreatClaudeShapedRecordsAsCodexSearchContent() throws {
        try withTranscript([
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "amber foreign record"]]]],
        ], kind: .codex) { file in
            let outcome = PaletteTranscriptScanner.scan(query: "amber", files: [file], budget: .first, shouldStop: { false })
            #expect(outcome.hits.isEmpty)
        }
    }

    @MainActor
    @Test func configuredRolloutReachesTheLivePaletteAndPeekWithoutAClaudeProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-consumers-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let nativeID = UUID().uuidString.lowercased()
        let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(nativeID).jsonl")
        let objects: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": nativeID, "cwd": root.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fix the amber parser"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "The amber parser works."]]]],
        ]
        try (objects.map(line).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .codex, providerConversationID: nativeID, workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Codex session", createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui.json")))
        defer { model.stop() }
        let record = CatalogSession(session: session, title: "Codex session", createdAt: Date(), lastUsedAt: Date(),
                                    lifecycle: .idle, pinned: false)
        let sources = LivePaletteSources(model: model, transcriptsDirectory: { nil })
        let unavailable = try await sources.searchTranscripts(query: "amber", budget: .first) { _ in }
        #expect(unavailable.hits.isEmpty && unavailable.coverage.unavailable)
        #expect(model.peekTarget(for: record) == nil)
        model.setCodexConfigDirectory(home)
        let outcome = try await sources.searchTranscripts(query: "amber", budget: .first) { _ in }
        #expect(outcome.hits.count == 2 && outcome.coverage.isComplete)
        #expect(outcome.hits.last?.snippet.role.label == "Codex")
        let store = model.sidebarPeek
        await store.load(record, model: model)
        #expect(store.tooltip(for: session.id) == "You: Fix the amber parser\nCodex: The amber parser works.")
        let projectID = UUID()
        let projectRecord = CatalogSession(session: session, title: "Codex session", createdAt: Date(), lastUsedAt: Date(),
                                           lifecycle: .idle, pinned: false, projectID: projectID)
        model.projectPage.projectID = projectID
        model.projectPage.records = [projectRecord]
        await model.loadProjectLastLine(projectRecord)
        #expect(model.projectPage.lastLines[session.id] == "The amber parser works.")
        #expect(ProjectLastLine.read(sessionID: nativeID, configDirectory: home, workingDirectory: root.path, kind: .codex)
                == "The amber parser works.")
        let nextHome = root.appendingPathComponent("second-home", isDirectory: true)
        let nextDay = nextHome.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: nextDay, withIntermediateDirectories: true)
        let nextFile = nextDay.appendingPathComponent("rollout-2026-10-28T19-24-03-\(nativeID).jsonl")
        let nextRecords: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": nativeID, "cwd": root.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Check the violet parser"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "The violet parser works."]]]],
        ]
        try (nextRecords.map(line).joined(separator: "\n") + "\n").write(to: nextFile, atomically: true, encoding: .utf8)
        model.setCodexConfigDirectory(nextHome)
        #expect(store.tooltip(for: session.id) == nil)
        #expect(model.projectPage.lastLines[session.id] == nil)
        await model.loadProjectLastLine(projectRecord)
        #expect(model.projectPage.lastLines[session.id] == "The violet parser works.")
        await store.load(record, model: model)
        #expect(store.tooltip(for: session.id) == "You: Check the violet parser\nCodex: The violet parser works.")
        let changed = try await sources.searchTranscripts(query: "violet", budget: .first) { _ in }
        #expect(changed.hits.count == 2 && changed.coverage.isComplete)
    }

}
