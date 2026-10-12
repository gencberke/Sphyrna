import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class RuntimeBundleAnchor: NSObject {}

/// CP5 C: the production runtime (supervisor, catalog, lifecycle controller,
/// hook server, provider adapters) driven through a provider-shaped fixture
/// instead of a model. Nothing here starts a real provider.
enum RuntimeFixture {
    static var binaries: URL {
        Bundle(for: RuntimeBundleAnchor.self).bundleURL.deletingLastPathComponent()
    }
}

/// `resolvingSymlinksInPath` keeps `/var`; a child's cwd is the real `/private/var` path.
func realPath(_ url: URL) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url.path }
    return String(cString: buffer)
}


final class HoldingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private(set) var writes = 0

    func write(_ data: Data) async throws -> Int {
        while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
        lock.withLock { writes += 1 }
        return data.count
    }

    func release() { lock.withLock { released = true } }
}

final class InputErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TerminalInputError] = []
    func append(_ error: TerminalInputError) { lock.withLock { storage.append(error) } }
    var values: [TerminalInputError] { lock.withLock { storage } }
}

final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private final class RuntimeCatalogGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false
    var entered: Bool { condition.withLock { waiting } }
    func hold() {
        condition.lock()
        waiting = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private extension SessionCatalog {
    func holdForRuntimeQuitTest(_ gate: RuntimeCatalogGate) { gate.hold() }
}

/// Toggles the resolver between failing and working so retries can be tested.
final class ToolchainSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (any Error)?
    private(set) var calls = 0
    private var pause: TimeInterval = 0

    func slow(by seconds: TimeInterval) { lock.withLock { pause = seconds } }
    var delay: TimeInterval { lock.withLock { pause } }

    func fail(with error: (any Error)?) { lock.withLock { failure = error } }

    func check() throws {
        try lock.withLock {
            calls += 1
            if let failure { throw failure }
        }
    }
}

struct RuntimeContext {
    let root: URL
    let home: URL
    let catalog: SessionCatalog
    let supervisor: ProcessSupervisor
    let runtime: SessionRuntime
    let toolchainSwitch: ToolchainSwitch
    let state: URL
    let profile: URL

