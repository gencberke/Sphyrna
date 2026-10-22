#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore
import LoomLaunchOptions
import LoomTerminal
import Synchronization

/// Development flavor only (`LOOM_EVIDENCE`): the implementations behind the call seams that
/// `DevelopmentSeams.swift` stubs out in the release flavor. Everything here is also inert without
/// `--evidence <dir>`, except the synthetic terminal controller, which a development launch always builds.
extension AppDelegate {
    var arguments: [String] { options.arguments }

    /// Development and fixture paths (`--fixture`, `--metal`, the synthetic
    /// terminal) exist only behind `--evidence`.
    var evidenceMode: Bool { options.isEvidence }

    func value(after flag: String) -> String? { options.value(after: flag) }

    func configureEvidenceAtLaunch(model: CatalogModel) {
        guard options.isEvidence else { return }
        // Without `--fake-providers` and `--claude-config`, `evidenceToolchains` resolves the real `claude` on the
        // login PATH and `evidenceClaudeProfile` a fresh `<data root>/claude-config`: Remora would reach a real CLI.
        // Such a launch holds it Off in memory; the preferences file is left as it is. Keep this condition in step
        // with those two functions.
        if value(after: "--fake-providers") == nil, value(after: "--claude-config") == nil {
            model.holdRemoraOff()
        }
        // The flag sets the sidebar style (Glass | Solid) in the isolated data root; the system's Reduce
        // Transparency still forces Solid, and no OS setting is changed.
        switch value(after: "--evidence-transparency") {
        case "glass": model.setSidebarStyle(.glass)
        case "opaque": model.setSidebarStyle(.solid)
        default: break
        }
        // Acceptance: hold the deleting state long enough for a screenshot.
        if let delay = value(after: "--delete-delay").flatMap(Double.init), delay > 0 {
            model.deletions.pauseBeforeRuntimeCall = .seconds(delay)
        }
    }

    func startEvidenceChannel() {
        if let directory = options.evidenceDirectory {
            evidence = DevelopmentEvidence(directory: URL(fileURLWithPath: directory), app: self)
        }
    }

