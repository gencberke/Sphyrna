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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let options: LaunchOptions
    /// Production or development, read once; the only source of identity-derived names.
    let identity = BuildIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
    /// The providers this build can start (the model gets the same set).
    var startableProviders: Set<ManagedSession.Provider> {
        Set(identity.startableProviders.compactMap(ManagedSession.Provider.init(rawValue:)))
    }
    private(set) var window: NSWindow?
    /// The frame `makeWindow` chose (saved, or the centered default). AppKit re-places a window
    /// that is shown for the first time (narrower, recentered), so it is applied again after the show.
    private var openingFrame: NSRect?
    /// The one Settings window (`SettingsWindowController`); nil until the model exists.
    var settingsController: SettingsWindowController?
    /// Claude usage for the footer chip and Settings; nil when the data root was refused.
    var usage: UsageModel?
    /// The one file-system stream behind the usage numbers; nil without a usage index.
    var usageWatcher: UsageTranscriptWatcher?
    /// "Collect Diagnostics…" for the Help menu and Settings → About; created with the Settings window.
    var diagnostics: DiagnosticsCollection?
    /// The Claude toolchain sessions use, handed over by the runtime; plan limits read it too.
    let toolchainSlot = ToolchainSlot()
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
    /// Menu bar item, needs-approval banners and the two system services behind them (H1-F; `AppDelegate+System`).
    var systemServices: SystemServices?
    var menuBar: MenuBarController?
    var approvalNotifier: ApprovalNotifier?
    /// Settings → General → Keep Mac awake: one assertion against idle system sleep while a session works.
    var keepAwake: KeepAwakeController?
    private(set) var quitAlert: NSAlert?
    /// "Quit Loom and stop N working sessions?" while it is on screen.
    private(set) var quitQuestion: NSAlert?
    /// The user answered that question with Quit; Try Again after a failed shutdown does not ask again.
    private var quitConfirmed = false
    /// The quit in progress came from the system (logout, restart, shutdown): it never asks, and a failed
    /// shutdown never holds it up. Read from the quit Apple event when the quit starts.
    private var quitIsSystemInitiated = false
    /// "Quit Anyway": the next quit ends Loom without a verified shutdown.
    private var terminatesWithoutVerifiedShutdown = false
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

    /// Applies Settings → Theme → Appearance to the app (the windows, the alerts and the panels follow it; Match
    /// system is no appearance of its own) and the tone to the live terminals and the Settings window.
    func applyTheme() {
        guard let model else { return }
        switch model.appearance {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
        conversations?.applyTerminalTheme()
        settingsController?.window?.backgroundColor = model.themePanelBackground
        // The split view's divider is drawn by AppKit: it follows Appearance and Increase Contrast, so it is redrawn here.
        splitController?.refreshChrome()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dark until the stored Appearance is read (`applyTheme`): the question about a damaged catalog comes before the
        // model exists. Alerts, open panels and other AppKit panels follow `NSApp.appearance`.
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
            let catalogURL = root.appendingPathComponent("catalog.sqlite3")
            do {
                catalog = try LoomSignposts.measure(.catalogOpen) { try SessionCatalog(url: catalogURL) }
            } catch {
                // A damaged file gets the restore question before anything else starts; every other
                // failure (newer schema, busy, foreign) is shown as it was.
                switch offerCatalogRecovery(after: error, catalogURL: catalogURL) {
                case let .opened(recovered): catalog = recovered
                case let .failed(message): catalogFailure = message
                case .quit:
                    NSApp.terminate(nil)
                    return
                }
            }
        }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        let model = CatalogModel(
            catalog: catalog, startupError: catalogFailure, events: hub, preferences: preferences,
            startableProviders: startableProviders
        )
        model.integration.attach(preferences: preferences) // the General options the system side keeps
        configureEvidenceAtLaunch(model: model)
        self.model = model
        model.onShowSettings = { [weak self] section in self?.showSettings(section: section) }
        // Settings → Theme (D-63): the appearance and the main pane's tone, applied here to what SwiftUI does not reach.
        model.onThemeChange = { [weak self] in self?.applyTheme() }
        model.installTheme()
        installUsage(model: model, root: root, refused: refusal != nil, catalog: catalog, preferences: preferences)
        model.onTerminalFontSizeChange = { [weak self] size in
            self?.conversations?.setTerminalFontSize(size)
            self?.controller?.terminalFontSize = size
        }
        model.presentingWindow = { [weak self] in self?.window }
        // The Dock badge counts the sessions that need the user; it follows live state changes, no timer.
        model.onAttentionCountChange = { count in NSApp.dockTile.badgeLabel = DockBadge.label(count: count) }
        installSystemIntegration(model: model)
        let window = makeWindow(model: model)
        self.window = window
        traceWindowCall("launch-before-show")
        window.makeKeyAndOrderFront(nil)
        if let openingFrame { window.setFrame(openingFrame, display: true) }
        NSApp.activate()
        releaseLaunchFocus(window)
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
        // "Quit Anyway" after a shutdown that could not be verified.
        if terminatesWithoutVerifiedShutdown { return .terminateNow }
        quitIsSystemInitiated = QuitConfirmation.isSystemInitiated(reason: currentQuitReason())
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
        if quitIsSystemInitiated, let open = quitQuestion {
            // The system is quitting applications while the question waits: it is not asked any more.
            window?.endSheet(open.window, returnCode: .abort)
        }
        if !quitConfirmed, !evidenceSkipsQuitQuestion(),
           let prompt = QuitConfirmation.prompt(busySessions: model?.busySessionCount() ?? 0,
                                                systemInitiated: quitIsSystemInitiated) {
            guard quitQuestion == nil else { return .terminateCancel }
            askBeforeQuitting(prompt)
            return .terminateLater
        }
        beginQuit()
        return .terminateLater
    }

    /// The Apple event that asks Loom to quit says why when the system does (log out, restart, shut down).
    private func currentQuitReason() -> UInt32? {
        NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: QuitConfirmation.reasonKeyword)?.enumCodeValue
    }

    /// Quitting stops every session; with work in flight the user is asked first. Cancel is the default
    /// button (Return) and answers Escape too.
    private func askBeforeQuitting(_ prompt: QuitConfirmation.Prompt) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.text
        alert.addButton(withTitle: prompt.cancelTitle)
        alert.addButton(withTitle: prompt.confirmTitle)
        quitQuestion = alert
        let answered: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.quitQuestion = nil
            if response == .alertSecondButtonReturn {
                self.quitConfirmed = true
                self.continueQuit()
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        presentMainWindow(reason: "quit-question")
        NSApp.activate()
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }

    private func continueQuit() {
        guard shutdownCoordinator != nil else { NSApp.reply(toApplicationShouldTerminate: true); return }
        beginQuit()
    }

    private func beginQuit() {
        guard let shutdownCoordinator else { return }
        conversations?.quitStarted()
        model?.statusMessage = "Stopping sessions before quitting…"
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
        window.title = "Sphyrna"
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
        // No appearance of its own: the window follows `NSApp.appearance` (Settings → Theme → Appearance).
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        let split = MainSplitViewController(model: model, settingsNavigation: { [weak self] in self?.settingsController?.navigation })
        window.contentViewController = split.makeWindowContentController()
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
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWindowActivity() }
            }
        }
        return window
    }

    /// Native full screen auto-hides the main window's empty toolbar with the menu bar, so it does not cover the top of the pane
    /// (`MainWindowFullScreen`). Only the main window has this delegate.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        MainWindowFullScreen.presentationOptions(proposed: proposedOptions)
    }

    /// A conversation counts as viewed only while the window is visible, not
    /// occluded, key, and the application is active. The relative times tick
    /// whenever the window can be seen (visible, not occluded, not minimized, app
    /// not hidden), key or not.
    private func updateWindowActivity() {
        guard let window, let model else { return }
        model.setWindowVisible(window.isVisible && window.occlusionState.contains(.visible)
                               && !window.isMiniaturized && !NSApp.isHidden)
        let active = window.isVisible && window.occlusionState.contains(.visible) && window.isKeyWindow && NSApp.isActive
        model.setWindowActive(active)
        usage?.windowActivityChanged(active) // the usage model acts on a change only
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
        model?.ownershipNotice = "New sessions are turned off because Sphyrna's process helper is missing. Without it Sphyrna cannot make sure Stop and Quit end all of a session's background work. Reinstall Sphyrna to fix this."
    }

    /// AppKit gives the first text field of a freshly shown window the key focus, which put the caret in the
    /// sidebar's search field at launch. 0.4.4 never did that on purpose (the terminal took the focus when a
    /// session was selected; the search field takes it only on Find, ⌘F). The window's first responder is
    /// let go of now and once more after the window's first layout; a field the user focuses meanwhile is not
    /// taken back (only a field editor that nobody typed into is released).
    private func releaseLaunchFocus(_ window: NSWindow) {
        func release() {
            guard model?.showsDevTerminal != true, let editor = window.firstResponder as? NSTextView,
                  editor.isFieldEditor, editor.string.isEmpty else { return }
            window.makeFirstResponder(nil)
        }
        release()
        DispatchQueue.main.async { release() }
    }

    @objc func showMainWindow() { presentMainWindow(reason: "window-menu") }

    func presentMainWindow(reason: String) {
        traceWindowCall("show-before-\(reason)")
        window?.makeKeyAndOrderFront(nil)
        if model?.showsDevTerminal == true, let view = controller?.surface?.view {
            window?.makeFirstResponder(view)
        }
        traceWindowCall("show-after-\(reason)")
    }

    /// Whatever is still waiting for the preference write debounce (the window frame) goes to disk.
    func applicationWillTerminate(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil
        approvalNotifier?.stop()
        keepAwake?.stop()
        usageWatcher?.stop()
        model?.flushPreferences()
    }

    func windowWillClose(_ notification: Notification) {
        recordVisibility("close")
        model?.setWindowActive(false)
        usage?.windowActivityChanged(false)
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
                self?.model?.ownershipNotice = "Work left by a previous Sphyrna could not be fully stopped: "
                    + recovery.leftovers.joined(separator: "; ")
            }

            // One runtime owns providers, lifecycle and cleanup. With no readable
            // catalog there is no runtime: actions stay disabled and nothing starts.
            var runtime: SessionRuntime?
            if let catalog {
                let created = SessionRuntime(
                    supervisor: supervisor, catalog: catalog,
                    configuration: runtimeConfiguration(root: root, supervisor: supervisor, model: model)
                )
                // Remora's host, with its forgetter registered before `start()`: a deletion that start recovers reaches Remora's
                // memory too. It starts nothing and reads only a folder listing; nothing calls Remora until the UI does.
                let slot = toolchainSlot
                await model.installRemora(runtime: created, dataRoot: root, toolchain: { try await slot.claude() },
                                          profile: usageProfileLayout(root: root))
                try await created.start()
                // The one session service: it holds the Chat host (made with the model's closures), the controller keeps the
                // terminals for it, and the model reads its state and the host through it. D-100: while the Chat face is
                // frozen (`ChatFreeze`) there is no host, so every Claude session runs in the terminal.
                let chatHost = ChatFreeze.isFrozen ? nil : model.makeChatSessionHost(runtime: created, dataRoot: root)
                let sessions = SessionService(runtime: created, startableProviders: startableProviders,
                                              structuredHost: chatHost)
                let conversations = ConversationController(service: sessions, model: model)
                model.chatSessionsInstalled(runtime: created, host: chatHost)
                await conversations.begin()
                // The cleanup review (Settings → Sessions) is in every build (D-69); it deletes only what
                // the user confirms there.
                let cleanup = CleanupCoordinator(runtime: created)
                await cleanup.recordLaunch()
                model.installCleanupReview(cleanup)
                self.runtime = created
                self.conversations = conversations
                diagnostics?.isAvailable = true
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
            showError("Sphyrna could not start its process supervisor.", detail: String(describing: error))
        }
    }

    /// Provider CLIs come from the user's real terminal environment; only the development
    /// flavor's acceptance runs (`--evidence`) may substitute fixture providers and isolated profiles.
    private func runtimeConfiguration(root: URL, supervisor: ProcessSupervisor, model: CatalogModel) -> SessionRuntimeConfiguration {
        let helpers = Bundle.main.executableURL!.deletingLastPathComponent()
        let socketDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(identity.socketDirectoryName, isDirectory: true)
        let origin = LaunchEnvironment.origin(
            parent: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier, parentPID: getppid()
        )
        let system = SystemProviderToolchains(supervisor: supervisor, origin: origin)
        let evidence = evidenceToolchains(root: root, supervisor: supervisor, origin: origin)
        let toolchains: ProviderToolchainResolver = evidence ?? { provider in try await system.toolchain(for: provider) }
        toolchainSlot.provide(toolchains)
        // A delete targets the folder the login shell names (DP-CP4-8); an acceptance run has fixture providers. It shares
        // the toolchains' capture, so a launch runs the login shell once.
        var loginEnvironment: (@Sendable () async throws -> [String: String])?
        if evidence == nil {
            loginEnvironment = { try await system.terminalEnvironment().environment }
            // Which CLIs the lists offer (C2B) is looked up in the same terminal environment; an acceptance run reads none.
            model.installHarnessAvailability(HarnessAvailabilityReader(toolchains: system))
        }
        // The commit names the build for Codex; CFBundleVersion is only a growing number.
        let info = Bundle.main.infoDictionary
        let build = info?["LoomRevision"] as? String ?? info?["CFBundleVersion"] as? String ?? "dev"
        return SessionRuntimeConfiguration(
            toolchains: toolchains, hookHelperPath: helpers.appendingPathComponent("loom-hook").path,
            socketDirectory: socketDirectory,
            clientVersion: "loom-\(build)",
            // A running session is never stopped for inactivity (user decision, 8 Oct 2026).
            idlePolicy: SessionIdlePolicy(stopsIdleRuns: false),
            claudeProfileDirectory: evidenceClaudeProfile(root: root),
            claudeLoginEnvironment: loginEnvironment,
            claudePluginDirectory: root.appendingPathComponent("claude-plugin", isDirectory: true),
            // A failed start makes the next one read the CLI again instead of reusing the cache.
            toolchainInvalidator: { provider in await system.invalidate(provider) },
            // Home's Continue lists runs by what the catalog says; it reads again once the open runs are closed.
            runsRecovered: { await model.runsWereRecovered() },
            // An opened session whose agent passed no `--mode` takes Sphyrna's default, resolved as the draft resolves it
            // (Q3, D-103): Settings' fixed mode, else the project's last used, else Ask before edits.
            defaultOpenedMode: { [weak model] projectID in
                await MainActor.run { model?.draftStartChoices(projectID: projectID).permissionMode }
            }
        )
    }

    @objc func toggleSidebarFromMenu(_ sender: Any?) {
        model?.onToggleSidebar?()
    }
    @objc func newClaudeFromMenu(_ sender: Any?) {
        model?.beginNewSessionFromCommand()
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
    @objc func askQuickQuestionFromMenu(_ sender: Any?) {
        presentMainWindow(reason: "quick-question-menu")
        model?.askQuickQuestion()
    }
    @objc func deleteFromMenu(_ sender: Any?) {
        if let id = model?.selectedSessionID { model?.requestDeletion(id) }
    }
    @objc func showNextTab(_ sender: Any?) { model?.selectAdjacentTab(.next) }
    @objc func showPreviousTab(_ sender: Any?) { model?.selectAdjacentTab(.previous) }
    @objc func closeTabFromMenu(_ sender: Any?) { model?.closeSelectedTab() }
    @objc func reopenClosedTabFromMenu(_ sender: Any?) { model?.reopenClosedTab() }
    /// Close Window (⌘W). A method of its own, so that the sheet rule can hold the key back while a question is open.
    @objc func closeWindowFromMenu(_ sender: Any?) { window?.performClose(nil) }
    @objc func jumpToNextAttention(_ sender: Any?) { jumpToAttention(item: .next) }
    @objc func jumpToPreviousAttention(_ sender: Any?) { jumpToAttention(item: .previous) }
    private func jumpToAttention(item: StepDirection) {
        let event = NSApp.currentEvent
        model?.jumpToAttention(SessionShortcut.attentionDirection(
            fromKeyDown: event?.type == .keyDown, shift: event?.modifierFlags.contains(.shift) == true, item: item))
    }
    @objc func selectNextSession(_ sender: Any?) { model?.selectAdjacentSession(.next) }
    @objc func selectPreviousSession(_ sender: Any?) { model?.selectAdjacentSession(.previous) }
    /// Edit > Find (⌘F): the sidebar's search is the command palette's door, so Find opens the palette (an open one stays).
    @objc func findFromMenu(_ sender: Any?) {
        presentMainWindow(reason: "find-menu")
        if let model, !model.palette.isOpen { model.openPalette() }
    }

    /// Menu commands follow the same rules as the buttons.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(newCodexFromMenu(_:)),
           CatalogModel.newSessionUnavailableReason(.codex, startable: startableProviders) != nil {
            return false // listed in every build, startable only where the build includes Codex (D-69)
        }
        guard let model else { return true }
        // A sheet asks one question: the window's own key commands wait until it is answered, so no shortcut renames, deletes,
        // rewinds, closes or starts anything behind it. The menu items stay usable with the mouse (only a key-down is held back).
        if NSApp.currentEvent?.type == .keyDown,
           MainWindowKeys.holdsBack(attachedSheet: window?.attachedSheet != nil, sheetOpen: model.mainSheetIsOpen) {
            return false
        }
        switch item.action {
        case #selector(newClaudeFromMenu(_:)):
            return model.canStart(.newSessionDefault, projectID: model.contextProjectID)
        case #selector(newCodexFromMenu(_:)):
            return model.canStart(.codex, projectID: model.contextProjectID)
        case #selector(resumeFromMenu(_:)):
            return model.selectedRow.map(model.canResume) ?? false
        case #selector(stopFromMenu(_:)):
            return model.selectedRow.map(model.canStop) ?? false
        case #selector(askQuickQuestionFromMenu(_:)):
            let reason = model.quickQuestionUnavailableReason
            item.subtitle = reason
            item.toolTip = reason
            return reason == nil
        case #selector(deleteFromMenu(_:)):
            // Cmd+Delete belongs to a text field being edited (search, or rename's field) and to a focused terminal
            // (Cmd+Backspace edits the prompt line there); a sheet open already held the key back above. The menu item
            // itself stays usable with the mouse.
            if NSApp.currentEvent?.type == .keyDown {
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSText || responder is LoomTerminalView { return false }
            }
            return model.selectedRow.map(model.canDelete) ?? false
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return model.canSelectAdjacentTab
        case #selector(closeTabFromMenu(_:)):
            return model.canCloseSelectedTab
        case #selector(reopenClosedTabFromMenu(_:)):
            return model.canReopenClosedTab
        case #selector(jumpToNextAttention(_:)), #selector(jumpToPreviousAttention(_:)):
            return model.canJumpToAttention
        case #selector(selectNextSession(_:)):
            return model.canSelectAdjacentSession(.next)
        case #selector(selectPreviousSession(_:)):
            return model.canSelectAdjacentSession(.previous)
        case #selector(collectDiagnosticsFromMenu(_:)):
            return diagnostics?.canCollect ?? false
        case #selector(findFromMenu(_:)):
            // The palette opens over the main window; another key window (Settings) keeps Cmd+F to itself.
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
        // The report is written either way. A logout, restart or shutdown is not held up by a shutdown that
        // could not be verified: the system's own quit goes on.
        if quitIsSystemInitiated {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        // Timeout or remaining processes never count as a successful quit.
        NSApp.reply(toApplicationShouldTerminate: false)
        // A failure, not progress: the "Stopping…" status gives way to it.
        model?.statusMessage = nil
        model?.reportFailure("Sphyrna did not quit: it could not confirm that every session process stopped.")
        presentMainWindow(reason: "failed-quit")
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sphyrna could not verify that its processes stopped."
        let remaining = report.remainingCountVerified == false ? "unavailable" : String(report.remaining.count)
        alert.informativeText = QuitConfirmation.failedShutdownText(remaining: remaining, errors: report.errors)
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Keep Sphyrna Open")
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        quitAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.quitAlert = nil
            switch response {
            case .alertFirstButtonReturn:
                NSApp.terminate(nil)
            case .alertThirdButtonReturn:
                // Without a verified shutdown: Loom ends, whatever it could not stop may keep running.
                self.terminatesWithoutVerifiedShutdown = true
                NSApp.terminate(nil)
            default:
                self.quitConfirmed = false
            }
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

    @objc func showSettings(_ sender: Any?) { showSettings(section: nil) }
    /// About Sphyrna (the app menu): Settings on its About section.
    @objc func showAbout(_ sender: Any?) { showSettings(section: .about) }

    func showSettings(section: SettingsSection?) {
        settingsController?.show(section: section)
    }
}
