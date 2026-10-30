import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// S3 (r9 closing optimizer): the header's model segment of a Codex session shows the model and context its rollout
/// recorded, read for the header itself (the Overview closed), and Codex's ids never reach Claude's usage index.
@MainActor
@Suite struct HeaderCodexReadingTests {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    @Test func aCodexHeaderShowsTheRecordedModelAndContextAndClaudeKeepsItsIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-header-codex-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("codex", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let codexID = UUID().uuidString.lowercased()
        let counts = ["input_tokens": 400, "cached_input_tokens": 0, "output_tokens": 10, "total_tokens": 410]
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": codexID, "cwd": root.path]],
            ["type": "turn_context", "payload": ["model": "gpt-test"]],
            ["type": "event_msg", "timestamp": "2026-10-28T19:24:03.915Z", "payload":
                ["type": "token_count", "info": ["total_token_usage": counts, "last_token_usage": counts,
                                               "model_context_window": 1_000]]],
        ]
        try records.map(line).joined()
            .write(to: day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(codexID).jsonl"), atomically: true, encoding: .utf8)

        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let codex = ManagedSession(provider: .codex, providerConversationID: codexID, workingDirectory: root.path)
        let claude = ManagedSession(provider: .claude, providerConversationID: "conv-claude", workingDirectory: root.path)
        for (session, title) in [(codex, "Codex"), (claude, "Claude")] {
            try await catalog.insertSession(session, title: title, createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui.json")))
        defer { model.stop() }
        let index = ClaudeUsageIndex(databaseURL: root.appendingPathComponent("usage.sqlite"),
                                     profile: ClaudeProfileLayout(profileDirectory: root.appendingPathComponent("claude"),
                                                                  environment: [:], home: root))
        let usage = UsageModel(index: index)
        let connections = HarnessConnections()
        usage.attachHarness(probe: HarnessProbe(connections: connections, sources: [:]), connections: connections)
        model.usage = usage
        model.setCodexConfigDirectory(home)
        await model.start()
        await waitFor("both sessions to have rows") { model.rowModels[codex.id] != nil && model.rowModels[claude.id] != nil }
        let codexRow = try #require(model.rowModels[codex.id])
        #expect(model.headerShowsModelSegment(codexRow), "a Codex session reads its context, so the header has the segment")
        #expect(model.modelContent(of: codexRow.record)?.usage == nil, "nothing is read before the header shows")

        // Only the header's segment is shown: the Overview never opens, and the segment reads the rollout itself.
        let hosting = NSHostingController(rootView: HeaderModelSegment(model: model, row: codexRow).frame(width: 400, height: 40))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer { window.close() }
        let reading = ContextUsage(tokens: 400, window: 1_000, model: "gpt-test")
        let content = await waitFor("the Codex header to show the recorded reading", observe: { () -> HeaderModelContent? in
            hosting.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return model.modelContent(of: codexRow.record)
        }, until: { $0?.usage == reading })
        #expect(content?.name == "gpt-test", "the recorded model, by its id where the Codex catalog has no title")
        #expect(content?.accessibilityLabel == "Model gpt-test, \(ContextRingText.spoken(reading))", "the ring is drawn")
        #expect(!window.isVisible && !window.isKeyWindow)

        // The Claude index is asked only for Claude sessions.
        model.select(codex.id)
        model.setInspector(open: true, for: codex.id)
        #expect(model.inspectorContextSessions.isEmpty, "a Codex id never reaches the Claude index")
        model.select(claude.id)
        model.setInspector(open: true, for: claude.id)
        #expect(model.inspectorContextSessions == ["conv-claude"], "a Claude session is tracked as before")
        let claudeRow = try #require(model.rowModels[claude.id])
        #expect(model.modelContent(of: claudeRow.record) == nil, "a Claude session with no reading and no launch model has none")
    }
}
