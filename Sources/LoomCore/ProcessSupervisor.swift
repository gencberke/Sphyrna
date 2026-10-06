import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

/// Actor-isolated CP2 lifecycle entry point. It owns terminal objects and exposes
/// value snapshots, so process and PTY work never needs to execute on MainActor.
public actor ProcessSupervisor {
    public nonisolated let ownershipRunID: UUID
    public nonisolated let events: SessionEventHub

    private enum StopPhase { case unprepared, prepared, completionPending, completed }

    private struct Runtime {
        let launchSessionID: UUID
        var activeSessionID: UUID
        var run: ManagedRun
        var terminal: TerminalEndpoint
        var outsideOwnership: [ProcessRecord]
        var catalogStarted: Bool
        var stopPhase: StopPhase = .unprepared
        var scope: RunScope? = nil
    }

    private var ledger: OwnershipLedger
    private let ledgerURL: URL?
    /// When set, every run starts inside a LaunchServices run host's fresh
    /// resource coalition. Without it (tests only) ownership is narrowed.
    private let scopeLauncher: RunScopeLauncher?
    private nonisolated let scopeLauncherConfigured: Bool
    private var liveScopes: [UInt64: RunScope] = [:]
    private var releasingScopes: Set<UInt64> = []
    /// Scoped processes of another UID: Loom cannot stop them, so a stop or
    /// Quit that finds one is reported as unverified, never as success.
    private var outsideScopes: [ProcessRecord] = []
    private var environmentScope: RunScope?
    private var scopeRuns: [UInt64: Set<UUID>] = [:]
    private let catalog: SessionCatalog?
    private var sessions: [UUID: ManagedSession] = [:]
    private var internalSessionIDs: Set<UUID> = []
    private var runtimes: [UUID: Runtime] = [:]
    private var reservedSessions: Set<UUID> = []
    private var markerInspected: Set<ProcessIdentity> = []
    private var managedRunMarkers: [ProcessIdentity: UUID] = [:]
    private var stoppingRuns: Set<UUID> = []
    private var stopHooks: [UUID: ManagedRunStopHooks] = [:]
    private var identityStates: [UUID: SessionIdentityState] = [:]
    private var recentStopDiagnostics: [StopDiagnostic] = []
    private var lastStopReports: [UUID: SessionStopReport] = [:]
    private var pendingCatalogWrites: [UUID: Task<Void, Never>] = [:]
    private var catalogWriteErrors: [UUID: String] = [:]
    private var environmentJobs: [UUID: EnvironmentResolutionJob] = [:]
    private var workStates: [UUID: ProviderWorkState] = [:]
    /// Ingress can monotonically invalidate a run even while its actor consumer
    /// is paused. This flag has no alternate mutable provider-state authority.
    private nonisolated let unreliableProviderRuns = Mutex<Set<UUID>>([])
    /// A transition retains run ownership until durable commit and publication.
    private var transitioningRuns: Set<UUID> = []
    private var stopping = false
    private var shutdownInProgress = false
    private var lastShutdownReport: ShutdownReport?
    private var ownershipSamplingFailpoint: (@Sendable () throws -> Void)?

    /// Internal test boundary; normal ownership samples always use the OS table.
    func setOwnershipSamplingFailpointForTesting(_ failpoint: (@Sendable () throws -> Void)?) {
        ownershipSamplingFailpoint = failpoint
    }

    /// `events` lets the application create the hub first (the UI model needs
    /// it before the supervisor can be built asynchronously).
    public init(ledger: OwnershipLedger = OwnershipLedger(), ledgerURL: URL? = nil,
                catalog: SessionCatalog? = nil,
                events: SessionEventHub = SessionEventHub(),
                scopeLauncher: RunScopeLauncher? = nil) throws {
        self.ledger = ledger
        self.ledgerURL = ledgerURL
        self.catalog = catalog
        self.events = events
        self.scopeLauncher = scopeLauncher
        scopeLauncherConfigured = scopeLauncher != nil
        ownershipRunID = ledger.runID
        // Persist the owner marker before any managed process can be spawned.
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    /// Bootstrap path for a reopened application. Durable conversations are
    /// restored without reviving their previous OS runs.
    public static func restoring(
        ledger: OwnershipLedger = OwnershipLedger(), ledgerURL: URL? = nil,
        catalog: SessionCatalog, events: SessionEventHub = SessionEventHub(),
        scopeLauncher: RunScopeLauncher? = nil
    ) async throws -> ProcessSupervisor {
        let supervisor = try ProcessSupervisor(
            ledger: ledger, ledgerURL: ledgerURL, catalog: catalog, events: events,
            scopeLauncher: scopeLauncher
        )
        try await supervisor.restoreCatalogSessions()
        return supervisor
    }

    public func createSession(_ session: ManagedSession, projectID: UUID? = nil) async throws {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard sessions[session.id] == nil, !reservedSessions.contains(session.id) else {
            throw SessionManagementError.sessionAlreadyExists(session.id)
        }
        reservedSessions.insert(session.id)
        defer { reservedSessions.remove(session.id) }
        if let catalog { try await catalog.insertSession(session, projectID: projectID) }
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        sessions[session.id] = session
        await events.publish(
            sessionID: session.id,
            change: .conversationIdentity(session.providerConversationID)
        )
    }

    /// Registers an app-owned helper
    /// under the same process ownership contract without exposing it as a user
    /// conversation or persisting it in the conversation catalog.
    public func createInternalSession(_ session: ManagedSession) throws {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard sessions[session.id] == nil, !reservedSessions.contains(session.id) else {
            throw SessionManagementError.sessionAlreadyExists(session.id)
        }
        sessions[session.id] = session
        internalSessionIDs.insert(session.id)
    }

    public func discardInternalSession(_ sessionID: UUID) throws {
        guard internalSessionIDs.contains(sessionID) else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard sessions[sessionID]?.currentRun == nil else {
            throw SessionManagementError.sessionAlreadyRunning(sessionID)
        }
        sessions[sessionID] = nil
        internalSessionIDs.remove(sessionID)
        lastStopReports[sessionID] = nil
    }

    public func session(id: UUID) -> ManagedSession? { sessions[id] }

    public func managedSessions() -> [ManagedSession] {
        sessions.values.filter { !internalSessionIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public struct StopDiagnostic: Codable, Sendable {
        public let sessionID: UUID
        public let runID: UUID
        public let providerStages: [ProviderStopStage]
        public let remainingCount: Int?
        public let succeeded: Bool
    }

    public func stopDiagnostics() -> [StopDiagnostic] { recentStopDiagnostics }

    public func lastStopReport(sessionID: UUID) -> SessionStopReport? {
        lastStopReports[sessionID]
    }

    /// Conversations that currently own a live run.
    func pendingConversationTransitionCount() -> Int { transitioningRuns.count }
    func pendingStopCount() -> Int { stoppingRuns.count }

    public func runningSessionIDs() -> Set<UUID> {
        Set(runtimes.values.map(\.activeSessionID))
    }

    public func activeSessionID(runID: UUID) -> UUID? {
        runtimes[runID]?.activeSessionID
    }

    public func setIdentityState(_ state: SessionIdentityState, runID: UUID) async throws {
        guard let runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        identityStates[runID] = state
        await events.publish(
            sessionID: runtime.activeSessionID, change: .identityState(state)
        )
    }

    public func identityState(sessionID: UUID) -> SessionIdentityState {
        guard let runID = sessions[sessionID]?.currentRun?.id else { return .known }
        return identityStates[runID] ?? .known
    }

    public func registerStopHooks(runID: UUID, hooks: ManagedRunStopHooks) throws {
        guard runtimes[runID] != nil else {
            throw SessionManagementError.runNotFound(runID)
        }
        stopHooks[runID] = hooks
    }

    public func providerWorkState(sessionID: UUID) -> ProviderWorkState? {
        guard let runID = sessions[sessionID]?.currentRun?.id else { return nil }
        if !providerWorkStateIsReliable(runID: runID) { return ProviderWorkState(activity: .unknown) }
        return workStates[runID]
    }

    nonisolated func invalidateProviderWorkState(runID: UUID) -> Bool {
        unreliableProviderRuns.withLock { $0.insert(runID).inserted }
    }

    nonisolated func providerWorkStateIsReliable(runID: UUID) -> Bool {
        unreliableProviderRuns.withLock { !$0.contains(runID) }
    }

    nonisolated func clearProviderWorkInvalidation(runID: UUID) {
        _ = unreliableProviderRuns.withLock { $0.remove(runID) }
    }

    public func updateProviderWorkState(runID: UUID, state: ProviderWorkState) async throws {
        guard let runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        let reliableState = providerWorkStateIsReliable(runID: runID) ? state : ProviderWorkState(activity: .unknown)
        workStates[runID] = reliableState
        await events.publish(sessionID: runtime.activeSessionID, change: .status(reliableState))
    }

    public func runContext(runID: UUID) -> ManagedRunContext? {
        guard let runtime = runtimes[runID],
              let session = sessions[runtime.activeSessionID] else { return nil }
        return ManagedRunContext(
            launchSessionID: runtime.launchSessionID,
            activeSessionID: runtime.activeSessionID,
            session: session
        )
    }

    public func ledgerSnapshot() -> OwnershipLedger { ledger }

    /// App-wide ownership view used by recovery and the checkpoint probe. Run
    /// lifecycle code should prefer the session-scoped sampler below.
    public func ownedProcesses() throws -> [ProcessRecord] { try sampleOwnership() }

    public func isStopping() -> Bool { stopping }

    /// Resolves the user's terminal environment on the supervisor actor rather
    /// than MainActor. The synchronous resolver remains bounded and its spawned
    /// shell participates in the same ownership ledger.
    public func terminalEnvironment(
        origin: LaunchEnvironment.LaunchOrigin
    ) async throws -> LaunchEnvironment.Resolution {
        try await resolveEnvironment { runID, job, spawner in
            try LaunchEnvironment.terminal(
                origin: origin, runID: runID, spawner: spawner,
                onSpawn: job.register, onPoll: job.sample
            )
        }
    }

    /// Deterministic seam for proving that a slow shell capture does not occupy
    /// the supervisor actor or a terminal's IO queue.
    func terminalEnvironment(
        parent: [String: String], session: [String: String],
        testZDOTDIR: URL, timeout: TimeInterval
    ) async throws -> LaunchEnvironment.Resolution {
        try await resolveEnvironment { runID, job, spawner in
            try LaunchEnvironment.resolve(
                parent: parent, session: session, testZDOTDIR: testZDOTDIR,
                timeout: timeout, runID: runID, spawner: spawner,
                onSpawn: job.register, onPoll: job.sample
            )
        }
    }

    /// Runs a short helper command (a provider's `--version`/`--help`) under
    /// the same ownership as the environment shell: registered in the ledger,
    /// cancelled and awaited by `shutdown`, one deadline, bounded output. After
    /// a successful Quit no helper of this kind is left running.
    public func captureHelper(
        _ executable: String, _ arguments: [String], environment: [String: String],
        timeout: TimeInterval = 15
    ) async throws -> String {
        try await runOwnedJob(scope: .perCall) { _, job, spawner in
            try LaunchEnvironment.runHelper(
                executable, arguments, environment: environment, timeout: timeout,
                spawner: spawner, onSpawn: job.register, onPoll: job.sample
            )
        }
    }

    private func resolveEnvironment(
        _ operation: @escaping @Sendable (
            UUID, EnvironmentResolutionJob, HelperSpawner
        ) throws -> LaunchEnvironment.Resolution
    ) async throws -> LaunchEnvironment.Resolution {
        try await runOwnedJob(scope: .environment, operation)
    }

    /// Environment startup work (a login shell's background jobs) may keep
    /// running until Quit, so its scope lives as long as the app run. A
    /// one-shot helper's scope is stopped and released when it returns.
    private enum JobScope { case environment, perCall }

    private func runOwnedJob<Result: Sendable>(
        scope kind: JobScope,
        _ operation: @escaping @Sendable (UUID, EnvironmentResolutionJob, HelperSpawner) throws -> Result
    ) async throws -> Result {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        let jobID = UUID()
        let runID = ownershipRunID
        let job = EnvironmentResolutionJob(
            runID: runID, observes: scopeLauncher == nil
        )
        environmentJobs[jobID] = job
        defer { environmentJobs[jobID] = nil }
        var scope: RunScope?
        if scopeLauncher != nil {
            if kind == .environment, let environmentScope, liveScopes[environmentScope.coalitionID] != nil {
                scope = environmentScope
            } else {
                scope = try await openScope()
                if kind == .environment { environmentScope = scope }
            }
        }
        let spawner = scope.map(HelperSpawner.scoped) ?? .local
        do {
            let result = try await Task.detached {
                try operation(runID, job, spawner)
            }.value
            if scopeLauncher == nil { ledger.recordDescendants(Array(job.observedIdentities())) }
            _ = try sampleOwnership()
            if kind == .perCall, let scope {
                let errors = await releaseScope(scope)
                guard errors.isEmpty else {
                    throw LoomError.message("Helper cleanup could not be verified: " + errors.joined(separator: "; "))
                }
            }
            guard !stopping else { throw SessionManagementError.shutdownStarted }
            return result
        } catch {
            if scopeLauncher == nil { ledger.recordDescendants(Array(job.observedIdentities())) }
            _ = try? sampleOwnership()
            if kind == .perCall, let scope { _ = await releaseScope(scope) }
            throw error
        }
    }

    /// Launches a new OS run for an existing durable conversation. The caller
    /// provides the app ownership and conversation markers; the supervisor adds
    /// a fresh execution marker that callers cannot accidentally reuse.
    @discardableResult
    public func launch(sessionID: UUID, executable: String, arguments: [String] = [],
                       environment: [String: String], rows: UInt16 = 24,
                       columns: UInt16 = 80,
                       outputSink: (any TerminalOutputSink)? = nil,
                       managedRunID requestedRunID: UUID? = nil,
                       scope requestedScope: RunScope? = nil) async throws -> ManagedSessionLaunch {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard var session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard session.currentRun == nil, !reservedSessions.contains(sessionID) else {
            throw SessionManagementError.sessionAlreadyRunning(sessionID)
        }
        if let conversationID = session.providerConversationID,
           sessions.values.contains(where: {
               $0.id != sessionID && $0.provider == session.provider
                   && $0.providerConversationID == conversationID
                   && $0.currentRun != nil
           }) {
            throw SessionManagementError.conversationAlreadyRunning(
                provider: session.provider, conversationID: conversationID
            )
        }
        guard environment["LOOM_RUN_ID"] == ownershipRunID.uuidString,
              environment["LOOM_SESSION_ID"] == sessionID.uuidString else {
            throw SessionManagementError.invalidOwnershipMarkers(sessionID: sessionID)
        }
        reservedSessions.insert(sessionID)
        defer { reservedSessions.remove(sessionID) }

        let runID = requestedRunID ?? UUID()
        guard runtimes[runID] == nil else {
            throw SessionManagementError.runAlreadyExists(runID)
        }
        var runEnvironment = environment
        runEnvironment["LOOM_MANAGED_RUN_ID"] = runID.uuidString
        let scope: RunScope?
        var ownsNewScope = false
        if let requestedScope {
            guard liveScopes[requestedScope.coalitionID] === requestedScope,
                  !releasingScopes.contains(requestedScope.coalitionID) else {
                throw RunScopeError.lost
            }
            scope = requestedScope
        } else if scopeLauncher != nil {
            scope = try await openScope()
            ownsNewScope = true
            if stopping {
                _ = await releaseScope(scope!)
                throw SessionManagementError.shutdownStarted
            }
        } else {
            scope = nil
        }
        let process: PTYProcess
        // Counted before spawning so a concurrent stop of another run in this
        // scope never treats itself as the last run and sweeps this one.
        if let scope { scopeRuns[scope.coalitionID, default: []].insert(runID) }
        var runRegistered = false
        defer {
            if !runRegistered, let scope { scopeRuns[scope.coalitionID]?.remove(runID) }
        }
        if let scope {
            do {
                process = try await spawnInScope(
                    scope, executable: executable, arguments: arguments,
                    environment: runEnvironment, directory: session.workingDirectory,
                    rows: rows, columns: columns
                )
            } catch {
                if ownsNewScope { _ = await releaseScope(scope) }
                throw error
            }
        } else {
            process = try PTYProcess(executable: executable, arguments: arguments,
                                     environment: runEnvironment,
                                     directory: session.workingDirectory,
                                     rows: rows, columns: columns)
        }
        let snapshot: [ProcessRecord]
        do { snapshot = try ProcessTable.snapshot() }
        catch {
            await abandonUnregistered(process, scope: scope, ownsNewScope: ownsNewScope)
            throw error
        }
        guard let leader = snapshot.first(where: { $0.identity.pid == process.pid }) else {
            await abandonUnregistered(process, scope: scope, ownsNewScope: ownsNewScope)
            throw SessionManagementError.leaderIdentityUnavailable(process.pid)
        }

        let run = ManagedRun(id: runID, leader: leader.identity, startedAt: Date(),
                             state: .running, exitStatus: nil,
                             descendants: [leader.identity])
        var reap: (@Sendable (Int32, UnsafeMutablePointer<Int32>) -> Int32)?
        if let scope {
            reap = { pid, status in scope.reap(pid, status) }
        }
        let terminal = TerminalEndpoint(process: process, outputSink: outputSink, reap: reap) { [weak self] status in
            Task { await self?.recordLeaderExit(runID: runID, status: status) }
        }
        session.currentRun = run
        sessions[sessionID] = session
        runtimes[runID] = Runtime(
            launchSessionID: sessionID, activeSessionID: sessionID,
            run: run, terminal: terminal, outsideOwnership: [],
            catalogStarted: catalog == nil, scope: scope
        )
        runRegistered = true
        await events.publish(sessionID: sessionID, change: .runStarted(runID))
        markerInspected.insert(leader.identity)
        managedRunMarkers[leader.identity] = runID

        // Without run scopes the ledger is the recovery and final-shutdown
        // oracle; with them, scope records (persisted at openScope) are, and
        // only scope membership selects what may be signaled.
        if scopeLauncher == nil {
            ledger.register(leader.identity)
            _ = ledger.observe(snapshot)
        }
        do { if scopeLauncher == nil { try persistLedger() } }
        catch {
            let persistenceError = error
            _ = await stop(sessionID: sessionID, runID: runID, graceSeconds: 0.2,
                           endReason: .requested)
            throw persistenceError
        }
        if let catalog, !internalSessionIDs.contains(sessionID) {
            do { try await catalog.startRun(run, sessionID: sessionID) }
            catch {
                _ = await stop(sessionID: sessionID, runID: runID, graceSeconds: 0.2,
                               endReason: .requested)
                throw error
            }
            if var runtime = runtimes[runID] {
                runtime.catalogStarted = true
                runtimes[runID] = runtime
            } else {
                try await catalog.finishRun(
                    runID, reason: stopping ? .applicationQuit : .processExited,
                    exitStatus: await terminal.exitStatus()
                )
            }
        }
        if stopping {
            if runtimes[runID] != nil {
                _ = await stop(sessionID: sessionID, runID: runID, graceSeconds: 0.2,
                               endReason: .applicationQuit)
            }
            throw SessionManagementError.shutdownStarted
        }
        return ManagedSessionLaunch(session: sessions[sessionID] ?? session, terminal: terminal)
    }

    /// Provider-independent durable conversation binding and in-TUI movement.
    @discardableResult
    public func adoptConversation(
        runID: UUID, conversationID: String,
        transition: ConversationTransition, at date: Date = Date()
    ) async throws -> UUID {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard !stoppingRuns.contains(runID) else { throw SessionManagementError.runNotFound(runID) }
        while transitioningRuns.contains(runID) {
            try await Task.sleep(for: .milliseconds(1))
            guard !stopping else { throw SessionManagementError.shutdownStarted }
            guard !stoppingRuns.contains(runID) else { throw SessionManagementError.runNotFound(runID) }
            guard runtimes[runID] != nil else {
                throw SessionManagementError.runNotFound(runID)
            }
        }
        transitioningRuns.insert(runID)
        var reservedDestination: UUID?
        defer {
            transitioningRuns.remove(runID)
            if let reservedDestination { reservedSessions.remove(reservedDestination) }
        }
        guard var runtime = runtimes[runID], runtime.run.state == .running,
              var current = sessions[runtime.activeSessionID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        if current.providerConversationID == conversationID { return current.id }
        let provider = current.provider
        if let existing = sessions.values.first(where: {
            $0.id != current.id && $0.provider == provider
                && $0.providerConversationID == conversationID && $0.currentRun != nil
        }) {
            throw SessionManagementError.conversationAlreadyRunning(
                provider: existing.provider, conversationID: conversationID
            )
        }
        if transition == .bind || (transition == .automatic
            && current.providerConversationID == nil) {
            guard current.providerConversationID == nil else {
                throw SessionManagementError.conversationAlreadyRunning(
                    provider: provider,
                    conversationID: current.providerConversationID ?? conversationID
                )
            }
            if let catalog {
                try await catalog.updateProviderConversationID(
                    sessionID: current.id, newID: conversationID, changedAt: date
                )
            }
            // A leader-exit callback can update run state while the catalog is
            // awaited. Preserve its current state instead of the old snapshot.
            current = sessions[current.id] ?? current
            current.providerConversationID = conversationID
            sessions[current.id] = current
            await events.publish(
                sessionID: current.id, change: .conversationIdentity(conversationID)
            )
            return current.id
        }
        let existing: ManagedSession?
        if transition == .resume {
            if let catalog {
                existing = try await catalog.session(
                    provider: provider, conversationID: conversationID
                )?.session
            } else {
                existing = sessions.values.first {
                    $0.provider == provider
                        && $0.providerConversationID == conversationID
                }
            }
        } else { existing = nil }
        var destination: ManagedSession
        if var matched = existing {
            if let inMemory = sessions[matched.id] { matched = inMemory }
            if matched.currentRun != nil || reservedSessions.contains(matched.id) {
                throw SessionManagementError.conversationAlreadyRunning(
                    provider: provider, conversationID: conversationID
                )
            }
            reservedSessions.insert(matched.id)
            reservedDestination = matched.id
            if let catalog {
                try await catalog.transitionRun(
                    runID, from: current.id,
                    toExistingSessionID: matched.id, at: date
                )
            }
            matched.currentRun = runtime.run
            destination = matched
        } else {
            var created = ManagedSession(
                provider: provider, providerConversationID: conversationID,
                workingDirectory: current.workingDirectory
            )
            if let catalog {
                try await catalog.transitionRun(
                    runID, from: current.id, to: created, at: date
                )
            }
            created.currentRun = runtime.run
            destination = created
        }
        guard let latestRuntime = runtimes[runID] else { throw SessionManagementError.runNotFound(runID) }
        runtime = latestRuntime
        destination.currentRun = runtime.run
        current = sessions[current.id] ?? current
        current.currentRun = nil
        sessions[current.id] = current
        sessions[destination.id] = destination
        runtime.activeSessionID = destination.id
        runtimes[runID] = runtime
        await events.publish(
            sessionID: current.id, change: .runDetached(runID)
        )
        await events.publish(
            sessionID: destination.id, change: .conversationIdentity(conversationID)
        )
        await events.publish(
            sessionID: destination.id, change: .runStarted(runID)
        )
        return destination.id
    }


    public func markProviderUsed(runID: UUID, at date: Date = Date()) async throws {
        guard let runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        if let catalog {
            try await catalog.markUsed(
                sessionID: runtime.activeSessionID, at: date, reactivate: true
            )
        }
    }

    /// Every live process in every scope this supervisor holds, run hosts and
    /// launchd-started service instances included, for resource accounting.
    public func liveScopeMembers() throws -> [RunScopeMember] {
        try RunScopeTable.members(coalitionIDs: Array(liveScopes.keys)).values.joined()
            .filter { !$0.zombie }
    }

    /// Every live forked process in the run scope of the session's current
    /// run, across all runs sharing that scope (a Codex TUI and its server).
    /// Nil when runs are not scoped. Automatic idle must treat any of them as
    /// possible background work.
    public func scopeWork(sessionID: UUID) throws -> [ProcessRecord]? {
        guard let runID = sessions[sessionID]?.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        guard let scope = runtimes[runID]?.scope else { return nil }
        let forked = Set(try scope.forkedMembers().map(\.identity))
        return try ProcessTable.snapshot().filter { forked.contains($0.identity) && !$0.zombie }
    }

    @discardableResult
    public func sample(sessionID: UUID) throws -> [ProcessRecord] {
        guard let session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard let runID = session.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        return try sample(runID: runID)
    }

    /// Stops exactly one managed run: its own processes, or its whole run scope
    /// when it is the scope's last run.
    public func stop(sessionID: UUID, graceSeconds: Double = 0.2) async throws -> SessionStopReport {
        guard !shutdownInProgress else { throw SessionManagementError.shutdownStarted }
        guard let session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard let runID = session.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        return await stop(sessionID: sessionID, runID: runID, graceSeconds: graceSeconds,
                          endReason: .requested)
    }

    /// The lifecycle controller uses a distinct durable reason so an automatic
    /// idle transition cannot be confused with an explicit user stop.
    public func stopForIdle(
        sessionID: UUID, graceSeconds: Double = 0.2
    ) async throws -> SessionStopReport {
        guard !shutdownInProgress else { throw SessionManagementError.shutdownStarted }
        guard let session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard let runID = session.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        return await stop(
            sessionID: sessionID, runID: runID, graceSeconds: graceSeconds,
            endReason: .idle
        )
    }

    /// Applies one app-wide signal schedule, then records completion separately
    /// for every run. The ownership sweep also catches escaped marked processes.
    public func shutdown(graceSeconds: Double = 0.2,
                         pendingOperationGraceSeconds: Double = 2.1) async -> ShutdownReport {
        if shutdownInProgress {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.02, pendingOperationGraceSeconds)
            while shutdownInProgress, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            if !shutdownInProgress, let lastShutdownReport { return lastShutdownReport }
            return ShutdownReport(remainingCountVerified: false,
                elapsedSeconds: 0, signals: [], remaining: [],
                errors: ["Timed out waiting for the active shutdown"], outsideOwnership: [],
                ownershipGuarantee: ownershipGuarantee)
        }
        shutdownInProgress = true
        defer { shutdownInProgress = false }
        let report = await performShutdown(graceSeconds: graceSeconds,
                                           pendingOperationGraceSeconds: pendingOperationGraceSeconds)
        lastShutdownReport = report
        return report
    }

    private func performShutdown(graceSeconds: Double,
                                 pendingOperationGraceSeconds: Double) async -> ShutdownReport {
        stopping = true
        for job in environmentJobs.values { job.cancel() }
        let start = Date()
        var attempts: [SignalAttempt] = []
        var errors: [String] = []
        // Actor methods are reentrant while catalog writes are awaited. Let any
        // create/launch that began before shutdown publish (or fail) first, so
        // its process cannot appear after the active-run snapshot below.
        let pendingDeadline = ProcessInfo.processInfo.systemUptime
            + max(0.02, pendingOperationGraceSeconds)
        while (!reservedSessions.isEmpty || !environmentJobs.isEmpty || !transitioningRuns.isEmpty || !stoppingRuns.isEmpty),
              ProcessInfo.processInfo.systemUptime < pendingDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !reservedSessions.isEmpty || !environmentJobs.isEmpty {
            errors.append(
                "Timed out waiting for pending operations; sessions=\(reservedSessions.map(\.uuidString).sorted()), environmentJobs=\(environmentJobs.count)"
            )
        }
        if !transitioningRuns.isEmpty || !stoppingRuns.isEmpty {
            if !transitioningRuns.isEmpty {
                errors.append("Timed out waiting for conversation transitions: \(transitioningRuns.count)")
            }
            if !stoppingRuns.isEmpty { errors.append("Timed out waiting for active stops: \(stoppingRuns.count)") }
            // The in-flight catalog transaction owns this run until commit.
            // Leave it live for a verified retry instead of racing its commit.
            var remaining: [ProcessRecord] = []
            var countVerified = true
            for runID in runtimes.keys {
                do { remaining += try sample(runID: runID) }
                catch { countVerified = false; errors.append(String(describing: error)) }
            }
            return ShutdownReport(remainingCountVerified: countVerified,
                elapsedSeconds: Date().timeIntervalSince(start), signals: [],
                remaining: remaining, errors: errors,
                outsideOwnership: outsideOwnership,
                ownershipGuarantee: ownershipGuarantee
            )
        }
        LaunchEnvironment.forget(runID: ownershipRunID)

        let active = sessions.values.compactMap { session in
            session.currentRun.map { (session.id, $0.id) }
        }
        var sessionIdentities: [UUID: Set<ProcessIdentity>] = [:]
        var sessionErrors: [UUID: [String]] = [:]
        let shutdownSnapshot: [ProcessRecord]?
        do { shutdownSnapshot = try ProcessTable.snapshot() }
        catch {
            shutdownSnapshot = nil
            errors.append(String(describing: error))
        }
        for (sessionID, runID) in active {
            do {
                if let shutdownSnapshot {
                    _ = try sample(runID: runID, snapshot: shutdownSnapshot)
                }
                sessionIdentities[runID] = runtimes[runID]?.run.descendants ?? []
            } catch {
                sessionErrors[runID, default: []].append(String(describing: error))
            }
            if var runtime = runtimes[runID] {
                runtime.run.state = .stopping
                runtimes[runID] = runtime
                if var session = sessions[sessionID] {
                    session.currentRun = runtime.run
                    sessions[sessionID] = session
                }
                stoppingRuns.insert(runID)
            }
        }

        // Quit has one app-wide escalation clock. This sends each signal to all
        // owned runs before waiting, instead of paying a full grace window per
        // session. The per-run completion below still retains separate reports.
        let sharedTermination = await terminate(graceSeconds: graceSeconds) {
            try sampleOwnership()
        }
        attempts += sharedTermination.attempts
        errors += sharedTermination.errors
        let remaining = sharedTermination.remaining

        let catalogDeadline = ProcessInfo.processInfo.systemUptime + max(0.02, pendingOperationGraceSeconds)
        let globalDestructionVerified = sharedTermination.countVerified
            && sharedTermination.remaining.isEmpty
            && outsideOwnership.isEmpty
        let reports = await withTaskGroup(of: SessionStopReport.self) { group in
            for (sessionID, runID) in active {
                let owned = sessionIdentities[runID] ?? []
                let runErrors = sessionErrors[runID] ?? []
                let runAttempts = sharedTermination.attempts
                let runRemaining = remaining
                group.addTask {
                    await self.completeShutdownRun(
                        sessionID: sessionID, runID: runID,
                        ownedIdentities: owned,
                        sharedAttempts: runAttempts,
                        sharedRemaining: runRemaining,
                        countVerified: sharedTermination.countVerified,
                        globalDestructionVerified: globalDestructionVerified,
                        catalogDeadline: catalogDeadline,
                        errors: runErrors
                    )
                }
            }
            var reports: [SessionStopReport] = []
            for await report in group { reports.append(report) }
            return reports
        }
        for report in reports {
            errors += report.errors
            if !report.outsideOwnership.isEmpty {
                errors.append("Session \(report.sessionID) has processes outside the current user")
            }
        }
        while !pendingCatalogWrites.isEmpty,
              ProcessInfo.processInfo.systemUptime < catalogDeadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        if !pendingCatalogWrites.isEmpty {
            errors.append(
                "Timed out waiting for catalog writes: \(pendingCatalogWrites.keys.map(\.uuidString).sorted())"
            )
        }
        errors += catalogWriteErrors.values.sorted()
        errors += await releaseIdleScopes()
        if scopeLauncher == nil, let issue = ledger.observationIssue { errors.append(issue) }
        return ShutdownReport(remainingCountVerified: sharedTermination.countVerified,
            elapsedSeconds: Date().timeIntervalSince(start), signals: attempts,
            remaining: remaining, errors: errors,
            outsideOwnership: outsideOwnership,
            ownershipGuarantee: ownershipGuarantee
        )
    }

    private func completeShutdownRun(
        sessionID: UUID, runID: UUID,
        ownedIdentities: Set<ProcessIdentity>,
        sharedAttempts: [SignalAttempt],
        sharedRemaining: [ProcessRecord],
        countVerified: Bool, globalDestructionVerified: Bool, catalogDeadline: Double,
        errors initialErrors: [String]
    ) async -> SessionStopReport {
        let start = Date()
        defer { stoppingRuns.remove(runID) }
        guard let runtime = runtimes[runID] else {
            return settledStopReport(sessionID: sessionID, runID: runID, started: start)
        }
        var errors = initialErrors
        let remaining = sharedRemaining.filter { ownedIdentities.contains($0.identity) }
        let outside = runtime.outsideOwnership
        let signals = sharedAttempts.filter { ownedIdentities.contains($0.identity) }
        if !countVerified { errors.append("Process count unavailable after shutdown") }
        if countVerified && remaining.isEmpty && outside.isEmpty && errors.isEmpty {
            if runtime.stopPhase != .completed, stopHooks[runID] != nil {
                // A closed RPC connection alone is not cleanup authority. Only
                // verified destruction of all owned processes supersedes an
                // unresolved provider hook, including its server-side join.
                if globalDestructionVerified, var latest = runtimes[runID] {
                    latest.stopPhase = .completed
                    runtimes[runID] = latest
                    stopHooks[runID] = nil
                } else { errors.append("Provider cleanup requires verified app-wide process destruction") }
            }
            if errors.isEmpty {
                errors += await finishStoppedRunResources(runID: runID, reason: .applicationQuit,
                                                           catalogDeadline: catalogDeadline)
            }
            if errors.isEmpty { await releaseFinalizedRun(runID: runID, reason: .applicationQuit) }
        }
        let report = SessionStopReport(remainingCountVerified: countVerified,
            sessionID: sessionID, runID: runID,
            elapsedSeconds: Date().timeIntervalSince(start), signals: signals,
            remaining: remaining, errors: errors, outsideOwnership: outside)
        await recordStopReport(report)
        return report
    }

    /// Keeps the query-able last report and carries an unverified stop to every
    /// event consumer as part of the session's latest state, so a skipped frame
    /// cannot hide it.
    private func recordStopReport(_ report: SessionStopReport) async {
        lastStopReports[report.sessionID] = report
        if recentStopDiagnostics.count == 256 { recentStopDiagnostics.removeFirst() }
        recentStopDiagnostics.append(StopDiagnostic(
            sessionID: report.sessionID, runID: report.runID,
            providerStages: report.providerStages ?? [],
            remainingCount: report.remainingCountVerified == false ? nil : report.remaining.count,
            succeeded: report.succeeded
        ))
        var summary: String?
        if !report.succeeded {
            var parts: [String] = []
            if !report.remaining.isEmpty { parts.append("\(report.remaining.count) process(es) still running") }
            if !report.outsideOwnership.isEmpty {
                parts.append("\(report.outsideOwnership.count) process(es) outside verified ownership")
            }
            if let first = report.errors.first { parts.append(first) }
            summary = "Stop could not be verified: " + parts.joined(separator: "; ")
        }
        await events.publish(sessionID: report.sessionID, change: .stopFailure(summary))
    }

    private func sample(runID: UUID) throws -> [ProcessRecord] {
        try sample(runID: runID, snapshot: ProcessTable.snapshot())
    }

    private func sample(
        runID: UUID, snapshot: [ProcessRecord]
    ) throws -> [ProcessRecord] {
        try ownershipSamplingFailpoint?()
        guard var runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        let byPID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.identity.pid, $0) })
        let live = Set(snapshot.map(\.identity))
        runtime.run.descendants.formIntersection(live)
        markerInspected.formIntersection(live)
        managedRunMarkers = managedRunMarkers.filter { live.contains($0.key) }

        var selected = runtime.run.descendants
        let leaderIsLive = live.contains(runtime.run.leader)
        let liveSessionMember = snapshot.contains {
            $0.sessionID == runtime.run.leader.pid && selected.contains($0.identity)
        }
        if leaderIsLive || liveSessionMember {
            selected.formUnion(snapshot.filter { $0.sessionID == runtime.run.leader.pid }.map(\.identity))
        }

        var newMarkers: [ProcessIdentity: UUID] = [:]
        for record in snapshot where record.identity.pid != getpid()
            && !markerInspected.contains(record.identity) {
            markerInspected.insert(record.identity)
            if let value = ProcessTable.managedRunID(pid: record.identity.pid),
               let marker = UUID(uuidString: value) {
                newMarkers[record.identity] = marker
            }
        }
        // Environment lookup accepts a bare PID. Confirm the identity after the
        // lookup before allowing it to seed an ancestry walk.
        if !newMarkers.isEmpty {
            let confirmation = Set(try ProcessTable.snapshot().map(\.identity))
            newMarkers = newMarkers.filter { confirmation.contains($0.key) }
            managedRunMarkers.merge(newMarkers) { _, newest in newest }
        }
        selected.formUnion(managedRunMarkers.compactMap { $0.value == runID ? $0.key : nil })

        var changed = true
        while changed {
            changed = false
            for record in snapshot where !selected.contains(record.identity) {
                if let parent = byPID[record.parentPID], selected.contains(parent.identity) {
                    selected.insert(record.identity)
                    changed = true
                }
            }
        }
        if let scope = runtime.scope {
            // Session, markers and parent links only tell runs of one scope
            // apart. They never extend ownership: a debugger's tracee or a
            // marked process elsewhere is not in this coalition.
            let forked = Set(try scope.forkedMembers().map(\.identity))
            selected.formIntersection(forked)
            // The scope's last run owns everything forked inside it,
            // including detached work the other views cannot see.
            if scopeRuns[scope.coalitionID] == [runID] { selected.formUnion(forked.intersection(live)) }
        }

        runtime.run.descendants = selected
        runtime.outsideOwnership = snapshot.filter {
            selected.contains($0.identity) && $0.userID != getuid()
        }
        runtimes[runID] = runtime
        if var session = sessions[runtime.activeSessionID] {
            session.currentRun = runtime.run
            sessions[runtime.activeSessionID] = session
        }
        return snapshot.filter { selected.contains($0.identity) && $0.userID == getuid() }
    }

    private func settledStopReport(sessionID: UUID, runID: UUID, started: Date) -> SessionStopReport {
        if let report = lastStopReports.values.first(where: { $0.runID == runID }) { return report }
        return SessionStopReport(sessionID: sessionID, runID: runID,
                                 elapsedSeconds: Date().timeIntervalSince(started),
                                 signals: [], remaining: [], errors: ["Managed run not found"], outsideOwnership: [])
    }

    private func stop(sessionID: UUID, runID: UUID, graceSeconds: Double,
                      endReason: ManagedRunEndReason) async -> SessionStopReport {
        let start = Date()
        if stoppingRuns.contains(runID) {
            while stoppingRuns.contains(runID) { try? await Task.sleep(for: .milliseconds(10)) }
            return settledStopReport(sessionID: sessionID, runID: runID, started: start)
        }
        stoppingRuns.insert(runID)
        defer { stoppingRuns.remove(runID) }
        let transitionDeadline = ProcessInfo.processInfo.systemUptime + 2.1
        while transitioningRuns.contains(runID), ProcessInfo.processInfo.systemUptime < transitionDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if transitioningRuns.contains(runID) {
            var errors = ["Timed out waiting for conversation transition before stop"]
            var countVerified = true
            let remaining: [ProcessRecord]
            do { remaining = try sample(runID: runID) }
            catch { remaining = []; countVerified = false; errors.append(String(describing: error)) }
            let report = SessionStopReport(remainingCountVerified: countVerified,
                sessionID: sessionID, runID: runID,
                elapsedSeconds: Date().timeIntervalSince(start), signals: [], remaining: remaining,
                errors: errors, outsideOwnership: runtimes[runID]?.outsideOwnership ?? [])
            await recordStopReport(report)
            return report
        }
        let sessionID = runtimes[runID]?.activeSessionID ?? sessionID
        guard var runtime = runtimes[runID] else {
            return settledStopReport(sessionID: sessionID, runID: runID, started: start)
        }
        var attempts: [SignalAttempt] = []
        var errors: [String] = []
        var remaining: [ProcessRecord] = []
        var providerStages: [ProviderStopStage] = []
        if endReason == .idle, !providerWorkStateIsReliable(runID: runID) {
            let report = automaticStopReliabilityFailure(sessionID: sessionID, runID: runID, start: start)
            await recordStopReport(report)
            return report
        }
        if runtime.stopPhase == .unprepared {
            if let hooks = stopHooks[runID] {
                do {
                    try await hooks.prepare()
                    providerStages.append(ProviderStopStage(stage: "prepare", threadID: hooks.threadID))
                } catch is ProviderUnavailableError {
                    // Nothing provider-side can still produce work; process
                    // destruction below is the only authority left.
                    providerStages.append(ProviderStopStage(stage: "prepare-provider-gone", threadID: hooks.threadID))
                } catch {
                    let stage = ProviderStopStage(stage: "prepare", threadID: hooks.threadID, error: error)
                    var failures = [stage.failureDescription]
                    var countVerified = true
                    do { remaining = try sample(runID: runID) }
                    catch { countVerified = false; failures.append("Process count unavailable after provider preparation failed") }
                    let report = SessionStopReport(remainingCountVerified: countVerified,
                        providerStages: [stage], sessionID: sessionID, runID: runID,
                        elapsedSeconds: Date().timeIntervalSince(start), signals: [], remaining: remaining,
                        errors: failures, outsideOwnership: [])
                    await recordStopReport(report)
                    return report
                }
            }
            guard let latest = runtimes[runID] else {
                return settledStopReport(sessionID: sessionID, runID: runID, started: start)
            }
            runtime = latest
        }
        if endReason == .idle, !providerWorkStateIsReliable(runID: runID) {
            let report = automaticStopReliabilityFailure(sessionID: sessionID, runID: runID, start: start)
            await recordStopReport(report)
            return report
        }
        do { remaining = try sample(runID: runID) }
        catch { errors.append(String(describing: error)) }
        guard let latest = runtimes[runID] else {
            return settledStopReport(sessionID: sessionID, runID: runID, started: start)
        }
        runtime = latest
        runtime.run.state = .stopping
        runtimes[runID] = runtime
        if var session = sessions[sessionID] {
            session.currentRun = runtime.run
            sessions[sessionID] = session
        }
        let termination = await terminate(graceSeconds: graceSeconds) { try sample(runID: runID) }
        attempts += termination.attempts
        errors += termination.errors
        remaining = termination.remaining
        guard let afterTermination = runtimes[runID] else {
            return settledStopReport(sessionID: sessionID, runID: runID, started: start)
        }
        let outside = afterTermination.outsideOwnership
        if termination.countVerified && remaining.isEmpty && outside.isEmpty {
            // Preparation can become stale while a live TUI produces more work.
            // Only native destruction makes its proof reusable across retries.
            if afterTermination.stopPhase == .unprepared, var updated = runtimes[runID] {
                updated.stopPhase = .prepared
                runtimes[runID] = updated
            }
            if afterTermination.stopPhase != .completed {
                if let hooks = stopHooks[runID] {
                    do {
                        do { try await hooks.completed() }
                        catch is ProviderUnavailableError {
                            // Verified destruction of this run already holds here.
                            providerStages.append(ProviderStopStage(stage: "completed-provider-gone", threadID: hooks.threadID))
                        }
                        providerStages.append(ProviderStopStage(stage: "completed", threadID: hooks.threadID))
                        guard var updated = runtimes[runID] else {
                            return settledStopReport(sessionID: sessionID, runID: runID, started: start)
                        }
                        updated.stopPhase = .completed
                        runtimes[runID] = updated
                        stopHooks[runID] = nil
                    } catch {
                        let stage = ProviderStopStage(stage: "completed", threadID: hooks.threadID, error: error)
                        providerStages.append(stage)
                        errors.append(stage.failureDescription)
                        guard var updated = runtimes[runID] else {
                            return settledStopReport(sessionID: sessionID, runID: runID, started: start)
                        }
                        updated.stopPhase = .completionPending
                        runtimes[runID] = updated
                    }
                } else if var updated = runtimes[runID] {
                    updated.stopPhase = .completed
                    runtimes[runID] = updated
                }
            }
            if errors.isEmpty {
                errors += await finishStoppedRunResources(runID: runID, reason: endReason,
                    catalogDeadline: ProcessInfo.processInfo.systemUptime + 2.1)
            }
            if errors.isEmpty { await releaseFinalizedRun(runID: runID, reason: endReason) }
        }
        let report = SessionStopReport(remainingCountVerified: termination.countVerified,
            providerStages: providerStages, sessionID: sessionID, runID: runID,
            elapsedSeconds: Date().timeIntervalSince(start), signals: attempts,
            remaining: remaining, errors: errors, outsideOwnership: outside)
        await recordStopReport(report)
        return report
    }

    private func finishStoppedRunResources(runID: UUID, reason: ManagedRunEndReason,
                                            catalogDeadline: Double) async -> [String] {
        guard let runtime = runtimes[runID] else { return ["Managed run not found during finalization"] }
        let exitStatus: Int32?
        do { exitStatus = try await runtime.terminal.finish() }
        catch { return [String(describing: error)] }
        // The host must still report the leader's exit above; only then may it
        // go. A scope that cannot be shown empty keeps the run for a retry.
        if let scope = runtime.scope, scopeRuns[scope.coalitionID] == [runID] {
            let scopeErrors = await releaseScope(scope, finishingRun: runID)
            if !scopeErrors.isEmpty { return scopeErrors }
        }
        guard let latest = runtimes[runID] else { return ["Managed run not found during finalization"] }
        if latest.catalogStarted {
            queueCatalogFinish(runID: runID, reason: reason, exitStatus: exitStatus)
            return await awaitCatalogFinish(runID: runID, deadline: catalogDeadline)
        }
        return []
    }

    private func awaitCatalogFinish(runID: UUID, deadline: Double) async -> [String] {
        while pendingCatalogWrites[runID] != nil, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        if pendingCatalogWrites[runID] != nil { return ["Timed out waiting for catalog run \(runID)"] }
        if let error = catalogWriteErrors.removeValue(forKey: runID) { return [error] }
        return []
    }

    private func releaseFinalizedRun(runID: UUID, reason: ManagedRunEndReason) async {
        guard let runtime = runtimes.removeValue(forKey: runID) else { return }
        if let scope = runtime.scope { scopeRuns[scope.coalitionID]?.remove(runID) }
        identityStates[runID] = nil
        workStates[runID] = nil
        clearProviderWorkInvalidation(runID: runID)
        stopHooks[runID] = nil
        if var session = sessions[runtime.activeSessionID], session.currentRun?.id == runID {
            session.currentRun = nil
            sessions[runtime.activeSessionID] = session
        }
        await events.publish(sessionID: runtime.activeSessionID, change: .runEnded(runID, reason))
    }

    private func automaticStopReliabilityFailure(sessionID: UUID, runID: UUID, start: Date) -> SessionStopReport {
        var errors = ["Automatic stop refused: provider hook delivery is unreliable"]
        var countVerified = true
        let remaining: [ProcessRecord]
        do { remaining = try sample(runID: runID) }
        catch { remaining = []; countVerified = false; errors.append(String(describing: error)) }
        return SessionStopReport(remainingCountVerified: countVerified, sessionID: sessionID, runID: runID,
            elapsedSeconds: Date().timeIntervalSince(start), signals: [], remaining: remaining,
            errors: errors, outsideOwnership: runtimes[runID]?.outsideOwnership ?? [])
    }

    /// The one escalation loop for both a session stop and the final app-wide
    /// recovery sweep. The caller supplies only the ownership scope.
    private func terminate(
        graceSeconds: Double,
        sample: () throws -> [ProcessRecord]
    ) async -> (attempts: [SignalAttempt], remaining: [ProcessRecord], errors: [String], countVerified: Bool) {
        var attempts: [SignalAttempt] = []
        var errors: [String] = []
        var remaining: [ProcessRecord] = []
        var countVerified = false
        for signal in [SIGHUP, SIGTERM, SIGKILL] {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.02, graceSeconds)
            var signaled: Set<ProcessIdentity> = []
            repeat {
                do {
                    remaining = try sample()
                    countVerified = true
                    if signal == SIGKILL {
                        // Freeze first so no owned process can fork between this
                        // sample and its kill; reused PIDs fail the identity check.
                        for record in remaining where !record.zombie && !signaled.contains(record.identity) {
                            try? ProcessTable.signal(record.identity, SIGSTOP)
                        }
                    }
                    for record in remaining where !record.zombie
                        && !signaled.contains(record.identity) {
                        do {
                            try ProcessTable.signal(record.identity, signal)
                            attempts.append(SignalAttempt(
                                identity: record.identity, signal: signal
                            ))
                            signaled.insert(record.identity)
                        } catch {
                            errors.append(String(describing: error))
                        }
                    }
                } catch {
                    countVerified = false
                    errors.append(String(describing: error))
                    break
                }
                if remaining.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(10))
            } while ProcessInfo.processInfo.systemUptime < deadline
            if remaining.isEmpty { break }
        }
        // SIGKILL is asynchronous. Give killed processes a bounded chance to
        // exit and be reaped before deciding whether live work remains.
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 1.5
        while remaining.contains(where: { !$0.zombie }),
              ProcessInfo.processInfo.systemUptime < reapDeadline {
            try? await Task.sleep(for: .milliseconds(10))
            do { remaining = try sample(); countVerified = true }
            catch {
                countVerified = false
                errors.append(String(describing: error))
                break
            }
        }
        do { remaining = try sample().filter { !$0.zombie }; countVerified = true }
        catch { countVerified = false; errors.append(String(describing: error)) }
        return (attempts, remaining, errors, countVerified)
    }

    @discardableResult
    private func sampleOwnership() throws -> [ProcessRecord] {
        try ownershipSamplingFailpoint?()
        let snapshot = try ProcessTable.snapshot()
        let scoped = Set(try RunScopeTable.members(coalitionIDs: ledger.currentBootScopes().map(\.coalitionID))
            .values.joined().filter { !$0.launchdSpawned && !$0.zombie }.map(\.identity))
        if scopeLauncher != nil {
            // Loom signals only forked members of its own scopes.
            outsideScopes = snapshot.filter { scoped.contains($0.identity) && $0.userID != getuid() }
            return snapshot.filter { scoped.contains($0.identity) && $0.userID == getuid() }
        }
        // Narrowed mode (tests, probe): the legacy ledger, plus any scopes a
        // recovered app ledger recorded.
        let before = ledger
        var records = ledger.observe(snapshot)
        if ledger != before { try persistLedger() }
        let known = Set(records.map(\.identity))
        records += snapshot.filter {
            scoped.contains($0.identity) && !known.contains($0.identity) && $0.userID == getuid()
        }
        return records
    }

    private var outsideOwnership: [ProcessRecord] {
        scopeLauncher != nil ? outsideScopes : (ledger.outsideOwnership ?? [])
    }

    private var ownershipGuarantee: String {
        if scopeLauncher != nil {
            return "Run-scoped ownership: each run's resource coalition is stopped and verified empty; work handed to launchd or LaunchServices is outside it."
        }
        // Tests and the probe only: no run scopes, so detached unmarked work
        // that was never observed may survive.
        return ledger.observationIssue
            ?? "Narrowed ownership: session, observed ancestry and readable run markers only; unobserved unmarked escapes may remain."
    }

    /// Scopes without a live run at Quit: ones whose launch failed after the
    /// scope opened, and scopes recorded by a previous Loom in this boot. Their
    /// forked work was already stopped by the app-wide termination above.
    private func releaseIdleScopes() async -> [String] {
        var errors: [String] = []
        for scope in liveScopes.values where (scopeRuns[scope.coalitionID] ?? []).isEmpty {
            errors += await releaseScope(scope)
        }
        let live = Set(liveScopes.keys)
        let boot = ProcessTable.bootSessionID()
        for record in ledger.scopes ?? [] where !live.contains(record.coalitionID) {
            if record.bootSessionID == boot {
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                var members: [RunScopeMember] = []
                repeat {
                    do { members = try RunScopeTable.members(coalitionID: record.coalitionID).filter { !$0.zombie } }
                    catch { errors.append(String(describing: error)); break }
                    if members.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(20))
                } while ProcessInfo.processInfo.systemUptime < deadline
                guard members.isEmpty else {
                    errors.append("Recovered run scope \(record.coalitionID) is not empty: \(members.count) process(es)")
                    continue
                }
            }
            ledger.remove(scope: record)
        }
        do { try persistLedger() } catch { errors.append(String(describing: error)) }
        return errors
    }

    /// True when runs start in LaunchServices run scopes (the app); false in
    /// narrowed test supervisors, where `openScope` is unavailable.
    public nonisolated var runScopesEnabled: Bool { scopeLauncherConfigured }

    /// Opens a run scope and records it durably before anything is spawned in
    /// it. Codex uses one scope for its per-session server and TUI.
    public func openScope() async throws -> RunScope {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard let scopeLauncher else {
            throw RunScopeError.hostUnavailable("run scopes are not configured")
        }
        let scope = try await scopeLauncher.launch()
        liveScopes[scope.coalitionID] = scope
        ledger.register(scope: scope.record)
        do { try persistLedger() }
        catch {
            _ = await releaseScope(scope)
            throw error
        }
        return scope
    }

    /// Ends a scope with no remaining runs; see RunScope.release.
    public func releaseScope(_ scope: RunScope) async -> [String] {
        await releaseScope(scope, finishingRun: nil)
    }

    private func releaseScope(_ scope: RunScope, finishingRun: UUID?) async -> [String] {
        let others = (scopeRuns[scope.coalitionID] ?? []).subtracting(finishingRun.map { [$0] } ?? [])
        guard others.isEmpty else {
            return ["Run scope \(scope.coalitionID) still has \(others.count) run(s)"]
        }
        releasingScopes.insert(scope.coalitionID)
        defer { releasingScopes.remove(scope.coalitionID) }
        let errors = await scope.release()
        guard errors.isEmpty else { return errors }
        liveScopes[scope.coalitionID] = nil
        scopeRuns[scope.coalitionID] = nil
        ledger.remove(scope: scope.record)
        do { try persistLedger() } catch { return [String(describing: error)] }
        return []
    }

    private func spawnInScope(
        _ scope: RunScope, executable: String, arguments: [String],
        environment: [String: String], directory: String, rows: UInt16, columns: UInt16
    ) async throws -> PTYProcess {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard loom_open_pty(rows, columns, &master, &slave) == 0 else {
            throw LoomError.system("PTY open", errno)
        }
        defer { Darwin.close(slave) }
        do {
            let pid = try await scope.spawn(
                executable: executable, arguments: arguments, environment: environment,
                directory: directory, stdio: .terminal(slave: slave)
            )
            return PTYProcess(adoptingPID: pid, masterFD: master)
        } catch {
            Darwin.close(master)
            throw error
        }
    }

    /// A spawned leader that never became a run. Its scope is checked: a scope
    /// created for it is drained; a shared one loses only that process.
    private func abandonUnregistered(_ process: PTYProcess, scope: RunScope?, ownsNewScope: Bool) async {
        guard let scope else {
            process.terminateUnregisteredChild()
            return
        }
        process.closeTerminal()
        if ownsNewScope {
            _ = loom_kill_scope_forked_members(scope.coalitionID, 0, 2)
            _ = await releaseScope(scope)
        } else if let member = RunScopeTable.lineage(pid: process.pid),
                  member.identity.pid == process.pid, !member.launchdSpawned {
            try? RunScopeTable.signal(member, coalitionID: scope.coalitionID, SIGKILL)
        }
    }

    private func persistLedger() throws {
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    private func recordLeaderExit(runID: UUID, status: Int32?) async {
        guard var runtime = runtimes[runID] else { return }
        runtime.run.exitStatus = status
        if runtime.run.state == .running { runtime.run.state = .exited }
        runtimes[runID] = runtime
        if var session = sessions[runtime.activeSessionID], session.currentRun?.id == runID {
            session.currentRun = runtime.run
            sessions[runtime.activeSessionID] = session
        }
        // A user/global finalizer owns this run; a real exit only supplies its
        // status and must not consume a failed cleanup's explicit retry.
        guard !shutdownInProgress, !stoppingRuns.contains(runID), runtime.run.state != .stopping else { return }
        let reason: ManagedRunEndReason = stopping ? .applicationQuit : .processExited
        _ = await stop(sessionID: runtime.activeSessionID, runID: runID,
                       graceSeconds: 0.2, endReason: reason)
    }

    private func queueCatalogFinish(
        runID: UUID, reason: ManagedRunEndReason, exitStatus: Int32?
    ) {
        guard let catalog, pendingCatalogWrites[runID] == nil else { return }
        pendingCatalogWrites[runID] = Task { [weak self] in
            let completionError: String?
            do {
                try await catalog.finishRun(
                    runID, reason: reason, exitStatus: exitStatus
                )
                completionError = nil
            } catch let caughtError {
                completionError = String(describing: caughtError)
            }
            await self?.catalogWriteCompleted(runID: runID, error: completionError)
        }
    }

    private func catalogWriteCompleted(runID: UUID, error: String?) {
        pendingCatalogWrites[runID] = nil
        // Only a fresh durable success clears a prior write failure.
        catalogWriteErrors[runID] = error
    }

    private func restoreCatalogSessions() async throws {
        guard let catalog else { return }
        let records = try await catalog.sessions()
        for record in records {
            var session = record.session
            session.currentRun = nil
            sessions[session.id] = session
        }
    }
}
