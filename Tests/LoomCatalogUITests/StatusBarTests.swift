import AppKit
import Foundation
import Observation
import Synchronization
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

@MainActor @Suite(.serialized) struct StatusBarTests {
    let now = Date(timeIntervalSince1970: 1_791_374_400)
    let zone = TimeZone(secondsFromGMT: 0)!

    @Test func cachedWindowsShowRemainingShareAndAllResetTimes() throws {
        let reading = HarnessReading(provider: .codex, windows: [
            .init(id: "first", name: "5-hour", durationMinutes: 300, usedPercent: 4, resetsAt: now.addingTimeInterval(3 * 3_600 + 39 * 60)),
            .init(id: "second", name: "Weekly", durationMinutes: 10_080, usedPercent: 96, resetsAt: now.addingTimeInterval(5 * 86_400)),
            .init(id: "expired", name: "Expired", durationMinutes: 60, usedPercent: 99, resetsAt: now.addingTimeInterval(-60))
        ], readAt: now)
        let segment = StatusBarUsage.make(harness: .codex, reading: reading, now: now)
        #expect(segment.windows.map(\.name) == ["5-hour", "Weekly"])
        #expect(segment.windows.map(\.remainingPercent) == [96, 4])
        #expect(segment.windows.map(\.reset) == ["3h 39m", "5d"])
        #expect(segment.tightest?.remainingPercent == 4)
        #expect(StatusBarUsage.paceLines(reading: reading, now: now, timeZone: zone).map(\.left) == ["96% left", "4% left"])
        #expect(segment.accessibilityLabel.contains("5-hour, 96% left"))
        #expect(segment.accessibilityLabel.contains("Weekly, 4% left"))
    }

    @Test func unknownDoesNotInferSignOutAndMissingResetStaysUnknown() throws {
        let unknown = StatusBarUsage.make(harness: .claude, reading: nil, now: now)
        #expect(unknown.windows.isEmpty)
        #expect(unknown.accessibilityLabel == "Claude, No limits read")
        let reading = HarnessReading(provider: .claude, windows: [
            .init(id: "plain", name: "30-minute", durationMinutes: 30, usedPercent: 20, resetsAt: nil)
        ], readAt: now)
        let segment = StatusBarUsage.make(harness: .claude, reading: reading, now: now)
        #expect(try #require(segment.windows.first).reset == nil)
        #expect(StatusBarUsage.paceLines(reading: reading, now: now, timeZone: zone).first?.sentence == "No reset time reported")
    }

    private func model() -> CatalogModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-status-\(UUID())")
        return CatalogModel(catalog: nil, events: SessionEventHub(),
                            preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
    }

    @Test func selectedHarnessRefreshAsksOnceAndNeverScans() async throws {
        let index = FakeUsageIndex()
        let clock = TestClock(now)
        let connections = HarnessConnections()
        let first = UsageHarnessTests.Scripted([UsageHarnessTests.codexAnswer(at: now)])
        let second = UsageHarnessTests.Scripted([UsageHarnessTests.codexAnswer(at: now)])
        let probe = HarnessProbe(connections: connections, sources: [.claude: first, .codex: second], clock: { clock.now })
        let usage = UsageModel(index: index, clock: { clock.now }, timeZone: zone)
        usage.attachHarness(probe: probe, connections: connections)
        #expect(usage.statusSegments.map(\.harness) == UsageModel.usageHarnesses)
        #expect(usage.statusSegments.allSatisfy { $0.windows.isEmpty })
        #expect(first.asks == 0 && second.asks == 0 && index.refreshCalls == 0)
        // Reading the popover's pace lines is pure too.
        #expect(usage.statusPaces(of: .codex, at: now).isEmpty)
        #expect(first.asks == 0 && second.asks == 0 && index.refreshCalls == 0)
        await usage.checkStatusLimits(of: .codex)
        #expect(first.asks == 0 && second.asks == 1 && index.refreshCalls == 0)
        let codex = try #require(usage.statusSegments.first { $0.harness == .codex })
        #expect(codex.windows.map(\.remainingPercent) == [77, 39])
        #expect(usage.statusPaces(of: .codex, at: now).map(\.left) == ["77% left", "39% left"])
        connections.setConnected(.codex, false)
        await usage.checkStatusLimits(of: .codex)
        #expect(second.asks == 1 && usage.statusPaces(of: .codex, at: now).isEmpty)
    }

