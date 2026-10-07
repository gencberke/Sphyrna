import AppKit
import LoomCatalogUI
import LoomCore

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
            usageModel = UsageModel(index: index)
            ConversationForgetters.shared.register { _, ids in try await index.forget(sessionIDs: Array(Set(ids.flatMap { [$0, $0.lowercased(), $0.uppercased()] }))) }
        }
        usage = usageModel
        model.usage = usageModel
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String
        let about = SettingsAbout(
            version: build.map { "Version \(version) (build \($0))" } ?? "Version \(version)",
            dataFolder: root, claudeProfile: usageModel == nil ? nil : layout.configDirectory)
        settingsController = SettingsWindowController(model: model, usage: usageModel, about: about)
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