    /// A development run may ask for a fixture; normal launch starts nothing.
    func evidenceStartupFinished() {
        if evidenceMode, let index = arguments.firstIndex(of: "--fixture") {
            newTerminal(fixtureArguments: Array(arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }))
        }
    }

    func evidenceQuitRecorder(started: Double) -> (@Sendable (ShutdownReport) async -> Void)? {
        evidence?.quitRecorder(runtime: runtime, started: started)
    }

    /// Acceptance only: prove that a missing host refuses starts honestly.
    func evidenceRunHost(_ host: URL) -> URL {
        if options.isEvidence, ProcessInfo.processInfo.environment["LOOM_FORCE_SCOPE_FAILURE"] == "1" {
            return host.appendingPathComponent("missing")
        }
        return host
    }

    /// Acceptance runs quit with sessions working (the command channel's `quit`); the question of D-45
    /// would wait for a click nobody gives.
    func evidenceSkipsQuitQuestion() -> Bool { options.isEvidence }

    /// Acceptance only (CHECKPOINT-5-HISTORY §18.1 madde 3): the first quit reports a
    /// failure without stopping anything, so the real alert and Try Again
    /// path can be exercised. Requires --evidence.
    func evidenceInjectedShutdownFailure() -> (@Sendable () -> ShutdownReport?)? {
        guard options.isEvidence, arguments.contains("--fail-first-quit") else { return nil }
        let attempts = Mutex(0)
        return {
            guard attempts.withLock({ $0 += 1; return $0 }) == 1 else { return nil }
            return ShutdownReport(remainingCountVerified: false,
                elapsedSeconds: 0, signals: [], remaining: [],
                errors: ["Forced first-quit failure (--fail-first-quit)"],
                outsideOwnership: [], ownershipGuarantee: "not attempted"
            )
        }
    }

    /// The synthetic terminal (A slice): one launching or live run at a time, reachable through
    /// the development menu item and `--fixture`.
    func installDevelopmentTerminal(hub: SessionEventHub, supervisor: ProcessSupervisor, model: CatalogModel) {
        let controller = TerminalRunController(
            events: hub,
            launch: TerminalRunController.syntheticLaunch(
                supervisor: supervisor,
                executable: Bundle.main.executableURL!.deletingLastPathComponent()
                    .appendingPathComponent("loom-test-child").path,
                directory: FileManager.default.homeDirectoryForCurrentUser.path
            )
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
    }

    /// Provider CLIs come from the user's real terminal environment. Acceptance
    /// runs (`--evidence`) may substitute fixture providers and isolated
    /// profiles; a normal launch cannot. Nil means the normal resolution.
    func evidenceToolchains(root: URL, supervisor: ProcessSupervisor,
                            origin: LaunchEnvironment.LaunchOrigin) -> ProviderToolchainResolver? {
        guard options.isEvidence else { return nil }
        if let fixtures = value(after: "--fake-providers") {
            let fake = URL(fileURLWithPath: fixtures).appendingPathComponent("loom-fake-provider").path
            let state = root.appendingPathComponent("fake-state", isDirectory: true)
            // Acceptance: a slow environment resolution, so Quit can land mid-start.
            let delay = value(after: "--fake-toolchain-delay").flatMap(Double.init) ?? 0
            // Home's first-run evidence (V05): `LOOM_FAKE_NO_CLAUDE=1` makes the Claude toolchain fail the way a
            // machine without the CLI does, and the fixture's own `LOOM_FAKE_USAGE*` variables (the plan limits it
            // answers) pass from this process to the fixture.
            let noClaude = ProcessInfo.processInfo.environment["LOOM_FAKE_NO_CLAUDE"] == "1"
            let fixtureEnvironment: [String: String] = {
                var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LOOM_FAKE_STATE": state.path]
                for (key, text) in ProcessInfo.processInfo.environment where key.hasPrefix("LOOM_FAKE_USAGE") {
                    environment[key] = text
                }
                return environment
            }()
            return { provider in
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                if noClaude, provider == .claude {
                    throw ProviderToolchainError.executableNotFound(provider: .claude, searched: 0)
                }
                return ProviderToolchain(
                    provider: provider, executable: fake,
                    capabilities: ProviderCapabilities(
                        version: "fixture",
                        help: "--settings <settings> --session-id <id> --fork-session --remote <ADDR> --effort <level> -n, --name <name> --plugin-dir <path> "
                            + "--permission-mode <mode> --model <model>",
                        serverHelp: "--listen <URL>"
                    ),
                    environment: fixtureEnvironment,
                    profileDirectory: root.appendingPathComponent(
                        provider == .codex ? "codex-home" : "claude-config", isDirectory: true
                    )
                )
            }
        }
        let system = SystemProviderToolchains(
            supervisor: supervisor, origin: origin,
            claudeProfile: value(after: "--claude-config").map { URL(fileURLWithPath: $0) },
            codexHome: value(after: "--codex-home").map { URL(fileURLWithPath: $0) }
        )
        return { provider in try await system.toolchain(for: provider) }
    }

    /// Acceptance runs read usage from the profile they were given, never from `~/.claude`: the fake
    /// providers' (and the default) is `<data root>/claude-config`; `--claude-config` names another.
    func evidenceClaudeProfile(root: URL) -> URL? {
        guard options.isEvidence else { return nil }
        let isolated = root.appendingPathComponent("claude-config", isDirectory: true)
        if value(after: "--fake-providers") != nil { return isolated }
        return value(after: "--claude-config").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? isolated
    }

    func installDevelopmentMenuItems(in fileMenu: NSMenu) {
        guard evidenceMode else { return }
        let synthetic = fileMenu.addItem(withTitle: "New Synthetic Terminal (Development)",
                                         action: #selector(newTerminalFromMenu(_:)), keyEquivalent: "n")
        synthetic.keyEquivalentModifierMask = [.command, .option]
        synthetic.target = self
        fileMenu.addItem(.separator())
    }

    /// Bounded visibility log so measurements can reject intervals in which
    /// the window was shown, hidden or occluded (CHECKPOINT-5-HISTORY §13 madde 6).
    func traceWindowCall(_ reason: String, hasVisibleWindows: Bool? = nil) {
        guard options.isEvidence else { return }
        recordVisibility(reason, hasVisibleWindows: hasVisibleWindows)
    }

    func recordVisibility(_ reason: String, hasVisibleWindows: Bool? = nil) {
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

    // MARK: Synthetic terminal

    @objc func newTerminalFromMenu(_ sender: Any?) { newTerminal(fixtureArguments: []) }

    /// A slice: one launching or live synthetic run at a time.
    func newTerminal(fixtureArguments: [String]) {
        guard evidenceMode, let controller else { return }
        // A started shutdown never admits new work, even after it failed.
        guard shutdownCoordinator?.state == .idle,
              let surface = controller.newTerminal(
                  arguments: fixtureArguments.isEmpty ? ["interactive"] : fixtureArguments
              )
        else {
            NSSound.beep()
            return
        }
        surface.onTitle = { [weak self] title in self?.model?.statusMessage = title }
        surface.onInputError = { [weak self] error in self?.model?.statusMessage = error.description }
        show(surface)
        model?.showDevTerminal(DevTerminal(panel: developmentTerminalPanel))
    }

    /// The terminal view of a development run is hosted in this transparent panel.
    private var developmentTerminalPanel: NSView {
        if let terminalPanel { return terminalPanel }
        let panel = NSView()
        terminalPanel = panel
        return panel
    }

    private func show(_ surface: TerminalSurface) {
        let panel = developmentTerminalPanel
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
        // CHECKPOINT-5-HISTORY §3.2 renderer experiment only; the product ships one path.
        if evidenceMode, arguments.contains("--metal") {
            do { try view.setUseMetal(true) }
            catch { showError("Metal rendering is unavailable.", detail: String(describing: error)) }
        }
    }

    // MARK: Resource pool bridge (normal launches expose no supervisor)

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
            model?.showDevTerminal(DevTerminal(panel: developmentTerminalPanel))
        } else {
            if let panel = terminalPanel, let responder = window?.firstResponder as? NSView,
               responder === panel || responder.isDescendant(of: panel) {
                window?.makeFirstResponder(nil)
            }
            terminalPanel?.subviews.forEach { $0.removeFromSuperview() }
            if resourcePreviousDevTerminal == true, let original = controller?.surface {
                show(original)
                model?.showDevTerminal(DevTerminal(panel: developmentTerminalPanel))
            } else { model?.select(model?.selectedSessionID) }
            resourcePreviousDevTerminal = nil
        }
    }
}
#endif
