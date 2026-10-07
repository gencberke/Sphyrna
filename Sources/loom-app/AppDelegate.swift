import AppKit
import Darwin
import LoomCatalogUI
import LoomCore
import LoomLaunchOptions
import LoomTerminal
import SwiftUI

/// One native window: the catalog sidebar (CP5 B) beside a detail pane. The
/// development flavor (`LOOM_EVIDENCE`, `Evidence/`) adds a synthetic terminal and
/// the acceptance tooling through the seams in `DevelopmentSeams.swift`. Cmd+W and
/// the close button only close the window; Cmd+Q waits for the shared
/// supervisor shutdown and stays open when it cannot be verified. Opening the
/// app or selecting a conversation starts no provider, PTY or terminal.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: LaunchOptions
    /// Production or development, read once; the only source of identity-derived names.
    let identity = BuildIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
    private(set) var window: NSWindow?
    /// The frame `makeWindow` chose (saved, or the centered default). AppKit re-places a window
    /// that is shown for the first time (narrower, recentered), so it is applied again after the show.
    private var openingFrame: NSRect?
    /// The one Settings window (`SettingsWindowController`); nil until the model exists.
    var settingsController: SettingsWindowController?
    /// Claude usage for the footer chip and Settings; nil when the data root was refused.
    var usage: UsageModel?
    private(set) var model: CatalogModel?
    private(set) var splitController: MainSplitViewController?
    /// The development flavor's synthetic terminal; always nil in the release flavor.
    var controller: TerminalRunController?
    private(set) var shutdownCoordinator: AppShutdownCoordinator?
    private(set) var supervisor: ProcessSupervisor?
    private(set) var runtime: SessionRuntime?
    private(set) var conversations: ConversationController?
    private var startupTask: Task<Void, Never>?
    private var startupFinished = false
    private(set) var runDirectory: URL?
    private(set) var quitAlert: NSAlert?
#if LOOM_EVIDENCE
    // State of the development-only evidence tooling (Evidence/).
    var evidence: DevelopmentEvidence?
    var resourcePreviousDevTerminal: Bool?
    var terminalPanel: NSView?
    var visibilityEvents: [[String: Any]] = []
