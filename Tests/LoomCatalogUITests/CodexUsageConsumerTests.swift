import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

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

        let generation = model.codexConfigGeneration
        model.setCodexConfigDirectory(home, refresh: true)
        #expect(model.codexConfigGeneration > generation)
        #expect(usage.sessionUsage(conversationID: id, kind: .codex) == nil,
                "an account or profile revision at the same path discards the old projection")
        await usage.loadSessionUsage(conversationID: id, kind: .codex)

        let revision = model.codexConfigGeneration
        let firstAccount = HarnessAccount.subscription(email: "first@example.invalid", plan: "test")
        model.applyCodexTranscriptAccount(firstAccount)
        model.applyCodexTranscriptAccount(firstAccount)
        #expect(model.codexConfigGeneration == revision, "unchanged probe answers keep the cached reader")
        model.applyCodexTranscriptAccount(.subscription(email: "second@example.invalid", plan: "test"))
        #expect(model.codexConfigGeneration > revision)
        #expect(usage.recordedModel(conversationID: id, kind: .codex) == nil)
        #expect(usage.sessionUsage(conversationID: id, kind: .codex) == nil)
        await usage.loadSessionUsage(conversationID: id, kind: .codex)

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

        // Host the actual local card: reasoning is a subset of output, and recorded dates feed the local daily bars.
        enableAccessibilityTree()
        let card = UsageCodexCardView(card: .message(UsageLimitMessage(title: "No account totals", detail: nil)),
                                      period: .days7, timeZone: TimeZone(secondsFromGMT: 0)!, local: summary)
        let hosting = NSHostingController(rootView: card.frame(width: 680, height: 700))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 680, height: 700))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let words = accessibilityElements(in: hosting.view).flatMap { [InkAX.value($0), InkAX.label($0)].compactMap { $0 } }
        #expect(words.contains { $0.contains("Reasoning 2") && $0.contains("included in output") })
        #expect(words.contains { $0.contains("Tokens per day") && $0.contains("110") })
        #expect(!window.isVisible && !window.isKeyWindow)

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

    @Test func localDaysAndModelsUseRecordedDeltasAndKeepMissingReasoningUnknown() throws {
        func data(_ row: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) }
        func event(_ timestamp: String, total: [String: Int], last: [String: Int]) -> [String: Any] {
            ["type": "event_msg", "timestamp": timestamp,
             "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last]]]
        }
        let first = ["input_tokens": 100, "cached_input_tokens": 20, "cache_write_input_tokens": 5,
                     "output_tokens": 10, "reasoning_output_tokens": 2, "total_tokens": 110]
        var total = ["input_tokens": 160, "cached_input_tokens": 30, "cache_write_input_tokens": 5,
                     "output_tokens": 20, "total_tokens": 180]
        var last = ["input_tokens": 60, "cached_input_tokens": 10, "cache_write_input_tokens": 0,
                    "output_tokens": 10, "total_tokens": 70]
        var parser = CodexUsageParser()
        parser.consume(try data(["type": "turn_context", "payload": ["model": "model-a"]]))
        parser.consume(try data(event("2026-10-27T19:00:00Z", total: first, last: first)))
        parser.consume(try data(["type": "turn_context", "payload": ["model": "model-b"]]))
        parser.consume(try data(event("2026-10-28T19:00:00Z", total: total, last: last)))
        let now = ISO8601DateFormatter().date(from: "2026-10-29T00:00:00Z")!
        let report = CodexUsageIndexReport(sessions: ["fixture": parser.reading], complete: true, sessionsRequested: 1, bytesRead: 0)
        let summary = CodexLocalSummary.make(report: report, period: .days7, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(summary.tokens.total == 180 && summary.tokens.output == 20 && summary.reasoningTokens == nil)
        #expect(summary.models.map(\.name) == ["model-a", "model-b"])
        #expect(summary.models.map(\.reasoningTokens) == [2, nil])
        #expect(summary.models.map { $0.tokens.total } == [110, 70])
        #expect(summary.bars.map(\.tokens).suffix(3) == [110, 70, 0])

        let partial = CodexUsageIndexReport(sessions: report.sessions, complete: false, sessionsRequested: 1, bytesRead: 0)
        #expect(CodexLocalSummary.make(report: partial, period: .days7, now: now, timeZone: TimeZone(secondsFromGMT: 0)!).bars.isEmpty)

        total["reasoning_output_tokens"] = 5
        last["reasoning_output_tokens"] = 3
        var complete = CodexUsageParser()
        complete.consume(try data(["type": "turn_context", "payload": ["model": "model-a"]]))
        complete.consume(try data(event("2026-10-27T19:00:00Z", total: first, last: first)))
        complete.consume(try data(["type": "turn_context", "payload": ["model": "model-b"]]))
        complete.consume(try data(event("2026-10-28T19:00:00Z", total: total, last: last)))
        let all = CodexUsageIndexReport(sessions: ["fixture": complete.reading], complete: true, sessionsRequested: 1, bytesRead: 0)
        let known = CodexLocalSummary.make(report: all, period: .days7, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(known.reasoningTokens == 5 && known.tokens.total == 180, "reasoning is already included in output")
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
