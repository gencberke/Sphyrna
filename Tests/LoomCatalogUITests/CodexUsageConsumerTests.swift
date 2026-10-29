import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite struct CodexUsageConsumerTests {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    @Test func configuredRolloutFeedsOverviewAndTheSeparateLocalUsageSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-usage-consumer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("codex", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
        let counts = ["input_tokens": 100, "cached_input_tokens": 20, "cache_write_input_tokens": 5,
                      "output_tokens": 10, "reasoning_output_tokens": 2, "total_tokens": 110]
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": root.path]],
            ["type": "turn_context", "payload": ["model": "gpt-test"]],
            ["type": "event_msg", "timestamp": "2026-10-28T19:24:03.915Z", "payload":
                ["type": "token_count", "info": ["total_token_usage": counts, "last_token_usage": counts,
                                               "model_context_window": 1_000]]],
        ]
        try records.map(line).joined().write(to: file, atomically: true, encoding: .utf8)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .codex, providerConversationID: id, workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Codex", createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui.json")))
        defer { model.stop() }
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        let index = ClaudeUsageIndex(databaseURL: root.appendingPathComponent("usage.sqlite"),
                                     profile: ClaudeProfileLayout(profileDirectory: claude, environment: [:], home: root))
        let usage = UsageModel(index: index)
        let connections = HarnessConnections()
        usage.attachHarness(probe: HarnessProbe(connections: connections, sources: [:]), connections: connections)
        model.usage = usage
        await usage.loadSessionUsage(conversationID: id, kind: .codex)
        #expect(usage.sessionUsageFailed(conversationID: id, kind: .codex))
        model.setCodexConfigDirectory(home)
        await usage.loadSessionUsage(conversationID: id, kind: .codex)
        let sessionUsage = try #require(usage.sessionUsage(conversationID: id, kind: .codex))
        #expect(sessionUsage.total.tokens.total == 110)
        #expect(!sessionUsage.partial && !sessionUsage.subagentBreakdownKnown)
        #expect(!sessionUsage.main.messageCountKnown)
        #expect(OverviewUsageText(sessionUsage).rows.map(\.title) == ["Session"])
        #expect(usage.contextUsage(conversationID: id, kind: .codex) == ContextUsage(tokens: 100, window: 1_000, model: "gpt-test"))
        #expect(usage.sessionUsage(conversationID: id, kind: .claude) == nil)

        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
        usage.selectSection(.tokens)
        let deadline = ContinuousClock.now + .seconds(5)
        while usage.codexLocalReport == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let report = try #require(usage.codexLocalReport)
        let now = ISO8601DateFormatter().date(from: "2026-10-29T00:00:00Z")!
        let summary = CodexLocalSummary.make(report: report, period: .days7, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(!summary.partial && summary.sessions == 1)
        #expect(summary.tokens.total == 110 && summary.models.map(\.name) == ["gpt-test"])
        #expect(summary.tokens.input == 75 && summary.tokens.cacheRead == 20 && summary.tokens.cacheWrite == 5)
        let recordedModel = try #require(usage.recordedModel(conversationID: id, kind: .codex))
        let overview = InspectorOverviewContent(status: "Ready", createdAt: now, now: now, provider: .codex,
            claudeVersion: nil, model: nil, recordedModel: recordedModel, reportedMode: nil, launchedMode: nil,
            reportedEffort: nil, launchedEffort: nil, project: nil, branch: nil, base: nil, directory: root.path,
            edits: nil, readsEdits: true, subagents: nil)
        #expect(overview.model == "gpt-test")
        #expect(overview.modelIsRecorded)
        usage.setSettingsWindowVisible(false)
    }

    @Test func failedSessionReadsStayWithinTheSameBoundedProjectionCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-usage-bound-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ClaudeProfileLayout(profileDirectory: root, environment: [:], home: root)
        let index = ClaudeUsageIndex(databaseURL: root.appendingPathComponent("usage.sqlite"), profile: profile)
        let usage = UsageModel(index: index)
        let ids = (0...CodexUsageIndex.maximumSessions).map { _ in UUID().uuidString }
        for id in ids { await usage.loadSessionUsage(conversationID: id, kind: .codex) }
        #expect(usage.codexSessionUsageFailures.count == CodexUsageIndex.maximumSessions)
        #expect(!usage.codexSessionUsageFailures.contains(ids[0]))
        #expect(usage.codexSessionUsageFailures.contains(ids[ids.count - 1]))
    }

    @Test func aDisconnectedCodexDoesNotStartTheHiddenLocalUsageScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-off-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let profile = ClaudeProfileLayout(profileDirectory: root, environment: [:], home: root)
        let index = ClaudeUsageIndex(databaseURL: root.appendingPathComponent("usage.sqlite"), profile: profile)
        let connections = HarnessConnections(disconnected: [.codex])
        let probe = HarnessProbe(connections: connections, sources: [:])
        let usage = UsageModel(index: index)
        usage.attachHarness(probe: probe, connections: connections)
        usage.configureCodex(home: root, catalog: catalog)
        usage.setSettingsWindowVisible(true)
        usage.setUsageSectionSelected(true)
        usage.selectSection(.tokens)
        await usage.settle()
        #expect(usage.codexLocalReport == nil)
        connections.setConnected(.codex, true)
        usage.codexAvailabilityChanged()
        await usage.settle()
        #expect(usage.codexLocalReport != nil)
        usage.setSettingsWindowVisible(false)
    }

}
