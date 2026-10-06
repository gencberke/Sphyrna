import Darwin
import Foundation

public struct SessionRuntimeConfiguration: Sendable {
    public var toolchains: ProviderToolchainResolver
    /// Path of the bundled `loom-hook` helper Claude runs for each hook event.
    public var hookHelperPath: String
    /// Owner-only folder for the hook and Codex sockets. Unix socket paths are
    /// limited to about 100 bytes, so keep it short.
    public var socketDirectory: URL
    /// Working directory of a conversation that belongs to no project.
    public var homeDirectory: String
    public var clientVersion: String
    public var idlePolicy: SessionIdlePolicy
    /// Deadline for noninteractive callers. An interactive terminal-ready
    /// callback keeps identity pending until provider completion, Stop or Quit.
    public var codexIdentityTimeout: TimeInterval
    public var codexServerStartupTimeout: TimeInterval
    /// A resumed run that ends this quickly is checked for provider history errors.
    public var resumeDiagnosticsWindow: TimeInterval

    public init(
        toolchains: @escaping ProviderToolchainResolver, hookHelperPath: String,
        socketDirectory: URL,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        clientVersion: String = "loom", idlePolicy: SessionIdlePolicy = SessionIdlePolicy(),
        codexIdentityTimeout: TimeInterval = 10, codexServerStartupTimeout: TimeInterval = 8,
        resumeDiagnosticsWindow: TimeInterval = 15
    ) {
        self.toolchains = toolchains
        self.hookHelperPath = hookHelperPath
        self.socketDirectory = socketDirectory
        self.homeDirectory = homeDirectory
        self.clientVersion = clientVersion
        self.idlePolicy = idlePolicy
        self.codexIdentityTimeout = codexIdentityTimeout
        self.codexServerStartupTimeout = codexServerStartupTimeout
        self.resumeDiagnosticsWindow = resumeDiagnosticsWindow
    }
}

public enum SessionRuntimeError: Error, CustomStringConvertible, Equatable, Sendable {
    case shuttingDown
    case catalogUnavailable
    case projectNotFound(UUID)
    case missingDirectory(String)
    case sessionNotFound(UUID)
    /// A start or resume for this conversation is already in progress.
    case alreadyStarting(UUID)
    case alreadyRunning(UUID)
    case notRunning(UUID)
    case noProviderIdentity(ManagedSession.Provider)
    case providerIdentityTimeout(ManagedSession.Provider)
    case unsupportedProvider(ManagedSession.Provider)
    case unverifiedStop(UUID)
    case requestNotPending(String)

    public var description: String {
        switch self {
        case .shuttingDown:
            "Loom is quitting; no new work is accepted"
        case .catalogUnavailable:
            "The conversation catalog is not available"
        case let .projectNotFound(id):
            "Project not found: \(id)"
        case let .missingDirectory(path):
            "The working directory no longer exists: \(path)"
        case let .sessionNotFound(id):
            "Conversation not found: \(id)"
        case let .alreadyStarting(id):
            "The conversation is already starting: \(id)"
        case let .alreadyRunning(id):
            "The conversation is already running: \(id)"
        case let .notRunning(id):
            "The conversation is not running: \(id)"
        case let .noProviderIdentity(provider):
            "This \(provider.rawValue) conversation has no provider identity yet, so it cannot be resumed. Loom will not start a new conversation in its place."
        case let .providerIdentityTimeout(provider):
            "\(provider.rawValue) did not report its conversation identity in time; the start was undone"
        case let .unsupportedProvider(provider):
            "\(provider.rawValue) conversations cannot be started from the app"
        case let .unverifiedStop(id):
            "The last stop of this conversation could not be verified: \(id)"
        case let .requestNotPending(id):
            "The provider request is no longer pending: \(id)"
        }
    }
}

/// A live provider terminal handed to the UI. `sessionID` owns the run at
/// launch; ownership can move later (`/clear`, `/new`) and is read from the
/// supervisor, never cached.
public struct RuntimeLaunch: Sendable {
    public let sessionID: UUID
    public let runID: UUID
    public let provider: ManagedSession.Provider
    public let terminal: TerminalEndpoint
}

public enum ProviderRequestDecision: Sendable {
    case accept
    case decline
}

/// The one application runtime: it wires the process supervisor, the catalog,
/// the lifecycle controller and both provider integrations. UI code only sends
/// intents here; process start, waiting and cleanup never run on MainActor.
/// Bounded authority ingress; isolated here so paused-consumer behavior can
/// be tested against the same transport path used by the runtime.
final class ClaudeHookIngress: Sendable {
    let stream: AsyncStream<ClaudeHookEnvelope>
    private let continuation: AsyncStream<ClaudeHookEnvelope>.Continuation
    private let adapter: ClaudeSessionAdapter

    init(adapter: ClaudeSessionAdapter, capacity: Int = 1_024) {
        self.adapter = adapter
        let pair = AsyncStream<ClaudeHookEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        stream = pair.stream
        continuation = pair.continuation
    }

    func receive(_ envelope: ClaudeHookEnvelope) {
        if case let .dropped(dropped) = continuation.yield(envelope) {
            adapter.noteHookLoss(runID: dropped.managedRunID)
        }
    }
}

/// Hands the lifecycle controller (built before the runtime exists) a way back
/// to the runtime without a reference cycle.
private final class CompanionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: SessionRuntime?

    var runtime: SessionRuntime? {
        get { lock.withLock { target } }
        set { lock.withLock { target = newValue } }
    }

    var companion: SessionRunCompanion {
        SessionRunCompanion(
            work: { [self] id in try await runtime?.companionWork(sessionID: id) },
            teardown: { [self] id in await runtime?.companionTeardown(runID: id) ?? [] }
        )
    }
}

