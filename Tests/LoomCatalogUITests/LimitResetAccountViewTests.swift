import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite struct LimitResetAccountViewTests {
    @Test func settingsExplainsAnUnknownAccountAndClearsTheNoticeWhenItIsKnown() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-reset-account-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), reset = Date().addingTimeInterval(3_600)
        let window = HarnessLimitWindow(id: "five_hour", name: "5-hour", durationMinutes: 300, usedPercent: 100, resetsAt: reset)
        let source = UsageHarnessTests.Scripted([HarnessProbeAnswer(account: .subscription(email: nil, plan: "max"), windows: [window])])
        let connections = HarnessConnections()
        let probe = HarnessProbe(connections: connections, sources: [.claude: source], clock: { now })
        let usage = UsageModel(index: FakeUsageIndex(), clock: { now })
        usage.attachHarness(probe: probe, connections: connections)
        await usage.checkStatusLimits(of: .claude)
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("preferences.json"))
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: preferences)
        model.integration.attach(preferences: preferences)
        model.integration.setNotifyLimitResets(true)
        model.usage = usage
        let host = NSHostingController(rootView: SystemSettingsCard(model: model, integration: model.integration)
            .frame(width: 650, height: 950))
        host.sizingOptions = []
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 950), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 650, height: 950))
        defer { panel.close() }
        func words() -> [String] {
            host.view.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            return accessibilityElements(in: host.view).flatMap { [InkAX.value($0), InkAX.label($0)].compactMap { $0 } }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(words().contains { $0.contains("Claude's account identity is not available") })
        source.set([HarnessProbeAnswer(account: .subscription(email: "fixture@example.invalid", plan: "max"), windows: [window])])
        await usage.checkStatusLimits(of: .claude)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!words().contains { $0.contains("Claude's account identity is not available") })
        #expect(source.asks == 1 && !panel.isVisible && !panel.isKeyWindow)
    }
}