    var events: SessionEventHub { supervisor.events }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: socketDirectory)
    }

    let socketDirectory: URL
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionRuntimeTests {
    static func makeContext(
        idlePolicy: SessionIdlePolicy = SessionIdlePolicy(),
        extraEnvironment: [String: String] = [:],
        startRuntime: Bool = true,
        scoped: Bool = false,
        executableOverride: String? = nil,
        claudePlugin: Bool = false
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
            let bundle = try RunScopeLauncher.assembleOwnedBundle(
                executable: RuntimeFixture.binaries.appendingPathComponent("loom-run-host"), in: root
            )
            supervisor = try await ProcessSupervisor.restoring(
                catalog: catalog,
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
            if toolchainSwitch.delay > 0 { try await Task.sleep(for: .seconds(toolchainSwitch.delay)) }
            try toolchainSwitch.check()
            return ProviderToolchain(
                provider: provider, executable: fake,
                capabilities: ProviderCapabilities(
                    version: "fake 1", help: "--settings <settings> --session-id <id> --remote <ADDR> --effort <level> -n, --name <name> --plugin-dir <path>",
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
                hookHelperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path,
                idlePolicy: idlePolicy, codexIdentityTimeout: 3,
                claudePluginDirectory: claudePlugin ? root.appendingPathComponent("claude-plugin", isDirectory: true) : nil
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

    /// The terminal sink of a test: like the app's surface it receives the
    /// bytes of a run, and it can type into the run's terminal.
    final class Screen: TerminalOutputSink, @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var terminal: TerminalEndpoint?

        func receive(_ data: Data) {
            lock.withLock { text += String(decoding: data, as: UTF8.self) }
        }

        func attach(_ terminal: TerminalEndpoint) { lock.withLock { self.terminal = terminal } }

        func contains(_ needle: String, timeout: TimeInterval = 5) async -> Bool {
            await SessionRuntimeTests.waitUntil(timeout) { snapshot.contains(needle) }
        }

        var snapshot: String { lock.withLock { text } }

        func send(_ line: String) async throws {
            guard let terminal = lock.withLock({ self.terminal }) else { return }
            _ = try await terminal.write(Data((line + "\r").utf8))
        }
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

    // MARK: C1 start

    @Test func newClaudeConversationRunsInTheProjectFolderWithHooksAndProfile() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let projectFolder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: projectFolder.path).project

        let (launch, screen) = try await Self.launchClaude(context, projectID: project.id)
        #expect(await screen.contains("FAKE-CLAUDE READY"))

        // Catalog row: project, provider, working directory; the run is linked.
        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(record.projectID == project.id)
        #expect(record.session.provider == .claude)
        #expect(record.session.workingDirectory == projectFolder.path)
        #expect(try await context.catalog.runs().contains { $0.id == launch.runID })

        // The hook path is live: a prompt reaches the reducers and binds the
        // provider identity chosen by the CLI.
        try await screen.send("hello runtime")
        #expect(await screen.contains("echo: hello runtime"))
        #expect(await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect(await context.supervisor.session(id: launch.sessionID)?.providerConversationID?.lowercased()
            == launch.sessionID.uuidString.lowercased())
        #expect(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID?.lowercased()
            == launch.sessionID.uuidString.lowercased())

        // Two-way terminal and an isolated profile reach the child.
        #expect(screen.snapshot.contains("profile=\(context.profile.path)"))
        #expect(screen.snapshot.contains("cwd=\(realPath(projectFolder))"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func projectlessConversationUsesTheHomeFolder() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        #expect(screen.snapshot.contains("cwd=\(realPath(context.home))"))
        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(record.projectID == nil)
        #expect(record.session.workingDirectory == context.home.path)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func missingToolchainLeavesNoCardOrRunAndRetrySucceeds() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        context.toolchainSwitch.fail(with: ProviderToolchainError.executableNotFound(provider: .claude, searched: 3))
        await #expect(throws: ProviderToolchainError.self) {
            _ = try await context.runtime.startConversation(provider: .claude, projectID: nil)
        }
        #expect(try await context.catalog.sessions().isEmpty)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(await context.runtime.liveRunCount() == 0)

        context.toolchainSwitch.fail(with: nil)
        let (_, screen) = try await Self.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        #expect(try await context.catalog.sessions().count == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func missingProjectFolderIsAnErrorNotAnotherFolder() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("gone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        try FileManager.default.removeItem(at: folder)
        await #expect(throws: SessionRuntimeError.missingDirectory(folder.path)) {
            _ = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        }
        #expect(try await context.catalog.sessions().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func repeatedStartRequestsCreateOneRun() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        async let first = context.runtime.startConversation(provider: .claude, projectID: nil)
        async let second: RuntimeLaunch? = try? await context.runtime.startConversation(provider: .claude, projectID: nil)
        let results = (try? await first, await second)
        let launches = [results.0, results.1].compactMap { $0 }
        #expect(launches.count == 1)
        #expect(try await context.catalog.sessions().count == 1)
        #expect(await context.supervisor.runningSessionIDs().count == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func quitRefusesNewWorkAndStopsEverythingOwned() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (_, screen) = try await Self.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        let report = await context.runtime.shutdown()
        #expect(report.succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        await #expect(throws: SessionRuntimeError.shuttingDown) {
            _ = try await context.runtime.startConversation(provider: .claude, projectID: nil)
        }
        #expect(try await context.catalog.runs().allSatisfy { $0.endReason != nil })
    }

    // MARK: C2 identity, resume and continuation

    private func lastEndedRun(_ context: RuntimeContext, _ runID: UUID) async -> Bool {
        await context.supervisor.runContext(runID: runID) == nil
    }

    @Test func resumeReopensTheSameProviderConversationAndRemembersHistory() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("remember this")
        #expect(await screen.contains("echo: remember this"))
        #expect(try await Self.waitUntil {
            try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID != nil
        })
        let identity = try #require(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID)

        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await Self.waitUntil { await lastEndedRun(context, launch.runID) })
        #expect(await context.runtime.liveRunCount() == 0)

        let (resumed, resumedScreen) = try await Self.resume(context, launch.sessionID)
        let sawResume = await resumedScreen.contains("RESUMED \(identity) remembered=1")
        #expect(sawResume, "screen: \(resumedScreen.snapshot)")
        #expect(resumed.sessionID == launch.sessionID)
        #expect(resumed.runID != launch.runID)
        // Same card, same identity, no second conversation.
        #expect(try await context.catalog.sessions().count == 1)
        #expect(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID == identity)
        #expect(try await context.catalog.session(id: launch.sessionID)?.lifecycle == .active)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// The user's report: after Stop and Resume the card read "State unknown" and Claude ran at
    /// its saved default instead of the `/effort` level set in the session.
    @Test func resumedClaudeIsReadyAndRunsAtTheEffortTheConversationUsed() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        #expect(await screen.contains("effort=default"))
        #expect(await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .atPrompt
        })
        try await screen.send("/effort max")
        #expect(await screen.contains("Set effort level to max (this session only)"))
        try await screen.send("first turn")
        #expect(await screen.contains("echo: first turn"))
        #expect(await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await Self.waitUntil { await lastEndedRun(context, launch.runID) })

        let (resumed, resumedScreen) = try await Self.resume(context, launch.sessionID)
        let sawEffort = await resumedScreen.contains("effort=max")
        #expect(sawEffort, "screen: \(resumedScreen.snapshot)")
        #expect(await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: resumed.sessionID)?.activity == .atPrompt
        })
        try await resumedScreen.send("second turn")
        #expect(await resumedScreen.contains("echo: second turn"))
        #expect(await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: resumed.sessionID)?.activity == .turnComplete
        })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func resumeOfMissingHistoryIsAnExplicitErrorNotANewConversation() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let session = ManagedSession(
            provider: .claude, providerConversationID: "missing-history-1",
            workingDirectory: context.home.path
        )
        try await context.supervisor.createSession(session)

        let launch = try await context.runtime.resumeConversation(sessionID: session.id)
        // The provider itself refuses; the card carries the typed error.
        #expect(await Self.waitUntil {
            await context.events.snapshot().sessions[session.id]?.issue?
                .contains("Provider history unavailable") == true
        })
        #expect(await Self.waitUntil { await lastEndedRun(context, launch.runID) })
        #expect(try await context.catalog.sessions().count == 1)
        #expect(await context.supervisor.session(id: session.id)?.providerConversationID == "missing-history-1")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func resumeWithoutIdentityOrFolderIsRefused() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let unassigned = ManagedSession(provider: .claude, workingDirectory: context.home.path)
        try await context.supervisor.createSession(unassigned)
        await #expect(throws: SessionRuntimeError.noProviderIdentity(.claude)) {
            _ = try await context.runtime.resumeConversation(sessionID: unassigned.id)
        }
        let orphan = ManagedSession(
            provider: .claude, providerConversationID: "some-id",
            workingDirectory: context.root.appendingPathComponent("vanished").path
        )
        try await context.supervisor.createSession(orphan)
        await #expect(throws: SessionRuntimeError.missingDirectory(orphan.workingDirectory)) {
            _ = try await context.runtime.resumeConversation(sessionID: orphan.id)
        }
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func repeatedResumeCreatesOneRunAndRunningResumeIsRefused() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let session = ManagedSession(
            provider: .claude, providerConversationID: "conv-repeat", workingDirectory: context.home.path
        )
        try await context.supervisor.createSession(session)
        async let first = context.runtime.resumeConversation(sessionID: session.id)
        async let second: RuntimeLaunch? = try? await context.runtime.resumeConversation(sessionID: session.id)
        let launches = [try? await first, await second].compactMap { $0 }
        #expect(launches.count == 1)
        #expect(await context.supervisor.runningSessionIDs() == [session.id])
        await #expect(throws: SessionRuntimeError.alreadyRunning(session.id)) {
            _ = try await context.runtime.resumeConversation(sessionID: session.id)
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func clearMovesTheSameTerminalToANewConversationInTheSameProject() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("clear-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let (launch, screen) = try await Self.launchClaude(context, projectID: project.id)
        try await screen.send("first prompt")
        #expect(await screen.contains("echo: first prompt"))
        #expect(try await Self.waitUntil {
            try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID != nil
        })

        try await screen.send("/clear")
        #expect(await screen.contains("CLEARED "))
        #expect(try await Self.waitUntil { try await context.catalog.sessions().count == 2 })
        let all = try await context.catalog.sessions()
        let newRecord = try #require(all.first { $0.session.id != launch.sessionID })
        // The old card is history; the new one owns the same run and the project.
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun == nil)
        #expect(await context.supervisor.session(id: newRecord.session.id)?.currentRun?.id == launch.runID)
        #expect(await context.supervisor.activeSessionID(runID: launch.runID) == newRecord.session.id)
        #expect(newRecord.projectID == project.id)
        #expect(try await context.catalog.session(id: launch.sessionID)?.projectID == project.id)
        let links = try await context.catalog.runSessionLinks(runID: launch.runID)
        #expect(links.map(\.sessionID) == [launch.sessionID, newRecord.session.id])

        // The old card can no longer act on the new conversation's run.
        await #expect(throws: SessionRuntimeError.notRunning(launch.sessionID)) {
            _ = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        }
        try await screen.send("after clear")
        #expect(await screen.contains("echo: after clear"))
        #expect(await context.supervisor.runningSessionIDs() == [newRecord.session.id])
        #expect((await context.runtime.shutdown()).succeeded)
    }

    // MARK: C5 two live conversations

    @Test func stoppingOneConversationLeavesTheOtherWorking() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (first, firstScreen) = try await Self.launchClaude(context)
        let (second, secondScreen) = try await Self.launchClaude(context)
        #expect(await firstScreen.contains("FAKE-CLAUDE READY"))
        #expect(await secondScreen.contains("FAKE-CLAUDE READY"))

        #expect(try await context.runtime.stopConversation(sessionID: first.sessionID).succeeded)
        try await secondScreen.send("still here")
        #expect(await secondScreen.contains("echo: still here"))
        #expect(await context.supervisor.runningSessionIDs() == [second.sessionID])
        await #expect(throws: SessionRuntimeError.notRunning(first.sessionID)) {
            _ = try await context.runtime.stopConversation(sessionID: first.sessionID)
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    // MARK: C3 lifecycle through the runtime

    private func blockers(_ context: RuntimeContext, _ id: UUID) async -> Set<SessionIdleBlocker> {
        await context.events.snapshot().sessions[id]?.blockers ?? []
    }

    @Test func idleIsBlockedUntilAReliableQuietMomentThenStopsSafely() async throws {
        let policy = SessionIdlePolicy(idleAfter: 0.6, staleAfter: 3_600, stopGraceSeconds: 0.1)
        let context = try await Self.makeContext(idlePolicy: policy)
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))

        // Before the first turn Claude is at its prompt, but no quiet process
        // baseline exists yet: the block stays visible and the terminal is not
        // mistaken for idle.
        #expect(try await Self.waitUntil(4) {
            await blockers(context, launch.sessionID).contains(.baselineNotCaptured)
        })
        #expect(!(await blockers(context, launch.sessionID).contains(.unknownAgentState)))
        #expect(await context.supervisor.runningSessionIDs() == [launch.sessionID])

        // An active turn keeps blocking; after it ends the baseline is taken
        // at that quiet moment and the run is stopped for inactivity.
        try await screen.send("/work 1500")
        #expect(await screen.contains("WORKING 1500"))
        #expect(try await Self.waitUntil(3) {
            await blockers(context, launch.sessionID).contains(.activeTurn)
        })
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(try await Self.waitUntil(8) {
            try await context.catalog.session(id: launch.sessionID)?.lifecycle == .idle
        })
        await idleDiagnostics(context, launch.sessionID, label: "quiet automatic idle")
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(await context.runtime.liveRunCount() == 0)
        let run = try #require(try await context.catalog.runs().first { $0.id == launch.runID })
        #expect(run.endReason == .idle)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// The app's policy (user decision, 8 Oct 2026): a quiet session past the idle period keeps
    /// running; only the user's Stop or Quit ends it.
    @Test func withAutomaticIdleStopOffAQuietSessionKeepsRunning() async throws {
        let policy = SessionIdlePolicy(idleAfter: 0.3, staleAfter: 3_600, stopGraceSeconds: 0.1, stopsIdleRuns: false)
        let context = try await Self.makeContext(idlePolicy: policy)
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("/work 100")
        #expect(await screen.contains("WORKING 100"))
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        // Several idle periods pass after the quiet moment the baseline is taken at.
        try await Task.sleep(for: .seconds(2))
        #expect(await context.supervisor.runningSessionIDs() == [launch.sessionID])
        #expect(try await context.catalog.session(id: launch.sessionID)?.lifecycle == .active)
        #expect(try await context.catalog.runs().first { $0.id == launch.runID }?.endReason == nil)
        try await screen.send("still here")
        #expect(await screen.contains("echo: still here"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func interruptedNativeWorkMetadataReopensInputAndCannotRepairHookLoss() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("/interrupt-work")
        #expect(await screen.contains("WORKING-UNTIL-INTERRUPT"))
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .working
        })
        try await screen.send("cancel")
        #expect(await screen.contains("INTERRUPTED-WORK"))
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .waitingForInput
        })
        try await screen.send("/interrupt-work")
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .working
        })
        // The same monotonic flag set synchronously by overflowing authority
        // ingress must also fence later perfectly valid metadata snapshots.
        #expect(context.supervisor.invalidateProviderWorkState(runID: launch.runID))
        try await screen.send("cancel")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .unknown)
        guard case let .blocked(reasons) = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: Date().addingTimeInterval(10_000)) else {
            Issue.record("Unreliable work must block idle"); return
        }
        #expect(reasons.contains(.unknownAgentState))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func nativeDenialRegistryReopensInputWithoutInventingSuccessfulTurn() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("/approve")
        #expect(await screen.contains("NEEDS-APPROVAL"))
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .waitingForApproval
        })
        try await screen.send("n")
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .waitingForInput
        })
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun?.id == launch.runID)
        guard case let .blocked(reasons) = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: Date().addingTimeInterval(10_000)) else {
            Issue.record("Input-ready metadata must block idle"); return
        }
        #expect(reasons.contains(.waitingForInput))
        // A later new approval cannot be cleared by the previous idle file.
        try await screen.send("/approve")
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .waitingForApproval
        })
        try await Task.sleep(for: .milliseconds(150))
        #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .waitingForApproval)
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.runtime.liveRunCount() == 0)
    }

    @Test func approvalAndBackgroundWorkKeepAConversationFromIdling() async throws {
        let policy = SessionIdlePolicy(idleAfter: 0.5, staleAfter: 3_600, stopGraceSeconds: 0.1)
        let context = try await Self.makeContext(idlePolicy: policy)
        defer { context.cleanup() }
        let (approval, approvalScreen) = try await Self.launchClaude(context)
        try await approvalScreen.send("/approve")
        #expect(await approvalScreen.contains("NEEDS-APPROVAL"))
        #expect(try await Self.waitUntil(4) {
            await blockers(context, approval.sessionID).contains(.waitingForApproval)
        })
        #expect(await context.supervisor.session(id: approval.sessionID)?.currentRun != nil)

        let (background, backgroundScreen) = try await Self.launchClaude(context)
        try await backgroundScreen.send("/background")
        #expect(await backgroundScreen.contains("BACKGROUND "))
        #expect(try await Self.waitUntil(4) {
            await blockers(context, background.sessionID)
                .contains { if case .pendingProviderWork = $0 { true } else { false } }
        })
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(await context.supervisor.runningSessionIDs() == [approval.sessionID, background.sessionID])
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func idleStopClosesInputAtomicallyAndPendingBytesBlockIt() async throws {
        // Automatic evaluation is off in effect (long idle); the test drives it.
        let context = try await Self.makeContext(
            idlePolicy: SessionIdlePolicy(idleAfter: 3_600, staleAfter: 7_200, stopGraceSeconds: 0.1)
        )
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("quiet prompt")
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect(try await Self.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })

        // Stand-in for the terminal surface: a queue whose write is held.
        let hold = HoldingWriter()
        let errors = InputErrorLog()
        let queue = TerminalInputQueue(writer: { try await hold.write($0) }, onError: { errors.append($0) })
        context.runtime.inputGate.register(runID: launch.runID, queue: queue)
        #expect(queue.enqueue(Array("x".utf8)))
        let later = Date().addingTimeInterval(4_000)

        // Bytes are still in flight: the stop must not happen.
        guard case let .blocked(reasons) = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: later
        ) else { Issue.record("expected the pending input to block the stop"); return }
        #expect(reasons.contains { if case .pendingPromptDelivery = $0 { true } else { false } })
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)

        // Once written, the bytes still count as fresh use (the provider may not
        // have read them): the stop keeps waiting instead of losing them.
        hold.release()
        #expect(try await Self.waitUntil { !queue.isDraining })
        guard case let .blocked(recent) = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: later
        ) else { Issue.record("recent input must block the stop"); return }
        #expect(recent.contains(.recentTerminalInput))

        // A terminal with no recent input: the stop goes ahead and the closed
        // terminal refuses new input whole instead of accepting and losing it.
        let quiet = TerminalInputQueue(writer: { try await hold.write($0) }, onError: { errors.append($0) })
        context.runtime.inputGate.register(runID: launch.runID, queue: quiet)
        guard case .transitioned = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: later
        ) else { Issue.record("expected the idle stop to succeed"); return }
        #expect(quiet.enqueue(Array("late".utf8)) == false)
        #expect(errors.values.contains { if case .closed = $0 { true } else { false } })
        #expect(quiet.pendingByteCount == 0)
        #expect(hold.writes == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    // MARK: C5 exit, failed stop and retry

    @Test func leaderExitEndsTheWholeRunAndKillsBackgroundDescendants() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("/background")
        #expect(await screen.contains("BACKGROUND "))
        let text = screen.snapshot
        let pid = try #require(text.components(separatedBy: "BACKGROUND ").last
            .flatMap { Int32($0.prefix { $0.isNumber }) })
        #expect(try ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie })

        // `/exit` only ends the leader; the run still owns the background work.
        try await screen.send("/exit")
        #expect(try await Self.waitUntil(8) { await lastEndedRun(context, launch.runID) })
        // A killed orphan may linger as a zombie until launchd reaps it; a
        // zombie is not running work.
        let gone = try await Self.waitUntil {
            try ProcessTable.snapshot().first { $0.identity.pid == pid }.map(\.zombie) ?? true
        }
        #expect(gone)
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.stopFailure == nil)
        #expect(await context.runtime.liveRunCount() == 0)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func failedStopStaysOnTheCardAndARetryClearsIt() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        let attempts = AttemptCounter()
        try await context.supervisor.registerStopHooks(
            runID: launch.runID,
            hooks: ManagedRunStopHooks(
                prepare: {
                    if attempts.next() == 1 { throw LoomError.message("provider work still running") }
                }, completed: {}
            )
        )

        let failed = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!failed.succeeded)
        #expect(failed.providerStages?.first?.errorCategory == "providerError")
        #expect(failed.signals.isEmpty)
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.stopFailure?
            .contains("Provider prepare failed (providerError)") == true)
        // The run is still alive, so the conversation cannot be started again.
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        await #expect(throws: SessionRuntimeError.self) {
            _ = try await context.runtime.resumeConversation(sessionID: launch.sessionID)
        }

        let retried = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(retried.succeeded)
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.stopFailure == nil)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// Count only this fixture's vnode paths. Regular/config-directory FDs
    /// can be checked independently of the runtime's record dictionary.
    static func registryDescriptorCounts(_ paths: Set<String>) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
            guard let fd = Int32(name) else { continue }
            var info = stat()
            if fstat(fd, &info) != 0 {
                if errno == EBADF { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let kind = info.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else { continue }
            var vnode = vnode_fdinfowithpath()
            errno = 0
            let size = proc_pidfdinfo(getpid(), fd, PROC_PIDFDVNODEPATHINFO, &vnode,
                                     Int32(MemoryLayout.size(ofValue: vnode)))
            if size != MemoryLayout.size(ofValue: vnode) {
                if errno == EBADF || errno == ENOENT { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
            }
            let value = withUnsafePointer(to: &vnode.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if paths.contains(value) { counts[value, default: 0] += 1 }
        }
        return counts
    }

    @Test func failedQuitReconcilesEndedRegistryWithNoEndFrameAndPreservesLiveRetry() async throws {
        // An unstarted observer is the deterministic equivalent of an end
        // frame delayed beyond shutdown. All launch/stop paths are production.
        let context = try await Self.makeContext(startRuntime: false)
        defer { context.cleanup() }
        let (ended, _) = try await Self.launchClaude(context)
        let (remaining, _) = try await Self.launchClaude(context)
        let endedPID = try #require(await context.supervisor.session(id: ended.sessionID)?.currentRun?.leader.pid)
        let remainingPID = try #require(await context.supervisor.session(id: remaining.sessionID)?.currentRun?.leader.pid)
        let config = realPath(context.profile)
        // Once `sessions` exists neither the config directory nor its parent is watched.
        let unwatched = Set([realPath(context.root), config])
        let directoryPaths = Set([config + "/sessions"])
        let endedPath = config + "/sessions/\(endedPID).json"
        let remainingPath = config + "/sessions/\(remainingPID).json"
        let paths = directoryPaths.union([endedPath, remainingPath]).union(unwatched)
        #expect(try await Self.waitUntil {
            let counts = try Self.registryDescriptorCounts(paths)
            return directoryPaths.allSatisfy { counts[$0] == 2 }
                && counts[endedPath] == 1 && counts[remainingPath] == 1
                && unwatched.allSatisfy { counts[$0] == nil }
        })
        #expect(await context.runtime.liveRunCount() == 2)
        // Finish one run without delivering its end frame, then hold the
        // other run's real catalog transition across the bounded Quit.
        #expect((try await context.supervisor.stop(sessionID: ended.sessionID)).succeeded)
        let gate = RuntimeCatalogGate()
        defer { gate.release() }
        let hold = Task.detached { await context.catalog.holdForRuntimeQuitTest(gate) }
        #expect(await Self.waitUntil { gate.entered })
        let adoption = Task {
            try await context.supervisor.adoptConversation(
                runID: remaining.runID, conversationID: "quit-retry-\(UUID())", transition: .new
            )
        }
        #expect(await Self.waitUntil { await context.supervisor.pendingConversationTransitionCount() == 1 })

        let failed = await context.runtime.shutdown()
        #expect(!failed.succeeded)
        #expect(failed.remaining.contains { $0.identity.pid == remainingPID })
        #expect(await context.supervisor.runContext(runID: ended.runID) == nil)
        #expect(await context.supervisor.runContext(runID: remaining.runID) != nil)
        #expect(await context.runtime.liveRunCount() == 1)
        #expect(try await Self.waitUntil(2) {
            let counts = try Self.registryDescriptorCounts(paths)
            return directoryPaths.allSatisfy { counts[$0] == 1 } && counts[endedPath] == nil
                && counts[remainingPath] == 1
        })

        gate.release()
        await hold.value
        _ = try await adoption.value
        let retried = await context.runtime.shutdown()
        #expect(retried.succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(await context.runtime.liveRunCount() == 0)
        #expect(try await Self.waitUntil(2) { try Self.registryDescriptorCounts(paths).isEmpty })
    }

    @Test func successfulQuitReconcilesRegistryWithoutAnEndFrame() async throws {
        let context = try await Self.makeContext(startRuntime: false)
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchClaude(context)
        let pid = try #require(await context.supervisor.session(id: launch.sessionID)?.currentRun?.leader.pid)
        let config = realPath(context.profile)
        let paths = Set([config + "/sessions", config + "/sessions/\(pid).json"])
        let unwatched = Set([realPath(context.root), config])
        #expect(try await Self.waitUntil {
            let counts = try Self.registryDescriptorCounts(paths.union(unwatched))
            return counts.count == paths.count && unwatched.allSatisfy { counts[$0] == nil }
        })
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.runtime.liveRunCount() == 0)
        #expect(try await Self.waitUntil(2) { try Self.registryDescriptorCounts(paths).isEmpty })
    }

    // MARK: D3 (C part): Quit while a start is in progress

    @Test func quitDuringASlowEnvironmentResolutionStartsNothing() async throws {
        let context = try await Self.makeContext()
        defer { context.cleanup() }
        context.toolchainSwitch.slow(by: 1)
        async let started: RuntimeLaunch? = try? await context.runtime.startConversation(provider: .claude, projectID: nil)
        try await Task.sleep(for: .milliseconds(200))
        let report = await context.runtime.shutdown()
        #expect(report.succeeded)
        #expect(await started == nil)
        #expect(try await context.catalog.sessions().isEmpty)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(await context.runtime.liveRunCount() == 0)
    }

    // MARK: Review §4.1 madde 2: user work started during the first turn

    private func firstTurnChild(
        _ context: RuntimeContext, command: String
    ) async throws -> (RuntimeLaunch, Screen, Int32) {
        let (launch, screen) = try await Self.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        try await screen.send(command)
        #expect(await screen.contains("BACKGROUND "))
        let pid = try #require(screen.snapshot.components(separatedBy: "BACKGROUND ").last
            .flatMap { Int32($0.prefix { $0.isNumber }) })
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        if command.hasSuffix("hidden") {
            // Nothing announced: the baseline is taken at this quiet moment.
            #expect(try await Self.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })
        }
        return (launch, screen, pid)
    }

    @Test(arguments: ["/hidden", "/background", "/delayed-hidden", "/delayed-background"])
    func aChildStartedInTheFirstTurnNeverBecomesPartOfTheBaseline(command: String) async throws {
        let context = try await Self.makeContext(
            idlePolicy: SessionIdlePolicy(idleAfter: 3_600, staleAfter: 7_200, stopGraceSeconds: 0.1)
        )
        defer { context.cleanup() }
        let (launch, _, pid) = try await firstTurnChild(context, command: command)
        // Announced (`/background`) or not (`/hidden`): the running child blocks idle.
        let outcome = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: Date().addingTimeInterval(4_000)
        )
        if case let .blocked(reasons) = outcome {
            #expect(reasons.contains { if case .nonBaselineDescendants = $0 { true } else { false } }
                || reasons.contains { if case .pendingProviderWork = $0 { true } else { false } })
        } else { Issue.record("a live user child must block the idle stop") }
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(try ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["/hidden", "/delayed-hidden"])
    func aChildFromBeforeClearStaysWorkForTheNewConversation(command: String) async throws {
        let context = try await Self.makeContext(
            idlePolicy: SessionIdlePolicy(idleAfter: 3_600, staleAfter: 7_200, stopGraceSeconds: 0.1)
        )
        defer { context.cleanup() }
        let (launch, screen, pid) = try await firstTurnChild(context, command: command)
        try await screen.send("/clear")
        #expect(try await Self.waitUntil { try await context.catalog.sessions().count == 2 })
        let newID = try #require(try await context.catalog.sessions().first { $0.session.id != launch.sessionID }?.session.id)
        try await screen.send("quiet prompt in the new conversation")
        #expect(try await Self.waitUntil { await context.runtime.baselineCaptured(sessionID: newID) })
        #expect(await context.supervisor.session(id: newID)?.currentRun?.id == launch.runID)
        let outcome = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: newID, at: Date().addingTimeInterval(4_000)
        )
        if case let .blocked(reasons) = outcome {
            #expect(reasons.contains { if case .nonBaselineDescendants = $0 { true } else { false } })
        } else { Issue.record("the earlier child must still block idle after /clear") }
        #expect(try ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    // MARK: Review §8.1: child exit without another provider event

    private func idleDiagnostics(_ context: RuntimeContext, _ id: UUID, label: String) async {
        let records = (try? await context.supervisor.sample(sessionID: id)) ?? []
        let reasons = await blockers(context, id)
        print("IDLE-DIAGNOSTICS \(label) blockers=\(reasons) processes=\(records.map { ($0.identity, $0.zombie) }) timer=\(await context.runtime.lifecycle.timerFireCount())")
    }

    @Test(arguments: [false, true])
    func childExitRearmsAutomaticIdleWithoutAnotherProviderEvent(heldHook: Bool) async throws {
        let context = try await Self.makeContext(
            idlePolicy: SessionIdlePolicy(idleAfter: 0.3, staleAfter: 3_600, stopGraceSeconds: 0.1),
            extraEnvironment: heldHook ? ["LOOM_FAKE_HOLD_STOP_HOOK": "1"] : [:]
        )
        defer { context.cleanup() }
        let launch: RuntimeLaunch
        let pid: Int32
        if heldHook {
            let (started, screen) = try await Self.launchClaude(context)
            launch = started
            try await screen.send("quiet prompt")
            let marker = context.state.appendingPathComponent("held-hook-pid")
            #expect(try await Self.waitUntil { FileManager.default.fileExists(atPath: marker.path) })
            pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))

        } else {
            let (started, _, child) = try await firstTurnChild(context, command: "/hidden")
            launch = started
            pid = child
        }
        #expect(try await Self.waitUntil {
            await blockers(context, launch.sessionID).contains {
                if case .nonBaselineDescendants = $0 { true } else { false }
            }
        })
        await idleDiagnostics(context, launch.sessionID, label: "blocked hook=\(heldHook)")
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(try ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie })
        let before = await context.runtime.lifecycle.timerFireCount()
        try await Task.sleep(for: .milliseconds(350))
        #expect(await context.runtime.lifecycle.timerFireCount() <= before + 1)
        if heldHook {
            try Data().write(to: context.state.appendingPathComponent("release-hook"))
        } else { #expect(kill(pid, SIGKILL) == 0) }
        // No prompt, selection, provider event, or manual idle evaluation follows.
        let idled = try await Self.waitUntil(8) {
            try await context.catalog.session(id: launch.sessionID)?.lifecycle == .idle
        }
        await idleDiagnostics(context, launch.sessionID, label: "after exit hook=\(heldHook)")
        #expect(idled)
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun == nil)
        #expect(await blockers(context, launch.sessionID).isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
        let stopped = await context.runtime.lifecycle.timerFireCount()
        try await Task.sleep(for: .milliseconds(350))
        #expect(await context.runtime.lifecycle.timerFireCount() == stopped)
    }

    // MARK: Review §4.1 madde 1: written to the PTY is not read by the provider

    @Test func aPromptAcceptedBeforeTheProviderReadsItIsNotLostToTheIdleStop() async throws {
        let context = try await Self.makeContext(
            idlePolicy: SessionIdlePolicy(idleAfter: 3_600, staleAfter: 7_200, stopGraceSeconds: 0.1)
        )
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("quiet prompt")
        #expect(try await Self.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect(try await Self.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })

        // turnComplete is delivered before its command helper exits. Isolate
        // the input-gate race from the separately tested descendant blocker.
        await idleDiagnostics(context, launch.sessionID, label: "before unread-prompt prerequisite")
        #expect(try await Self.waitUntil {
            let records = try await context.supervisor.sample(sessionID: launch.sessionID)
            return records.count == 1 && records.first?.identity.pid == launch.terminal.pid
        })

        // The production queue and endpoint, with the provider paused between
        // the PTY write and its read.
        let errors = InputErrorLog()
        let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { errors.append($0) })
        context.runtime.inputGate.register(runID: launch.runID, queue: queue)
        let pid = launch.terminal.pid
        #expect(kill(pid, SIGSTOP) == 0)
        #expect(queue.enqueue(Array("must-not-disappear\r".utf8)))
        #expect(try await Self.waitUntil { !queue.isDraining })

        let outcome = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: Date().addingTimeInterval(4_000)
        )
        kill(pid, SIGCONT)
        guard case let .blocked(reasons) = outcome else {
            Issue.record("the accepted prompt was stopped away: \(outcome)")
            return
        }
        await idleDiagnostics(context, launch.sessionID, label: "unread prompt outcome=\(outcome)")
        #expect(reasons.contains(.recentTerminalInput))
        // Nothing was rejected, and the provider handled the prompt exactly once.
        #expect(errors.values.isEmpty)
        #expect(await screen.contains("echo: must-not-disappear"))
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(screen.snapshot.components(separatedBy: "echo: must-not-disappear").count == 2)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func recentInputPostponesTheAutomaticIdleToOnePolicyPeriodAfterTheInput() async throws {
        let policy = SessionIdlePolicy(idleAfter: 1.2, staleAfter: 3_600, stopGraceSeconds: 0.1)
        let context = try await Self.makeContext(idlePolicy: policy)
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchClaude(context)
        try await screen.send("first")
        #expect(try await Self.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })
        let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { _ in })
        context.runtime.inputGate.register(runID: launch.runID, queue: queue)
        // Input a moment before the deadline moves the deadline; the run is not
        // stopped at the old one, and is stopped once the input is a period old.
        try await Task.sleep(for: .milliseconds(900))
        #expect(queue.enqueue(Array("still here\r".utf8)))
        try await Task.sleep(for: .milliseconds(600))
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(try await Self.waitUntil(6) {
            try await context.catalog.session(id: launch.sessionID)?.lifecycle == .idle
        })
        #expect(await screen.contains("echo: still here"))
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
