import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

private final class UsageWindowTestBundle: NSObject {}

@MainActor
@Suite(.serialized) struct UsageModelWindowTests {
    @Test func serverNamedWindowTravelsFromTheWireToTheDisplayedConsumers() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-model-wire-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let object: [String: Any] = ["type": "control_response", "response": ["subtype": "success", "request_id": "r1",
            "response": ["rate_limits": ["model_scoped": [["display_name": "Fable", "utilization": 100,
                                                            "resets_at": reset]]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard case let .answer(answer) = PlanLimitsWire.interpret(bytes, requestID: "r1") else {
            Issue.record("the model-scoped answer was lost before reaching the consumers")
            return
        }
        let fetcher = UsageHarnessTests.AccountFetcher()
        fetcher.set(PlanLimitsReading(limits: PlanLimits(fiveHour: answer.fiveHour, weekly: answer.weekly, fetchedAt: now,
                                                        modelWindows: answer.modelWindows,
                                                        modelWindowsComplete: answer.modelWindowsComplete),
                                      account: .subscription(email: "fixture@example.invalid", plan: "max")))
        let usage = UsageModel(index: FakeUsageIndex(), limits: fetcher, clock: { now })
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        model.usage = usage
        await usage.checkStatusLimits(of: .claude)
        let reading = try #require(usage.readings[.claude])
        #expect(UsageLimitsPage.group(harness: .claude, reading: reading, failure: nil, now: now, timeZone: .current)
            .cards.contains { $0.content.title == "Weekly · Fable" && $0.content.left == "0% left" })
        let status = try #require(usage.statusSegments.first { $0.harness == .claude })
        #expect(status.tightest?.name == "Weekly · Fable" && status.tightest?.remainingPercent == 0)
        #expect(usage.statusPaces(of: .claude, at: now).contains { $0.title == "Weekly · Fable" })
        let host = NSHostingController(rootView: HomeUsage(model: model).frame(width: 320, height: 500))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 320, height: 500))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(accessibilityElements(in: host.view).map(InkAX.label).contains { $0.contains("Weekly · Fable") && $0.contains("0% left") })
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func theRealReaderFeedsModelWindowsToTheUsageSurfaces() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-window-model-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Bundle(for: UsageWindowTestBundle.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-fake-provider").path
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let reset = formatter.string(from: now.addingTimeInterval(86_400))
        let toolchain = ProviderToolchain(provider: .claude, executable: fake,
            capabilities: ProviderCapabilities(version: "fake", help: ""),
            environment: ["PATH": "/usr/bin:/bin", "LOOM_FAKE_USAGE": "ok", "LOOM_FAKE_USAGE_FIVE": "0",
                          "LOOM_FAKE_USAGE_WEEK": "0", "LOOM_FAKE_USAGE_FIVE_RESET": reset,
                          "LOOM_FAKE_USAGE_WEEK_RESET": reset])
        let profile = ClaudeProfileLayout(profileDirectory: root.appendingPathComponent("profile"), environment: [:], home: root)
        let fetcher = ClaudePlanLimitsFetcher(toolchain: { toolchain }, profile: profile,
                                              workingDirectory: root.appendingPathComponent("probe"), clock: { now })
        let usage = UsageModel(index: FakeUsageIndex(), limits: fetcher, clock: { now })
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        model.usage = usage
        await usage.checkStatusLimits(of: .claude)
        let reading = try #require(usage.readings[.claude])
        let group = UsageLimitsPage.group(harness: .claude, reading: reading, failure: nil, now: now, timeZone: .current)
        #expect(group.cards.contains { $0.content.title == "Weekly · Opus" && $0.content.left == "95% left" })
        let status = try #require(usage.statusSegments.first { $0.harness == .claude })
        #expect(status.tightest?.name == "Weekly · Opus" && status.tightest?.remainingPercent == 95)
        #expect(usage.statusPaces(of: .claude, at: now).contains { $0.title == "Weekly · Opus" && $0.left == "95% left" })

        let hosting = NSHostingController(rootView: HomeUsage(model: model).frame(width: 320, height: 700))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 320, height: 700))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let labels = accessibilityElements(in: hosting.view).map(InkAX.label)
        #expect(labels.contains { $0.contains("Weekly · Opus") && $0.contains("95% left") })
        #expect(labels.contains { $0.contains("Some limits may be unavailable") })
        #expect(!window.isVisible && !window.isKeyWindow)

        let settings = NSHostingController(rootView: UsageLimitsView(groups: [group]).frame(width: 640, height: 600))
        settings.sizingOptions = []
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentViewController = settings
        settingsWindow.setContentSize(NSSize(width: 640, height: 600))
        defer { settingsWindow.close() }
        try await Task.sleep(for: .milliseconds(100))
        settings.view.layoutSubtreeIfNeeded()
        settingsWindow.displayIfNeeded()
        let settingsWords = accessibilityElements(in: settings.view).flatMap { [InkAX.value($0), InkAX.label($0)].compactMap { $0 } }
        #expect(settingsWords.contains {
            $0.contains("Weekly · Opus") && $0.contains("95% left")
        })
        #expect(settingsWords.contains { $0.contains("Some limits may be unavailable") })

        let host = InkHost()
        let split = NSViewController()
        split.view = NSView()
        let bar = NSHostingController(rootView: StatusBarView(model: model).inkHost(host))
        bar.sizingOptions = []
        let layout = StatusBarWindowLayout(split: split, bar: bar, overlays: [host.view], popoverHost: host)
        let barWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        barWindow.isReleasedWhenClosed = false
        barWindow.contentViewController = layout
        defer { barWindow.close() }
        try await Task.sleep(for: .milliseconds(100))
        layout.view.layoutSubtreeIfNeeded()
        barWindow.displayIfNeeded()
        let button = try #require(accessibilityElements(in: bar.view).first {
            $0.accessibilityRole?() == .button && InkAX.label($0).contains("Weekly · Opus")
        })
        #expect(button.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(100))
        layout.view.layoutSubtreeIfNeeded()
        barWindow.displayIfNeeded()
        #expect(host.state.active?.id == "status-limits-claude")
        #expect(accessibilityElements(in: host.view).map(InkAX.label).contains {
            $0.contains("Weekly · Opus") && $0.contains("95% left")
        })
        #expect(accessibilityElements(in: host.view).contains {
            (InkAX.value($0) ?? InkAX.label($0)).contains("Some limits may be unavailable")
        })
        #expect(!settingsWindow.isVisible && !barWindow.isVisible && !barWindow.isKeyWindow)
    }
}
