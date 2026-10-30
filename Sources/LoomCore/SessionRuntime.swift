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
    /// How long a join of an opened Codex thread (`thread/resume`) waits for the server (`CodexSessionCoordinator`).
    public var codexJoinTimeout: TimeInterval
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
    /// The user's login-shell environment (the launch-environment capture), asked once in the
    /// background when the runtime starts, so a deletion finds `CLAUDE_CONFIG_DIR` even when only the
    /// shell sets it and no session was started yet (DP-CP4-8). Nil asks nothing.
    public var claudeLoginEnvironment: (@Sendable () async throws -> [String: String])?
    /// Where Loom writes the plugin it gives its Claude sessions (`ClaudeLoomPlugin`); nil gives none.
    public var claudePluginDirectory: URL?
    /// How long Claude may report a running turn with no hook event reaching Loom before the
    /// session shows that Loom is not receiving events (`ClaudeSessionAdapter`).
    public var hookSilenceGrace: TimeInterval
    /// Seconds after start before the daily catalog backup is considered; nil takes none.
    public var catalogBackupDelay: TimeInterval?
    /// Called after a provider launch failed, so whatever resolves toolchains can forget its cache
    /// (the runtime re-resolves on its own in any case). `SystemProviderToolchains.invalidate`.
    public var toolchainInvalidator: (@Sendable (ManagedSession.Provider) async -> Void)?
    /// Called once `start()` has closed the runs an earlier Loom left open (also when none were), so whatever
    /// listed sessions by their runs before that (Home's Continue) can read again. The catalog already holds
    /// the closed runs when it is called.
    public var runsRecovered: (@Sendable () async -> Void)?
    /// The mode an opened session takes when its agent passed no `--mode` (Q3, D-103): Sphyrna's default, read on the main
    /// actor for the request's project. Nil takes Ask before edits.
    public var defaultOpenedMode: (@Sendable (UUID?) async -> String?)?
    /// Cached values only: no probe or model request is made while an agent asks to open a session.
    public var openedModels: (@Sendable (HarnessID) async -> [ModelCatalogEntry])?
    public var openedDefaultMode: (@Sendable (UUID?, HarnessID) async -> HarnessMode?)?
    /// How long a failed capability probe waits before its one retry (`SessionRuntime.toolchain(for:)`).
    public var toolchainProbeRetryPause: Duration
    /// Verified native limit errors only; no probe or model request is made here.
    public var onClaudeLimitReset: ClaudeLimitResetCallbacks?
    /// Optional task-only Claude stream controller, supplied from LoomChat.
    public var managedClaudeControllerFactory: ManagedTaskControllerFactory?
    /// Whether a harness in a mode can reach the session channel (`SessionChannelSandbox`). Only a test of a fake
    /// harness that has no sandbox replaces it.
    var sessionChannelBlock: @Sendable (HarnessID, HarnessMode?) -> String? = SessionChannelSandbox.blockedReason

    public init(
        toolchains: @escaping ProviderToolchainResolver, hookHelperPath: String,
        socketDirectory: URL,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        clientVersion: String = "sphyrna", idlePolicy: SessionIdlePolicy = SessionIdlePolicy(),
        codexIdentityTimeout: TimeInterval = 10, codexServerStartupTimeout: TimeInterval = 8,
        codexJoinTimeout: TimeInterval = CodexSessionCoordinator.defaultJoinTimeout,
        resumeDiagnosticsWindow: TimeInterval = 15,
        claudeTemporaryRoot: URL? = ClaudeDataInventory.defaultTemporaryRoot,
        forgetters: ConversationForgetters = .shared,
        claudeProfileDirectory: URL? = nil,
        claudeEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        claudeLoginEnvironment: (@Sendable () async throws -> [String: String])? = nil,
        claudePluginDirectory: URL? = nil,
        hookSilenceGrace: TimeInterval = 3,
        catalogBackupDelay: TimeInterval? = 10,
        toolchainInvalidator: (@Sendable (ManagedSession.Provider) async -> Void)? = nil,
        runsRecovered: (@Sendable () async -> Void)? = nil,
        defaultOpenedMode: (@Sendable (UUID?) async -> String?)? = nil,
        openedModels: (@Sendable (HarnessID) async -> [ModelCatalogEntry])? = nil,
        openedDefaultMode: (@Sendable (UUID?, HarnessID) async -> HarnessMode?)? = nil,
        toolchainProbeRetryPause: Duration = .seconds(1),
        onClaudeLimitReset: ClaudeLimitResetCallbacks? = nil,
        managedClaudeControllerFactory: ManagedTaskControllerFactory? = nil
    ) {
        self.toolchains = toolchains
        self.hookHelperPath = hookHelperPath
        self.socketDirectory = socketDirectory
        self.homeDirectory = homeDirectory
        self.clientVersion = clientVersion
        self.idlePolicy = idlePolicy
        self.codexIdentityTimeout = codexIdentityTimeout
        self.codexServerStartupTimeout = codexServerStartupTimeout
        self.codexJoinTimeout = codexJoinTimeout
        self.resumeDiagnosticsWindow = resumeDiagnosticsWindow
        self.claudeTemporaryRoot = claudeTemporaryRoot
        self.forgetters = forgetters
        self.claudeProfileDirectory = claudeProfileDirectory
        self.claudeEnvironment = claudeEnvironment
        self.claudeLoginEnvironment = claudeLoginEnvironment
        self.claudePluginDirectory = claudePluginDirectory
        self.hookSilenceGrace = hookSilenceGrace
        self.catalogBackupDelay = catalogBackupDelay
        self.toolchainInvalidator = toolchainInvalidator
        self.runsRecovered = runsRecovered
        self.defaultOpenedMode = defaultOpenedMode
        self.openedModels = openedModels
        self.openedDefaultMode = openedDefaultMode
        self.toolchainProbeRetryPause = toolchainProbeRetryPause
        self.onClaudeLimitReset = onClaudeLimitReset
        self.managedClaudeControllerFactory = managedClaudeControllerFactory
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
    case openRequestHarnessMismatch
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
            "Sphyrna is quitting; no new work is accepted"
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
            "This \(provider.rawValue) session has no provider identity yet, so it cannot be resumed. Sphyrna will not start a new session in its place."
        case let .providerIdentityTimeout(provider):
            "\(provider.rawValue) did not report its session identity in time; the start was undone"
        case let .unsupportedProvider(provider):
            "\(provider.rawValue) sessions cannot be started from the app"
        case let .unverifiedStop(id):
            "The last stop of this session could not be verified: \(id)"
        case let .requestNotPending(id):
            "The provider request is no longer pending: \(id)"
        case .openRequestHarnessMismatch:
            "The open request belongs to a different harness"
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
    /// The session whose agent asked.
    public let openedBy: UUID
    /// What the agent asked for with `open --model`, `--effort` and `--mode` (Q3, D-103); all nil leaves Loom's defaults.
    public let choices: HarnessLaunchChoices
    public let modeFromUserDefault: Bool
    /// Created only from a previously approved in-process task relationship.
    let approvedTask: (taskID: UUID, childID: UUID)?

    public init(title: String, firstMessage: String, openedBy: UUID,
                choices: HarnessLaunchChoices = HarnessLaunchChoices(), modeFromUserDefault: Bool = false) {
        self.title = title
        self.firstMessage = firstMessage
        self.openedBy = openedBy
        self.choices = choices
        self.modeFromUserDefault = modeFromUserDefault
        self.approvedTask = nil
    }

    init(approvedTask task: SessionTaskProjection, firstMessage: String, modeFromUserDefault: Bool = false) {
        self.title = task.childName
        self.firstMessage = firstMessage
        self.openedBy = task.parentSessionID
        self.choices = task.requestedChoices
        self.modeFromUserDefault = modeFromUserDefault
        self.approvedTask = (task.id, task.childSessionID)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.firstMessage == rhs.firstMessage && lhs.openedBy == rhs.openedBy &&
        lhs.choices == rhs.choices && lhs.modeFromUserDefault == rhs.modeFromUserDefault &&
        lhs.approvedTask?.taskID == rhs.approvedTask?.taskID && lhs.approvedTask?.childID == rhs.approvedTask?.childID
    }

    public init(title: String, firstMessage: String, openedBy: UUID, choices: ClaudeLaunchChoices) {
        self.init(title: title, firstMessage: firstMessage, openedBy: openedBy, choices: HarnessLaunchChoices(choices))
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
    struct Record: Sendable { let envelope: ClaudeHookEnvelope; let limitRevision: UInt64? }
    let stream: AsyncStream<Record>
    private let continuation: AsyncStream<Record>.Continuation
    private let adapter: ClaudeSessionAdapter
    private let taskIngress: SessionTaskIngressRegistry?
    private let limitObserver: ClaudeLimitResetObserver?

    init(adapter: ClaudeSessionAdapter, capacity: Int = 1_024,
         taskIngress: SessionTaskIngressRegistry? = nil, limitObserver: ClaudeLimitResetObserver? = nil) {
        self.adapter = adapter
        self.taskIngress = taskIngress
        self.limitObserver = limitObserver
        let pair = AsyncStream<Record>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        stream = pair.stream
        continuation = pair.continuation
    }

    func receive(_ envelope: ClaudeHookEnvelope) {
        taskIngress?.begin(runID: envelope.managedRunID)
        adapter.noteHookArrival(runID: envelope.managedRunID)
        let revision = limitObserver?.arrived(runID: envelope.managedRunID)
        switch continuation.yield(Record(envelope: envelope, limitRevision: revision)) {
        case let .dropped(dropped):
            taskIngress?.dropped(runID: dropped.envelope.managedRunID)
            limitObserver?.discard(runID: dropped.envelope.managedRunID, revision: dropped.limitRevision)
            adapter.noteHookLoss(runID: dropped.envelope.managedRunID)
        case .terminated:
            taskIngress?.dropped(runID: envelope.managedRunID)
            limitObserver?.discard(runID: envelope.managedRunID, revision: revision)
        case .enqueued:
            break
        @unknown default:
            taskIngress?.dropped(runID: envelope.managedRunID)
            limitObserver?.discard(runID: envelope.managedRunID, revision: revision)
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
        /// The run's terminal, or the pipes of a Chat-face child (`SessionRuntime+Chat`).
        let endpoint: RunEndpoint
        /// The card the run was last seen on; where a teardown failure is shown.
        var activeSession: UUID
        var baselineSessions: Set<UUID> = []
    }

    struct StartKey: Hashable {
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
    var claudeLimitObserver: ClaudeLimitResetObserver?
    /// The read model of this runtime's sessions: the catalog's listed sessions with the hub's live state (`SessionDirectory`).
    public nonisolated var directory: SessionDirectory {
        SessionDirectory(catalog: catalog, events: supervisor.events,
                         openRequests: { [openRequests] in await openRequests.snapshot() })
    }
    /// Where a component that keeps data for a conversation registers its cleanup for a deletion (`ConversationForgetters`).
    public nonisolated var conversationForgetters: ConversationForgetters { configuration.forgetters }
    /// The harnesses this runtime manages, by provider (R7): the provider-specific part of a session lives behind them.
    let harnesses: HarnessRegistry
    /// Requests of agents to open a session (D-40); the UI answers them (`SessionRuntime+OpenRequests`).
    let openRequests: OpenSessionCoordinator
    /// The durable task authority is created by the runtime; the UI only reads
    /// its bounded, message-free projections.
    var taskCoordinator: SessionTaskCoordinator?
    var taskSocket: SessionTaskSocket?
    var taskReadFence: SessionTaskReadFence?
    var taskSocketPath: String?
    var taskRunPlans: [UUID: SessionTaskRunPlan] = [:]
    var taskExpectedInputs: [UUID: SessionTaskExpectedInput] = [:]
    var taskProofWaiters: [UUID: SessionTaskProofWaiter] = [:]
    var taskInterruptWaiters: [UUID: SessionTaskInterruptWaiter] = [:]
    var peerMailbox: SessionMailbox?
    var peerReadFence: SessionTaskReadFence?
    let peerTargetFences = PeerTargetFences()
    var peerPendingRequests: [UUID: PeerPendingRequest] = [:]
    var peersNeedingDelivery: Set<UUID> = []
    var peerDeliveriesInFlight: Set<UUID> = []
    var peerDeliveriesRequested: Set<UUID> = []
    var peerApprovalsInFlight: [UUID: Int] = [:]
    var peerApprovalWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    var taskChildReservations: [UUID: SessionTaskChildReservation] = [:]
    var taskLaunchContexts: [UUID: SessionTaskLaunchContext] = [:]
    var managedTaskPresentations: [UUID: ManagedTaskPresentation] = [:]
    var managedTaskControllers: [UUID: ManagedTaskControllerState] = [:]
    var taskDeliveriesInFlight: Set<UUID> = []
    var managedCodexInterruptSignals: [UUID: ManagedCodexInterruptSignal] = [:]
    var taskDeliveriesRequested: Set<UUID> = []
    var tasksNeedingDelivery: Set<UUID> = []
    var retiredTaskRuns: [UUID: SessionTaskRetiredRun] = [:]
    var startingTaskChildren: Set<UUID> = []
    let taskIngress = SessionTaskIngressRegistry()

    private var toolchains: [ManagedSession.Provider: ProviderToolchain] = [:]
    /// The executable file each cached toolchain was read from; a changed file means a new CLI.
    private var toolchainStamps: [ManagedSession.Provider: ExecutableStamp] = [:]
    private var staleToolchains: Set<ManagedSession.Provider> = []
    /// Compatibility warnings already journaled in this run (version + missing options).
    var reportedCompatibility: Set<String> = []
    var backupTask: Task<Void, Never>?
    private var toolchainWarnings: [String] = []
    var runs: [UUID: RunRecord] = [:]
    var startingNew: Set<StartKey> = []
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
    /// The login shell's environment once the background capture finished (`claudeConfigDirectory`).
    var loginEnvironment: [String: String]?
    var loginEnvironmentCapture: Task<Void, Never>?
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
    var agyRuns: [UUID: AgyRunState] = [:]
    let routingDiagnostics = CodexRoutingDiagnostics()
    enum CodexSetupPhase: Sendable { case installing }
    var codexSetupObserverForTesting: (@Sendable (CodexSetupPhase) async -> Void)?
    func observeCodexSetupForTesting(_ observer: @escaping @Sendable (CodexSetupPhase) async -> Void) {
        codexSetupObserverForTesting = observer
    }
    var managedScopeOpenedForTesting: (@Sendable (ManagedTaskRun) async -> Void)?
    func observeManagedScopeOpenedForTesting(_ observer: @escaping @Sendable (ManagedTaskRun) async -> Void) {
        managedScopeOpenedForTesting = observer
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
        harnesses = HarnessRegistry(supervisor: supervisor, hookSilenceGrace: configuration.hookSilenceGrace)
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
            models: { id in await configuration.openedModels?(id) ?? ModelCatalog.claude },
            defaultMode: { projectID, id in
                if let resolve = configuration.openedDefaultMode { return await resolve(projectID, id) }
                if HarnessLaunchChoices(harness: id).claudeChoices != nil, let resolve = configuration.defaultOpenedMode {
                    return HarnessMode.fromStored(await resolve(projectID))
                }
                return HarnessCatalogue.descriptor(for: id)?.defaultMode
            }
        )
        relay.runtime = self
    }

    /// Starts the single lifecycle listener/timer and the run observer. Opening
    /// the app never starts a provider or a terminal.
    public func start() async throws {
        guard !started else { return }
        started = true
        recordLaunch()
        // Crash residue first, before anything of this run exists: stale sockets of an earlier
        // run, then runs the catalog still shows as open. Deletion recovery (below) comes after, so
        // a deletion that was stopping finds no phantom run.
        sweepStaleSockets()
        await closeAbandonedRuns()
        await startTaskAuthority()
        scheduleCatalogBackup()
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
        // The login shell's environment, once and off the main path: a deletion needs only its
        // `CLAUDE_CONFIG_DIR`. A failure leaves the rule as it was (Loom's own environment).
        if let source = configuration.claudeLoginEnvironment {
            loginEnvironmentCapture = Task { [weak self] in
                let captured = try? await source()
                guard !Task.isCancelled else { return }
                await self?.adoptLoginEnvironment(captured)
            }
        }
    }

    private func adoptLoginEnvironment(_ environment: [String: String]?) {
        guard !shuttingDown else { return }
        loginEnvironment = environment
    }

    /// Waits for the capture `start()` began (tests and evidence).
    public func finishLoginEnvironmentCapture() async { await loginEnvironmentCapture?.value }

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
        draft: NewSessionLaunch? = nil,
        onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)? = nil
    ) async throws -> RuntimeLaunch {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard let harness = harnesses[provider] else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        let sessionID = opening?.approvedTask?.childID ?? UUID(), runID = UUID()
        if opening?.approvedTask != nil {
            guard startingTaskChildren.insert(sessionID).inserted else { throw SessionTaskError.childAlreadyOwned }
        }
        defer { if opening?.approvedTask != nil { startingTaskChildren.remove(sessionID) } }
        if let task = opening?.approvedTask {
            guard let taskCoordinator, let projection = try await taskCoordinator.projectionForUser(taskID: task.taskID),
                  projection.lifecycle == .active, projection.childSessionID == sessionID,
                  projection.parentSessionID == opening?.openedBy, projection.requestedChoices == opening?.choices,
                  let reservation = taskChildReservations[task.taskID], reservation.childID == sessionID,
                  await authenticateTaskRun(reservation.parent) == projection.parentBinding,
                  try await catalog.session(id: sessionID) == nil,
                  await supervisor.session(id: sessionID) == nil,
                  let current = taskChildReservations[task.taskID], current.childID == sessionID,
                  await authenticateTaskRun(current.parent) == projection.parentBinding else { throw SessionTaskError.unauthorized }
            guard !shuttingDown, taskChildReservations[task.taskID]?.childID == sessionID else {
                throw SessionTaskError.unauthorized
            }
        }
        beginTaskRun(sessionID: sessionID, runID: runID)
        // A first message goes to the CLI as a launch argument, never through the terminal: its observation is still
        // the run's first clean submission, not unclassified input that blocks automatic input until the user types.
        if opening?.approvedTask == nil, let first = draft?.firstMessage ?? opening?.firstMessage, !first.isEmpty {
            inputGate.expectLaunchSubmission(runID: runID, message: first)
        }
        do {
            return try await withNewStart(provider: provider, projectID: projectID, opening: opening, draft: draft) {
                directory, toolchain in
                try await harness.startTerminal(in: self, HarnessTerminalStart(
                    sessionID: sessionID, runID: runID, projectID: projectID, directory: directory, toolchain: toolchain,
                    rows: rows, columns: columns, outputSink: outputSink, opening: opening, draft: draft,
                    onTerminalReady: onTerminalReady
                ))
            }
        } catch {
            revokeTaskRun(sessionID: sessionID, runID: runID)
            throw error
        }
    }

    /// Resumes a stopped conversation with its recorded provider identity and
    /// working directory. A missing identity, directory or provider history is
    /// an error the user sees; it never becomes a new conversation.
    ///
    /// A Claude session resumes with the mode, model and effort the catalog holds for it (S2: the CLI restores
    /// none of them); `choices` that are set replace those and are recorded.
    public func resumeConversation(
        sessionID: UUID, rows: UInt16 = 24, columns: UInt16 = 80,
        outputSink: (any TerminalOutputSink)? = nil,
        choices: ClaudeLaunchChoices = ClaudeLaunchChoices()
    ) async throws -> RuntimeLaunch {
        try await withResume(sessionID: sessionID, providers: harnesses.providers) { session, conversationID, toolchain in
            guard let harness = self.harnesses[session.provider] else {
                throw SessionRuntimeError.unsupportedProvider(session.provider)
            }
            let runID = UUID()
            self.beginTaskRun(sessionID: sessionID, runID: runID)
            do {
                let launch = try await harness.resumeTerminal(in: self, HarnessTerminalResume(
                    session: session, conversationID: conversationID, toolchain: toolchain,
                    rows: rows, columns: columns, outputSink: outputSink,
                    tee: DiagnosticOutputTee(downstream: outputSink), choices: choices
                ))
                if let task = self.taskLaunchContexts.first(where: { $0.value.childID == sessionID })?.key {
                    await self.supervisor.events.publish(sessionID: sessionID, change: .managedTaskDetached(task))
                }
                return launch
            } catch {
                self.revokeTaskRun(sessionID: sessionID, runID: runID)
                throw error
            }
        }
    }

    // MARK: Shared start and resume guards (both faces)

    /// The guards and preparation of every new start, in either face: shutdown, the opening/draft rules, the first
    /// message's size, one start per project at a time, the folder and the toolchain. `body` creates the card.
    func withNewStart<T: Sendable>(
        provider: ManagedSession.Provider, projectID: UUID?, opening: SessionOpening?, draft: NewSessionLaunch?,
        _ body: (_ directory: String, _ toolchain: ProviderToolchain) async throws -> T
    ) async throws -> T {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        // A harness coming later (D-120) is refused first, whoever asks: a stored draft, an opening or a plain start.
        for id in [HarnessID(provider), (draft?.choices ?? opening?.choices)?.harness].compactMap({ $0 }) {
            if let reason = HarnessCatalogue.comingLaterReason(for: id) { throw LoomError.message(reason) }
        }
        if let choices = draft?.choices ?? opening?.choices {
            guard choices.harness.provider == provider else {
                let name = HarnessCatalogue.descriptor(for: choices.harness)?.displayName ?? choices.harness.rawValue
                throw LoomError.message("\(name) cannot start this session in this build")
            }
            if choices.claudeChoices == nil {
                try choices.validate(models: await configuration.openedModels?(choices.harness) ?? [], allowFullAccess: false)
            }
        }
        guard (opening == nil && draft == nil) || harnesses[provider]?.takesOpeningOrDraft == true else {
            throw SessionRuntimeError.unsupportedProvider(provider)
        }
        guard opening == nil || draft == nil else {
            throw LoomError.message("A start takes an opening or a draft, never both.")
        }
        // Before any git step or card: a message that cannot be an argument is refused here, whoever asks.
        if let text = draft?.firstMessage ?? opening?.firstMessage {
            if text.utf8.count > NewSessionLaunch.maxFirstMessageBytes {
                throw LoomError.message("The first message is too long to start a session with (the limit is "
                    + "\(NewSessionLaunch.maxFirstMessageBytes / 1024) KB).")
            }
            guard !text.utf8.contains(0) else { throw LoomError.message("The first message contains a NUL character") }
        }
        let key = StartKey(provider: provider, projectID: projectID)
        guard startingNew.insert(key).inserted else {
            throw SessionRuntimeError.alreadyStarting(projectID ?? UUID())
        }
        defer { startingNew.remove(key) }
        let directory = try await workingDirectory(projectID: projectID)
        let toolchain = try await toolchain(for: provider)
        return try await body(directory, toolchain)
    }

    /// A new Claude session in `face`: the profile is validated before the card exists, the draft's branch or
    /// worktree is made right before the card (and undone when the start fails), the choices are recorded with the
    /// card, then `launch` spawns.
    func startClaude<T: Sendable>(
        sessionID: UUID, projectID: UUID?, directory: String, toolchain: ProviderToolchain,
        opening: SessionOpening?, draft: NewSessionLaunch?, face: ProviderLaunchProfile.ClaudeFace,
        launch: (ProviderLaunchProfile) async throws -> T
    ) async throws -> T {
        var choices = (draft?.choices ?? opening?.choices)?.claudeChoices ?? ClaudeLaunchChoices()
        // Direct callers obey the same agent boundary as requests that passed through the coordinator.
        if let opening, !opening.modeFromUserDefault, choices.permissionMode.map(HarnessMode.isFullAccessAlias) == true {
            throw OpenSessionRejection("Full access is never an agent's choice")
        }
        if opening != nil, choices.permissionMode == nil {
            let candidate = HarnessMode.fromStored(await configuration.defaultOpenedMode?(projectID))
            let descriptor = HarnessCatalogue.descriptor(for: .claude)
            choices.permissionMode = candidate.flatMap { descriptor?.modes.contains($0) == true ? $0.rawValue : nil }
                ?? ClaudePermissionMode.askBeforeEdits.rawValue
        }
        let hooks = try ensureHooks()
        // Validated before the card exists: an unsupported CLI leaves nothing behind.
        let profile = try claudeProfile(
            route: .new(sessionID), toolchain: toolchain, sessionID: sessionID, hooks: hooks, choices: choices,
            opening: opening.map {
                $0.approvedTask == nil
                    ? ProviderLaunchProfile.ClaudeOpening(title: $0.title, firstMessage: $0.firstMessage)
                    : ProviderLaunchProfile.ClaudeOpening(taskTitle: $0.title)
            } ?? draft.map {
                ProviderLaunchProfile.ClaudeOpening(title: "", firstMessage: $0.firstMessage)
            },
            face: face
        )
        // The branch or worktree of a draft's strip is made now: after everything that can refuse the
        // start without a trace, right before the card, and only when the user picked it.
        let prepared = try await GitWorkspace.begin(draft?.workspace ?? .projectFolder, projectFolder: directory)
        do {
            try await supervisor.createSession(
                ManagedSession(id: sessionID, provider: .claude, workingDirectory: prepared.folder),
                projectID: projectID, title: opening?.title, openedBy: opening?.openedBy
            )
            let bareManualStart = choices.isEmpty && opening == nil && draft == nil
            if !bareManualStart {
                await recordLaunchChoices(choices, sessionID: sessionID, rememberingInProject: opening == nil,
                                          completeNewStart: draft != nil)
            }
            startingSessions.insert(sessionID)
            defer { startingSessions.remove(sessionID) }
            let result = try await launch(profile)
            if bareManualStart { await rememberBareNewStart(sessionID: sessionID) }
            return result
        } catch {
            // A start that fails after the branch or worktree was made puts them back. What cannot be put
            // back is told with the failure; a card that was already made stays, with its error.
            let problems = await GitWorkspace.undo(prepared)
            guard !problems.isEmpty else { throw error }
            throw LoomError.message("\(error). Not undone: \(problems.joined(separator: "; "))")
        }
    }

    /// The guards of every resume, in either face: shutdown, one start per session, a pending deletion, a known
    /// session of an allowed provider, no live run, a verified last stop, a recorded identity, an existing folder.
    func withResume<T: Sendable>(
        sessionID: UUID, providers: Set<ManagedSession.Provider>,
        _ body: (_ session: ManagedSession, _ conversationID: String, _ toolchain: ProviderToolchain) async throws -> T
    ) async throws -> T {
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
        if let reason = HarnessCatalogue.comingLaterReason(for: HarnessID(session.provider)) { throw LoomError.message(reason) }
        guard await supervisor.session(id: sessionID)?.currentRun == nil else {
            throw SessionRuntimeError.alreadyRunning(sessionID)
        }
        if let report = await supervisor.lastStopReport(sessionID: sessionID), !report.succeeded {
            throw SessionRuntimeError.unverifiedStop(sessionID)
        }
        guard providers.contains(session.provider) else {
            throw SessionRuntimeError.unsupportedProvider(session.provider)
        }
        guard let conversationID = session.providerConversationID, !conversationID.isEmpty else {
            throw SessionRuntimeError.noProviderIdentity(session.provider)
        }
        try requireDirectory(session.workingDirectory)
        let toolchain = try await toolchain(for: session.provider)
        return try await body(session, conversationID, toolchain)
    }

    // MARK: Launch choices (V16)

    /// A bare manual start still changes the project's last harness, while preserving its remembered choices.
    private func rememberBareNewStart(sessionID: UUID) async {
        do {
            try await catalog.recordLaunchChoices(HarnessLaunchChoices(), sessionID: sessionID)
        } catch {
            LoomLog.error(.catalog, "Launch choices could not be recorded (\(LoomLog.category(of: error)))")
        }
    }

    /// The mode, model and effort a resume passes: the catalog's, with `passed` choices on top (and recorded).
    func resumeChoices(sessionID: UUID, passed: ClaudeLaunchChoices) async throws -> ClaudeLaunchChoices {
        await recordLaunchChoices(passed, sessionID: sessionID)
        return try await catalog.launchChoices(sessionID: sessionID).merging(passed)
    }

    /// Clears the recorded effort (see `SessionCatalog.clearLaunchEffort`).
    public func clearLaunchEffort(sessionID: UUID) async {
        do { try await catalog.clearLaunchEffort(sessionID: sessionID) } catch {
            LoomLog.error(.catalog, "The recorded effort could not be cleared (\(LoomLog.category(of: error)))")
        }
    }

    /// Puts the recorded model back to `model` (nil: none). See `SessionCatalog.setLaunchModel`.
    public func restoreLaunchModel(_ model: String?, sessionID: UUID) async {
        do { try await catalog.setLaunchModel(model, sessionID: sessionID) } catch {
            LoomLog.error(.catalog, "The recorded model could not be restored (\(LoomLog.category(of: error)))")
        }
    }

    /// Records a session's mode, model or effort (a start, or a live change that succeeded in the Chat face), so
    /// every later spawn in either face passes them. A failed write is logged; the session goes on. `rememberingInProject`
    /// false keeps a session an agent opened out of the project's "last used" (Q3, D-103).
    public func recordLaunchChoices(_ choices: ClaudeLaunchChoices, sessionID: UUID, rememberingInProject: Bool = true,
                                    completeNewStart: Bool = false) async {
        guard !choices.isEmpty || completeNewStart else { return }
        do {
            try await catalog.recordLaunchChoices(choices, sessionID: sessionID, rememberingInProject: rememberingInProject,
                                                  completeNewStart: completeNewStart)
        } catch {
            LoomLog.error(.catalog, "Launch choices could not be recorded (\(LoomLog.category(of: error)))")
        }
    }

    // MARK: Stop, use and answers

    /// Stops exactly this conversation's run. The report is the verified
    /// outcome; an unverified stop is also carried to the card as a failure.
    @discardableResult
    public func stopConversation(sessionID: UUID) async throws -> SessionStopReport {
        try await stopConversation(sessionID: sessionID, expectedRunID: nil)
    }

    /// Task lifecycle work may never follow a card to a newer or moved run.
    func stopConversation(sessionID: UUID, expectedRunID: UUID?) async throws -> SessionStopReport {
        revokeTaskRun(sessionID: sessionID, runID: expectedRunID)
        guard let session = await supervisor.session(id: sessionID) else {
            throw SessionRuntimeError.sessionNotFound(sessionID)
        }
        guard let run = session.currentRun, expectedRunID == nil || expectedRunID == run.id else {
            throw SessionRuntimeError.notRunning(sessionID)
        }
        let previousCard = runs[run.id]?.activeSession
        stopRequestedRuns.insert(run.id)
        runs[run.id]?.activeSession = sessionID
        let server = runs[run.id]?.server
        await closeManagedTaskController(runID: run.id)
        var report: SessionStopReport
        do {
            if let expectedRunID {
                guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
                report = await supervisor.stop(sessionID: sessionID, runID: expectedRunID,
                                               graceSeconds: 0.2, endReason: .requested,
                                               requiringSessionID: sessionID)
            } else { report = try await supervisor.stop(sessionID: sessionID) }
        } catch SessionManagementError.sessionNotRunning {
            // The run exited, or `/clear` moved it to another card, between the read above and the
            // stop: nothing of this card was stopped, and a run that still lives is not Loom's stop.
            if await supervisor.runContext(runID: run.id) != nil {
                stopRequestedRuns.remove(run.id)
                if let previousCard { runs[run.id]?.activeSession = previousCard }
            }
            throw SessionRuntimeError.notRunning(sessionID)
        }
        if expectedRunID != nil, !report.succeeded,
           let active = await supervisor.activeSessionID(runID: run.id), active != sessionID {
            stopRequestedRuns.remove(run.id)
            runs[run.id]?.activeSession = active
        }
        await reconcileEnded()
        let agyErrors = await finishAgyRun(run.id)
        if !agyErrors.isEmpty { report = report.adding(errors: agyErrors) }
        // The conversation's own app-server is part of its stop: the TUI went
        // first (so the provider stop hooks had a server), the server and its
        // scope go now. A server that cannot be shown gone is a failed stop.
        if let server, await supervisor.runContext(runID: run.id) == nil {
            let errors = await tearDown(server, card: sessionID)
            if !errors.isEmpty { report = report.adding(errors: errors) }
        }
        await endManagedTaskPresentation(runID: run.id, verified: report.succeeded)
        return report
    }

    /// A deliberate view of a visible, active conversation. Updates the
    /// persistent use date; a stale conversation stays stale.
    public func markViewed(sessionID: UUID) async throws {
        try await lifecycle.markViewed(sessionID: sessionID)
    }

    // MARK: Quit

    /// One shutdown for everything the app owns. Starts refusing new work
    /// first; a failed shutdown stays failed so the caller can offer a retry.
    public func shutdown() async -> ShutdownReport {
        shuttingDown = true
        let taskPlans = Array(taskRunPlans.values)
        for plan in taskPlans {
            revokeTaskRun(sessionID: plan.claim.sessionID, runID: plan.claim.managedRunID)
        }
        for runID in Array(managedTaskControllers.keys) { await closeManagedTaskController(runID: runID) }
        for plan in taskPlans {
            await fenceTaskRun(sessionID: plan.claim.sessionID, runID: plan.claim.managedRunID,
                               generation: plan.claim.generation)
        }
        for id in Array(taskProofWaiters.keys) { finishTaskProofWaiter(id, result: nil) }
        taskExpectedInputs.removeAll()
        taskChildReservations.removeAll()
        retiredTaskRuns.removeAll()
        taskReadFence?.stop()
        taskReadFence = nil
        peerReadFence?.stop()
        peerReadFence = nil
        await claudeLimitObserver?.cancelAll()
        await peerMailbox?.shutdown()
        peerMailbox = nil
        peerPendingRequests.removeAll()
        let taskSocketStopped = if let socket = taskSocket { await socket.stopAndWait() } else { true }
        // An unverified cleanup keeps the socket: a retried Quit asks it again and hears the same failure.
        if taskSocketStopped { taskSocket = nil }
        taskSocketPath = nil
        await taskCoordinator?.finishProjectionUpdates()
        let liveRuns = runs.count
        LoomLog.notice(.quit, "Shutdown started (\(liveRuns) live run(s))")
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
        loginEnvironmentCapture?.cancel()
        // Waiting clients hear that Loom is going; pending requests are lost (memory only).
        await openRequests.shutdown()
        controlServer?.stop()
        controlServer = nil
        hookServer?.stop()
        hookServer = nil
        hookTask?.cancel()
        hookTask = nil
        var socketErrors: [String] = taskSocketStopped ? [] : ["Task socket ownership or cleanup could not be verified"]
        var preparedSockets = Set<UUID>()
        for server in servers {
            _ = await server.teardownTask?.value
            server.requestTask?.cancel()
            server.requestTask = nil
            server.progressTask?.cancel()
            server.progressTask = nil
            await server.coordinator?.stop()
            let stopped = await server.manager.stopServerForShutdown()
            socketErrors += stopped.errors
            if stopped.errors.isEmpty {
                let errors = await server.manager.prepareSocketCleanup()
                socketErrors += errors
                if errors.isEmpty { preparedSockets.insert(server.id) }
            }
        }
        // A backup still waiting for its turn gives up; one being copied is awaited at the end, so nothing
        // of the runtime writes to the data root after shutdown returns.
        let backup = backupTask
        backupTask = nil
        backup?.cancel()
        let supervisorReport = await supervisor.shutdown()
        if supervisorReport.succeeded {
            for runID in Array(agyRuns.keys) { socketErrors += await finishAgyRun(runID) }
        }
        if supervisorReport.succeeded {
            for server in servers where preparedSockets.contains(server.id) {
                let errors = await server.manager.finishSocketCleanup()
                socketErrors += errors
                if errors.isEmpty { server.finished = true }
            }
            codexServers.removeAll { $0.finished }
        }
        let report = ShutdownReport(remainingCountVerified: supervisorReport.remainingCountVerified,
            elapsedSeconds: supervisorReport.elapsedSeconds, signals: supervisorReport.signals,
            remaining: supervisorReport.remaining, errors: supervisorReport.errors + socketErrors,
            outsideOwnership: supervisorReport.outsideOwnership, ownershipGuarantee: supervisorReport.ownershipGuarantee)
        recordQuit(report)
        observer?.cancel()
        observer = nil
        // End frames may still be queued when observation stops. Reconcile
        // genuinely finished runs on both successful and failed Quit; a live
        // run from a failed shutdown keeps its resources for the retry.
        await reconcileEnded()
        if report.succeeded {
            for runID in taskLaunchContexts.values.compactMap(\.currentRunID) {
                await endManagedTaskPresentation(runID: runID, verified: true)
            }
        }
        await backup?.value
        return report
    }

    // MARK: Launch helpers

    func workingDirectory(projectID: UUID?) async throws -> String {
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

    func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionRuntimeError.missingDirectory(path)
        }
    }

    /// Where Claude keeps this profile's files, found without running the CLI (a deletion must
    /// work with Claude removed from PATH): the explicit profile folder, else the resolved
    /// toolchain's when one exists already, else `CLAUDE_CONFIG_DIR` from the login shell's environment
    /// (captured once at launch, DP-CP4-8) or from Loom's own, else `~/.claude`.
    func claudeConfigDirectory() -> URL {
        let resolved = toolchains[.claude]
        return ClaudeProfileLayout(
            profileDirectory: configuration.claudeProfileDirectory ?? resolved?.profileDirectory,
            environment: resolved?.environment ?? loginEnvironment ?? configuration.claudeEnvironment,
            home: URL(fileURLWithPath: configuration.homeDirectory, isDirectory: true)
        ).configDirectory
    }

    /// The profile's `projects` folder: the only place a subagent's transcript is read from (FB4-5).
    public func claudeProjectsDirectory() -> URL {
        claudeConfigDirectory().appendingPathComponent("projects", isDirectory: true)
    }

    /// Resolved once per provider after it succeeds; a failure is retried on
    /// the next attempt.
    /// The toolchain is cached per provider while the executable it was read from is the same file
    /// (inode, mtime, size). A CLI update replaces or rewrites that file, so the next start reads
    /// `--version` and `--help` again instead of launching with the old one's capabilities; a
    /// launch failure also forces a fresh read (`invalidateToolchain`).
    func toolchain(for provider: ManagedSession.Provider) async throws -> ProviderToolchain {
        if let cached = toolchains[provider], !staleToolchains.contains(provider) {
            let current = toolchainStamps[provider].map { ExecutableStamp.read(cached.executable) == $0 } ?? true
            if current { return cached }
            LoomLog.notice(.toolchain, "\(provider.rawValue) executable changed on disk; resolving again")
        }
        let previous = toolchains[provider]
        let value = try await resolveToolchain(provider)
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        toolchains[provider] = value
        toolchainStamps[provider] = value.executableStamp ?? ExecutableStamp.read(value.executable)
        staleToolchains.remove(provider)
        for warning in value.warnings where !toolchainWarnings.contains(warning) {
            toolchainWarnings.append(warning)
        }
        noteToolchain(value, previous: previous)
        return value
    }

    /// One capability probe that fails (a timeout, an exit status, a spawn error: seen once in six app launches on the real
    /// CLI, with no journal detail) is tried once more after a short pause. Every failure is journaled by its kind, never by
    /// the CLI's output. A second failure goes on to the caller, whose draft keeps its text.
    private func resolveToolchain(_ provider: ManagedSession.Provider) async throws -> ProviderToolchain {
        do {
            return try await configuration.toolchains(provider)
        } catch let first as ProviderToolchainError {
            guard case let .capabilityProbeFailed(_, _, kind) = first, !shuttingDown else { throw first }
            journal.record("toolchain_probe_failed", [
                "provider": .string(provider.rawValue), "kind": .string(kind.description), "attempt": .int(1), "retrying": .bool(true),
            ])
            LoomLog.error(.toolchain, "\(provider.rawValue) capability probe failed (\(kind)); trying once more")
            try await Task.sleep(for: configuration.toolchainProbeRetryPause)
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            do {
                return try await configuration.toolchains(provider)
            } catch let second as ProviderToolchainError {
                if case let .capabilityProbeFailed(_, _, kind) = second {
                    journal.record("toolchain_probe_failed", [
                        "provider": .string(provider.rawValue), "kind": .string(kind.description), "attempt": .int(2),
                        "retrying": .bool(false),
                    ])
                }
                throw second
            }
        }
    }

    /// What the runtime has cached for a provider (diagnostics read it; nothing resolves here).
    func cachedToolchain(for provider: ManagedSession.Provider) -> ProviderToolchain? { toolchains[provider] }

    /// The version of a provider's CLI as its cached `--version` probe read it ("2.1.300"), for a session's details. No probe
    /// runs and no process starts here: nil until a start of that provider resolved its toolchain in this process, or when
    /// the answer held no version. The cache follows the executable on disk, so after a CLI update the next start's
    /// version shows, also for a session that still runs the older one.
    public func toolchainVersion(for provider: ManagedSession.Provider) -> String? {
        toolchains[provider]?.capabilities.cliVersion.map { $0.map(String.init).joined(separator: ".") }
    }

    /// A start failed: read the CLI again before the next one.
    func invalidateToolchain(_ provider: ManagedSession.Provider) async {
        staleToolchains.insert(provider)
        if case .claude = provider { await claudeLimitObserver?.cancelAll() }
        await configuration.toolchainInvalidator?(provider)
    }

    func register(
        _ launch: ManagedSessionLaunch, runID: UUID, provider: ManagedSession.Provider,
        server: CodexServer?, tee: DiagnosticOutputTee?
    ) async -> RuntimeLaunch {
        server?.runID = runID
        runs[runID] = RunRecord(
            runID: runID, launchSessionID: launch.session.id, provider: provider,
            server: server, startedAt: Date(),
            isResume: tee != nil, diagnostics: tee, endpoint: .terminal(launch.terminal),
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
        if agyRuns[runID] != nil { return await finishAgyRun(runID) }
        guard let server = codexServers.first(where: { $0.runID == runID }) else { return [] }
        let card = runs[runID]?.activeSession ?? server.ownerCard
        return await tearDown(server, card: card)
    }

    // MARK: Observing runs

    private func reconcile(_ frame: SessionEventFrame) async {
        await reconcileEnded()
        for (taskID, context) in taskLaunchContexts {
            if let runID = context.currentRunID { await refreshManagedCodexStatus(taskID: taskID, runID: runID) }
            guard let runID = context.currentRunID, frame.sessions[context.childID]?.runID == runID,
                  let status = frame.sessions[context.childID]?.status,
                  status.activity == .atPrompt || status.activity == .turnComplete else { continue }
            scheduleTaskDelivery(taskID)
        }
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
            revokeTaskRun(sessionID: record.launchSessionID, runID: record.runID)
            await closeManagedTaskController(runID: record.runID)
            await endManagedTaskPresentation(runID: record.runID, verified: false)
            await claudeLimitObserver?.forget(runID: snapshot.runID)
            if let harness = harnesses[record.provider] { await harness.runEnded(runID: record.runID, in: self) }
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
              let status = await record.endpoint.exitStatus(), status != 0,
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