public actor SessionRuntime {
    private struct RunRecord {
        let runID: UUID
        let launchSessionID: UUID
        let provider: ManagedSession.Provider
        /// The Codex app-server of this run. A run owns exactly one, for its
        /// whole life, whichever card (`/new`, `/clear`) it is on later.
        let server: CodexServer?
        let startedAt: Date
        let isResume: Bool
        let diagnostics: DiagnosticOutputTee?
        let terminal: TerminalEndpoint
        /// The card the run was last seen on; where a teardown failure is shown.
        var activeSession: UUID
        var baselineSessions: Set<UUID> = []
    }

    private struct StartKey: Hashable {
        let provider: ManagedSession.Provider
        let projectID: UUID?
    }

    public let supervisor: ProcessSupervisor
    public let catalog: SessionCatalog
    public let lifecycle: SessionLifecycleController
    /// Terminal surfaces register their input queues here so an automatic
    /// stop can refuse late input atomically (see `TerminalInputGate`).
    public nonisolated let inputGate: TerminalInputGate
    private let configuration: SessionRuntimeConfiguration
    private let claudeAdapter: ClaudeSessionAdapter
    private let codexAdapter: CodexSessionAdapter

    private var toolchains: [ManagedSession.Provider: ProviderToolchain] = [:]
    private var toolchainWarnings: [String] = []
    private var runs: [UUID: RunRecord] = [:]
    private var startingNew: Set<StartKey> = []
    private var startingSessions: Set<UUID> = []
    /// Runs Loom itself is stopping (user stop, undone launch): their exit is
    /// not a provider failure.
    private var stopRequestedRuns: Set<UUID> = []
    private var reservations: [UUID: (CodexLaunchReservation, CodexSessionCoordinator)] = [:]
    private var startupConnectionFailures: [UUID: String] = [:]
    private var shuttingDown = false
    private var started = false
    private var observer: Task<Void, Never>?

    private var hookServer: ClaudeHookServer?
    private var hookConfiguration: ClaudeHookLaunchConfiguration?
    private var hookTask: Task<Void, Never>?

    /// One app-server per Codex conversation run. It owns its socket, scope,
    /// client, coordinator and approval state, so nothing is shared between
    /// conversations. The run record references it; it is kept (even after the
    /// run ended) until its stop is verified.
    private final class CodexServer {
        let id = UUID()
        /// The card a failed teardown is retried for (resume of that card).
        var ownerCard: UUID
        let manager: CodexAppServerManager
        let socket: String
        let scope: RunScope?
        var runID: UUID?
        var client: CodexAppServerClient?
        var coordinator: CodexSessionCoordinator?
        var setup: (id: UUID, task: Task<CodexSessionCoordinator, any Error>)?
        var requestTask: Task<Void, Never>?
        var requests: [String: CodexPendingRequest] = [:]
        var requestRevision: UInt64 = 0
        var requestOwners: [String: UUID] = [:]
        var failedRequests: [String: String] = [:]
        var teardownTask: Task<[String], Never>?
        var finished = false
        init(ownerCard: UUID, manager: CodexAppServerManager, socket: String, scope: RunScope?) {
            self.ownerCard = ownerCard
            self.manager = manager
            self.socket = socket
            self.scope = scope
        }
    }
    private var codexServers: [CodexServer] = []
    private let routingDiagnostics = CodexRoutingDiagnostics()
    enum CodexSetupPhase: Sendable { case installing }
    private var codexSetupObserverForTesting: (@Sendable (CodexSetupPhase) async -> Void)?
    func observeCodexSetupForTesting(_ observer: @escaping @Sendable (CodexSetupPhase) async -> Void) {
        codexSetupObserverForTesting = observer
    }

    /// Test access: the coordinator of the oldest live Codex server.
    var codexCoordinator: CodexSessionCoordinator? {
        codexServers.lazy.compactMap(\.coordinator).first
    }
    func codexCoordinator(forSession key: UUID) async -> CodexSessionCoordinator? {
        await codexServer(forCard: key)?.coordinator
    }

    public init(
        supervisor: ProcessSupervisor, catalog: SessionCatalog,
        configuration: SessionRuntimeConfiguration
    ) {
        self.supervisor = supervisor
        self.catalog = catalog
        self.configuration = configuration
        let gate = TerminalInputGate()
        inputGate = gate
        let relay = CompanionRelay()
        lifecycle = SessionLifecycleController(
            supervisor: supervisor, catalog: catalog, policy: configuration.idlePolicy,
            inputGate: gate, companion: relay.companion
        )
        claudeAdapter = ClaudeSessionAdapter(supervisor: supervisor)
        codexAdapter = CodexSessionAdapter(supervisor: supervisor)
        relay.runtime = self
    }

    /// Starts the single lifecycle listener/timer and the run observer. Opening
    /// the app never starts a provider or a terminal.
    public func start() async throws {
        guard !started else { return }
        started = true
        let stream = await supervisor.events.subscribe()
        observer = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.reconcile(frame)
            }
        }
        try await lifecycle.startAutomaticEvaluation()
    }

    public func codexRoutingDiagnostics() async -> CodexRoutingDiagnostics.Snapshot {
        await routingDiagnostics.snapshot()
    }

    public func environmentWarnings() -> [String] { toolchainWarnings }

    public func liveRunCount() -> Int { runs.count }

    /// The Codex app-servers that exist: one per live Codex run, kept until
    /// its stop is verified. `internalSessionID` is the oldest running one's
    /// internal (never catalogued) server session.
    public func codexServerState() async -> (servers: Int, internalSessionID: UUID?) {
        (codexServers.count, await codexServerSessionIDs().first)
    }

    /// Internal server sessions of every conversation server that is running.
    public func codexServerSessionIDs() async -> [UUID] {
        var ids: [UUID] = []
        for server in codexServers {
            if let id = await server.manager.internalSessionID() { ids.append(id) }
        }
        return ids
    }

    /// The internal server session and scope of the server a card is using:
    /// the run now on that card, else the run launched under it.
    func codexServerIdentity(forSession key: UUID) async -> (internalSessionID: UUID?, scope: RunScope?)? {
        guard let server = await codexServer(forCard: key) else { return nil }
        return (await server.manager.internalSessionID(), server.scope)
    }

    private func codexServer(forCard key: UUID) async -> CodexServer? {
        for record in runs.values {
            if let server = record.server, await supervisor.activeSessionID(runID: record.runID) == key { return server }
        }
        for record in runs.values where record.launchSessionID == key {
            if let server = record.server { return server }
        }
        return codexServers.last { $0.ownerCard == key }
    }

    /// Whether this conversation's process baseline was taken on its current run.
    public func baselineCaptured(sessionID: UUID) async -> Bool {
        guard let runID = await supervisor.session(id: sessionID)?.currentRun?.id else { return false }
        return runs[runID]?.baselineSessions.contains(sessionID) == true
    }

    // MARK: Start and resume

    /// Starts a new conversation. A project conversation runs in the project's
    /// folder; a projectless one in the home folder. Nothing is created until
    /// the toolchain and provider plumbing are ready, so a missing CLI or a
    /// broken environment leaves no card and no process behind.
    public func startConversation(
        provider: ManagedSession.Provider, projectID: UUID?,
        rows: UInt16 = 24, columns: UInt16 = 80,
        outputSink: (any TerminalOutputSink)? = nil,
        onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)? = nil
    ) async throws -> RuntimeLaunch {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard provider == .claude || provider == .codex else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        let key = StartKey(provider: provider, projectID: projectID)
        guard startingNew.insert(key).inserted else {
            throw SessionRuntimeError.alreadyStarting(projectID ?? UUID())
        }
        defer { startingNew.remove(key) }

        let directory = try await workingDirectory(projectID: projectID)
        let toolchain = try await toolchain(for: provider)
        let sessionID = UUID(), runID = UUID()
        switch provider {
        case .claude:
            let hooks = try ensureHooks()
            // Validated before the card exists: an unsupported CLI leaves nothing behind.
            let profile = try claudeProfile(
                route: .new(sessionID), toolchain: toolchain, sessionID: sessionID, hooks: hooks
            )
            try await supervisor.createSession(
                ManagedSession(id: sessionID, provider: .claude, workingDirectory: directory),
                projectID: projectID
            )
            startingSessions.insert(sessionID)
            defer { startingSessions.remove(sessionID) }
            return try await launchClaude(
                sessionID: sessionID, runID: runID, toolchain: toolchain, profile: profile,
                rows: rows, columns: columns, outputSink: outputSink, tee: nil
            )
        case .codex:
            let (server, coordinator) = try await ensureCodex(card: sessionID, toolchain: toolchain)
            let profile: ProviderLaunchProfile
            do {
                profile = try codexNewProfile(
                    toolchain: toolchain, sessionID: sessionID, directory: directory, server: server
                )
                try await supervisor.createSession(
                    ManagedSession(id: sessionID, provider: .codex, workingDirectory: directory),
                    projectID: projectID
                )
            } catch {
                // No card exists to show a failed cleanup on: the caller gets it.
                throw await startFailure(error, cleaning: server)
            }
            startingSessions.insert(sessionID)
            defer { startingSessions.remove(sessionID) }
            return try await launchNewCodex(
                sessionID: sessionID, runID: runID, directory: directory,
                toolchain: toolchain, profile: profile, server: server, coordinator: coordinator,
                rows: rows, columns: columns, outputSink: outputSink,
                onTerminalReady: onTerminalReady
            )
        case .synthetic:
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
    }

    /// Resumes a stopped conversation with its recorded provider identity and
    /// working directory. A missing identity, directory or provider history is
    /// an error the user sees; it never becomes a new conversation.
    public func resumeConversation(
        sessionID: UUID, rows: UInt16 = 24, columns: UInt16 = 80,
        outputSink: (any TerminalOutputSink)? = nil
    ) async throws -> RuntimeLaunch {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard startingSessions.insert(sessionID).inserted else {
            throw SessionRuntimeError.alreadyStarting(sessionID)
        }
        defer { startingSessions.remove(sessionID) }
        guard let record = try await catalog.session(id: sessionID) else {
            throw SessionRuntimeError.sessionNotFound(sessionID)
        }
        let session = record.session
        guard await supervisor.session(id: sessionID)?.currentRun == nil else {
            throw SessionRuntimeError.alreadyRunning(sessionID)
        }
        if let report = await supervisor.lastStopReport(sessionID: sessionID), !report.succeeded {
            throw SessionRuntimeError.unverifiedStop(sessionID)
        }
        guard session.provider == .claude || session.provider == .codex else {
            throw SessionRuntimeError.unsupportedProvider(session.provider)
        }
        guard let conversationID = session.providerConversationID, !conversationID.isEmpty else {
            throw SessionRuntimeError.noProviderIdentity(session.provider)
        }
        try requireDirectory(session.workingDirectory)
        let toolchain = try await toolchain(for: session.provider)
        let tee = DiagnosticOutputTee(downstream: outputSink)
        switch session.provider {
        case .claude:
            let hooks = try ensureHooks()
            let profile = try claudeProfile(
                route: .resume(conversationID), toolchain: toolchain,
                sessionID: sessionID, hooks: hooks
            )
            return try await launchClaude(
                sessionID: sessionID, runID: nil, toolchain: toolchain, profile: profile,
                rows: rows, columns: columns, outputSink: outputSink, tee: tee
            )
        case .codex:
            let (server, coordinator) = try await ensureCodex(card: sessionID, toolchain: toolchain)
            return try await resumeCodex(
                session: session, conversationID: conversationID, toolchain: toolchain,
                server: server, coordinator: coordinator,
                rows: rows, columns: columns, tee: tee
            )
        case .synthetic:
            throw SessionRuntimeError.unsupportedProvider(session.provider)
        }
    }

    // MARK: Stop, use and answers

    /// Stops exactly this conversation's run. The report is the verified
    /// outcome; an unverified stop is also carried to the card as a failure.
    @discardableResult
    public func stopConversation(sessionID: UUID) async throws -> SessionStopReport {
        guard let session = await supervisor.session(id: sessionID) else {
            throw SessionRuntimeError.sessionNotFound(sessionID)
        }
        guard let run = session.currentRun else { throw SessionRuntimeError.notRunning(sessionID) }
        stopRequestedRuns.insert(run.id)
        runs[run.id]?.activeSession = sessionID
        let server = runs[run.id]?.server
        var report = try await supervisor.stop(sessionID: sessionID)
        await reconcileEnded()
        // The conversation's own app-server is part of its stop: the TUI went
        // first (so the provider stop hooks had a server), the server and its
        // scope go now. A server that cannot be shown gone is a failed stop.
        if let server, await supervisor.runContext(runID: run.id) == nil {
            let errors = await tearDown(server, card: sessionID)
            if !errors.isEmpty { report = report.adding(errors: errors) }
        }
        return report
    }

    /// A deliberate view of a visible, active conversation. Updates the
    /// persistent use date; a stale conversation stays stale.
    public func markViewed(sessionID: UUID) async throws {
        try await lifecycle.markViewed(sessionID: sessionID)
    }

    /// Explicit user reactivation of a stale conversation (resume does it too).
    public func reactivate(sessionID: UUID) async throws {
        try await lifecycle.reactivate(sessionID: sessionID)
    }

    /// Sends the user's decision to Codex. A failed write keeps the request
    /// open with the failure; it is never treated as an answer.
    public func respond(
        sessionID: UUID, requestID: String, decision: ProviderRequestDecision
    ) async throws {
        guard let server = codexServers.first(where: { $0.requestOwners[requestID] == sessionID }),
              let pending = server.requests[requestID], let coordinator = server.coordinator else {
            throw SessionRuntimeError.requestNotPending(requestID)
        }
        let request = pending.request
        guard request.kind == .commandExecution || request.kind == .fileChange else {
            throw SessionRuntimeError.requestNotPending(requestID)
        }
        let answer: JSONValue = .object([
            "decision": .string(decision == .accept ? "accept" : "decline"),
        ])
        do {
            try await coordinator.respond(to: pending, result: answer)
        } catch {
            // The coordinator alone recognizes an authoritative resolution
            // winning the write race. Cleanup removing a request is not success.
            await received(requests: await coordinator.pendingRequestSnapshot(), from: coordinator)
            if server.requests[requestID] != nil {
                await markRequestFailed(
                    requestID, CodexSessionCoordinator.failureText("The answer was not delivered", error), in: server
                )
            }
            throw error
        }
        await received(requests: await coordinator.pendingRequestSnapshot(), from: coordinator)
    }

    // MARK: Quit

    /// One shutdown for everything the app owns. Starts refusing new work
    /// first; a failed shutdown stays failed so the caller can offer a retry.
    public func shutdown() async -> ShutdownReport {
        shuttingDown = true
        let servers = codexServers
        for server in servers {
            let setup = server.setup
            server.setup = nil
            setup?.task.cancel()
            _ = await setup?.task.result
        }
        for (reservation, coordinator) in reservations.values {
            await coordinator.cancelNewLaunch(reservation)
        }
        await lifecycle.stopAutomaticEvaluation()
        hookServer?.stop()
        hookServer = nil
        hookTask?.cancel()
        hookTask = nil
        for server in servers {
            _ = await server.teardownTask?.value
            server.requestTask?.cancel()
            server.requestTask = nil
            await server.coordinator?.stop()
            _ = await server.manager.stopServer()
        }
        let report = await supervisor.shutdown()
        observer?.cancel()
        observer = nil
        // End frames may still be queued when observation stops. Reconcile
        // genuinely finished runs on both successful and failed Quit; a live
        // run from a failed shutdown keeps its resources for the retry.
        await reconcileEnded()
        if report.succeeded {
            for server in servers {
                unlink(server.socket)
                server.finished = true
            }
            codexServers.removeAll()
        }
        return report
    }

    // MARK: Launch helpers

    private func workingDirectory(projectID: UUID?) async throws -> String {
        guard let projectID else {
            try requireDirectory(configuration.homeDirectory)
            return configuration.homeDirectory
        }
        guard let project = try await catalog.projects().first(where: { $0.id == projectID }) else {
            throw SessionRuntimeError.projectNotFound(projectID)
        }
        try requireDirectory(project.path)
        return project.path
    }

    private func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionRuntimeError.missingDirectory(path)
        }
    }

    /// Resolved once per provider after it succeeds; a failure is retried on
    /// the next attempt.
    private func toolchain(for provider: ManagedSession.Provider) async throws -> ProviderToolchain {
        if let cached = toolchains[provider] { return cached }
        let value = try await configuration.toolchains(provider)
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        toolchains[provider] = value
        for warning in value.warnings where !toolchainWarnings.contains(warning) {
            toolchainWarnings.append(warning)
        }
        return value
    }

    private func ensureHooks() throws -> ClaudeHookLaunchConfiguration {
        if let hookConfiguration { return hookConfiguration }
        guard access(configuration.hookHelperPath, X_OK) == 0 else {
            throw ClaudeHookTransportError.invalidConfiguration(
                "hook helper is missing or not executable: \(configuration.hookHelperPath)"
            )
        }
        let socket = configuration.socketDirectory
            .appendingPathComponent("h-\(supervisor.ownershipRunID.uuidString.prefix(8)).sock").path
        let token = UUID().uuidString + UUID().uuidString
        // One ordered path from the socket to the reducers: hook events of a
        // run are applied in arrival order, never in racing tasks.
        let ingress = ClaudeHookIngress(adapter: claudeAdapter)
        let events = ingress.stream
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: token) { envelope in
            ingress.receive(envelope)
        }
        hookTask = Task { [weak self] in
            for await envelope in events { await self?.deliver(hook: envelope) }
        }
        hookServer = server
        let value = ClaudeHookLaunchConfiguration(
            helperPath: configuration.hookHelperPath, socketPath: socket,
            authenticationToken: token
        )
        hookConfiguration = value
        return value
    }

    private func deliver(hook envelope: ClaudeHookEnvelope) async {
        do {
            _ = try await claudeAdapter.receive(envelope)
        } catch {
            guard let sessionID = await supervisor.activeSessionID(runID: envelope.managedRunID) else { return }
            await supervisor.events.publish(
                sessionID: sessionID,
                change: .issue("A Claude event could not be processed: \(error)")
            )
        }
    }

    private func claudeProfile(
        route: ProviderLaunchProfile.ClaudeRoute, toolchain: ProviderToolchain,
        sessionID: UUID, hooks: ClaudeHookLaunchConfiguration
    ) throws -> ProviderLaunchProfile {
        let environment = LaunchEnvironment.make(
            base: toolchain.environment, runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        let profile = try ProviderLaunchProfile.claude(
            route: route, capabilities: toolchain.capabilities,
            config: toolchain.profileDirectory ?? URL(fileURLWithPath: "/"),
            environment: environment, hooks: hooks
        )
        guard toolchain.profileDirectory == nil else { return profile }
        // The provider's own default profile: do not pin a config directory.
        var defaulted = profile.environment
        defaulted["CLAUDE_CONFIG_DIR"] = toolchain.environment["CLAUDE_CONFIG_DIR"]
        return ProviderLaunchProfile(arguments: profile.arguments, environment: defaulted)
    }

    private func launchClaude(
        sessionID: UUID, runID: UUID?, toolchain: ProviderToolchain,
        profile: ProviderLaunchProfile, rows: UInt16, columns: UInt16,
        outputSink: (any TerminalOutputSink)?, tee: DiagnosticOutputTee?
    ) async throws -> RuntimeLaunch {
        // The run id is chosen here so a run that ends before `launch` returns
        // (an instant provider failure) is still known and diagnosed.
        let runID = runID ?? UUID()
        let launch: ManagedSessionLaunch
        do {
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            launch = try await supervisor.launch(
                sessionID: sessionID, executable: toolchain.executable,
                arguments: profile.arguments + toolchain.extraArguments,
                environment: profile.environment, rows: rows, columns: columns,
                outputSink: tee ?? outputSink, managedRunID: runID
            )
        } catch {
            await supervisor.events.publish(
                sessionID: sessionID, change: .issue("Claude could not be started: \(error)")
            )
            throw error
        }
        if tee != nil { await reactivateAfterResume(sessionID) }
        if let leader = launch.session.currentRun?.leader {
            let config = profile.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
            await claudeAdapter.observeRegistry(runID: runID, reader: ClaudeRegistryReader(
                config: config.resolvingSymlinksInPath(), leader: leader,
                directory: URL(fileURLWithPath: launch.session.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path))
        }
        return await register(launch, runID: runID, provider: .claude, server: nil, tee: tee)
    }

    private func codexHome(_ toolchain: ProviderToolchain) -> URL {
        toolchain.profileDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func codexNewProfile(
        toolchain: ProviderToolchain, sessionID: UUID, directory: String, server: CodexServer
    ) throws -> ProviderLaunchProfile {
        try ProviderLaunchProfile.codex(
            route: .remote(socket: server.socket, threadID: nil, workingDirectory: directory),
            capabilities: toolchain.capabilities, home: codexHome(toolchain),
            environment: LaunchEnvironment.make(
                base: toolchain.environment, runID: supervisor.ownershipRunID,
                sessionID: sessionID
            )
        )
    }

    private func launchNewCodex(
        sessionID: UUID, runID: UUID, directory: String, toolchain: ProviderToolchain,
        profile: ProviderLaunchProfile, server: CodexServer, coordinator: CodexSessionCoordinator,
        rows: UInt16, columns: UInt16, outputSink: (any TerminalOutputSink)?,
        onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)?
    ) async throws -> RuntimeLaunch {
        let reservation = await coordinator.reserveNewLaunch(
            sessionID: sessionID, managedRunID: runID, workingDirectory: directory
        )
        reservations[sessionID] = (reservation, coordinator)
        defer {
            reservations[sessionID] = nil
            stopRequestedRuns.remove(runID)
            startupConnectionFailures[sessionID] = nil
        }
        let launch: ManagedSessionLaunch
        do {
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            launch = try await supervisor.launch(
                sessionID: sessionID, executable: toolchain.executable,
                arguments: profile.arguments + toolchain.extraArguments,
                environment: profile.environment, rows: rows,
                columns: columns, outputSink: outputSink, managedRunID: runID,
                scope: server.scope
            )
        } catch {
            await coordinator.cancelNewLaunch(reservation)
            _ = await tearDown(server, card: sessionID)
            await supervisor.events.publish(
                sessionID: sessionID, change: .issue("Codex could not be started: \(error)")
            )
            throw error
        }
        let registered = await register(launch, runID: runID, provider: .codex, server: server, tee: nil)
        await onTerminalReady?(registered)
        do {
            _ = try await coordinator.waitForNewLaunch(
                reservation, timeout: onTerminalReady == nil ? configuration.codexIdentityTimeout : nil
            )
        } catch {
            if shuttingDown || stopRequestedRuns.contains(runID) {
                throw CancellationError()
            }
            if let failure = startupConnectionFailures[sessionID] {
                await undoLaunch(registered, reason: failure)
                throw LoomError.message(failure)
            }
            let exited = await supervisor.runContext(runID: registered.runID) == nil
            await undoLaunch(registered, reason: shuttingDown
                ? "Loom was quitting"
                : exited ? "Codex exited before it reported a conversation identity"
                : "Codex did not report its conversation identity in time")
            if exited { throw LoomError.message("Codex exited before it reported a conversation identity") }
            throw SessionRuntimeError.providerIdentityTimeout(.codex)
        }
        return registered
    }

    private func resumeCodex(
        session: ManagedSession, conversationID: String, toolchain: ProviderToolchain,
        server: CodexServer, coordinator: CodexSessionCoordinator,
        rows: UInt16, columns: UInt16, tee: DiagnosticOutputTee
    ) async throws -> RuntimeLaunch {
        let socket = server.socket
        let runID = UUID()
        let launch: ManagedSessionLaunch
        do {
            let environment = LaunchEnvironment.make(
                base: toolchain.environment, runID: supervisor.ownershipRunID, sessionID: session.id
            )
            let profile = try ProviderResumePlanner.codex(
                session: session, socketPath: socket, capabilities: toolchain.capabilities,
                home: codexHome(toolchain), environment: environment
            )
            launch = try await supervisor.launch(
                sessionID: session.id, executable: toolchain.executable,
                arguments: profile.arguments + toolchain.extraArguments,
                environment: profile.environment, rows: rows,
                columns: columns, outputSink: tee, managedRunID: runID,
                scope: server.scope
            )
        } catch {
            _ = await tearDown(server, card: session.id)
            await supervisor.events.publish(
                sessionID: session.id, change: .issue("Codex could not be resumed: \(error)")
            )
            throw error
        }
        await reactivateAfterResume(session.id)
        let registered = await register(launch, runID: runID, provider: .codex, server: server, tee: tee)
        do {
            try await coordinator.bindResume(
                sessionID: session.id, managedRunID: registered.runID,
                threadID: conversationID, workingDirectory: session.workingDirectory
            )
        } catch {
            // A TUI that already exited (deleted history) has no run to bind;
            // its own output explains why and is reported from the end handler.
            if await supervisor.runContext(runID: registered.runID) == nil {
                await reconcileEnded()
                return registered
            }
            await undoLaunch(registered, reason: "Codex resume could not be bound: \(error)")
            throw error
        }
        return registered
    }

    private func register(
        _ launch: ManagedSessionLaunch, runID: UUID, provider: ManagedSession.Provider,
        server: CodexServer?, tee: DiagnosticOutputTee?
    ) async -> RuntimeLaunch {
        server?.runID = runID
        runs[runID] = RunRecord(
            runID: runID, launchSessionID: launch.session.id, provider: provider,
            server: server, startedAt: Date(),
            isResume: tee != nil, diagnostics: tee, terminal: launch.terminal,
            activeSession: launch.session.id
        )
        let result = RuntimeLaunch(
            sessionID: launch.session.id, runID: runID, provider: provider,
            terminal: launch.terminal
        )
        // The run may already be over (instant exit): release and diagnose now.
        await reconcileEnded()
        return result
    }

    /// Resume reactivates a stale conversation on the user's explicit action.
    private func reactivateAfterResume(_ sessionID: UUID) async {
        try? await lifecycle.reactivate(sessionID: sessionID)
    }

    /// Stops a run that started but could not finish starting, releases what
    /// it held, and reports a failed cleanup instead of hiding it.
    private func undoLaunch(_ launch: RuntimeLaunch, reason: String) async {
        stopRequestedRuns.insert(launch.runID)
        let report = try? await supervisor.stop(sessionID: launch.sessionID)
        if let coordinator = runs[launch.runID]?.server?.coordinator {
            await coordinator.unbind(runID: launch.runID)
        }
        if report?.succeeded != false {
            await supervisor.events.publish(sessionID: launch.sessionID, change: .issue(reason))
        }
        await reconcileEnded()
    }

    // MARK: Codex plumbing

    /// Starts a new app-server (in its own run scope when scopes are on) and
    /// the coordinator that watches it, for one run of the conversation on
    /// `card`. Nothing is shared with any other run; a server a live run still
    /// references is never touched. On any failure what started is stopped again.
    private func ensureCodex(
        card: UUID, toolchain: ProviderToolchain
    ) async throws -> (CodexServer, CodexSessionCoordinator) {
        try Task.checkCancellation()
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        // A server this card left behind by an earlier run (a Stop that could
        // not be verified, or a teardown still finishing) must be gone first.
        let referenced = Set(runs.values.compactMap { $0.server?.id })
        for previous in codexServers where previous.ownerCard == card && !referenced.contains(previous.id) {
            let errors = await tearDown(previous)
            guard errors.isEmpty else {
                throw LoomError.message(
                    "The previous Codex app-server of this conversation could not be stopped: \(errors.joined(separator: "; "))"
                )
            }
        }
        let server = try await makeCodexServer(card: card, toolchain: toolchain)
        codexServers.append(server)
        do {
            let client = try await server.manager.start()
            try Task.checkCancellation()
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            let id = UUID()
            let task = Task { try await self.installCodexCoordinator(server: server, client: client, setupID: id) }
            // Published before the first suspension so Quit can find and cancel it.
            server.setup = (id, task)
            let coordinator = try await task.value
            if server.setup?.id == id { server.setup = nil }
            try Task.checkCancellation()
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            guard server.client === client, server.coordinator === coordinator else { throw CancellationError() }
            return (server, coordinator)
        } catch {
            server.setup = nil
            throw await startFailure(error, cleaning: server)
        }
    }

    /// A start that failed after its server existed: stop the server again.
    /// A cleanup that cannot be verified is part of the error the caller gets,
    /// because the card it would belong on does not exist (yet).
    private func startFailure(_ error: any Error, cleaning server: CodexServer) async -> any Error {
        let cleanup = await tearDown(server)
        guard !cleanup.isEmpty else { return error }
        return LoomError.message(
            "\(error); the Codex app-server could not be fully stopped: \(cleanup.joined(separator: "; "))"
        )
    }

    private func makeCodexServer(card: UUID, toolchain: ProviderToolchain) async throws -> CodexServer {
        try FileManager.default.createDirectory(
            at: configuration.socketDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Unique per server and short: Unix socket paths are limited to ~100 bytes.
        let socket = configuration.socketDirectory
            .appendingPathComponent("c-\(UUID().uuidString.prefix(8)).sock").path
        var scope: RunScope?
        if supervisor.runScopesEnabled {
            scope = try await supervisor.openScope()
            if shuttingDown {
                _ = await supervisor.releaseScope(scope!)
                throw SessionRuntimeError.shuttingDown
            }
        }
        let manager = CodexAppServerManager(
            supervisor: supervisor,
            configuration: CodexAppServerConfiguration(
                executable: toolchain.executable, capabilities: toolchain.capabilities,
                home: codexHome(toolchain),
                baseEnvironment: toolchain.environment,
                workingDirectory: configuration.homeDirectory, socketPath: socket,
                clientVersion: configuration.clientVersion,
                startupTimeout: configuration.codexServerStartupTimeout,
                scope: scope
            )
        )
        return CodexServer(ownerCard: card, manager: manager, socket: socket, scope: scope)
    }

    private func requireCodexSetup(_ server: CodexServer, _ id: UUID) throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard server.setup?.id == id else { throw CancellationError() }
    }

    private func installCodexCoordinator(
        server: CodexServer, client: CodexAppServerClient, setupID: UUID
    ) async throws -> CodexSessionCoordinator {
        let coordinator = CodexSessionCoordinator(
            client: client, supervisor: supervisor, adapter: codexAdapter,
            router: CodexSessionRouter(diagnostics: routingDiagnostics)
        )
        do {
            await codexSetupObserverForTesting?(.installing)
            try requireCodexSetup(server, setupID)
            await coordinator.setConnectionLostHandler { [weak self, weak coordinator] detail in
                guard let coordinator else { return }
                Task { await self?.codexConnectionLost(detail, from: coordinator) }
            }
            try requireCodexSetup(server, setupID)
            await coordinator.setIssueHandler { [weak self, weak coordinator] issue in
                guard let coordinator else { return }
                Task { await self?.codexIssue(issue, from: coordinator) }
            }
            try requireCodexSetup(server, setupID)
            let serverID = server.id
            await coordinator.setServerGone { [weak self] in
                await self?.serverProcessGone(serverID: serverID) ?? true
            }
            try requireCodexSetup(server, setupID)
            await coordinator.start()
            try requireCodexSetup(server, setupID)
            server.client = client
            server.coordinator = coordinator
            server.requestRevision = 0
            let requests = coordinator.requests
            server.requestTask = Task { [weak self] in
                for await snapshot in requests {
                    await self?.received(requests: snapshot, from: coordinator)
                }
            }
            return coordinator
        } catch {
            await coordinator.stop()
            throw error
        }
    }

    /// True only when the server process is verified gone: it is no longer
    /// running, its run ended, or its leader does not exist (or is a zombie).
    /// A failed process check is "not verified".
    private func serverProcessGone(serverID: UUID) async -> Bool {
        guard let server = codexServers.first(where: { $0.id == serverID }) else { return true }
        guard let id = await server.manager.internalSessionID(),
              let run = await supervisor.session(id: id)?.currentRun else { return true }
        guard let table = try? ProcessTable.snapshot() else { return false }
        return !table.contains { $0.identity == run.leader && !$0.zombie }
    }

    private func codexServer(for coordinator: CodexSessionCoordinator) -> CodexServer? {
        codexServers.first { $0.coordinator === coordinator }
    }

    /// Ends a run's server after its TUI run is over: coordinator, then the
    /// server run (the scope's last run, so the supervisor sweeps what the
    /// conversation forked and releases the scope). Returns what could not be
    /// verified; a failed teardown is retryable and is shown on `card`, the
    /// card the run was on (nothing is published when no card exists).
    @discardableResult
    private func tearDown(_ server: CodexServer, card: UUID? = nil) async -> [String] {
        if server.finished { return [] }
        if let running = server.teardownTask { return await running.value }
        let task = Task { await self.performTearDown(server) }
        server.teardownTask = task
        let errors = await task.value
        if errors.isEmpty {
            server.finished = true
            codexServers.removeAll { $0 === server }
        } else {
            server.teardownTask = nil
            if let card {
                server.ownerCard = card
                await publishServerStopFailure(errors, sessionID: card)
            }
        }
        return errors
    }

    private func performTearDown(_ server: CodexServer) async -> [String] {
        let setup = server.setup
        server.setup = nil
        setup?.task.cancel()
        _ = await setup?.task.result
        server.requestTask?.cancel()
        server.requestTask = nil
        await server.coordinator?.stop()
        server.coordinator = nil
        server.client = nil
        var errors = await server.manager.stopServer().errors
        if errors.isEmpty, let scope = server.scope {
            // Normally already released by the server run's stop; this covers a
            // server that never started. Never success unless shown empty.
            errors += await supervisor.releaseScope(scope)
        }
        if errors.isEmpty { unlink(server.socket) }
        return errors
    }

    private func publishServerStopFailure(_ errors: [String], sessionID: UUID) async {
        await supervisor.events.publish(
            sessionID: sessionID,
            change: .stopFailure("Stop could not be verified: Codex app-server: " + errors.joined(separator: "; "))
        )
    }

    private func received(requests snapshot: CodexRequestSnapshot, from coordinator: CodexSessionCoordinator) async {
        guard let server = codexServer(for: coordinator), snapshot.revision >= server.requestRevision else { return }
        var accepted: [String: CodexPendingRequest] = [:]
        for pending in snapshot.pending {
            guard let context = await supervisor.runContext(runID: pending.binding.managedRunID),
                  context.activeSessionID == pending.binding.sessionID,
                  context.session.providerConversationID == pending.binding.threadID else { continue }
            accepted[pending.id.uuidString] = pending
        }
        // Actor reentrancy can deliver a newer local-response snapshot while
        // owner validation is suspended. Never restore an older pending list.
        guard server.coordinator === coordinator, snapshot.revision >= server.requestRevision else { return }
        server.requestRevision = snapshot.revision
        let affected = Set(server.requestOwners.values).union(accepted.values.map { $0.binding.sessionID })
        server.requests = accepted
        server.requestOwners = accepted.mapValues { $0.binding.sessionID }
        server.failedRequests = server.failedRequests.filter { accepted[$0.key] != nil }
        for owner in affected { await publishRequests(for: owner, in: server) }
    }

    private func markRequestFailed(_ id: String, _ failure: String, in server: CodexServer) async {
        server.failedRequests[id] = failure
        if let owner = server.requestOwners[id] { await publishRequests(for: owner, in: server) }
    }

    private func publishRequests(for sessionID: UUID, in server: CodexServer) async {
        var list: [ProviderUserRequest] = []
        for (id, owner) in server.requestOwners where owner == sessionID {
            guard let request = server.requests[id]?.request else { continue }
            list.append(ProviderUserRequest(
                id: id, kind: Self.kind(of: request.kind),
                summary: Self.summary(of: request), failure: server.failedRequests[id]
            ))
        }
        list.sort { $0.id < $1.id }
        await supervisor.events.publish(sessionID: sessionID, change: .userRequests(list))
    }

    private static func kind(of kind: CodexApprovalKind) -> ProviderUserRequest.Kind {
        switch kind {
        case .commandExecution: .command
        case .fileChange: .fileChange
        case .permissions: .unsupported("permissions")
        case .userInput: .unsupported("input")
        case let .other(method): .unsupported(method)
        }
    }

    private static func summary(of request: CodexServerRequest) -> String {
        let object = request.params.object ?? [:]
        switch request.kind {
        case .commandExecution:
            return object["command"]?.string.map { "Run: \($0)" } ?? "Run a command"
        case .fileChange:
            return object["reason"]?.string ?? "Change files"
        case .permissions:
            return "Codex asks for extra permissions. Answer it in the terminal."
        case .userInput:
            return "Codex asks a question. Answer it in the terminal."
        case let .other(method):
            return "Codex sent a request Loom cannot answer (\(method)). Answer it in the terminal."
        }
    }

    /// A coordinator problem that cannot be tied to one card (a dropped
    /// request, a failed binding) is shown on every live card of that
    /// conversation's server: better a visible warning than an approval nobody sees.
    private func codexIssue(_ issue: String, from coordinator: CodexSessionCoordinator) async {
        guard let server = codexServer(for: coordinator) else { return }
        for record in runs.values where record.server === server {
            guard let session = await supervisor.activeSessionID(runID: record.runID) else { continue }
            guard server.coordinator === coordinator else { return }
            await supervisor.events.publish(sessionID: session, change: .issue(issue))
        }
    }

    private func codexConnectionLost(_ detail: String, from coordinator: CodexSessionCoordinator) async {
        guard let server = codexServer(for: coordinator) else { return }
        for (sessionID, (reservation, reservationCoordinator)) in reservations
        where reservationCoordinator === coordinator {
            guard server.coordinator === coordinator else { return }
            startupConnectionFailures[sessionID] = "Codex app-server connection closed before conversation identity was received"
            await reservationCoordinator.cancelNewLaunch(reservation)
        }
        let message = "\(detail). Requests and status from Codex are no longer received; the conversation may need to be restarted."
        for record in runs.values where record.server === server {
            guard let session = await supervisor.activeSessionID(runID: record.runID) else { continue }
            guard server.coordinator === coordinator else { return }
            await supervisor.events.publish(sessionID: session, change: .issue(message))
        }
        guard server.coordinator === coordinator else { return }
        for id in server.requests.keys { server.failedRequests[id] = "The connection to Codex was lost" }
        for owner in Set(server.requestOwners.values) { await publishRequests(for: owner, in: server) }
    }

    // MARK: Idle companion

    /// Everything the conversation's run scope holds besides its own TUI tree:
    /// with scopes, every forked process of the scope (the Codex server's
    /// forks included); without them, the server run's own tree. The server's
    /// leader is infrastructure, not user work.
    fileprivate func companionWork(sessionID: UUID) async throws -> SessionRunCompanion.Work? {
        guard let runID = await supervisor.session(id: sessionID)?.currentRun?.id,
              let server = runs[runID]?.server else { return nil }
        var infrastructure: Set<ProcessIdentity> = []
        var serverSession: UUID?
        if let id = await server.manager.internalSessionID(),
           let leader = await supervisor.session(id: id)?.currentRun?.leader {
            infrastructure = [leader]
            serverSession = id
        }
        if let scoped = try await supervisor.scopeWork(sessionID: sessionID) {
            return .init(infrastructure: infrastructure, live: scoped)
        }
        guard let serverSession else { return .init(infrastructure: infrastructure, live: []) }
        return .init(
            infrastructure: infrastructure, live: try await supervisor.sample(sessionID: serverSession)
        )
    }

    /// After an idle stop of the TUI: the run's server must be gone too.
    fileprivate func companionTeardown(runID: UUID) async -> [String] {
        guard let server = codexServers.first(where: { $0.runID == runID }) else { return [] }
        let card = runs[runID]?.activeSession ?? server.ownerCard
        return await tearDown(server, card: card)
    }

    // MARK: Observing runs

    private func reconcile(_ frame: SessionEventFrame) async {
        await reconcileEnded()
        for record in Array(runs.values) {
            guard let sessionID = await supervisor.activeSessionID(runID: record.runID) else { continue }
            guard let work = frame.sessions[sessionID]?.status,
                  work.activity == .turnComplete, work.pendingProviderWorkCount == 0,
                  !record.baselineSessions.contains(sessionID) else { continue }
            // Quiet state permits evaluation, not classifying live children as
            // startup helpers. The lifecycle baseline includes only the leader.
            do {
                try await lifecycle.captureProcessBaseline(sessionID: sessionID)
                runs[record.runID]?.baselineSessions.insert(sessionID)
            } catch {
                // Keep baselineNotCaptured visible and allow a later frame to retry.
            }
        }
    }

    /// Frames coalesce, so end-of-run handling asks the supervisor instead of
    /// trusting a single event.
    private func reconcileEnded() async {
        for snapshot in Array(runs.values) {
            if let active = await supervisor.activeSessionID(runID: snapshot.runID) {
                runs[snapshot.runID]?.activeSession = active
            }
            guard await supervisor.runContext(runID: snapshot.runID) == nil else { continue }
            // Reentrant callers (the observer, Stop, a launch) race on the same
            // ended run: only the one that removes the record handles it.
            guard let record = runs.removeValue(forKey: snapshot.runID) else { continue }
            if record.provider == .claude { await claudeAdapter.stopRegistry(runID: record.runID) }
            // A start still waiting for this run's identity can stop waiting now.
            if record.server != nil, let (reservation, coordinator) = reservations[record.launchSessionID],
               reservation.managedRunID == record.runID {
                await coordinator.cancelNewLaunch(reservation)
            }
            if let server = record.server {
                await server.coordinator?.unbind(runID: record.runID)
                await dropRequests(ofRun: record.runID, in: server)
                await tearDown(server, card: record.activeSession)
            }
            await diagnoseQuickResumeExit(record)
        }
    }

    private func dropRequests(ofRun runID: UUID, in server: CodexServer) async {
        var affected: Set<UUID> = []
        for (id, owner) in server.requestOwners {
            let ownerRun = await supervisor.session(id: owner)?.currentRun?.id
            if ownerRun == nil || ownerRun == runID {
                server.requests[id] = nil
                server.requestOwners[id] = nil
                server.failedRequests[id] = nil
                affected.insert(owner)
            }
        }
        for owner in affected { await publishRequests(for: owner, in: server) }
    }

    /// A resumed run that dies at once usually says why in its first output.
    /// Recognised provider-history errors become the typed error; any other
    /// abnormal early exit is reported as unknown, never as a new conversation.
    private func diagnoseQuickResumeExit(_ record: RunRecord) async {
        defer {
            if reservations[record.launchSessionID] == nil { stopRequestedRuns.remove(record.runID) }
        }
        guard record.isResume, let diagnostics = record.diagnostics,
              !stopRequestedRuns.contains(record.runID), !shuttingDown,
              Date().timeIntervalSince(record.startedAt) <= configuration.resumeDiagnosticsWindow,
              let status = await record.terminal.exitStatus(), status != 0,
              let conversationID = await catalogConversationID(record.launchSessionID),
              let error = ProviderResumeDiagnostics.error(
                provider: record.provider, conversationID: conversationID,
                output: diagnostics.text, exitStatus: status
              ) else { return }
        await supervisor.events.publish(
            sessionID: record.launchSessionID, change: .issue(String(describing: error))
        )
    }

    private func catalogConversationID(_ sessionID: UUID) async -> String? {
        await supervisor.session(id: sessionID)?.providerConversationID
    }
}

/// Keeps the first few KiB of a run's output next to the terminal sink so a
/// resume that fails at once can be classified from the provider's own words.
final class DiagnosticOutputTee: TerminalOutputSink, @unchecked Sendable {
    static let limit = 16 * 1024
    private let downstream: (any TerminalOutputSink)?
    private let lock = NSLock()
    private var head = Data()

    init(downstream: (any TerminalOutputSink)?) { self.downstream = downstream }

    func receive(_ data: Data) {
        lock.lock()
        if head.count < Self.limit { head.append(data.prefix(Self.limit - head.count)) }
        lock.unlock()
        downstream?.receive(data)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: head, as: UTF8.self)
    }
}

extension SessionStopReport {
    /// The same stop with further failures that belong to the conversation's
    /// stop (its own app-server), so the report is never better than the whole.
    func adding(errors extra: [String]) -> SessionStopReport {
        SessionStopReport(
            remainingCountVerified: remainingCountVerified, providerStages: providerStages,
            sessionID: sessionID, runID: runID, elapsedSeconds: elapsedSeconds,
            signals: signals, remaining: remaining, errors: errors + extra,
            outsideOwnership: outsideOwnership
        )
    }
}
