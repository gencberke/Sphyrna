import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// Shared by `SessionRuntimeTests` and the tests of other tiers that reuse its fixtures (DEVELOPMENT §3.1).
enum SessionRuntimeRig {
    static func makeContext(
        idlePolicy: SessionIdlePolicy = SessionIdlePolicy(),
        extraEnvironment: [String: String] = [:],
        startRuntime: Bool = true,
        scoped: Bool = false,
        durableLedger: Bool = false,
        executableOverride: String? = nil,
        claudePlugin: Bool = false,
        hookHelperPath: String? = nil,
        hookSilenceGrace: TimeInterval = 3,
        codexJoinTimeout: TimeInterval = CodexSessionCoordinator.defaultJoinTimeout,
        catalogBackupDelay: TimeInterval? = nil,
        claudeVersion: String = "fake 1",
        extraClaudeHelp: String = "",
        runsRecovered: (@Sendable () async -> Void)? = nil,
        defaultOpenedMode: (@Sendable (UUID?) async -> String?)? = nil,
        openedModels: (@Sendable (HarnessID) async -> [ModelCatalogEntry])? = nil,
        managedClaudeControllerFactory: ManagedTaskControllerFactory? = nil
    ) async throws -> RuntimeContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-runtime-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let state = root.appendingPathComponent("fake-state", isDirectory: true)
        let profile = root.appendingPathComponent("claude-config", isDirectory: true)
        for directory in [home, state, profile] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/lr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let supervisor: ProcessSupervisor
        var fakePath = executableOverride
            ?? RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        if scoped {
            // Run hosts are their own TCC-responsible apps: a scoped child must
            // execute a copy from a temporary directory, not from ~/Documents.
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let copy = bin.appendingPathComponent("loom-fake-provider")
            try FileManager.default.copyItem(atPath: fakePath, toPath: copy.path)
            fakePath = copy.path
            let bundle = try SharedRunHost.bundle(for: RuntimeFixture.binaries.appendingPathComponent("loom-run-host"))
            supervisor = try await ProcessSupervisor.restoring(
                ledgerURL: durableLedger ? root.appendingPathComponent("ledger.json") : nil, catalog: catalog,
                scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs"))
            )
        } else {
            supervisor = try await ProcessSupervisor.restoring(
                ledger: OwnershipLedger(), catalog: catalog
            )
        }
        let toolchainSwitch = ToolchainSwitch()
        let fake = fakePath
        let resolver: ProviderToolchainResolver = { provider in
            toolchainSwitch.beginResolution()
            if toolchainSwitch.delay > 0 { try await Task.sleep(for: .seconds(toolchainSwitch.delay)) }
            try toolchainSwitch.check()
            return ProviderToolchain(
                provider: provider, executable: fake,
                capabilities: ProviderCapabilities(
                    version: claudeVersion,
                    help: "--settings <settings> --session-id <id> --remote <ADDR> --effort <level> -n, --name <name> --plugin-dir <path> "
                        + extraClaudeHelp,
                    serverHelp: "--listen <URL>"
                ),
                environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LOOM_FAKE_STATE": state.path]
                    .merging(extraEnvironment) { _, new in new },
                profileDirectory: profile, extraArguments: []
            )
        }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: resolver,
                hookHelperPath: hookHelperPath ?? RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path,
                idlePolicy: idlePolicy, codexIdentityTimeout: 3, codexJoinTimeout: codexJoinTimeout,
                claudePluginDirectory: claudePlugin ? root.appendingPathComponent("claude-plugin", isDirectory: true) : nil,
                hookSilenceGrace: hookSilenceGrace, catalogBackupDelay: catalogBackupDelay,
                runsRecovered: runsRecovered, defaultOpenedMode: defaultOpenedMode, openedModels: openedModels,
                managedClaudeControllerFactory: managedClaudeControllerFactory
            )
        )
        if startRuntime { try await runtime.start() }
        return RuntimeContext(
            root: root, home: home, catalog: catalog, supervisor: supervisor, runtime: runtime,
            toolchainSwitch: toolchainSwitch, state: state, profile: profile,
            socketDirectory: socketDirectory
        )
    }

    static func waitUntil(
        _ seconds: TimeInterval = 5, _ condition: () async throws -> Bool
    ) async rethrows -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    static func launchClaude(
        _ context: RuntimeContext, projectID: UUID? = nil
    ) async throws -> (RuntimeLaunch, Screen) {
        let screen = Screen()
        let launch = try await context.runtime.startConversation(
            provider: .claude, projectID: projectID, outputSink: screen
        )
        screen.attach(launch.terminal)
        return (launch, screen)
    }

    static func resume(
        _ context: RuntimeContext, _ sessionID: UUID
    ) async throws -> (RuntimeLaunch, Screen) {
        let screen = Screen()
        let launch = try await context.runtime.resumeConversation(sessionID: sessionID, outputSink: screen)
        screen.attach(launch.terminal)
        return (launch, screen)
    }

    /// The terminal sink of a test: like the app's surface it receives the
    /// bytes of a run, and it can type into the run's terminal.
    final class Screen: TerminalOutputSink, @unchecked Sendable {
        let lock = NSLock()
        var text = ""
        var terminal: TerminalEndpoint?

        func receive(_ data: Data) {
            lock.withLock { text += String(decoding: data, as: UTF8.self) }
        }

        func attach(_ terminal: TerminalEndpoint) { lock.withLock { self.terminal = terminal } }

        func contains(_ needle: String, timeout: TimeInterval = 5) async -> Bool {
            await SessionRuntimeRig.waitUntil(timeout) { snapshot.contains(needle) }
        }

        var snapshot: String { lock.withLock { text } }

        func send(_ line: String) async throws {
            guard let terminal = lock.withLock({ self.terminal }) else { return }
            _ = try await terminal.write(Data((line + "\r").utf8))
        }
    }
}