    @Test func unchangedValuesDoNotPublishDuringAnExistingMinuteTick() async {
        let clock = TestClock(now)
        let connections = HarnessConnections()
        let source = UsageHarnessTests.Scripted([HarnessProbeAnswer(windows: [
            HarnessLimitWindow(id: "no-reset", name: "30-minute", durationMinutes: 30, usedPercent: 25, resetsAt: nil)
        ])])
        let probe = HarnessProbe(connections: connections, sources: [.codex: source], clock: { clock.now })
        let usage = UsageModel(index: FakeUsageIndex(), clock: { clock.now }, timeZone: zone)
        usage.attachHarness(probe: probe, connections: connections)
        await usage.checkStatusLimits(of: .codex)
        usage.windowActivityChanged(false)
        let changes = Mutex(0)
        withObservationTracking { _ = usage.statusSegments } onChange: { changes.withLock { $0 += 1 } }
        clock.advance(60)
        usage.minuteTick()
        #expect(changes.withLock { $0 } == 0)
        #expect(source.asks == 1)
    }

    @Test func anIdenticalReadingAtALaterMinuteDoesNotRepublishTheClosedBar() async throws {
        let clock = TestClock(now)
        let connections = HarnessConnections()
        let source = UsageHarnessTests.Scripted([HarnessProbeAnswer(windows: [
            HarnessLimitWindow(id: "no-reset", name: "30-minute", durationMinutes: 30, usedPercent: 25, resetsAt: nil)
        ])])
        let probe = HarnessProbe(connections: connections, sources: [.codex: source], clock: { clock.now })
        let usage = UsageModel(index: FakeUsageIndex(), clock: { clock.now }, timeZone: zone)
        usage.attachHarness(probe: probe, connections: connections)
        await usage.checkStatusLimits(of: .codex)
        let changes = Mutex(0)
        withObservationTracking { _ = usage.statusSegments } onChange: { changes.withLock { $0 += 1 } }
        clock.advance(60)
        await usage.checkStatusLimits(of: .codex)
        #expect(source.asks == 2 && usage.readings[.codex]?.readAt == clock.now)
        #expect(changes.withLock { $0 } == 0)
    }

    @Test func existingMinuteTickUpdatesChangedResetTextWithoutAProbe() async throws {
        let clock = TestClock(now)
        let connections = HarnessConnections()
        let source = UsageHarnessTests.Scripted([HarnessProbeAnswer(windows: [
            HarnessLimitWindow(id: "five", name: "5-hour", durationMinutes: 300, usedPercent: 25,
                               resetsAt: now.addingTimeInterval(3 * 3_600))
        ])])
        let probe = HarnessProbe(connections: connections, sources: [.codex: source], clock: { clock.now })
        let usage = UsageModel(index: FakeUsageIndex(), clock: { clock.now }, timeZone: zone)
        usage.attachHarness(probe: probe, connections: connections)
        await usage.checkStatusLimits(of: .codex)
        usage.windowActivityChanged(false)
        #expect(try #require(usage.statusSegments.first { $0.harness == .codex }).windows.first?.reset == "3h")
        let changes = Mutex(0)
        withObservationTracking { _ = usage.statusSegments } onChange: { changes.withLock { $0 += 1 } }
        clock.advance(60)
        usage.minuteTick()
        #expect(try #require(usage.statusSegments.first { $0.harness == .codex }).windows.first?.reset == "2h 59m")
        #expect(changes.withLock { $0 } == 1 && source.asks == 1)
    }

