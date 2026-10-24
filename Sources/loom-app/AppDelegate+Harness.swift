import Foundation
import LoomCatalogUI
import LoomCore

/// Wiring of the harness probe and the connect switch (D-94, D-98): one of each for the app. Nothing here asks the probe;
/// usage and connections decide when. The Claude source wraps the same plan-limits fetcher the usage model asks, so one child
/// answers for the account and the windows alike.
extension AppDelegate {
    func installHarness(model: CatalogModel, preferences: UIPreferencesStore, root: URL, limits: ClaudePlanLimitsFetcher?) {
        // The switch starts from the stored flags; a change goes back to the file.
        let connections = HarnessConnections(disconnected: preferences.current.disconnectedHarnesses) { provider, connected in
            Task { @MainActor in try? preferences.update { $0.setHarnessConnected(provider, connected) } }
        }
        ModelCatalog.shared.connections = connections

        var sources: [ManagedSession.Provider: any HarnessProbeSource] = [:]
        if let limits { sources[.claude] = ClaudeProbeSource(fetcher: limits) }
        // The runtime, and so the supervisor, comes after the window: the Codex source looks for it when it is asked.
        let info = Bundle.main.infoDictionary
        let build = info?["LoomRevision"] as? String ?? info?["CFBundleVersion"] as? String ?? "dev"
        let slot = claudeToolchain
        sources[.codex] = DeferredCodexSource(
            supervisor: { [weak self] in await MainActor.run { self?.supervisor } },
            toolchain: { try await slot.toolchain(for: .codex) },
            socketDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(identity.socketDirectoryName, isDirectory: true),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, clientVersion: "loom-\(build)")

        // Codex's models reach the composer's lists through the catalog.
        model.harnessProbe = HarnessProbe(connections: connections, sources: sources, onReading: { reading in
            Task { @MainActor in ModelCatalog.shared.apply(reading) }
        })
        model.harnessConnections = connections
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
        return await CodexProbeSource(
            supervisor: supervisor, toolchain: toolchain, workingDirectory: workingDirectory,
            socketDirectory: socketDirectory, clientVersion: clientVersion).read()
    }
}
