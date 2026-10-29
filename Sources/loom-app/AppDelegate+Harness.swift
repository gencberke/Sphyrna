import AppKit
import Foundation
import LoomCatalogUI
import LoomCore

/// Wiring of the harness probe and the connect switch (D-94, D-98): one of each for the app. Nothing here asks the probe;
/// usage and connections decide when. The Claude source wraps the same plan-limits fetcher the usage model asks, so one child
/// answers for the account and the windows alike.
extension AppDelegate {
    func installHarness(model: CatalogModel, preferences: UIPreferencesStore, root: URL, limits: ClaudePlanLimitsFetcher?) {
        // The switch starts from the stored flags; a change goes back to the file, and the CLIs are looked for again (C2B).
        let connections = preferences.makeHarnessConnections { [weak model] in
            model?.refreshHarnessAvailability(force: true)
        }
        // The composer's model lists: the app's one catalogue, read with the same switch, handed to the model (C2B).
        let catalog = ModelCatalog(connections: connections)
        model.modelCatalog = catalog

        var sources: [ManagedSession.Provider: any HarnessProbeSource] = [:]
        if let limits { sources[.claude] = ClaudeProbeSource(fetcher: limits) }
        // The runtime, and so the supervisor, comes after the window: the Codex source looks for it when it is asked.
        let info = Bundle.main.infoDictionary
        let build = info?["LoomRevision"] as? String ?? info?["CFBundleVersion"] as? String ?? "dev"
        let slot = toolchainSlot
        sources[.codex] = DeferredCodexSource(
            supervisor: { [weak self] in await MainActor.run { self?.supervisor } },
            toolchain: { try await slot.toolchain(for: .codex) },
            socketDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(identity.socketDirectoryName, isDirectory: true),
            workingDirectory: root.appendingPathComponent("harness-probe", isDirectory: true).path, clientVersion: "sphyrna-\(build)")

        // Codex's models reach the composer's lists through the catalog.
        model.harnessProbe = HarnessProbe(connections: connections, sources: sources, onReading: { [weak model] reading in
            Task { @MainActor in
                catalog.apply(reading)
                if case .some(.codex) = HarnessTranscriptKind(provider: reading.provider) {
                    model?.applyCodexTranscriptAccount(reading.account)
                }
            }
        })
        model.harnessConnections = connections
        installConnections(model: model, root: root)
        // The app becomes active: the CLIs are looked for again, at most once a minute (a PATH lookup; no CLI runs) (C2B).
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.refreshHarnessAvailability() }
        }
    }
}

/// The Codex probe source for an app whose supervisor does not exist yet when the probe is made.
private struct DeferredCodexSource: HarnessProbeSource {
    let supervisor: @Sendable () async -> ProcessSupervisor?
    let toolchain: @Sendable () async throws -> ProviderToolchain
    let socketDirectory: URL
    let workingDirectory: String
    let clientVersion: String

    func read() async -> HarnessProbeAnswer? {
        guard let supervisor = await supervisor() else { return nil }
        // Sphyrna's own folder for the server's internal session, made when a probe first needs it (never a project, never home).
        try? FileManager.default.createDirectory(
            atPath: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return await CodexProbeSource(
            supervisor: supervisor, toolchain: toolchain, workingDirectory: workingDirectory,
            socketDirectory: socketDirectory, clientVersion: clientVersion).read()
    }
}
