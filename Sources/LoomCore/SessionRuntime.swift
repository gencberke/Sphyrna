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
    /// Where a deletion also looks for Claude's temporary task output (tier 2); nil skips it.
    public var claudeTemporaryRoot: URL?
    /// Hooks the deletion of a conversation calls so other components drop what they keep
    /// for it (usage index, tabs). Shared by default so the app can register before the
    /// runtime exists; tests pass their own.
    public var forgetters: ConversationForgetters
    /// The Claude profile folder an acceptance run was given (`--claude-config`, or the isolated
    /// profile of a fake-provider run); nil in a normal run. Deletion finds the config folder
    /// without running the Claude CLI: this folder, else the resolved toolchain's profile when one
    /// exists already, else `claudeEnvironment`, else `~/.claude` (`ClaudeProfileLayout`).
    public var claudeProfileDirectory: URL?
    /// `CLAUDE_CONFIG_DIR` is read from here when no toolchain has been resolved yet: Loom's own
    /// environment, the same rule the usage index follows.
    public var claudeEnvironment: [String: String]

    public init(
        toolchains: @escaping ProviderToolchainResolver, hookHelperPath: String,
        socketDirectory: URL,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        clientVersion: String = "loom", idlePolicy: SessionIdlePolicy = SessionIdlePolicy(),
        codexIdentityTimeout: TimeInterval = 10, codexServerStartupTimeout: TimeInterval = 8,
        resumeDiagnosticsWindow: TimeInterval = 15,
        claudeTemporaryRoot: URL? = ClaudeDataInventory.defaultTemporaryRoot,
        forgetters: ConversationForgetters = .shared,
        claudeProfileDirectory: URL? = nil,
        claudeEnvironment: [String: String] = ProcessInfo.processInfo.environment
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
        self.claudeTemporaryRoot = claudeTemporaryRoot
        self.forgetters = forgetters
        self.claudeProfileDirectory = claudeProfileDirectory
        self.claudeEnvironment = claudeEnvironment
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
    /// Deletion is refused for this conversation; the text says why (shown to the user).
    case deletionRefused(String)
    /// The conversation is being deleted: no start, resume, view or input until it finishes.
    case deletionPending(UUID)
    case deletionNotPending(UUID)
    /// A deletion of this conversation is running right now.
    case deletionInProgress(UUID)

    public var description: String {
        switch self {
        case .shuttingDown:
            "Loom is quitting; no new work is accepted"
        case .catalogUnavailable:
            "The session catalog is not available"
        case let .projectNotFound(id):
            "Project not found: \(id)"
        case let .missingDirectory(path):
            "The working directory no longer exists: \(path)"
        case let .sessionNotFound(id):
            "Session not found: \(id)"
        case let .alreadyStarting(id):
            "The session is already starting: \(id)"
        case let .alreadyRunning(id):
            "The session is already running: \(id)"
        case let .notRunning(id):
            "The session is not running: \(id)"
        case let .noProviderIdentity(provider):
            "This \(provider.rawValue) session has no provider identity yet, so it cannot be resumed. Loom will not start a new session in its place."
        case let .providerIdentityTimeout(provider):
            "\(provider.rawValue) did not report its session identity in time; the start was undone"
        case let .unsupportedProvider(provider):
            "\(provider.rawValue) sessions cannot be started from the app"
        case let .unverifiedStop(id):
            "The last stop of this session could not be verified: \(id)"
        case let .requestNotPending(id):
            "The provider request is no longer pending: \(id)"
        case let .deletionRefused(reason):
            "This session cannot be deleted: \(reason)"
        case let .deletionPending(id):
            "The session is being deleted: \(id)"
        case let .deletionNotPending(id):
            "No deletion is waiting for this session: \(id)"
        case let .deletionInProgress(id):
            "The session is already being deleted: \(id)"
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

/// A new Claude session an agent asked for and the user approved (D-40): the title is the session's
/// name and its automatic card title, the message is Claude's first prompt.
public struct SessionOpening: Equatable, Sendable {
    public let title: String
    public let firstMessage: String
    public let ticketKey: String?
    /// The session whose agent asked.
    public let openedBy: UUID

    public init(title: String, firstMessage: String, ticketKey: String?, openedBy: UUID) {
        self.title = title
        self.firstMessage = firstMessage
        self.ticketKey = ticketKey
        self.openedBy = openedBy
    }
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
    struct RunRecord {
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
    let configuration: SessionRuntimeConfiguration
    let claudeAdapter: ClaudeSessionAdapter
    let codexAdapter: CodexSessionAdapter
    /// Requests of agents to open a session (D-40); the UI answers them (`SessionRuntime+OpenRequests`).
    let openRequests: OpenSessionCoordinator

    private var toolchains: [ManagedSession.Provider: ProviderToolchain] = [:]
    private var toolchainWarnings: [String] = []
    var runs: [UUID: RunRecord] = [:]
    private var startingNew: Set<StartKey> = []
    var startingSessions: Set<UUID> = []
    /// Runs Loom itself is stopping (user stop, undone launch): their exit is
    /// not a provider failure.
    var stopRequestedRuns: Set<UUID> = []
    var reservations: [UUID: (CodexLaunchReservation, CodexSessionCoordinator)] = [:]
    var startupConnectionFailures: [UUID: String] = [:]
    var shuttingDown = false
    private var started = false
    private var observer: Task<Void, Never>?
    /// Conversations whose deletion is executing in this process (one runner each).
    var deletionsInFlight: Set<UUID> = []
    var deletionRecovery: Task<Void, Never>?
    /// Set when a deletion record could not be read at launch; recovery stopped loudly.
    var deletionRecoveryIssue: String?
    /// Test seam: called before and after each deletion step; a throw is that step's failure.
    var deletionFailpoint: (@Sendable (CatalogDeletionState, DeletionFailpointPhase) throws -> Void)?
    func setDeletionFailpointForTesting(
        _ failpoint: (@Sendable (CatalogDeletionState, DeletionFailpointPhase) throws -> Void)?
    ) { deletionFailpoint = failpoint }

    var hookServer: ClaudeHookServer?
    var controlServer: OpenSessionControlServer?
    var hookConfiguration: ClaudeHookLaunchConfiguration?
    var hookTask: Task<Void, Never>?

    var codexServers: [CodexServer] = []
    let routingDiagnostics = CodexRoutingDiagnostics()
    enum CodexSetupPhase: Sendable { case installing }
    var codexSetupObserverForTesting: (@Sendable (CodexSetupPhase) async -> Void)?
    func observeCodexSetupForTesting(_ observer: @escaping @Sendable (CodexSetupPhase) async -> Void) {
        codexSetupObserverForTesting = observer
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
        openRequests = OpenSessionCoordinator(
            catalog: catalog,
            authorize: { sessionID, runID in
                // The hook rule: only the live run this Loom started, for the card it was launched on.
                // The request belongs to the card the run is on now (`/clear` moves a run).
                guard let context = await supervisor.runContext(runID: runID),
                      context.launchSessionID == sessionID,
                      let run = context.session.currentRun, run.id == runID, run.state == .running
                else { return nil }
                return context.activeSessionID
            },
            isRunning: { await supervisor.session(id: $0)?.currentRun != nil }
        )
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
        // Interrupted deletions finish now: no run of this process exists yet, so a deletion
        // that was stopping resolves. Failures stay on the records for a manual retry.
        deletionRecovery = Task { [weak self] in await self?.recoverDeletions() }
    }

    public func environmentWarnings() -> [String] { toolchainWarnings }

    public func liveRunCount() -> Int { runs.count }

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
        opening: SessionOpening? = nil,
        onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)? = nil
    ) async throws -> RuntimeLaunch {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard provider == .claude || provider == .codex else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        guard opening == nil || provider == .claude else {
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
                route: .new(sessionID), toolchain: toolchain, sessionID: sessionID, hooks: hooks,
                opening: opening.map {
                    ProviderLaunchProfile.ClaudeOpening(title: $0.title, firstMessage: $0.firstMessage)
                }
            )
            try await supervisor.createSession(
                ManagedSession(id: sessionID, provider: .claude, workingDirectory: directory),
                projectID: projectID, title: opening?.title, ticketKey: opening?.ticketKey,
                openedBy: opening?.openedBy
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
        guard !(try await catalog.isDeletionPending(sessionID)) else {
            throw SessionRuntimeError.deletionPending(sessionID)
        }
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
        let previousCard = runs[run.id]?.activeSession
        stopRequestedRuns.insert(run.id)
        runs[run.id]?.activeSession = sessionID
        let server = runs[run.id]?.server
        var report: SessionStopReport
        do { report = try await supervisor.stop(sessionID: sessionID) }
        catch SessionManagementError.sessionNotRunning {
            // The run exited, or `/clear` moved it to another card, between the read above and the
            // stop: nothing of this card was stopped, and a run that still lives is not Loom's stop.
            if await supervisor.runContext(runID: run.id) != nil {
                stopRequestedRuns.remove(run.id)
                if let previousCard { runs[run.id]?.activeSession = previousCard }
            }
            throw SessionRuntimeError.notRunning(sessionID)
        }
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

    /// The user's own Stop is real use of the session; idle stops and Quit are not.
    public func markUserStopped(sessionID: UUID) async throws {
        try await lifecycle.markActivity(sessionID: sessionID)
    }

    /// Explicit user reactivation of a stale conversation (resume does it too).
    public func reactivate(sessionID: UUID) async throws {
        try await lifecycle.reactivate(sessionID: sessionID)
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
        // Waiting clients hear that Loom is going; pending requests are lost (memory only).
        await openRequests.shutdown()
        controlServer?.stop()
        controlServer = nil
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

    /// Where Claude keeps this profile's files, found without running the CLI (a deletion must
    /// work with Claude removed from PATH): the explicit profile folder, else the resolved
    /// toolchain's when one exists already, else `CLAUDE_CONFIG_DIR` from its captured environment
    /// or from Loom's own, else `~/.claude`; the same rule as the usage index.
    func claudeConfigDirectory() -> URL {
        let resolved = toolchains[.claude]
        return ClaudeProfileLayout(
            profileDirectory: configuration.claudeProfileDirectory ?? resolved?.profileDirectory,
            environment: resolved?.environment ?? configuration.claudeEnvironment,
            home: URL(fileURLWithPath: configuration.homeDirectory, isDirectory: true)
        ).configDirectory
    }

    /// Resolved once per provider after it succeeds; a failure is retried on
    /// the next attempt.
    func toolchain(for provider: ManagedSession.Provider) async throws -> ProviderToolchain {
        if let cached = toolchains[provider] { return cached }
        let value = try await configuration.toolchains(provider)
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        toolchains[provider] = value
        for warning in value.warnings where !toolchainWarnings.contains(warning) {
            toolchainWarnings.append(warning)
        }
        return value
    }

    func register(
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
    func reactivateAfterResume(_ sessionID: UUID) async {
        try? await lifecycle.reactivate(sessionID: sessionID)
    }

    /// Stops a run that started but could not finish starting, releases what
    /// it held, and reports a failed cleanup instead of hiding it.
    func undoLaunch(_ launch: RuntimeLaunch, reason: String) async {
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
    func reconcileEnded() async {
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
