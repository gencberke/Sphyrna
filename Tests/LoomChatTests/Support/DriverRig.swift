import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// The Chat driver rig the driver suites share: a scoped supervisor, the runtime, the fake provider and the driver.
private enum DriverFixture {
    static var binaries: URL { Products.directory }
}

/// What the driver's callbacks reported.
final class Reports: Sendable {
    let windows = Mutex<[String: Int]>([:])
    let choices = Mutex<[ClaudeLaunchChoices]>([])
}

struct Rig {
    let root: URL
    let home: URL
    let profile: URL
    let socketDirectory: URL
    let catalog: SessionCatalog
    let supervisor: ProcessSupervisor
    let runtime: SessionRuntime
    let reports = Reports()

    var events: SessionEventHub { supervisor.events }

    /// - Parameter plugin: Loom's Claude plugin is written and passed as `--plugin-dir` (the output style of Ask comes
    ///   from it); false is a Loom whose plugin folder cannot be written.
    /// - Parameter probeFailures: the first this many toolchain resolutions fail as a capability probe does (a timeout).
    /// - Parameter listsForwardSubagentText: the fake CLI's help lists `--forward-subagent-text`, as Claude Code 2.1.300's does.
    static func make(environment: [String: String] = [:], version: String = "fake 1", plugin: Bool = true,
                     probeFailures: Int = 0, listsForwardSubagentText: Bool = true,
                     managedClaudeControllerFactory: ManagedTaskControllerFactory? = nil) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let profile = root.appendingPathComponent("claude-config", isDirectory: true)
        for directory in [home, profile] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/lc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        // Run hosts are their own TCC-responsible apps: a scoped child runs a copy from a temporary folder.
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("loom-fake-provider")
        try FileManager.default.copyItem(at: DriverFixture.binaries.appendingPathComponent("loom-fake-provider"), to: fake)
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: DriverFixture.binaries.appendingPathComponent("loom-run-host"), in: root
        )
        let supervisor = try await ProcessSupervisor.restoring(
            ledgerURL: managedClaudeControllerFactory == nil ? nil : root.appendingPathComponent("ledger.json"),
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs"))
        )
        let fakePath = fake.path
        let failuresLeft = Mutex(probeFailures)
        let resolver: ProviderToolchainResolver = { provider in
            let fails = failuresLeft.withLock { left -> Bool in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            if fails {
                throw ProviderToolchainError.capabilityProbeFailed(command: "claude --help", detail: "timed out", kind: .timeout)
            }
            return ProviderToolchain(
                provider: provider, executable: fakePath,
                capabilities: ProviderCapabilities(
                    version: version,
                    help: "--settings <settings> --session-id <id> --effort <level> -n, --name <name> --plugin-dir <path> "
                        + "--permission-mode <mode> --model <model> --fork-session"
                        + (listsForwardSubagentText ? " --forward-subagent-text" : ""),
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
                hookHelperPath: DriverFixture.binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path,
                idlePolicy: SessionIdlePolicy(), codexIdentityTimeout: 3,
                claudePluginDirectory: plugin ? root.appendingPathComponent("claude-plugin", isDirectory: true) : nil,
                hookSilenceGrace: 3, catalogBackupDelay: nil,
                toolchainProbeRetryPause: .milliseconds(50),
                managedClaudeControllerFactory: managedClaudeControllerFactory
            )
        )
        try await runtime.start()
        return Rig(root: root, home: home, profile: profile, socketDirectory: socketDirectory, catalog: catalog,
                   supervisor: supervisor, runtime: runtime)
    }

    func driver(_ sessionID: UUID = UUID(), queue: ChatQueueStore? = nil, drafts: ChatDraftStore? = nil,
                rewinds: ChatRewindStore? = nil, readyTimeout: Duration = .seconds(20)) -> ChatSessionDriver {
        let reports = reports
        return ChatSessionDriver(
            sessionID: sessionID, runtime: runtime, queueStore: queue, draftStore: drafts, rewindStore: rewinds,
            readyTimeout: readyTimeout,
            onChoicesChanged: { value in reports.choices.withLock { $0.append(value) } },
            onContextWindow: { model, window in reports.windows.withLock { $0[model] = window } }
        )
    }

    func status(_ sessionID: UUID) async -> AgentActivity? {
        await events.snapshot().sessions[sessionID]?.status?.activity
    }

    func issue(_ sessionID: UUID) async -> String? {
        await events.snapshot().sessions[sessionID]?.issue
    }

    func finish() async {
        let report = await runtime.shutdown()
        #expect(report.succeeded)
        guard report.succeeded else { return }
        RunScopeLauncher.removeOwnedBundle(in: root)
        try? FileManager.default.removeItem(at: socketDirectory)
        try? FileManager.default.removeItem(at: root)
    }
}

func waitUntil(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}

extension ChatDriverSnapshot {
    var texts: [String] {
        model.entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } }
    }

    func delivery(_ id: String) -> UserPrompt.Delivery? {
        guard case let .user(prompt) = model.entry(id: id)?.body else { return nil }
        return prompt.delivery
    }

    var markers: [Marker] {
        model.entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } }
    }

    var youStopped: Bool { markers.contains { if case .interrupted = $0 { true } else { false } } }

    var isIdle: Bool { phase == .ready && !turnRunning }
}

extension ChatSendReceipt {
    var id: String {
        switch self {
        case let .sent(id), let .queued(id): id
        }
    }
}

func idle(_ driver: ChatSessionDriver, _ seconds: Double = 10) async -> Bool {
    await waitUntil(seconds) { await driver.snapshot().isIdle }
}
