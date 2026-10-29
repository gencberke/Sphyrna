import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// The live chat rig the live view suites share: the real Chat driver on the fake provider, its feed and presentation.
struct LiveRig {
    let root: URL
    let profile: URL
    let socketDirectory: URL
    let runtime: SessionRuntime

    /// `forkable`: the fake CLI's help lists `--fork-session`, as a CLI that can fork a session does (the Side tab's fork).
    static func make(environment: [String: String] = [:], forkable: Bool = false) async throws -> LiveRig {
        let binaries = Products.directory
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-live-view-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let profile = root.appendingPathComponent("claude-config", isDirectory: true)
        for directory in [home, profile] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/lv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("loom-fake-provider")
        try FileManager.default.copyItem(at: binaries.appendingPathComponent("loom-fake-provider"), to: fake)
        let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: binaries.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try await ProcessSupervisor.restoring(
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs"))
        )
        let fakePath = fake.path
        let resolver: ProviderToolchainResolver = { provider in
            ProviderToolchain(
                provider: provider, executable: fakePath,
                capabilities: ProviderCapabilities(
                    version: "fake 1",
                    help: "--settings <settings> --session-id <id> --effort <level> -n, --name <name> --plugin-dir <path> "
                        + "--permission-mode <mode> --model <model>" + (forkable ? " --fork-session" : ""),
                    serverHelp: "--listen <URL>"
                ),
                environment: ["PATH": "/usr/bin:/bin", "HOME": home.path].merging(environment) { _, new in new },
                profileDirectory: profile, extraArguments: []
            )
        }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: resolver,
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path,
                idlePolicy: SessionIdlePolicy(), codexIdentityTimeout: 3,
                claudePluginDirectory: root.appendingPathComponent("claude-plugin", isDirectory: true),
                hookSilenceGrace: 3, catalogBackupDelay: nil
            )
        )
        try await runtime.start()
        return LiveRig(root: root, profile: profile, socketDirectory: socketDirectory, runtime: runtime)
    }

    func finish() async {
        let report = await runtime.shutdown()
        #expect(report.succeeded)
        RunScopeLauncher.removeOwnedBundle(in: root)
        try? FileManager.default.removeItem(at: socketDirectory)
        try? FileManager.default.removeItem(at: root)
    }
}
