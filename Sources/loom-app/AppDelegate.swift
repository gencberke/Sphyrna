import AppKit
import Darwin
import LoomCatalogUI
import LoomCore
import LoomLaunchOptions
import LoomTerminal
import Synchronization
import SwiftUI

/// One native window: the catalog sidebar (CP5 B) beside a detail pane. The
/// A-slice synthetic run stays available as a development terminal. Cmd+W and
/// the close button only close the window; Cmd+Q waits for the shared
/// supervisor shutdown and stays open when it cannot be verified. Opening the
/// app or selecting a conversation starts no provider, PTY or terminal.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: LaunchOptions
    private var arguments: [String] { options.arguments }
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var resourcePreviousDevTerminal: Bool?
    private var terminalPanel: NSView?
    private(set) var model: CatalogModel?
    private var splitController: MainSplitViewController?
    private var controller: TerminalRunController?
    private var supervisor: ProcessSupervisor?
    private var runtime: SessionRuntime?
    private var conversations: ConversationController?
    private var startupTask: Task<Void, Never>?
    private var startupFinished = false
    private var runDirectory: URL?
    private var evidence: DevelopmentEvidence?
    private var quitAlert: NSAlert?
    /// Bounded visibility log so measurements can reject intervals in which
    /// the window was shown, hidden or occluded (CP5 §13 madde 6).
    private(set) var visibilityEvents: [[String: Any]] = []

    init(arguments: [String]) { self.options = LaunchOptions(arguments: arguments) }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
            } catch {
                catalogFailure = String(describing: error)
            }
        }
        let model = CatalogModel(
            catalog: catalog, startupError: catalogFailure, events: hub,
            preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        )
        if options.isEvidence {
            switch value(after: "--evidence-transparency") {
            case "glass": model.sidebarTransparencyOverride = false
            case "opaque": model.sidebarTransparencyOverride = true
            default: break // system is the normal behavior; no OS setting is changed.
            }
        }
        self.model = model
        model.onShowSettings = { [weak self] in self?.showSettings(nil) }
        model.onTerminalFontSizeChange = { [weak self] size in
            self?.conversations?.setTerminalFontSize(size)
            self?.controller?.terminalFontSize = size
        }
        model.presentingWindow = { [weak self] in self?.window }
        let window = makeWindow(model: model)
        self.window = window
        traceWindowCall("launch-before-show")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        traceWindowCall("launch-after-show")
        updateWindowActivity()
        if let directory = options.evidenceDirectory {
            evidence = DevelopmentEvidence(directory: URL(fileURLWithPath: directory), app: self)
        }
        // The runtime is built off the launch path; opening the app starts no
        // provider, PTY or terminal, and Quit waits for this to finish first.
        startupTask = Task { @MainActor in
            if refusal == nil { await startRuntime(root: root, hub: hub, catalog: catalog, model: model) }
            await model.start()
            startupFinished = true
            // A development run may ask for a fixture; normal launch starts nothing.
            if evidenceMode, let index = arguments.firstIndex(of: "--fixture") {
                newTerminal(fixtureArguments: Array(arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }))
            }
        }
    }

    /// `~/Library/Application Support/Loom-Dev` (or `Loom`) for a normal launch.
    /// Evidence runs always use an isolated root (`--data-root` or
    /// `<evidence>/data`); see `LaunchOptions.resolveDataRoot`.
    private func dataRoot() -> LaunchOptions.DataRoot {
        let dataName = Bundle.main.bundleIdentifier == "local.loom.desktop" ? "Loom" : "Loom-Dev"
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dataName)", isDirectory: true)
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
                guard controller != nil else { NSApp.reply(toApplicationShouldTerminate: true); return }
                beginQuit()
            }
            return .terminateLater
        }
        guard controller != nil else { return .terminateNow }
        beginQuit()
        return .terminateLater
    }

    private func beginQuit() {
        guard let controller else { return }
        conversations?.quitStarted()
        model?.statusMessage = "Stopping owned processes…"
        let started = ProcessInfo.processInfo.systemUptime
        let recordQuit = evidence?.quitRecorder(runtime: runtime, started: started)
        controller.requestQuit(prepareReply: recordQuit) { [weak self] report in
            self?.quitFinished(report)
        }
    }

    // MARK: Window

    private func makeWindow(model: CatalogModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
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
        window.minSize = NSSize(width: 780, height: 500)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        let split = MainSplitViewController(model: model)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1220, height: 780))
        window.center()
        splitController = split
        // The terminal view of a development run is hosted in this transparent panel.
        let panel = NSView()
        terminalPanel = panel
        let center = NotificationCenter.default
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
        model.setWindowActive(
            window.isVisible && window.occlusionState.contains(.visible) && window.isKeyWindow && NSApp.isActive
        )
    }

    /// Every run starts in its own run-host scope. Without the bundled host
    /// nothing can start safely, so starts fail visibly instead of narrowing.
    private func runScopeLauncher() -> RunScopeLauncher {
        var host = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LoomRunHost.app")
        // Acceptance only: prove that a missing host refuses starts honestly.
        if options.isEvidence, ProcessInfo.processInfo.environment["LOOM_FORCE_SCOPE_FAILURE"] == "1" {
            host = host.appendingPathComponent("missing")
        }
        let isDevelopment = Bundle.main.bundleIdentifier != "local.loom.desktop"
        let sockets = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(isDevelopment ? ".loom-dev/scopes" : ".loom/scopes", isDirectory: true)
        return RunScopeLauncher(hostBundle: host, socketDirectory: sockets)
    }

    private func showOwnershipNotice(_ launcher: RunScopeLauncher) {
        let executable = launcher.hostBundle
            .appendingPathComponent("Contents/MacOS/\(RunScopeLauncher.hostExecutableName)")
        guard !FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        model?.ownershipNotice = "Conversations cannot start: Loom's run-scope helper is missing, so Loom could not guarantee that Stop and Quit end all of a conversation's background work."
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

    func windowWillClose(_ notification: Notification) {
        recordVisibility("close")
        model?.setWindowActive(false)
    }

    private func traceWindowCall(_ reason: String, hasVisibleWindows: Bool? = nil) {
        guard options.isEvidence else { return }
        recordVisibility(reason, hasVisibleWindows: hasVisibleWindows)
    }

    private func recordVisibility(_ reason: String, hasVisibleWindows: Bool? = nil) {
        guard let window else { return }
        if visibilityEvents.count >= 200 { visibilityEvents.removeFirst() }
        var event: [String: Any] = [
            "uptime": ProcessInfo.processInfo.systemUptime, "reason": reason,
            "visible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible),
        ]
        if options.isEvidence {
            event["applicationActive"] = NSApp.isActive
            event["applicationHidden"] = NSApp.isHidden
            event["windowKey"] = window.isKeyWindow
            if let hasVisibleWindows { event["hasVisibleWindows"] = hasVisibleWindows }
            // Only numeric envelope metadata; no event payload or sender profile.
            // AppKit may invoke a callback outside Apple-event dispatch, in which
            // case the absent metadata is deliberately unavailable.
            if let appleEvent = NSAppleEventManager.shared().currentAppleEvent {
                var envelope: [String: Any] = ["class": Int(appleEvent.eventClass), "id": Int(appleEvent.eventID)]
                // SDK AEDataModel.h keySenderPIDAttr ('spid'), returned as SInt32.
                envelope["senderPID"] = appleEvent.attributeDescriptor(forKeyword: 0x73706964)
                    .map { Int($0.int32Value) } as Any? ?? NSNull()
                event["appleEvent"] = envelope
            } else { event["appleEvent"] = NSNull() }
        }
        visibilityEvents.append(event)
    }

    // MARK: Runs

    private func startRuntime(root: URL, hub: SessionEventHub, catalog: SessionCatalog?,
                              model: CatalogModel) async {
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
            if let owner = try ProcessTable.snapshot().first(where: { $0.identity.pid == getpid() }) {
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

            // Acceptance only (CP5 §18.1 madde 3): the first quit reports a
            // failure without stopping anything, so the real alert and Try Again
            // path can be exercised. Requires --evidence.
            let failFirstQuit = options.isEvidence && arguments.contains("--fail-first-quit")
            let quitAttempts = Mutex(0)
            let controller = TerminalRunController(
                events: hub,
                launch: TerminalRunController.syntheticLaunch(
                    supervisor: supervisor,
                    executable: Bundle.main.executableURL!.deletingLastPathComponent()
                        .appendingPathComponent("loom-test-child").path,
                    directory: FileManager.default.homeDirectoryForCurrentUser.path
                ),
                shutdown: { [runtime] in
                    let attempt = quitAttempts.withLock { $0 += 1; return $0 }
                    if failFirstQuit, attempt == 1 {
                        return ShutdownReport(remainingCountVerified: false,
                            elapsedSeconds: 0, signals: [], remaining: [],
                            errors: ["Forced first-quit failure (--fail-first-quit)"],
                            outsideOwnership: [], ownershipGuarantee: "not attempted"
                        )
                    }
                    // Everything the app owns goes through the runtime's one shutdown.
                    if let runtime { return await runtime.shutdown() }
                    return await supervisor.shutdown()
                }
            )
            controller.onStateChange = { [weak self] state in
                if case .ended = state {
                    self?.model?.statusMessage = "Process exited. Option+Cmd+N starts a new synthetic terminal."
                }
            }
            controller.onLaunchError = { [weak self] error in
                self?.showError("The synthetic terminal could not start.", detail: String(describing: error))
            }
            controller.terminalFontSize = model.terminalFontSize
            self.controller = controller
        } catch {
            showError("Loom could not start its process supervisor.", detail: String(describing: error))
        }
    }

    /// Provider CLIs come from the user's real terminal environment. Acceptance
    /// runs (`--evidence`) may substitute fixture providers and isolated
    /// profiles; a normal launch cannot.
    private func runtimeConfiguration(root: URL, supervisor: ProcessSupervisor) -> SessionRuntimeConfiguration {
        let helpers = Bundle.main.executableURL!.deletingLastPathComponent()
        let isDevelopment = Bundle.main.bundleIdentifier != "local.loom.desktop"
        let socketDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(isDevelopment ? ".loom-dev" : ".loom", isDirectory: true)
        let acceptance = options.isEvidence
        let toolchains: ProviderToolchainResolver
        if acceptance, let fixtures = value(after: "--fake-providers") {
            let fake = URL(fileURLWithPath: fixtures).appendingPathComponent("loom-fake-provider").path
            let state = root.appendingPathComponent("fake-state", isDirectory: true)
            // Acceptance: a slow environment resolution, so Quit can land mid-start.
            let delay = value(after: "--fake-toolchain-delay").flatMap(Double.init) ?? 0
            toolchains = { provider in
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                return ProviderToolchain(
                    provider: provider, executable: fake,
                    capabilities: ProviderCapabilities(
                        version: "fixture",
                        help: "--settings <settings> --session-id <id> --remote <ADDR>",
                        serverHelp: "--listen <URL>"
                    ),
                    environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                                  "LOOM_FAKE_STATE": state.path],
                    profileDirectory: root.appendingPathComponent(
                        provider == .codex ? "codex-home" : "claude-config", isDirectory: true
                    )
                )
            }
        } else {
            let origin = LaunchEnvironment.origin(
                parent: ProcessInfo.processInfo.environment,
                bundleIdentifier: Bundle.main.bundleIdentifier, parentPID: getppid()
            )
            let isolatedClaude = acceptance ? value(after: "--claude-config").map { URL(fileURLWithPath: $0) } : nil
            let isolatedCodex = acceptance ? value(after: "--codex-home").map { URL(fileURLWithPath: $0) } : nil
            let system = SystemProviderToolchains(
                supervisor: supervisor, origin: origin,
                claudeProfile: isolatedClaude, codexHome: isolatedCodex
            )
            toolchains = { provider in try await system.toolchain(for: provider) }
        }
        return SessionRuntimeConfiguration(
            toolchains: toolchains, hookHelperPath: helpers.appendingPathComponent("loom-hook").path,
            socketDirectory: socketDirectory,
            clientVersion: "loom-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")"
        )
    }

    @objc func newTerminalFromMenu(_ sender: Any?) { newTerminal(fixtureArguments: []) }
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

    /// A slice: one launching or live synthetic run at a time.
    func newTerminal(fixtureArguments: [String]) {
        guard evidenceMode, let controller else { return }
        guard let surface = controller.newTerminal(
            arguments: fixtureArguments.isEmpty ? ["interactive"] : fixtureArguments
        ) else {
            NSSound.beep()
            return
        }
        surface.onTitle = { [weak self] title in self?.model?.statusMessage = title }
        surface.onInputError = { [weak self] error in self?.model?.statusMessage = error.description }
        show(surface)
        model?.showDevTerminal(DevTerminal(panel: terminalPanel ?? NSView()))
    }

    private func show(_ surface: TerminalSurface) {
        guard let panel = terminalPanel else { return }
        panel.subviews.forEach { $0.removeFromSuperview() }
        let view = surface.view
        view.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            view.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
        panel.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(view)
        // CP5 §3.2 renderer experiment only; the product ships one path.
        if evidenceMode, arguments.contains("--metal") {
            do { try view.setUseMetal(true) }
            catch { showError("Metal rendering is unavailable.", detail: String(describing: error)) }
        }
    }

    // Evidence-only resource pool bridge; normal launches expose no supervisor.
    var resourceSupervisorForEvidence: ProcessSupervisor? {
        !options.isEvidence ? nil : supervisor
    }

    var resourceFixtureForEvidence: String? {
        guard options.isEvidence else { return nil }
        return Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    var resourceDirectoryForEvidence: String {
        guard case .root(let root) = dataRoot() else { return NSTemporaryDirectory() }
        return root.appendingPathComponent("evidence-resources", isDirectory: true).path
    }

    func showResourceSurfaceForEvidence(_ surface: TerminalSurface?) {
        guard options.isEvidence else { return }
        if let surface {
            if resourcePreviousDevTerminal == nil { resourcePreviousDevTerminal = model?.showsDevTerminal ?? false }
            show(surface)
            model?.showDevTerminal(DevTerminal(panel: terminalPanel ?? NSView()))
        } else {
            if let panel = terminalPanel, let responder = window?.firstResponder as? NSView,
               responder === panel || responder.isDescendant(of: panel) {
                window?.makeFirstResponder(nil)
            }
            terminalPanel?.subviews.forEach { $0.removeFromSuperview() }
            if resourcePreviousDevTerminal == true, let original = controller?.surface {
                show(original)
                model?.showDevTerminal(DevTerminal(panel: terminalPanel ?? NSView()))
            } else { model?.select(model?.selectedSessionID) }
            resourcePreviousDevTerminal = nil
        }
    }

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
        model?.statusMessage = "Quit could not verify that owned processes stopped."
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

    private func showError(_ message: String, detail: String) {
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

    @objc private func showSettings(_ sender: Any?) {
        guard let model else { return }
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.title = "Settings"
            settings.isReleasedWhenClosed = false
            settings.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        let codex = fileMenu.addItem(withTitle: "New Codex Conversation", action: #selector(newCodexFromMenu(_:)),
                                     keyEquivalent: "n")
        codex.keyEquivalentModifierMask = [.command, .shift]
        codex.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Resume Conversation", action: #selector(resumeFromMenu(_:)),
                         keyEquivalent: "r").target = self
        let stop = fileMenu.addItem(withTitle: "Stop Conversation", action: #selector(stopFromMenu(_:)),
                                    keyEquivalent: ".")
        stop.target = self
        fileMenu.addItem(.separator())
        if evidenceMode {
            let synthetic = fileMenu.addItem(withTitle: "New Synthetic Terminal (Development)",
                                             action: #selector(newTerminalFromMenu(_:)), keyEquivalent: "n")
            synthetic.keyEquivalentModifierMask = [.command, .option]
            synthetic.target = self
            fileMenu.addItem(.separator())
        }
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        windowMenu.addItem(withTitle: "Loom", action: #selector(showMainWindow), keyEquivalent: "").target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Development and fixture paths (`--fixture`, `--metal`, the synthetic
    /// terminal) exist only behind `--evidence`.
    private var evidenceMode: Bool { options.isEvidence }

    private func value(after flag: String) -> String? { options.value(after: flag) }

    // MARK: Development evidence

    /// Real providers (no `--fake-providers`): evidence carries no terminal
    /// text, titles or request text; only expected tokens' presence
    /// (`--evidence-tokens A,B`). Fixture runs keep the raw screen.
    var redactsContent: Bool { value(after: "--fake-providers") == nil }
    private var evidenceTokens: [String] {
        value(after: "--evidence-tokens")?.split(separator: ",").map(String.init) ?? []
    }

    var evidenceState: [String: Any] {
        var state: [String: Any] = [
            "pid": Int(getpid()),
            "uptime": ProcessInfo.processInfo.systemUptime,
            "windowVisible": window?.isVisible ?? false,
            "windowOcclusionVisible": window?.occlusionState.contains(.visible) ?? false,
            "windowCount": NSApp.windows.filter { $0.identifier?.rawValue == "loom-main" }.count,
            "visibilityEvents": visibilityEvents,
            "ownershipNoticeShown": model?.ownershipNotice != nil && window?.isVisible == true,
            "terminalState": controller.map { String(describing: $0.state) } ?? NSNull(),
            "quitState": controller.map { String(describing: $0.quitState) } ?? NSNull(),
            "quitAlert": quitAlert.map { [
                "message": $0.messageText, "attachedAsSheet": window?.attachedSheet === $0.window,
                "buttons": $0.buttons.map(\.title),
            ] as [String: Any] } ?? NSNull(),
            "renderer": evidenceMode && arguments.contains("--metal") ? "metal" : "coregraphics",
            "sidebarMaterial": model?.effectiveSidebarMaterial ?? "unknown",
            "effectiveReduceTransparency": model?.effectiveReduceTransparency ?? true,
            "chaseIndicators": window?.contentView.map { IndicatorEvidence.chases(in: $0) } ?? [:],
            "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "transparencyOverride": model?.sidebarTransparencyOverride.map { $0 ? "opaque" : "glass" } ?? "system",
            "runDirectory": runDirectory?.path ?? NSNull(),
        ]
        if let model {
            let statistics = model.statistics
            state["catalog"] = [
                "ready": model.isReady, "startupError": model.startupError ?? NSNull(),
                "viewMode": model.viewMode.rawValue, "search": model.searchText,
                "selectedSessionID": model.selectedSessionID?.uuidString ?? NSNull(),
                "selectedTitle": redactsContent ? NSNull() : (model.selectedRow.map { model.title(of: $0) } ?? NSNull()),
                "projects": model.projects.map {
                    ["id": $0.id.uuidString, "name": $0.name, "collapsed": $0.collapsed,
                     "count": model.sessionCounts[$0.id] ?? 0] as [String: Any]
                },
                "unassignedCount": model.sessionCounts[nil] ?? 0,
                "activityRows": model.list(for: .activity).rows.count,
                "activityFirstTitles": redactsContent ? [] : model.list(for: .activity).rows.prefix(3).map { model.title(of: $0) },
                "activityHasMore": model.list(for: .activity).hasMore,
                "projectRows": model.projects.map { model.list(for: .project($0.id)).rows.count },
                "errorMessage": model.errorMessage ?? NSNull(), "infoMessage": model.infoMessage ?? NSNull(),
                "windowIsActive": model.windowIsActive, "sidebarCollapsed": model.sidebarCollapsed,
                "actionsAvailable": model.actionsAvailable, "quitting": model.quitting,
                "busy": model.busy.map { ["id": $0.key.uuidString, "state": String(describing: $0.value)] },
                "startingKeys": model.startingKeys.map { "\($0.provider.rawValue):\($0.projectID?.uuidString ?? "none")" },
                "selectedIndicator": model.selectedRow?.indicator.label ?? NSNull(),
                "selectedProvider": model.selectedRow?.record.session.provider.rawValue ?? NSNull(),
                "selectedProjectID": model.selectedRow?.record.projectID?.uuidString ?? NSNull(),
                "selectedLifecycle": model.selectedRow?.record.lifecycle.rawValue ?? NSNull(),
                "selectedRunID": model.selectedRow?.live?.runID?.uuidString ?? NSNull(),
                "selectedIssue": model.selectedRow?.live?.issue ?? NSNull(),
                "selectedStopFailure": model.selectedRow?.live?.stopFailure ?? NSNull(),
                "selectedRequests": (model.selectedRow?.live?.userRequests ?? []).map {
                    ["id": $0.id, "summary": redactsContent ? "" : $0.summary, "answerable": $0.isAnswerable,
                     "failure": $0.failure ?? ""] as [String: Any]
                },
                "selectedHasTerminalView": model.selectedSessionID.flatMap { model.terminalView(for: $0) } != nil,
                "activityRowDetails": model.list(for: .activity).rows.prefix(12).map { row in
                    ["id": row.id.uuidString, "provider": row.record.session.provider.rawValue,
                     "title": redactsContent ? "" : model.title(of: row), "indicator": row.indicator.label ?? "",
                     "live": row.live?.runID != nil, "lifecycle": row.record.lifecycle.rawValue,
                     "conversationID": row.record.session.providerConversationID ?? "",
                     "lastUsed": row.record.lastUsedAt.timeIntervalSince1970,
                     "issue": row.live?.issue ?? ""] as [String: Any]
                },
                "showsDevTerminal": model.showsDevTerminal,
                "pageQueries": statistics.pageQueries, "framesApplied": statistics.framesApplied,
                "fastPathFrames": statistics.fastPathFrames, "fullReconciles": statistics.fullReconciles,
                "rowModels": statistics.rowModels, "loadedRows": statistics.loadedRows,
                "startMilliseconds": statistics.startMilliseconds,
                "preferences": [
                    "viewMode": model.preferencesSnapshot.viewMode.rawValue,
                    "selectedSessionID": model.preferencesSnapshot.selectedSessionID?.uuidString ?? NSNull(),
                    "sidebarWidth": model.preferencesSnapshot.sidebarWidth,
                    "sidebarCollapsed": model.preferencesSnapshot.sidebarCollapsed,
                ] as [String: Any],
            ] as [String: Any]
        }
        if let window {
            state["windowContentSize"] = [Double(window.contentLayoutRect.width), Double(window.contentLayoutRect.height)]
            state["sidebarWidth"] = splitController?.sidebarWidth ?? NSNull()
            state["attachedSheet"] = window.attachedSheet.map { String(describing: type(of: $0)) } ?? NSNull()
            state["appActive"] = NSApp.isActive
            state["windowIsKey"] = window.isKeyWindow
            state["windowFrameSize"] = [Double(window.frame.width), Double(window.frame.height)]
            state["openPanelVisible"] = NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible }
            state["renameDraftText"] = model?.renameDraft?.text ?? NSNull()
        }
        state["terminalSurfaceExists"] = controller?.surface != nil
        state["conversationTerminals"] = (conversations?.terminalEvidence(
            redacted: redactsContent, tokens: evidenceTokens
        ) ?? []).map {
            ["runID": $0.runID.uuidString, "owner": $0.owner.uuidString,
             "screenTail": $0.screenTail ?? NSNull(), "tokenPresence": $0.tokenPresence,
             "outputBytes": $0.outputBytes, "pendingInputBytes": $0.pendingInputBytes,
             "inputErrors": $0.inputErrors] as [String: Any]
        }
        if let surface = controller?.surface, let data = try? JSONEncoder().encode(surface.statistics),
           let object = try? JSONSerialization.jsonObject(with: data) {
            state["terminal"] = object
        }
        return state
    }

    func runtimeEvidence() async -> [String: Any] { await conversations?.runtimeEvidence() ?? [:] }
    func typeForEvidence(_ text: String, intoSession id: UUID) -> Bool {
        conversations?.typeForEvidence(text, intoSession: id) ?? false
    }
    func closeWindowForEvidence() {
        traceWindowCall("evidence-close-before")
        window?.performClose(nil)
        traceWindowCall("evidence-close-after")
    }
    /// The folder panel, whether attached as a sheet or standalone.
    private var openPanelForEvidence: NSOpenPanel? {
        if let panel = window?.attachedSheet as? NSOpenPanel { return panel }
        return NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible }
    }
    func closeSheetForEvidence() {
        if let panel = openPanelForEvidence { panel.cancel(nil); return }
        guard let window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: .cancel)
    }
    /// Ends the real folder panel and hands the chosen folder to the same
    /// handler its completion uses. NSOpenPanel's `ok:` must not be called
    /// directly (AppKit raises), and no key events can be synthesized here, so
    /// the URL AppKit itself would return is not exercised.
    func chooseFolderInPanelForEvidence(_ path: String) {
        closeSheetForEvidence()
        model?.folderPanelFinished(accepted: true, url: URL(fileURLWithPath: path, isDirectory: true))
    }
    func toggleSidebarForEvidence() { splitController?.toggleSidebar(nil) }
    func setSidebarWidthForEvidence(_ width: Double) { splitController?.setSidebarWidth(width) }
    func resizeForEvidence(width: Double, height: Double) {
        window?.setContentSize(NSSize(width: width, height: height))
    }

    /// Renders the window's content view (the app's own pixels, no screen
    /// recording permission needed).
    func saveScreenshot(to url: URL) {
        Self.writePNG(of: window?.contentView, to: url)
        // The window frame view also holds the titlebar and the traffic lights,
        // which the content view alone never shows.
        let framed = url.deletingPathExtension().appendingPathExtension("window.png")
        Self.writePNG(of: window?.contentView?.superview, to: framed)
    }

    private static func writePNG(of view: NSView?, to url: URL) {
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    /// Evidence only: hands a file's bytes to the development terminal's engine
    /// as if the program had printed them (color and rendering samples).
    func feedForEvidence(path: String) {
        guard let surface = controller?.surface, let data = FileManager.default.contents(atPath: path) else { return }
        surface.outputSink.receive(data)
    }
    /// Evidence: where the window buttons are relative to their container and
    /// whether a real hit test at their center and near their bottom edge lands on them.
    func windowButtonsEvidence() -> [String: Any] {
        guard let window, let frameView = window.contentView?.superview else { return [:] }
        var result: [String: Any] = ["windowContent": "\(window.contentView?.bounds.size ?? .zero)",
                                     "fullScreen": window.styleMask.contains(.fullScreen)]
        for (name, kind) in [("close", NSWindow.ButtonType.closeButton), ("mini", .miniaturizeButton), ("zoom", .zoomButton)] {
            guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
            func hit(_ y: CGFloat) -> String {
                let point = frameView.convert(NSPoint(x: button.bounds.midX, y: y), from: button)
                let view = frameView.hitTest(point)
                return view === button ? "button" : "\(view.map { String(describing: type(of: $0)) } ?? "nil")"
            }
            let inside = container.bounds.contains(button.frame)
            result[name] = ["frame": "\(button.frame)", "container": "\(type(of: container))",
                            "containerBounds": "\(container.bounds)", "fullyInside": inside,
                            "hitCenter": button.isHidden ? "hidden" : hit(button.bounds.midY),
                            "hitNearBottom": button.isHidden ? "hidden" : hit(button.bounds.minY + 1),
                            "hitNearTop": button.isHidden ? "hidden" : hit(button.bounds.maxY - 1)]
        }
        result["controls"] = controlHitTests(frameView: frameView)
        return result
    }

    /// Hit-tests the center of every header control through the window's frame
    /// view, like a click would; each must land in the SwiftUI hosting view and
    /// not in the toolbar view that spans the titlebar. Centers come from the
    /// header layout (sidebar row 26 pt below the top; 26 pt wide controls, 4 pt
    /// apart, 10 pt padding; detail row padded 8 + 14), then a sweep along the
    /// header center line reports every x range that does not reach a hosting view.
    private func controlHitTests(frameView: NSView) -> [String: Any] {
        guard let window, let model else { return [:] }
        let width = window.frame.width
        let y = window.frame.height - 26
        func hit(_ x: CGFloat) -> (type: String, hosting: Bool, toolbar: Bool) {
            let point = frameView.convert(NSPoint(x: x, y: y), from: nil)
            let view = frameView.hitTest(point)
            var ancestor = view
            var hosting = false, toolbar = false
            while let current = ancestor {
                let name = String(describing: type(of: current))
                if name.contains("HostingView") { hosting = true }
                if name.contains("Toolbar") { toolbar = true }
                ancestor = current.superview
            }
            return (view.map { String(describing: type(of: $0)) } ?? "nil", hosting, toolbar)
        }
        var points: [(String, CGFloat)] = []
        let sidebarWidth = CGFloat(splitController?.sidebarWidth ?? 0)
        if !model.sidebarCollapsed {
            let leading: CGFloat = window.styleMask.contains(.fullScreen) ? 0 : 76
            points += [("sidebar toggle", 10 + leading + 13), ("sidebar ellipsis", sidebarWidth - 10 - 13),
                       ("sidebar activity mode", sidebarWidth - 10 - 26 - 4 - 13),
                       ("sidebar projects mode", sidebarWidth - 10 - 2 * (26 + 4) - 13)]
        } else {
            points.append(("detail toggle", 8 + 14 + 66 + 8 + 13))
        }
        points.append(("detail ellipsis", width - 8 - 14 - 13))
        let controls = points.map { name, x -> [String: Any] in
            let result = hit(x)
            return ["control": name, "x": Double(x), "hit": result.type,
                    "inSwiftUIHostingView": result.hosting, "inToolbarView": result.toolbar]
        }
        // Sweep: every 4 pt along the header center line outside the native buttons.
        var bad: [String] = []
        var x: CGFloat = 84
        while x < width - 2 {
            let result = hit(x)
            if !result.hosting || result.toolbar { bad.append("\(Int(x)):\(result.type)") }
            x += 4
        }
        return ["points": controls, "sweepFrom84NotHosting": bad, "centerLineYFromTop": 26]
    }
    func toggleFullScreenForEvidence() { window?.toggleFullScreen(nil) }
    func newTerminalForEvidence() { newTerminal(fixtureArguments: []) }
    var surfaceForEvidence: TerminalSurface? { controller?.surface }
    /// Clicks a button of the visible quit-failure alert, as the user would.
    func pressQuitAlertButton(_ index: Int) {
        guard let alert = quitAlert, alert.buttons.indices.contains(index) else { return }
        alert.buttons[index].performClick(nil)
    }
}
