import AppKit
import Combine
import SwiftUI

// AppKit owns the main window; a placeholder SwiftUI scene would create a second window.
@main
enum HerdrDesktopApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = DesktopAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var model: AppModel?
    var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var attentionObserver: AnyCancellable?
    private var performance: PerformanceRecorder?
    private var performanceToggle: NSMenuItem?
    private var performanceAppSummary: NSMenuItem?
    private var performanceAgentSummary: NSMenuItem?
    private var performanceMarker: NSMenuItem?
    private let startedAt = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // The dev bundle opens the synthetic preview unless `--live` asks for its isolated local sessions.
        let demo = CommandLine.arguments.contains("--demo")
            || (Bundle.main.bundleIdentifier == "local.herdr.desktop.dev" && !CommandLine.arguments.contains("--live"))
        let model = AppModel(demo: demo)
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("herdr-main")
        window.title = "Herdr Desktop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        // The SwiftUI root draws a translucent material over the desktop.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 780, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        // An empty unified toolbar gives the standard title bar height and centers the window buttons in it.
        window.toolbar = NSToolbar(identifier: "herdr-main")
        window.toolbarStyle = .unified
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.contentView = NSHostingView(rootView: DesktopView(model: model))
        if demo || !window.setFrameUsingName("HerdrDesktop.main") { window.center() }
        if !demo { window.setFrameAutosaveName("HerdrDesktop.main") }
        window.makeKeyAndOrderFront(nil)
        // Start without selecting the first toolbar button; Tab navigation remains available.
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        configurePerformance(demo: demo)
        installMenus()
        installStatusItem(model)
        if let pngPath = argument(after: "--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.saveSnapshot(to: pngPath) }
        }
        if CommandLine.arguments.contains("--metrics") {
            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            print("window_ready_ms=\(Int(elapsed)) pid=\(getpid())")
            fflush(stdout)
        }
    }

    /// The menu bar mark and Dock badge share the model's attention count; nothing polls.
    private func installStatusItem(_ model: AppModel) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "menubar-herdr", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Herdr Desktop"
            item.button?.image = image
        }
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        attentionObserver = model.$attentionCount.removeDuplicates().sink { [weak self] count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            self?.statusItem?.button?.title = count > 0 ? "\(count)" : ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let sessions = model.attentionSessions
        if sessions.isEmpty {
            menu.addItem(withTitle: "Nothing needs attention", action: nil, keyEquivalent: "").isEnabled = false
        }
        for conversation in sessions.prefix(12) {
            let state = conversation.status == "blocked" && model.isLive(conversation) ? "Waiting for input" : "Finished"
            let item = menu.addItem(withTitle: "\(conversation.title) · \(state)", action: #selector(openAttentionSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = conversation.id
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Herdr Desktop", action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Herdr Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
    }

    @objc private func showMainWindow() {
        model?.windowVisible = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.attachSelected()
    }

    @objc private func openAttentionSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let conversation = model?.conversations.first(where: { $0.id == id }) else { return }
        showMainWindow()
        model?.open(conversation)
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            mainMenu.addItem(item)
            return submenu
        }
        func action(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "") {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = self
        }

        let appMenu = menu("Herdr Desktop")
        appMenu.addItem(withTitle: "About Herdr Desktop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        action(appMenu, "Settings…", #selector(showSettings), ",")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Herdr Desktop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Herdr Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in appMenu.items where item.action != nil && item.target == nil {
            item.target = NSApp
        }

        let file = menu("File")
        action(file, "Add Project…", #selector(addProject), "o")
        action(file, "New Conversation", #selector(newConversation), "n")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w").target = window

        let edit = menu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = menu("View")
        action(view, "Toggle Sidebar", #selector(toggleSidebar), "s")
        view.items.last?.keyEquivalentModifierMask = [.command, .control]
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.target = window
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let diagnostics = menu("Performance")
        diagnostics.autoenablesItems = false
        performanceToggle = diagnostics.addItem(withTitle: "Record Performance", action: #selector(togglePerformance), keyEquivalent: "")
        performanceToggle?.target = self
        performanceToggle?.state = performance?.isRecording == true ? .on : .off
        performanceAppSummary = diagnostics.addItem(withTitle: "App: waiting for samples", action: nil, keyEquivalent: "")
        performanceAppSummary?.isEnabled = false
        performanceAgentSummary = diagnostics.addItem(withTitle: "Child processes: waiting for samples", action: nil, keyEquivalent: "")
        performanceAgentSummary?.isEnabled = false
        diagnostics.addItem(.separator())
        performanceMarker = diagnostics.addItem(withTitle: "Mark Performance Issue", action: #selector(markPerformanceIssue), keyEquivalent: "")
        performanceMarker?.target = self
        performanceMarker?.isEnabled = performance?.isRecording == true
        action(diagnostics, "Open Performance Logs", #selector(openPerformanceLogs))

        let windows = menu("Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m").target = window
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "").target = window
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "").target = NSApp
        NSApp.windowsMenu = windows
        NSApp.mainMenu = mainMenu
    }

    private func configurePerformance(demo: Bool) {
        let recorder = PerformanceRecorder()
        performance = recorder
        recorder.context = { [weak self] in
            PerformanceContext(active: NSApp.isActive,
                visible: self?.window?.occlusionState.contains(.visible) ?? false,
                terminalCount: self?.model?.terminal.runningSessionIDs.count ?? 0,
                selectedTerminal: self?.model?.terminal.attachedSessionID,
                terminals: self?.model?.terminal.performanceRoots ?? [:])
        }
        recorder.onSample = { [weak self] sample in
            func summary(_ rows: [PerformanceProcess]) -> String {
                let cpu = rows.compactMap(\.cpuPercent)
                let value = rows.isEmpty ? "0.0%" : cpu.count == rows.count
                    ? String(format: "%.1f%%", cpu.reduce(0, +)) : "warming up / partial"
                let memory = Double(rows.reduce(UInt64(0)) { $0 + $1.footprintBytes }) / 1_048_576
                return "CPU \(value) · \(Int(memory)) MiB"
            }
            self?.performanceAppSummary?.title = "App: " + (sample.unreadablePIDs.contains(getpid())
                ? "measurement unavailable" : summary(sample.processes.filter { $0.pid == getpid() }))
            self?.performanceAgentSummary?.title = "Child processes: " + summary(sample.processes.filter { $0.pid != getpid() })
                + (sample.unreadablePIDs.contains { $0 != getpid() } ? " (partial)" : "")
        }
        recorder.onError = { [weak self] error in
            self?.performanceToggle?.state = .off
            self?.performanceMarker?.isEnabled = false
            self?.performanceAppSummary?.title = "Recording stopped: write failed"
            self?.performanceAgentSummary?.title = "Child processes: recording paused"
            self?.model?.errorMessage = "Performance recording stopped: \(error.localizedDescription)"
        }
        let enabled = UserDefaults.standard.object(forKey: "recordPerformance") as? Bool ?? true
        if (!demo && enabled) || CommandLine.arguments.contains("--performance-log") { recorder.start() }
    }

    @objc private func togglePerformance() {
        guard let performance else { return }
        if performance.isRecording { performance.stop() } else { performance.start() }
        UserDefaults.standard.set(performance.isRecording, forKey: "recordPerformance")
        performanceToggle?.state = performance.isRecording ? .on : .off
        performanceMarker?.isEnabled = performance.isRecording
        if !performance.isRecording {
            performanceAppSummary?.title = "Recording paused"
            performanceAgentSummary?.title = "Child processes: recording paused"
        }
    }
    @objc private func markPerformanceIssue() { performance?.record(event: "user_marker") }
    @objc private func openPerformanceLogs() {
        guard let performance else { return }
        do {
            try FileManager.default.createDirectory(at: performance.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(performance.directory)
        } catch { model?.errorMessage = "Could not open performance logs: \(error.localizedDescription)" }
    }

    @objc private func showSettings() { model?.showSettings = true }
    @objc private func addProject() { model?.addProject() }
    @objc private func toggleSidebar() {
        model?.sidebarVisible.toggle()
        model?.persist()
    }

    private func argument(after option: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: option), CommandLine.arguments.indices.contains(i + 1) else { return nil }
        return CommandLine.arguments[i + 1]
    }

    private func saveSnapshot(to path: String) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func reportActivity() {
        guard CommandLine.arguments.contains("--metrics") else { return }
        print("app_active=\(NSApp.isActive) window_visible=\(window?.occlusionState.contains(.visible) ?? false)")
        fflush(stdout)
    }

    func applicationDidBecomeActive(_ notification: Notification) { reportActivity() }
    func applicationDidResignActive(_ notification: Notification) { reportActivity() }
    func windowDidChangeOcclusionState(_ notification: Notification) { reportActivity() }

    @objc func newConversation() {
        guard let model else { return }
        let harness = model.selected?.harness ?? .claude
        guard let project = model.projects.first(where: { $0.id == model.selected?.projectID }) ?? model.projects.first else {
            model.startSession(harness: harness); return
        }
        model.start(project: project, harness: harness)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model?.windowVisible = true; window?.makeKeyAndOrderFront(nil); model?.attachSelected() }
        return true
    }
    func windowWillClose(_ notification: Notification) { model?.windowVisible = false; model?.terminal.detach() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.prepareToQuit { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        performance?.stop()
        model?.shutdown()
    }
}
