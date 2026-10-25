import AppKit
import LoomCatalogUI
import LoomCore

/// Wiring of the harness health (D-98): one `HarnessHealthModel` next to the probe and the connect switch, asked when the app
/// becomes active and when a session starts or ends (the page and Check Again ask for themselves). Nothing here runs on a timer
/// or calls a model; Deep Check runs only when its button is pressed.
extension AppDelegate {
    func installConnections(model: CatalogModel, root: URL) {
        guard let probe = model.harnessProbe, let connections = model.harnessConnections else { return }
        let slot = claudeToolchain
        let toolchain: @Sendable (ManagedSession.Provider) async throws -> ProviderToolchain = { provider in
            try await slot.toolchain(for: provider)
        }
        let checker = HarnessHealthChecker(connections: connections, probe: probe, toolchain: toolchain)
        // The supervisor comes after the window: Deep Check looks for it when it is asked.
        let deepFolder = root.appendingPathComponent("deep-check", isDirectory: true)
        let health = HarnessHealthModel(connections: connections, checker: checker, deepCheck: { [weak self] provider in
            guard let supervisor = await MainActor.run(body: { self?.supervisor }) else {
                return HarnessDeepCheck.Result(text: "Sphyrna is still starting. Try again in a moment.", succeeded: false)
            }
            return await HarnessDeepCheck(supervisor: supervisor, toolchain: toolchain, workingDirectory: deepFolder).run(provider)
        })
        model.installHarnessHealth(health)

        // The app becomes active: each connected harness is checked under its floor, and a harness whose Install or Sign In
        // button was used goes again once whatever the floor says. The first activation is the launch's.
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { health.appBecameActive() }
        }
        // A session starts or ends: the supervisor's hub says so. It exists once the runtime has started; wait for it the way
        // the toolchain's slot does, for a bounded time.
        Task { [weak self] in
            var waited = 0
            var supervisor: ProcessSupervisor?
            while supervisor == nil, waited < 300 {
                supervisor = await MainActor.run { self?.supervisor }
                if supervisor == nil { try? await Task.sleep(for: .milliseconds(100)) }
                waited += 1
            }
            guard let supervisor else { return }
            for await frame in await supervisor.events.subscribe() {
                switch frame.change {
                case .runStarted, .runEnded: await MainActor.run { health.sessionRunChanged() }
                default: break
                }
            }
        }
    }
}
