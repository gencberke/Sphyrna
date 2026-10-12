import AppKit
import LoomCatalogUI
import LoomCore
import Synchronization

/// Wiring of the usage index and the Settings window (U1). The index runs on its own queue; this
/// code only decides which Claude profile it reads and builds the objects the views share.
extension AppDelegate {
    /// Creates the usage model and the Settings controller. Nothing is read here: the first scan
    /// starts when the catalog's first load completes (`CatalogModel.start`).
    func installUsage(model: CatalogModel, root: URL, refused: Bool) {
        let layout = usageProfileLayout(root: root)
        var usageModel: UsageModel?
        if !refused {
            let index = ClaudeUsageIndex(databaseURL: root.appendingPathComponent("usage-index.sqlite3"), profile: layout)
            let toolchain = claudeToolchain
            let limits = ClaudePlanLimitsFetcher(
                toolchain: { try await toolchain.claude() }, profile: layout,
                workingDirectory: root.appendingPathComponent("usage-probe", isDirectory: true))
            let created = UsageModel(index: index, limits: limits)
            usageModel = created
            // The numbers follow the transcripts on disk: the stream reports, the model decides
            // whether anyone is looking and reads only the changed files.
            let watcher = UsageTranscriptWatcher(directory: layout.projectsDirectory) { [weak created] change in
                Task { @MainActor in created?.transcriptsChanged(change) }
            }
            watcher.start()
            usageWatcher = watcher
            ConversationForgetters.shared.register { _, ids in try await index.forget(sessionIDs: ids) }
        }
        usage = usageModel
        model.usage = usageModel
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String
        let about = SettingsAbout(
            version: build.map { "Version \(version) (build \($0))" } ?? "Version \(version)",
            dataFolder: root, claudeProfile: usageModel == nil ? nil : layout.configDirectory)
        let diagnostics = makeDiagnosticsCollection()
        self.diagnostics = diagnostics
        settingsController = SettingsWindowController(model: model, usage: usageModel, about: about, diagnostics: diagnostics)
    }

    /// Which Claude profile usage is read from, without resolving the terminal environment (that
    /// would run a login shell just to show a number). The rule:
    /// 1. an acceptance run uses the profile it was given (`evidenceClaudeProfile`), never `~/.claude`;
    /// 2. otherwise `CLAUDE_CONFIG_DIR` from Loom's own environment when it is an absolute path;
    /// 3. otherwise `~/.claude`.
    /// A conversation resolves the real toolchain only when it first starts, so a profile that only
    /// the login shell sets is not seen until a later launch environment is inherited; usage then
    /// reads the default profile (the launcher uses the same fallback).
    private func usageProfileLayout(root: URL) -> ClaudeProfileLayout {
        ClaudeProfileLayout(
            profileDirectory: evidenceClaudeProfile(root: root),
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// The Claude toolchain the runtime resolves for sessions (executable, environment). The runtime
/// hands its resolver over when it starts; a plan-limits request that comes earlier waits for it,
/// for a bounded time, and gives up when the runtime never starts.
final class ClaudeToolchainSlot: Sendable {
    private let resolver = Mutex<ProviderToolchainResolver?>(nil)

    func provide(_ value: @escaping ProviderToolchainResolver) {
        resolver.withLock { $0 = value }
    }

    func claude(waitingUpTo seconds: Double = 30) async throws -> ProviderToolchain {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while true {
            if let value = resolver.withLock({ $0 }) { return try await value(.claude) }
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
