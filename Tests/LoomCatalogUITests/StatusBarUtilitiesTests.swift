import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

extension StatusBarTests {
/// The actual main-window root, serialized with the other test that temporarily replaces NSApp.helpMenu.
@MainActor @Suite(.serialized) struct StatusBarUtilitiesTests {
    private final class HelpMenu: NSMenu {
        private(set) weak var anchor: NSView?
        private(set) var location: NSPoint?
        private(set) var calls = 0
        private(set) var openedDuringPress = false
        private(set) var usedAppMenu = true
        var performingPress = false
        var onOpen: (() -> Void)?

        override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
            calls += 1
            anchor = view
            self.location = location
            openedDuringPress = openedDuringPress || performingPress
            usedAppMenu = usedAppMenu && NSApp.helpMenu === self
            let action = onOpen
            onOpen = nil
            action?()
            return true
        }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

    private func buttons(_ label: String, in view: NSView) -> [AnyObject] {
        accessibilityElements(in: view).filter { $0.accessibilityRole?() == .button && InkAX.label($0) == label }
    }

    @Test func helpReturnsBeforeMenuTrackingAndIgnoresStaleOrRepeatedPresses() async throws {
        enableAccessibilityTree()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-status-help-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: directory.appendingPathComponent("preferences.json")))
        defer { model.stop() }
        let menu = HelpMenu(title: "Help")
        let originalHelp = NSApp.helpMenu
        NSApp.helpMenu = menu
        defer { NSApp.helpMenu = originalHelp }
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
        window.setContentSize(NSSize(width: 900, height: 600))
        defer { host.state.dismiss(); window.close() }
        try await settle(window)
        #expect(!window.isVisible && !window.isKeyWindow)
        let help = try #require(buttons("Help", in: bar.view).first)
        func press() -> Bool {
            menu.performingPress = true
            defer { menu.performingPress = false }
            return help.accessibilityPerformPress?() == true
        }
        // Simulate a second activation while the menu's nested tracking loop is active.
        menu.onOpen = { #expect(press()) }
        #expect(press())
        #expect(menu.calls == 0, "the accessibility action must return before menu tracking begins")
        #expect(press())
        #expect(menu.calls == 0, "another pending press must not open another menu")
        try await settle(window)
        #expect(menu.calls == 1 && !menu.openedDuringPress && menu.usedAppMenu,
                "one deferred popup uses the actual app Help menu, including during a repeated active press")
        if let anchor = menu.anchor {
            #expect(anchor.window === window && anchor.isDescendant(of: bar.view))
            #expect(menu.location == NSPoint(x: 0, y: anchor.bounds.maxY))
        } else { Issue.record("Help did not use the actual status bar anchor") }

