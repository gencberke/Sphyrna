import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

/// Actor-isolated CP2 lifecycle entry point. It owns terminal objects and exposes
/// value snapshots, so process and PTY work never needs to execute on MainActor.
public actor ProcessSupervisor {
    public nonisolated let ownershipRunID: UUID
    public nonisolated let events: SessionEventHub

    enum StopPhase { case unprepared, prepared, completionPending, completed }

    struct Runtime {
        let launchSessionID: UUID
        var activeSessionID: UUID
        var run: ManagedRun
        var terminal: TerminalEndpoint
        var outsideOwnership: [ProcessRecord]
        var catalogStarted: Bool
        var stopPhase: StopPhase = .unprepared
        var scope: RunScope? = nil
    }

    var ledger: OwnershipLedger
    let ledgerURL: URL?
    /// When set, every run starts inside a LaunchServices run host's fresh
    /// resource coalition. Without it (tests only) ownership is narrowed.
    let scopeLauncher: RunScopeLauncher?
    nonisolated let scopeLauncherConfigured: Bool
    var liveScopes: [UInt64: RunScope] = [:]
    var releasingScopes: Set<UInt64> = []
    /// Scoped processes of another UID: Loom cannot stop them, so a stop or
    /// Quit that finds one is reported as unverified, never as success.
    var outsideScopes: [ProcessRecord] = []
    var environmentScope: RunScope?
    /// Environment jobs currently using each scope; the scope is only ever
    /// released when this reaches zero.
    var environmentScopeJobs: [UInt64: Int] = [:]
    var scopeRuns: [UInt64: Set<UUID>] = [:]
    let catalog: SessionCatalog?
    var sessions: [UUID: ManagedSession] = [:]
    /// Provider conversation ids (lowercase) of conversations deleted in this process.
    /// A late provider event naming one must not recreate the conversation; the set
    /// lives as long as the supervisor and is bounded by what the user deleted.
    var deletedProviderIDs: Set<String> = []
    private var internalSessionIDs: Set<UUID> = []
    var runtimes: [UUID: Runtime] = [:]
    var reservedSessions: Set<UUID> = []
    var markerInspected: Set<ProcessIdentity> = []
    var managedRunMarkers: [ProcessIdentity: UUID] = [:]
    var stoppingRuns: Set<UUID> = []
    var stopHooks: [UUID: ManagedRunStopHooks] = [:]
    var identityStates: [UUID: SessionIdentityState] = [:]
    var recentStopDiagnostics: [StopDiagnostic] = []
    var lastStopReports: [UUID: SessionStopReport] = [:]
    var pendingCatalogWrites: [UUID: Task<Void, Never>] = [:]
    var catalogWriteErrors: [UUID: String] = [:]
    var environmentJobs: [UUID: EnvironmentResolutionJob] = [:]
    var workStates: [UUID: ProviderWorkState] = [:]
    /// Ingress can monotonically invalidate a run even while its actor consumer
    /// is paused. This flag has no alternate mutable provider-state authority.
    private nonisolated let unreliableProviderRuns = Mutex<Set<UUID>>([])
    /// A transition retains run ownership until durable commit and publication.
    var transitioningRuns: Set<UUID> = []
    var stopping = false
    var shutdownInProgress = false
    var lastShutdownReport: ShutdownReport?
    var ownershipSamplingFailpoint: (@Sendable () throws -> Void)?

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

    /// `title` is an automatic title (a later rename wins); `ticketKey` and `openedBy` are set for a
    /// session an agent asked Loom to open (D-40).
    public func createSession(_ session: ManagedSession, projectID: UUID? = nil, title: String? = nil,
                              ticketKey: String? = nil, openedBy: UUID? = nil) async throws {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard sessions[session.id] == nil, !reservedSessions.contains(session.id) else {
            throw SessionManagementError.sessionAlreadyExists(session.id)
        }
        reservedSessions.insert(session.id)
        defer { reservedSessions.remove(session.id) }
        if let catalog {
            try await catalog.insertSession(
                session, title: title.flatMap { SessionCatalog.normalizedTitle($0) },
                projectID: projectID, ticketKey: ticketKey, openedBy: openedBy
            )
        }
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

    /// Forgets a deleted conversation: its in-memory entry and last stop report go, and its
    /// provider ids are fenced for the life of this supervisor (`deletedProviderIDs`). Refused
    /// while it owns a run. Absent is not an error (a recovered deletion has no entry).
    func discardSession(_ sessionID: UUID, providerIDs: [String]) throws {
        if let session = sessions[sessionID], session.currentRun != nil || reservedSessions.contains(sessionID) {
            throw SessionManagementError.sessionAlreadyRunning(sessionID)
        }
        guard !internalSessionIDs.contains(sessionID) else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        for id in providerIDs { deletedProviderIDs.insert(id.lowercased()) }
        sessions[sessionID] = nil
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
        // A conversation being deleted never starts a process, not even one the catalog would
        // refuse right after the spawn. Checked once the id is reserved, so a concurrent launch
        // is rejected without waiting for the catalog.
        if let catalog, !internalSessionIDs.contains(sessionID),
           try await catalog.isDeletionPending(sessionID) {
            throw SessionManagementError.deletionPending(sessionID)
        }
        guard !stopping else { throw SessionManagementError.shutdownStarted }

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
        // Run scopes own membership, so the leader alone is read; only the
        // unscoped ledger needs the whole table.
        var snapshot: [ProcessRecord] = []
        let leaderRecord: ProcessRecord?
        if scopeLauncher == nil {
            do { snapshot = try ProcessTable.snapshot() }
            catch {
                await abandonUnregistered(process, scope: scope, ownsNewScope: ownsNewScope)
                throw error
            }
            leaderRecord = snapshot.first(where: { $0.identity.pid == process.pid })
        } else {
            leaderRecord = ProcessTable.record(pid: process.pid)
        }
        guard let leader = leaderRecord else {
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
        // Neither a pending deletion nor one finished in this process may get a
        // row back from a late event that names its provider conversation.
        if deletedProviderIDs.contains(conversationID.lowercased()) {
            throw SessionManagementError.conversationBeingDeleted(provider: provider)
        }
        if let catalog, try await catalog.isProviderIDPendingDeletion(conversationID) {
            throw SessionManagementError.conversationBeingDeleted(provider: provider)
        }
        guard runtimes[runID] != nil else { throw SessionManagementError.runNotFound(runID) }
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


    /// A finished turn: real use that is not a prompt. Moves the activity time
    /// and the use time without changing the lifecycle.
    public func markProviderActivity(runID: UUID, at date: Date = Date()) async throws {
        guard let runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        if let catalog {
            try await catalog.markActivity(sessionID: runtime.activeSessionID, at: date)
            await events.publishActivity(sessionID: runtime.activeSessionID)
        }
    }

    public func markProviderUsed(runID: UUID, at date: Date = Date()) async throws {
        guard let runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        if let catalog {
            try await catalog.markUsed(
                sessionID: runtime.activeSessionID, at: date, reactivate: true
            )
            await events.publishActivity(sessionID: runtime.activeSessionID)
        }
    }
}