    @Test func actualWindowContainerSpansAndHidesTheBarAndOverlays() {
        let panes = NSSplitViewController()
        let left = NSSplitViewItem(viewController: NSViewController())
        let right = NSSplitViewItem(viewController: NSViewController())
        left.viewController.view = NSView()
        right.viewController.view = NSView()
        left.canCollapse = true
        panes.addSplitViewItem(left)
        panes.addSplitViewItem(right)
        let bar = NSViewController()
        bar.view = NSView()
        let overlay = NSView()
        let root = StatusBarWindowLayout(split: panes, bar: bar, overlays: [overlay])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        defer { window.close() }
        func layout() { root.view.layoutSubtreeIfNeeded() }
        layout()
        #expect(!window.isVisible)
        #expect(bar.view.frame.width == root.view.bounds.width && bar.view.frame.height == 26)
        #expect(panes.view.frame.height + bar.view.frame.height == root.view.bounds.height)
        #expect(overlay.frame == root.view.bounds)
        left.isCollapsed = true
        layout()
        #expect(bar.view.frame.width == root.view.bounds.width)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        layout()
        #expect(bar.view.isHidden && bar.view.frame.height == 0)
        #expect(panes.view.frame.height == root.view.bounds.height && overlay.frame == root.view.bounds)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        layout()
        #expect(!bar.view.isHidden && bar.view.frame.height == 26)
    }

