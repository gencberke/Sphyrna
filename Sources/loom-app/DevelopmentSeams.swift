#if !LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// The release flavor of the call seams `AppDelegate` uses for development evidence. The real
/// implementations live in `Sources/loom-app/Evidence/` and are compiled only when `LOOM_EVIDENCE`
/// is defined (the dev manifest); the clean loom tree does not contain that directory, so a release
/// binary carries none of the acceptance tooling and `--evidence` does nothing beyond the data-root
/// rule in `LaunchOptions`.
extension AppDelegate {
    func configureEvidenceAtLaunch(model: CatalogModel) {}
    func startEvidenceChannel() {}
    func evidenceStartupFinished() {}
    func evidenceQuitRecorder(started: Double) -> (@Sendable (ShutdownReport) async -> Void)? { nil }
    func evidenceRunHost(_ host: URL) -> URL { host }
    func evidenceSkipsQuitQuestion() -> Bool { false }
    func evidenceInjectedShutdownFailure() -> (@Sendable () -> ShutdownReport?)? { nil }
    func installDevelopmentTerminal(hub: SessionEventHub, supervisor: ProcessSupervisor, model: CatalogModel) {}
    func evidenceToolchains(root: URL, supervisor: ProcessSupervisor, origin: LaunchEnvironment.LaunchOrigin) -> ProviderToolchainResolver? { nil }
    func evidenceClaudeProfile(root: URL) -> URL? { nil }
    func installDevelopmentMenuItems(in fileMenu: NSMenu) {}
    func traceWindowCall(_ reason: String, hasVisibleWindows: Bool? = nil) {}
    func recordVisibility(_ reason: String, hasVisibleWindows: Bool? = nil) {}
}
#endif