        let opened = menu.calls
        #expect(press())
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(bar.view.isHidden)
        try await settle(window)
        #expect(menu.calls == opened, "a pending popup must not open after the bar becomes hidden")
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        try await settle(window)
        #expect(!bar.view.isHidden)
        #expect(press())
        window.contentViewController = nil
        try await Task.sleep(for: .milliseconds(150))
        #expect(menu.calls == opened, "a pending popup must not open after the root is detached")
    }

    @Test func utilitiesAreInsideTheOneBottomBarWithAndWithoutTheSidebar() async throws {
        enableAccessibilityTree()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-status-utilities-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: directory.appendingPathComponent("preferences.json")))
        defer { model.stop() }
        var settingsOpens = 0
        model.onShowSettings = { _ in settingsOpens += 1 }
        let index = FakeUsageIndex()
        let source = UsageHarnessTests.Scripted([UsageHarnessTests.codexAnswer(at: Date())])
        let connections = HarnessConnections()
        let probe = HarnessProbe(connections: connections, sources: [.claude: source])
        let usage = UsageModel(index: index)
        usage.attachHarness(probe: probe, connections: connections)
        model.usage = usage

        let menu = HelpMenu(title: "Help")
        menu.addItem(withTitle: "Collect Diagnostics…", action: nil, keyEquivalent: "")
        let originalHelp = NSApp.helpMenu
        NSApp.helpMenu = menu
        defer { NSApp.helpMenu = originalHelp }

        let host = InkHost()
        let sidebar = NSHostingController(rootView: SidebarView(model: model).inkHost(host))
        sidebar.sizingOptions = []
        let split = NSSplitViewController()
        split.splitView = CanvasSplitView()
        let left = NSSplitViewItem(viewController: sidebar)
        left.canCollapse = true
        left.minimumThickness = 220
        left.maximumThickness = 520
        left.preferredThicknessFraction = 0.25
        left.holdingPriority = NSLayoutConstraint.Priority(260)
        let detail = NSViewController()
        detail.view = NSView()
        split.addSplitViewItem(left)
        let right = NSSplitViewItem(viewController: detail)
        right.minimumThickness = 480
        split.addSplitViewItem(right)
        let bar = NSHostingController(rootView: StatusBarView(model: model).inkHost(host))
        bar.sizingOptions = []
        let root = StatusBarWindowLayout(split: split, bar: bar, overlays: [host.view], popoverHost: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        window.setContentSize(NSSize(width: 900, height: 600))
        defer { host.state.dismiss(); window.close() }
        root.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(300, ofDividerAt: 0)
        try await settle(window)
        #expect(!window.isVisible && !window.isKeyWindow)
        try #require(abs(root.view.bounds.width - 900) < 1 && abs(root.view.bounds.height - 600) < 1,
                     "the real main-window root must have the requested size before measuring its children: \(root.view.bounds)")
        #expect(abs(bar.view.frame.height - 26) < 1 && abs(bar.view.frame.width - root.view.bounds.width) < 1)
        #expect(buttons("Settings", in: sidebar.view).isEmpty && buttons("Help", in: sidebar.view).isEmpty,
                "the sidebar no longer owns a separate utility footer")
        let scroll = try #require(descendants(sidebar.view).compactMap { $0 as? NSScrollView }.first)
        let listFrame = scroll.convert(scroll.bounds, to: nil)
        let sidebarFrame = sidebar.view.convert(sidebar.view.bounds, to: nil)
        try #require(sidebarFrame.width > 0 && sidebarFrame.height > 0,
                     "the actual split must lay out a visible sidebar before its list is measured: \(sidebarFrame)")
        #expect(abs(listFrame.minY - sidebarFrame.minY) < 1, "the list reaches the sidebar's bottom: \(listFrame), \(sidebarFrame)")

        func checkUtilities() {
            let settings = buttons("Settings", in: bar.view)
            let help = buttons("Help", in: bar.view)
            #expect(settings.count == 1 && help.count == 1, "the global bar contains one pair of named controls")
            guard let gear = settings.first, let info = help.first else { return }
            let barFrame = window.convertToScreen(bar.view.convert(bar.view.bounds, to: nil))
            let gearFrame = InkAX.frame(gear), infoFrame = InkAX.frame(info)
            #expect(abs(gearFrame.width - 24) < 1 && abs(gearFrame.height - 24) < 1)
            #expect(abs(infoFrame.width - 24) < 1 && abs(infoFrame.height - 24) < 1)
            #expect(barFrame.contains(gearFrame) && barFrame.contains(infoFrame))
            #expect(gearFrame.minX < infoFrame.minX)
            let limits = accessibilityElements(in: bar.view).first { InkAX.label($0) == "Claude, No limits read" }
            #expect(limits.map { infoFrame.maxX <= InkAX.frame($0).minX } == true, "utilities precede cached limits")
        }
        checkUtilities()
        if let settings = buttons("Settings", in: bar.view).first {
            #expect(settings.accessibilityPerformPress?() == true && settingsOpens == 1)
        }
        if let help = buttons("Help", in: bar.view).first {
            #expect(help.accessibilityPerformPress?() == true && menu.calls == 0)
            try await settle(window)
            #expect(menu.calls == 1)
            if let anchor = menu.anchor {
                #expect(anchor.window === window && anchor.isDescendant(of: bar.view))
                #expect(menu.location == NSPoint(x: 0, y: anchor.bounds.maxY))
            } else { Issue.record("Help did not anchor the actual app menu to the status bar") }
        }
        #expect(source.asks == 0 && index.refreshCalls == 0 && index.changedCalls.isEmpty && index.snapshotRanges.isEmpty,
                "mounting and utility actions start no usage read or index scan")
        #expect(!host.state.handle(.return) && !host.state.handle(.escape), "closed controls do not steal Return or Escape")

        left.isCollapsed = true
        try await settle(window)
        #expect(left.isCollapsed && abs(bar.view.frame.width - root.view.bounds.width) < 1)
        checkUtilities()
        if let settings = buttons("Settings", in: bar.view).first {
            #expect(settings.accessibilityPerformPress?() == true && settingsOpens == 2)
        }
        if let help = buttons("Help", in: bar.view).first {
            #expect(help.accessibilityPerformPress?() == true && menu.calls == 1)
            try await settle(window)
            #expect(menu.calls == 2)
        }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        try await settle(window)
        #expect(bar.view.isHidden && bar.view.frame.height == 0)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        try await settle(window)
        #expect(!bar.view.isHidden && abs(bar.view.frame.height - 26) < 1)
        checkUtilities()
        #expect(!window.isVisible && !window.isKeyWindow)
    }
}
}