    @Test func cachedWorkingCountAndMenuIncludeOffscreenLiveSessions() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        var ids: [UUID] = []
        for n in 0..<7 {
            let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
            ids.append(session.id)
            let stamp = now.addingTimeInterval(Double(n))
            model.liveRecords[session.id] = CatalogSession(session: session, title: "Session \(n)", createdAt: stamp,
                                                          lastUsedAt: stamp, lifecycle: .active, pinned: false, projectID: nil)
            model.liveStates[session.id] = SessionViewState(status: ProviderWorkState(activity: .working), runID: UUID())
        }
        model.updateAttentionCount()
        #expect(model.rowModels.isEmpty && model.workingSessionCount == 7)
        let menu = StatusBarWorkingMenu.state(model: model)
        #expect(menu.working.map(\.id) == Array(ids.reversed().prefix(MenuBarState.maxRows)))
        #expect(menu.workingMore == 2)
        StatusBarWorkingMenu.select(menu.working[0].id, model: model)
        #expect(model.selectedSessionID == ids.last)
        model.setViewMode(.projects)
        model.setSearchText("filter")
        model.setSidebarCollapsed(true)
        var expanded = false
        model.onToggleSidebar = { expanded = true; model.setSidebarCollapsed(false) }
        StatusBarWorkingMenu.showMore(model: model)
        #expect(model.viewMode == .activity && model.searchText.isEmpty && expanded && !model.sidebarCollapsed)
        let changes = Mutex(0)
        withObservationTracking { _ = model.workingSessionCount } onChange: { changes.withLock { $0 += 1 } }
        model.liveStates[ids[0]]?.turnStartedAt = now
        model.updateAttentionCount()
        #expect(changes.withLock { $0 } == 0)
        model.liveStates[ids[0]] = nil
        model.updateAttentionCount()
        #expect(model.workingSessionCount == 6 && changes.withLock { $0 } == 1)
    }

    #if DEBUG
    @Test(.renderProbe) func closedHostedBarDoesNotRedrawForAnUnrelatedLiveHook() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 1, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let id = try #require(rig.everyID.first)
        try await rig.feed(.runStarted(UUID()), for: id)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: id)
        #expect(rig.model.workingSessionCount == 1)
        StatusBarRenderProbe.watch(rig.model)
        defer { StatusBarRenderProbe.watch(nil) }
        let bar = NSHostingController(rootView: StatusBarView(model: rig.model))
        bar.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 26), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = bar
        defer { window.close() }
        func draw() { bar.view.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        await waitFor("the bar and its working count to draw") {
            draw()
            return StatusBarRenderProbe.rootBodies > 0 && StatusBarRenderProbe.workingBodies > 0
        }
        let before = (StatusBarRenderProbe.rootBodies, StatusBarRenderProbe.workingBodies, StatusBarRenderProbe.menuBodies)
        #expect(before.0 > 0 && before.1 > 0 && !window.isVisible)
        let revision = rig.model.liveRevision
        try await rig.feed(.reason(StatusReason(.automaticTurn, detail: "Background command finished")), for: id)
        #expect(rig.model.liveRevision > revision && rig.model.workingSessionCount == 1)
        // The negative window: for 150 ms of drawing, the reason re-evaluates no part of the bar.
        await holds("no part of the bar re-evaluates for a reason that changes nothing it shows", for: .milliseconds(150)) {
            draw()
            return StatusBarRenderProbe.rootBodies == before.0 && StatusBarRenderProbe.workingBodies == before.1
                && StatusBarRenderProbe.menuBodies == before.2
        }
        #expect(StatusBarRenderProbe.rootBodies == before.0)
        #expect(StatusBarRenderProbe.workingBodies == before.1)
        #expect(StatusBarRenderProbe.menuBodies == before.2)
    }
    #endif

    @Test func updatesRequireARealVersionAndTheHealthRecommendation() {
        let recommended = HarnessHealth(provider: .claude, state: .ready, headline: "", version: [1],
                                        versionStatus: .belowRecommended)
        let required = HarnessHealth(provider: .codex, state: .attention, headline: "", version: [1],
                                     versionStatus: .belowMinimum)
        let unknown = HarnessHealth(provider: .codex, state: .checking, headline: "", versionStatus: .belowRecommended)
        let current = HarnessHealth(provider: .codex, state: .ready, headline: "", version: [2], versionStatus: .current)
        let off = HarnessHealth(provider: .codex, state: .disabled, headline: "", version: [1], versionStatus: .belowMinimum)
        #expect(StatusBarUpdates.recommendations([unknown, current, recommended, off, required]) == [recommended, required])
    }

    @Test func settingsHelpAndKeepAwakeUseExistingRoutes() async throws {
        enableAccessibilityTree()
        let model = model()
        var openedSettings = false
        model.onShowSettings = { _ in openedSettings = true }
        let target = HelpTarget()
        let menu = NSMenu(title: "Help")
        let item = menu.addItem(withTitle: "Collect Diagnostics…", action: #selector(HelpTarget.run(_:)), keyEquivalent: "")
        item.target = target
        let originalHelp = NSApp.helpMenu
        NSApp.helpMenu = menu
        defer { NSApp.helpMenu = originalHelp }
        let status = NSHostingController(rootView: StatusBarView(model: model))
        status.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 26), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = status
        window.setContentSize(NSSize(width: 280, height: 26))
        defer { window.close() }
        func draw() { status.view.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func briefLine() -> Bool {
            accessibilityElements(in: status.view).contains {
                $0.accessibilityRole?() == .staticText && (InkAX.value($0) ?? InkAX.label($0)) == "Remora is reading a brief"
            }
        }
        await waitFor("the bar's Settings button") {
            draw()
            return accessibilityElements(in: status.view).contains { InkAX.label($0) == "Settings" }
        }
        let elements = accessibilityElements(in: status.view)
        let settings = try #require(elements.first { InkAX.label($0) == "Settings" })
        #expect(elements.contains { InkAX.label($0) == "Help" })
        #expect(abs(settings.accessibilityFrame().height - 24) < 1)
        #expect(settings.accessibilityPerformPress?() == true && openedSettings)
        #expect(!window.isVisible)
        menu.performActionForItem(at: 0)
        #expect(target.calls == 1)

        let toggle = try #require(accessibilityElements(in: status.view).first { InkAX.label($0) == "Keep Mac awake" })
        #expect(abs(toggle.accessibilityFrame().height - 24) < 1)
        #expect(model.integration.keepAwake == .off)
        #expect(toggle.accessibilityPerformPress?() == true)
        #expect(model.integration.keepAwake == .whileWorking)
        model.integration.setKeepAwake(.off)
        #expect(model.integration.keepAwake == .off)
        model.remora.phase = .briefing
        await waitFor("the bar to say Remora is reading a brief") { draw(); return briefLine() }
        model.remora.phase = .asking
        await waitFor("the brief line to go when Remora asks instead") { draw(); return !briefLine() }
    }

    @Test func usagePopoverUsesTheWindowHostAndClosesForEscapeDisconnectAndFullScreen() async throws {
        enableAccessibilityTree()
        let model = model()
        let connections = HarnessConnections()
        let index = FakeUsageIndex()
        let readAt = Date()
        let clock = TestClock(readAt)
        let source = UsageHarnessTests.Scripted([HarnessProbeAnswer(windows: [
            HarnessLimitWindow(id: "five", name: "5-hour", durationMinutes: 300, usedPercent: 50,
                               resetsAt: readAt.addingTimeInterval(3 * 3_600))
        ])])
        let probe = HarnessProbe(connections: connections, sources: [.claude: source], clock: { clock.now })
        let usage = UsageModel(index: index, clock: { clock.now })
        usage.attachHarness(probe: probe, connections: connections)
        await usage.checkStatusLimits(of: .claude)
        model.usage = usage
        var openedUsage = false
        model.onShowSettings = { openedUsage = $0 == .usage }
        let host = InkHost()
        let panes = NSViewController()
        panes.view = NSView()
        let bar = NSHostingController(rootView: StatusBarView(model: model).inkHost(host))
        bar.sizingOptions = []
        let root = StatusBarWindowLayout(split: panes, bar: bar, overlays: [host.view], popoverHost: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        defer { window.close() }
        func draw() { root.view.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func claudeButton() -> AnyObject? {
            accessibilityElements(in: bar.view).first { InkAX.label($0).contains("Claude, 5-hour, 50% left") }
        }
        func popoverShows(_ text: String) -> Bool {
            accessibilityElements(in: host.view).contains { (InkAX.value($0) ?? InkAX.label($0)) == text }
        }
        func pressClaude(_ why: String) async throws {
            await waitFor("the Claude limit button (\(why))") { draw(); return claudeButton() != nil }
            #expect(try #require(claudeButton()).accessibilityPerformPress?() == true)
            await waitFor("the Claude popover to open (\(why))") {
                draw()
                return host.state.active?.id == "status-limits-claude" && popoverShows("Check Again")
            }
        }
        try await pressClaude("first open")
        #expect(!window.isVisible)
        let popoverElements = accessibilityElements(in: host.view)
        let check = try #require(popoverElements.first { InkAX.label($0) == "Check Again" })
        #expect(popoverElements.contains { InkAX.label($0) == "5-hour, 50% left" })
        #expect(popoverElements.contains { (InkAX.value($0) ?? InkAX.label($0)) == "Read \(UsageText.time(readAt, usage.timeZone))" })
        #expect(source.asks == 1 && index.refreshCalls == 0, "opening the popover asks nothing")
        clock.advance(60)
        #expect(check.accessibilityPerformPress?() == true)
        let readNow = "Read \(UsageText.time(clock.now, usage.timeZone))"
        await waitFor("Check Again to read once more and show \(readNow)") {
            draw()
            return source.asks == 2 && popoverShows(readNow)
        }
        #expect(source.asks == 2 && index.refreshCalls == 0)
        let updatedElements = accessibilityElements(in: host.view)
        #expect(updatedElements.contains {
            (InkAX.value($0) ?? InkAX.label($0)) == "Read \(UsageText.time(clock.now, usage.timeZone))"
        })
        let openUsage = try #require(updatedElements.first { InkAX.label($0) == "Open Usage" })
        #expect(openUsage.accessibilityPerformPress?() == true)
        await waitFor("Open Usage to open the Usage page and close the popover") { draw(); return openedUsage && host.state.active == nil }
        try await pressClaude("before Escape")
        #expect(host.state.handle(.escape))
        #expect(host.state.active == nil)
        try await pressClaude("before a disconnect")
        connections.setConnected(.claude, false)
        await waitFor("a disconnect to close the popover") { draw(); return host.state.active == nil }
        connections.setConnected(.claude, true)
        try await pressClaude("before full screen")
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        await waitFor("entering full screen to close the popover") { draw(); return host.state.active == nil }
        #expect(!window.isVisible)
    }

    private final class HelpTarget: NSObject {
        var calls = 0
        @objc func run(_ sender: Any?) { calls += 1 }
    }

}
