import AppKit
import LoomCatalogUI
import LoomCore
import Synchronization

/// Wiring of the usage index and the Settings window (U1). The index runs on its own queue; this
/// code only decides which Claude profile it reads and builds the objects the views share.
extension AppDelegate {
    /// Creates the usage model and the Settings controller. Nothing is read here: the first scan
    /// starts when the catalog's first load completes (`CatalogModel.start`).
    func installUsage(model: CatalogModel, root: URL, refused: Bool, catalog: SessionCatalog?, preferences: UIPreferencesStore) {
        let layout = usageProfileLayout(root: root)
        var usageModel: UsageModel?
        var limitsFetcher: ClaudePlanLimitsFetcher?
        if !refused {
            // The side chats' ids (V22): a fork copies its parent's messages, which the index must keep the parent's.
            let index = ClaudeUsageIndex(
                databaseURL: root.appendingPathComponent("usage-index.sqlite3"), profile: layout,
                sideChats: { (try? await catalog?.sideChatProviderIDs()) ?? [] })
            let toolchain = toolchainSlot
            let limits = ClaudePlanLimitsFetcher(
                toolchain: { try await toolchain.claude() }, profile: layout,
                workingDirectory: root.appendingPathComponent("usage-probe", isDirectory: true))
            limitsFetcher = limits
            let created = UsageModel(index: index, limits: limits)
            usageModel = created
            // The numbers follow the transcripts on disk: the stream reports, the model decides
            // whether anyone is looking and reads only the changed files.
            let watcher = UsageTranscriptWatcher(directory: layout.projectsDirectory) { [weak created] change in
                Task { @MainActor in created?.transcriptsChanged(change) }
            }
            // Without a stream (it failed to start, or the profile has no `projects` folder yet) a
            // finished turn keeps reading every transcript.
            var isDirectory: ObjCBool = false
            let hasProjects = FileManager.default.fileExists(atPath: layout.projectsDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            created.setTranscriptWatcherRunning(watcher.start() && hasProjects)
            usageWatcher = watcher
            ConversationForgetters.shared.register { _, ids in try await index.forget(sessionIDs: ids) }
        }
        ConversationForgetters.shared.register { [weak self] id, _ in
            await MainActor.run { self?.approvalNotifier?.sessionDeleted(id) }
        }
        installHarness(model: model, preferences: preferences, root: root, limits: limitsFetcher)
        // The page and Claude's limits ask go through the probe (so one child answers the account and the windows); the
        // page's section is kept in the preferences.
        usageModel?.attachHarness(
            probe: model.harnessProbe, connections: model.harnessConnections, section: preferences.current.usageSection
        ) { section in
            Task { @MainActor in try? preferences.update { $0.usageSection = section } }
        }
        usage = usageModel
        model.usage = usageModel
        // One Claude profile for usage, the palette's session text search and the Chat view (nothing when refused),
        // known here at launch, before the window shows and without the runtime.
        model.setClaudeConfigDirectory(refused ? nil : layout.configDirectory)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        // "build 12, 611bc29": the numeric build and the commit it was built from.
        let build = [info?["CFBundleVersion"] as? String, info?["LoomRevision"] as? String]
            .compactMap { $0 }.joined(separator: ", ")
        let about = SettingsAbout(
            version: build.isEmpty ? "Version \(version)" : "Version \(version) (build \(build))",
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
    func usageProfileLayout(root: URL) -> ClaudeProfileLayout {
        ClaudeProfileLayout(
            profileDirectory: evidenceClaudeProfile(root: root),
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// The toolchains (Claude's and Codex's) the runtime resolves for sessions (executable, environment). The runtime
/// hands its resolver over when it starts; a plan-limits request that comes earlier waits for it,
/// for a bounded time, and gives up when the runtime never starts.
final class ToolchainSlot: Sendable {
    private let resolver = Mutex<ProviderToolchainResolver?>(nil)

    func provide(_ value: @escaping ProviderToolchainResolver) {
        resolver.withLock { $0 = value }
    }

    func claude(waitingUpTo seconds: Double = 30) async throws -> ProviderToolchain {
        try await toolchain(for: .claude, waitingUpTo: seconds)
    }

    /// The toolchain of any provider, resolved as sessions get it (the harness probe asks for Codex's).
    func toolchain(for provider: ManagedSession.Provider, waitingUpTo seconds: Double = 30) async throws -> ProviderToolchain {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while true {
            if let value = resolver.withLock({ $0 }) { return try await value(provider) }
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