#endif

    init(arguments: [String]) {
        LoomSignposts.begin(.launchToFirstPage)
        LoomSignposts.begin(.windowShown)
        self.options = LaunchOptions(arguments: arguments)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is dark-only: alerts, open panels and other AppKit panels follow this, not the system.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // One window by design: no tab bar, no "Show Tab Bar"/"Merge All Windows" items.
        NSWindow.allowsAutomaticWindowTabbing = false
        installMenus()
        let resolvedRoot = dataRoot()
        // A refused root (for example --data-root without --evidence) opens no
        // catalog and starts no runtime; the default root is never a fallback.
        let root: URL
        var refusal: String?
        switch resolvedRoot {
        case .root(let url): root = url
        case .refused(let message):
            refusal = message
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-refused-\(getpid())", isDirectory: true)
        }
        // The hub exists before the supervisor so the model can subscribe at once.
        let hub = SessionEventHub()
        var catalog: SessionCatalog?
        var catalogFailure: String?
        if let refusal {
            catalogFailure = refusal
        } else {
            do {
                catalog = try LoomSignposts.measure(.catalogOpen) {
                    try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
                }
            } catch {
                catalogFailure = String(describing: error)
            }
        }
        let model = CatalogModel(
            catalog: catalog, startupError: catalogFailure, events: hub,
            preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")),
            startableProviders: Set(identity.startableProviders.compactMap(ManagedSession.Provider.init(rawValue:))),
            permanentDeletionEnabled: identity.permanentDeletionEnabled
        )
        configureEvidenceAtLaunch(model: model)
        self.model = model
        model.onShowSettings = { [weak self] section in self?.showSettings(section: section) }
        installUsage(model: model, root: root, refused: refusal != nil)
        model.onTerminalFontSizeChange = { [weak self] size in
            self?.conversations?.setTerminalFontSize(size)
            self?.controller?.terminalFontSize = size
        }
        model.presentingWindow = { [weak self] in self?.window }
        let window = makeWindow(model: model)
        self.window = window
        traceWindowCall("launch-before-show")
        window.makeKeyAndOrderFront(nil)
        if let openingFrame { window.setFrame(openingFrame, display: true) }
        NSApp.activate()
        traceWindowCall("launch-after-show")
        LoomSignposts.end(.windowShown)
        updateWindowActivity()
        startEvidenceChannel()
        // The runtime is built off the launch path; opening the app starts no
        // provider, PTY or terminal, and Quit waits for this to finish first.
        // The sidebar needs only the catalog and the hub, so it loads while the
        // runtime starts instead of after it.
        startupTask = Task { @MainActor in
            async let sidebar: Void = model.start()
            if refusal == nil { await startRuntime(root: root, hub: hub, catalog: catalog, model: model) }
            await sidebar
            startupFinished = true
            evidenceStartupFinished()
        }
    }

    /// `~/Library/Application Support/Loom-Dev` (or `Loom`) for a normal launch.
    /// Evidence runs always use an isolated root (`--data-root` or
    /// `<evidence>/data`); see `LaunchOptions.resolveDataRoot`.
    func dataRoot() -> LaunchOptions.DataRoot {
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(identity.dataDirectoryName)", isDirectory: true)
        return options.resolveDataRoot(defaultRoot: defaultRoot)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click or a second LaunchServices open brings back the same window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        traceWindowCall("application-reopen", hasVisibleWindows: flag)
        presentMainWindow(reason: "application-reopen")
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard startupFinished else {
            // The runtime is still being built: let it finish, then quit through it.
            Task { @MainActor in
                await startupTask?.value
                guard shutdownCoordinator != nil else { NSApp.reply(toApplicationShouldTerminate: true); return }
                beginQuit()
            }
            return .terminateLater
        }
        guard shutdownCoordinator != nil else { return .terminateNow }
        beginQuit()
        return .terminateLater
    }

    private func beginQuit() {
        guard let shutdownCoordinator else { return }
        conversations?.quitStarted()
        model?.statusMessage = "Stopping conversations before quitting…"
        let started = ProcessInfo.processInfo.systemUptime
        let recordQuit = evidenceQuitRecorder(started: started)
        shutdownCoordinator.requestQuit(prepareReply: recordQuit) { [weak self] report in
            self?.quitFinished(report)
        }
    }

    // MARK: Window

    private func makeWindow(model: CatalogModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: UIPreferences.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("loom-main")
        window.title = "Loom"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar makes AppKit give the titlebar the unified height and
        // center the window buttons in it natively (they are otherwise pinned to
        // a 32 pt strip); no item or separator is shown.
        window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("loom-main"))
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.minSize = UIPreferences.windowMinimumSize
        window.isReleasedWhenClosed = false
        // The frame is this app's own preference (below). AppKit's saved window state is keyed by
        // bundle identifier only, so it would carry one data root's frame into another.
        window.isRestorable = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        let split = MainSplitViewController(model: model)
        window.contentViewController = split
        // The last frame the user left (kept in ui-preferences.json of this data root, never in
        // the bundle's defaults) when it still fits a screen; otherwise the default, centered.
        if let saved = model.preferencesSnapshot.windowFrame?.restorable(onScreens: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(saved, display: false)
        } else {
            window.setContentSize(UIPreferences.defaultWindowSize)
            window.center()
        }
        openingFrame = window.frame
        splitController = split
        let center = NotificationCenter.default
        // Moves and resizes are remembered (the model writes them after a short pause and at Quit);
        // full screen, a minimized window and the window's opening (before the first page is ready)
        // are not.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window, let model = self?.model, model.isReady, window.isVisible,
                          !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
                    model.setWindowFrame(window.frame)
                }
            }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated {
                    if name == NSWindow.didChangeOcclusionStateNotification {
                        self?.recordVisibility("occlusion")
                    }
                    self?.updateWindowActivity()
                }
            }
        }
        // Full screen hides the native window buttons; the model carries it to the headers.
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                let entering = notification.name == NSWindow.willEnterFullScreenNotification
                    || notification.name == NSWindow.didEnterFullScreenNotification
                MainActor.assumeIsolated { self?.model?.setFullScreen(entering) }
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWindowActivity() }
            }
        }
        return window
    }

    /// A conversation counts as viewed only while the window is visible, not
    /// occluded, key, and the application is active.
    private func updateWindowActivity() {
        guard let window, let model else { return }
        let active = window.isVisible && window.occlusionState.contains(.visible) && window.isKeyWindow && NSApp.isActive
        model.setWindowActive(active)
        usage?.windowActivityChanged(active)
    }

    /// Every run starts in its own run-host scope. Without the bundled host
    /// nothing can start safely, so starts fail visibly instead of narrowing.
    private func runScopeLauncher() -> RunScopeLauncher {
        let host = evidenceRunHost(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LoomRunHost.app"))
        let sockets = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("\(identity.socketDirectoryName)/scopes", isDirectory: true)
        return RunScopeLauncher(hostBundle: host, socketDirectory: sockets)
    }

    private func showOwnershipNotice(_ launcher: RunScopeLauncher) {
        let executable = launcher.hostBundle
            .appendingPathComponent("Contents/MacOS/\(RunScopeLauncher.hostExecutableName)")
        guard !FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        model?.ownershipNotice = "New conversations are turned off because Loom's process helper is missing. Without it Loom cannot make sure Stop and Quit end all of a conversation's background work. Reinstall Loom to fix this."
    }

    @objc func showMainWindow() { presentMainWindow(reason: "window-menu") }

    private func presentMainWindow(reason: String) {
        traceWindowCall("show-before-\(reason)")
        window?.makeKeyAndOrderFront(nil)
        if model?.showsDevTerminal == true, let view = controller?.surface?.view {
            window?.makeFirstResponder(view)
        }
        traceWindowCall("show-after-\(reason)")
    }

    /// Whatever is still waiting for the preference write debounce (the window frame) goes to disk.
    func applicationWillTerminate(_ notification: Notification) {
        model?.flushPreferences()
    }

    func windowWillClose(_ notification: Notification) {
        recordVisibility("close")
        model?.setWindowActive(false)
    }

    // MARK: Runs

    private func startRuntime(root: URL, hub: SessionEventHub, catalog: SessionCatalog?,
                              model: CatalogModel) async {
        LoomSignposts.begin(.runtimeStart)
        defer { LoomSignposts.end(.runtimeStart) }
        do {
            // Ownership is per run scope; the app's own coalition is never used.
            let ledger = OwnershipLedger()
            let scopeLauncher = runScopeLauncher()
            let directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let ledgerURL = directory.appendingPathComponent("ledger.json")
            let supervisor: ProcessSupervisor
            if let catalog {
                supervisor = try await ProcessSupervisor.restoring(
                    ledger: ledger, ledgerURL: ledgerURL, catalog: catalog, events: hub,
                    scopeLauncher: scopeLauncher
                )
            } else {
                supervisor = try ProcessSupervisor(
                    ledger: ledger, ledgerURL: ledgerURL, events: hub, scopeLauncher: scopeLauncher
                )
            }
            self.supervisor = supervisor
            runDirectory = directory
            if let owner = ProcessTable.record(pid: getpid()) {
                try JSONEncoder().encode(owner.identity)
                    .write(to: directory.appendingPathComponent("owner.json"), options: .atomic)
            }
            try Data("Run-scoped ownership; host: \(scopeLauncher.hostBundle.path)".utf8)
                .write(to: directory.appendingPathComponent("ownership-guarantee.txt"), options: .atomic)
            showOwnershipNotice(scopeLauncher)
            // A previous Loom that crashed may have left scopes; their hosts
            // normally stopped them already. Verify, never start anything.
            let runsDirectory = root.appendingPathComponent("runs")
            Task { [weak self] in
                let recovery = await PreviousRunRecovery.recover(runsDirectory: runsDirectory, current: directory)
                guard !recovery.leftovers.isEmpty else { return }
                self?.model?.ownershipNotice = "Work left by a previous Loom could not be fully stopped: "
                    + recovery.leftovers.joined(separator: "; ")
            }

            // One runtime owns providers, lifecycle and cleanup. With no readable
            // catalog there is no runtime: actions stay disabled and nothing starts.
            var runtime: SessionRuntime?
            if let catalog {
                let created = SessionRuntime(
                    supervisor: supervisor, catalog: catalog,
                    configuration: runtimeConfiguration(root: root, supervisor: supervisor)
                )
                try await created.start()
                let conversations = ConversationController(runtime: created, model: model)
                await conversations.begin()
                self.runtime = created
                self.conversations = conversations
                runtime = created
            }
            // The missing-host notice is more important than shell warnings and is kept.
            let warnings = await runtime?.environmentWarnings() ?? []
            if !warnings.isEmpty, model.ownershipNotice == nil { model.ownershipNotice = warnings.joined(separator: " ") }

            let injectedFailure = evidenceInjectedShutdownFailure()
            shutdownCoordinator = AppShutdownCoordinator(
                shutdown: { [runtime] in
                    if let report = injectedFailure?() { return report }
                    // Everything the app owns goes through the runtime's one shutdown.
                    if let runtime { return await runtime.shutdown() }
                    return await supervisor.shutdown()
                }
            )
            installDevelopmentTerminal(hub: hub, supervisor: supervisor, model: model)
        } catch {
            showError("Loom could not start its process supervisor.", detail: String(describing: error))
        }
    }

    /// Provider CLIs come from the user's real terminal environment; only the development
    /// flavor's acceptance runs (`--evidence`) may substitute fixture providers and isolated profiles.
    private func runtimeConfiguration(root: URL, supervisor: ProcessSupervisor) -> SessionRuntimeConfiguration {
        let helpers = Bundle.main.executableURL!.deletingLastPathComponent()
        let socketDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(identity.socketDirectoryName, isDirectory: true)
        let origin = LaunchEnvironment.origin(
            parent: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier, parentPID: getppid()
        )
        let toolchains: ProviderToolchainResolver = evidenceToolchains(root: root, supervisor: supervisor, origin: origin)
            ?? { [system = SystemProviderToolchains(supervisor: supervisor, origin: origin)] provider in
                try await system.toolchain(for: provider)
            }
        return SessionRuntimeConfiguration(
            toolchains: toolchains, hookHelperPath: helpers.appendingPathComponent("loom-hook").path,
            socketDirectory: socketDirectory,
            clientVersion: "loom-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")"
        )
    }

    @objc func newClaudeFromMenu(_ sender: Any?) {
        model?.startConversation(.claude, projectID: model?.contextProjectID)
    }
    @objc func newCodexFromMenu(_ sender: Any?) {
        model?.startConversation(.codex, projectID: model?.contextProjectID)
    }
    @objc func resumeFromMenu(_ sender: Any?) {
        if let id = model?.selectedSessionID { model?.resumeConversation(id) }
    }
    @objc func stopFromMenu(_ sender: Any?) {
        if let id = model?.selectedSessionID { model?.stopConversation(id) }
    }
    @objc func deleteFromMenu(_ sender: Any?) {
        if let id = model?.selectedSessionID { model?.requestDeletion(id) }
    }
    @objc func showNextTab(_ sender: Any?) { model?.selectAdjacentTab(.next) }
    @objc func showPreviousTab(_ sender: Any?) { model?.selectAdjacentTab(.previous) }
    @objc func closeTabFromMenu(_ sender: Any?) { model?.closeSelectedTab() }
    @objc func findFromMenu(_ sender: Any?) {
        presentMainWindow(reason: "find-menu")
        model?.requestSearchFocus()
    }

    /// Menu commands follow the same rules as the buttons.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model else { return true }
        switch item.action {
        case #selector(newClaudeFromMenu(_:)):
            return model.canStart(.claude, projectID: model.contextProjectID)
        case #selector(newCodexFromMenu(_:)):
            return model.canStart(.codex, projectID: model.contextProjectID)
        case #selector(resumeFromMenu(_:)):
            return model.selectedRow.map(model.canResume) ?? false
        case #selector(stopFromMenu(_:)):
            return model.selectedRow.map(model.canStop) ?? false
        case #selector(deleteFromMenu(_:)):
            // Cmd+Delete belongs to a text field being edited (search, rename) and to a focused terminal
            // (Cmd+Backspace edits the prompt line there); the menu item itself stays usable.
            if NSApp.currentEvent?.type == .keyDown,
               window?.firstResponder is NSText || window?.firstResponder is LoomTerminalView { return false }
            return model.selectedRow.map(model.canDelete) ?? false
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return model.canSelectAdjacentTab
        case #selector(closeTabFromMenu(_:)):
            return model.canCloseSelectedTab
        case #selector(findFromMenu(_:)):
            // The search field lives in the main window; another key window (Settings) keeps Cmd+F to itself.
            return NSApp.keyWindow.map { $0 === window } ?? true
        default:
            return true
        }
    }

    @objc func addProjectFromMenu(_ sender: Any?) {
        presentMainWindow(reason: "add-project-menu")
        model?.presentAddProject()
    }
    @objc func showActivityView(_ sender: Any?) { model?.setViewMode(.activity) }
    @objc func showProjectView(_ sender: Any?) { model?.setViewMode(.projects) }

    // MARK: Quit

    private func quitFinished(_ report: ShutdownReport) {
        if let runDirectory {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: runDirectory.appendingPathComponent("shutdown.json"),
                                              options: .atomic)
        }
        if report.succeeded {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        // Timeout or remaining processes never count as a successful quit.
        NSApp.reply(toApplicationShouldTerminate: false)
        model?.statusMessage = "Loom did not quit: it could not confirm that every conversation process stopped."
        presentMainWindow(reason: "failed-quit")
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Loom could not verify that its processes stopped."
        let remaining = report.remainingCountVerified == false ? "unavailable" : String(report.remaining.count)
        alert.informativeText = "Remaining: \(remaining). Errors: \(report.errors.prefix(3).joined(separator: "; "))"
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Keep Loom Open")
        quitAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.quitAlert = nil
            if response == .alertFirstButtonReturn { NSApp.terminate(nil) }
        }
    }

    func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }

    // MARK: Menus

    @objc private func showSettings(_ sender: Any?) { showSettings(section: nil) }

    func showSettings(section: SettingsSection?) {
        settingsController?.show(section: section)
    }

    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Loom", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Loom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Project…", action: #selector(addProjectFromMenu(_:)),
                         keyEquivalent: "o").target = self
        // New conversations start in the selected conversation's project (or none).
        fileMenu.addItem(withTitle: "New Claude Conversation", action: #selector(newClaudeFromMenu(_:)),
                         keyEquivalent: "n").target = self
        if !identity.isProduction {
            let codex = fileMenu.addItem(withTitle: "New Codex Conversation", action: #selector(newCodexFromMenu(_:)),
                                         keyEquivalent: "n")
            codex.keyEquivalentModifierMask = [.command, .shift]
            codex.target = self
        }
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Resume Conversation", action: #selector(resumeFromMenu(_:)),
                         keyEquivalent: "r").target = self
        let stop = fileMenu.addItem(withTitle: "Stop Conversation", action: #selector(stopFromMenu(_:)),
                                    keyEquivalent: ".")
        stop.target = self
        if identity.permanentDeletionEnabled {
            fileMenu.addItem(.separator())
            let delete = fileMenu.addItem(withTitle: "Delete Conversation…", action: #selector(deleteFromMenu(_:)),
                                          keyEquivalent: "\u{8}")
            delete.target = self
        }
        fileMenu.addItem(.separator())
        installDevelopmentMenuItems(in: fileMenu)
        // Cmd+W keeps closing the window; the tab closes with Opt+Cmd+W.
        let closeTab = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTabFromMenu(_:)),
                                        keyEquivalent: "w")
        closeTab.keyEquivalentModifierMask = [.command, .option]
        closeTab.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find", action: #selector(findFromMenu(_:)), keyEquivalent: "f").target = self
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar",
                                       action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                       keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Recent Activity", action: #selector(showActivityView(_:)),
                         keyEquivalent: "1").target = self
        viewMenu.addItem(withTitle: "Group by Project", action: #selector(showProjectView(_:)),
                         keyEquivalent: "2").target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        // Tab shortcuts (DP-U2): Shift+Cmd+] / [ are the visible items; Ctrl+Tab / Ctrl+Shift+Tab and
        // the shifted characters a keyboard layout may report are hidden twins of the same action.
        let tabKeys: [(String, Selector, String, NSEvent.ModifierFlags, Bool)] = [
            ("Show Next Tab", #selector(showNextTab(_:)), "]", [.command, .shift], false),
            ("Show Next Tab", #selector(showNextTab(_:)), "}", [.command, .shift], true),
            ("Show Next Tab", #selector(showNextTab(_:)), "\t", [.control], true),
            ("Show Previous Tab", #selector(showPreviousTab(_:)), "[", [.command, .shift], false),
            ("Show Previous Tab", #selector(showPreviousTab(_:)), "{", [.command, .shift], true),
            ("Show Previous Tab", #selector(showPreviousTab(_:)), "\u{19}", [.control, .shift], true),
        ]
        for (title, action, key, mask, hidden) in tabKeys {
            let item = windowMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
            item.isHidden = hidden
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Loom", action: #selector(showMainWindow), keyEquivalent: "").target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
