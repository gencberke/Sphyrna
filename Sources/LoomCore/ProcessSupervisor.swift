import Darwin
import Foundation

/// Actor-isolated CP2 lifecycle entry point. It owns terminal objects and exposes
/// value snapshots, so process and PTY work never needs to execute on MainActor.
public actor ProcessSupervisor {
    public nonisolated let ownershipRunID: UUID

    private struct Runtime {
        var sessionID: UUID
        var run: ManagedRun
        var terminal: TerminalEndpoint
        var outsideOwnership: [ProcessRecord]
        var catalogStarted: Bool
    }

    private var ledger: OwnershipLedger
    private let ledgerURL: URL?
    private let catalog: SessionCatalog?
    private var sessions: [UUID: ManagedSession] = [:]
    private var runtimes: [UUID: Runtime] = [:]
    private var reservedSessions: Set<UUID> = []
    private var markerInspected: Set<ProcessIdentity> = []
    private var managedRunMarkers: [ProcessIdentity: UUID] = [:]
    private var stoppingRuns: Set<UUID> = []
    private var lastStopReports: [UUID: SessionStopReport] = [:]
    private var pendingCatalogWrites: [UUID: Task<Void, Never>] = [:]
    private var catalogWriteErrors: [UUID: String] = [:]
    private var environmentJobs: [UUID: EnvironmentResolutionJob] = [:]
    private var stopping = false

    public init(ledger: OwnershipLedger = OwnershipLedger(), ledgerURL: URL? = nil,
                catalog: SessionCatalog? = nil) throws {
        self.ledger = ledger
        self.ledgerURL = ledgerURL
        self.catalog = catalog
        ownershipRunID = ledger.runID
        // Persist the owner marker before any managed process can be spawned.
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    /// Bootstrap path for a reopened application. Durable conversations are
    /// restored without reviving their previous OS runs.
    public static func restoring(
        ledger: OwnershipLedger = OwnershipLedger(), ledgerURL: URL? = nil,
        catalog: SessionCatalog
    ) async throws -> ProcessSupervisor {
        let supervisor = try ProcessSupervisor(
            ledger: ledger, ledgerURL: ledgerURL, catalog: catalog
        )
        try await supervisor.restoreCatalogSessions()
        return supervisor
    }

    public func createSession(_ session: ManagedSession) async throws {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard sessions[session.id] == nil, !reservedSessions.contains(session.id) else {
            throw SessionManagementError.sessionAlreadyExists(session.id)
        }
        reservedSessions.insert(session.id)
        defer { reservedSessions.remove(session.id) }
        if let catalog { try await catalog.insertSession(session) }
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        sessions[session.id] = session
    }

    public func session(id: UUID) -> ManagedSession? { sessions[id] }

    public func managedSessions() -> [ManagedSession] {
        sessions.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func lastStopReport(sessionID: UUID) -> SessionStopReport? {
        lastStopReports[sessionID]
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
        try await resolveEnvironment { runID, job in
            try LaunchEnvironment.terminal(
                origin: origin, runID: runID,
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
        try await resolveEnvironment { runID, job in
            try LaunchEnvironment.resolve(
                parent: parent, session: session, testZDOTDIR: testZDOTDIR,
                timeout: timeout, runID: runID,
                onSpawn: job.register, onPoll: job.sample
            )
        }
    }

    private func resolveEnvironment(
        _ operation: @escaping @Sendable (
            UUID, EnvironmentResolutionJob
        ) throws -> LaunchEnvironment.Resolution
    ) async throws -> LaunchEnvironment.Resolution {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        let jobID = UUID()
        let runID = ownershipRunID
        let job = EnvironmentResolutionJob(
            runID: runID, coalition: ledger.coalition ?? .probe(forceFailure: true)
        )
        environmentJobs[jobID] = job
        defer { environmentJobs[jobID] = nil }
        do {
            let result = try await Task.detached {
                try operation(runID, job)
            }.value
            ledger.recordDescendants(Array(job.observedIdentities()))
            _ = try sampleOwnership()
            guard !stopping else { throw SessionManagementError.shutdownStarted }
            return result
        } catch {
            ledger.recordDescendants(Array(job.observedIdentities()))
            _ = try? sampleOwnership()
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
                       outputSink: (any TerminalOutputSink)? = nil) async throws -> ManagedSessionLaunch {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard var session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard session.currentRun == nil, !reservedSessions.contains(sessionID) else {
            throw SessionManagementError.sessionAlreadyRunning(sessionID)
        }
        guard environment["LOOM_RUN_ID"] == ownershipRunID.uuidString,
              environment["LOOM_SESSION_ID"] == sessionID.uuidString else {
            throw SessionManagementError.invalidOwnershipMarkers(sessionID: sessionID)
        }
        reservedSessions.insert(sessionID)
        defer { reservedSessions.remove(sessionID) }

        let runID = UUID()
        var runEnvironment = environment
        runEnvironment["LOOM_MANAGED_RUN_ID"] = runID.uuidString
        let process = try PTYProcess(executable: executable, arguments: arguments,
                                     environment: runEnvironment,
                                     directory: session.workingDirectory,
                                     rows: rows, columns: columns)
        let snapshot: [ProcessRecord]
        do { snapshot = try ProcessTable.snapshot() }
        catch {
            process.terminateUnregisteredChild()
            throw error
        }
        guard let leader = snapshot.first(where: { $0.identity.pid == process.pid }) else {
            process.terminateUnregisteredChild()
            throw SessionManagementError.leaderIdentityUnavailable(process.pid)
        }

        let run = ManagedRun(id: runID, leader: leader.identity, startedAt: Date(),
                             state: .running, exitStatus: nil,
                             descendants: [leader.identity])
        let terminal = TerminalEndpoint(process: process, outputSink: outputSink) { [weak self] status in
            Task { await self?.recordLeaderExit(runID: runID, status: status) }
        }
        session.currentRun = run
        sessions[sessionID] = session
        runtimes[runID] = Runtime(sessionID: sessionID, run: run, terminal: terminal,
                                  outsideOwnership: [], catalogStarted: catalog == nil)
        markerInspected.insert(leader.identity)
        managedRunMarkers[leader.identity] = runID

        // The CP1 ledger remains the app-run recovery and final-shutdown oracle.
        // Per-session stop below deliberately does not use its coalition scope.
        ledger.register(leader.identity)
        _ = ledger.observe(snapshot)
        do { try persistLedger() }
        catch {
            let persistenceError = error
            _ = await stop(sessionID: sessionID, runID: runID, graceSeconds: 0.2,
                           endReason: .requested, waitForCatalog: true)
            throw persistenceError
        }
        if let catalog {
            do { try await catalog.startRun(run, sessionID: sessionID) }
            catch {
                _ = await stop(sessionID: sessionID, runID: runID, graceSeconds: 0.2,
                               endReason: .requested, waitForCatalog: true)
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
                               endReason: .applicationQuit, waitForCatalog: true)
            }
            throw SessionManagementError.shutdownStarted
        }
        return ManagedSessionLaunch(session: sessions[sessionID] ?? session, terminal: terminal)
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

    /// Stops exactly one managed run. Resource coalition membership is app-wide
    /// and is therefore excluded from this selection; final shutdown still uses it.
    public func stop(sessionID: UUID, graceSeconds: Double = 0.2) async throws -> SessionStopReport {
        guard let session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard let runID = session.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        return await stop(sessionID: sessionID, runID: runID, graceSeconds: graceSeconds,
                          endReason: .requested, waitForCatalog: true)
    }

    /// Applies one app-wide signal schedule, then records completion separately
    /// for every run. The ownership sweep also catches escaped marked processes.
    public func shutdown(graceSeconds: Double = 0.2,
                         pendingOperationGraceSeconds: Double = 2.1) async -> ShutdownReport {
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
        while (!reservedSessions.isEmpty || !environmentJobs.isEmpty),
              ProcessInfo.processInfo.systemUptime < pendingDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !reservedSessions.isEmpty || !environmentJobs.isEmpty {
            errors.append(
                "Timed out waiting for pending operations; sessions=\(reservedSessions.map(\.uuidString).sorted()), environmentJobs=\(environmentJobs.count)"
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
        let catalogDeadline = ProcessInfo.processInfo.systemUptime
            + max(0.02, pendingOperationGraceSeconds)
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
        catalogWriteErrors.removeAll()
        if let issue = ledger.observationIssue { errors.append(issue) }
        return ShutdownReport(
            elapsedSeconds: Date().timeIntervalSince(start), signals: attempts,
            remaining: remaining, errors: errors,
            outsideOwnership: ledger.outsideOwnership ?? [],
            ownershipGuarantee: ledger.observationIssue ?? ledger.coalition?.guarantee
                ?? "Narrowed ownership: legacy ledger has no coalition identity."
        )
    }

    private func completeShutdownRun(
        sessionID: UUID, runID: UUID,
        ownedIdentities: Set<ProcessIdentity>,
        sharedAttempts: [SignalAttempt],
        sharedRemaining: [ProcessRecord],
        errors initialErrors: [String]
    ) async -> SessionStopReport {
        let start = Date()
        defer { stoppingRuns.remove(runID) }
        guard let runtime = runtimes[runID] else {
            return SessionStopReport(
                sessionID: sessionID, runID: runID, elapsedSeconds: 0,
                signals: [], remaining: [], errors: initialErrors,
                outsideOwnership: []
            )
        }
        var errors = initialErrors
        let remaining = sharedRemaining.filter { ownedIdentities.contains($0.identity) }
        let outside = runtime.outsideOwnership
        let signals = sharedAttempts.filter { ownedIdentities.contains($0.identity) }
        if remaining.isEmpty && outside.isEmpty {
            var exitStatus = runtime.run.exitStatus
            do { exitStatus = try await runtime.terminal.finish() }
            catch { errors.append(String(describing: error)) }
            if runtimes[runID]?.catalogStarted == true {
                queueCatalogFinish(
                    runID: runID, reason: .applicationQuit, exitStatus: exitStatus
                )
            }
            runtimes[runID] = nil
            if var session = sessions[sessionID], session.currentRun?.id == runID {
                session.currentRun = nil
                sessions[sessionID] = session
            }
        }
        let report = SessionStopReport(
            sessionID: sessionID, runID: runID,
            elapsedSeconds: Date().timeIntervalSince(start), signals: signals,
            remaining: remaining, errors: errors, outsideOwnership: outside
        )
        lastStopReports[sessionID] = report
        return report
    }

    private func sample(runID: UUID) throws -> [ProcessRecord] {
        try sample(runID: runID, snapshot: ProcessTable.snapshot())
    }

    private func sample(
        runID: UUID, snapshot: [ProcessRecord]
    ) throws -> [ProcessRecord] {
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

        runtime.run.descendants = selected
        runtime.outsideOwnership = snapshot.filter {
            selected.contains($0.identity) && $0.userID != getuid()
        }
        runtimes[runID] = runtime
        if var session = sessions[runtime.sessionID] {
            session.currentRun = runtime.run
            sessions[runtime.sessionID] = session
        }
        return snapshot.filter { selected.contains($0.identity) && $0.userID == getuid() }
    }

    private func stop(sessionID: UUID, runID: UUID, graceSeconds: Double,
                      endReason: ManagedRunEndReason,
                      waitForCatalog: Bool) async -> SessionStopReport {
        let start = Date()
        if stoppingRuns.contains(runID) {
            while stoppingRuns.contains(runID) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if runtimes[runID] == nil {
                return SessionStopReport(sessionID: sessionID, runID: runID,
                                         elapsedSeconds: Date().timeIntervalSince(start),
                                         signals: [], remaining: [], errors: [],
                                         outsideOwnership: [])
            }
        }
        stoppingRuns.insert(runID)
        defer { stoppingRuns.remove(runID) }
        guard var runtime = runtimes[runID] else {
            return SessionStopReport(sessionID: sessionID, runID: runID,
                                     elapsedSeconds: 0, signals: [], remaining: [],
                                     errors: ["Managed run not found"], outsideOwnership: [])
        }
        var attempts: [SignalAttempt] = []
        var errors: [String] = []
        var remaining: [ProcessRecord] = []
        // Capture the live OS session before terminal closure can make the leader
        // exit. This preserves descendants whose platform binary hides markers.
        do { remaining = try sample(runID: runID) }
        catch { errors.append(String(describing: error)) }
        runtime = runtimes[runID] ?? runtime
        runtime.run.state = .stopping
        runtimes[runID] = runtime
        if var session = sessions[sessionID] {
            session.currentRun = runtime.run
            sessions[sessionID] = session
        }
        let termination = await terminate(graceSeconds: graceSeconds) {
            try sample(runID: runID)
        }
        attempts += termination.attempts
        errors += termination.errors
        remaining = termination.remaining
        let outside = runtimes[runID]?.outsideOwnership ?? []

        if remaining.isEmpty && outside.isEmpty {
            var exitStatus = runtimes[runID]?.run.exitStatus
            if let terminal = runtimes[runID]?.terminal {
                do { exitStatus = try await terminal.finish() }
                catch { errors.append(String(describing: error)) }
            }
            if runtimes[runID]?.catalogStarted == true {
                queueCatalogFinish(
                    runID: runID, reason: endReason, exitStatus: exitStatus
                )
                if waitForCatalog {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2.1
                    while pendingCatalogWrites[runID] != nil,
                          ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    if pendingCatalogWrites[runID] != nil {
                        errors.append("Timed out waiting for catalog run \(runID)")
                    }
                    if let error = catalogWriteErrors.removeValue(forKey: runID) {
                        errors.append(error)
                    }
                }
            }
            runtimes[runID] = nil
            if var session = sessions[sessionID], session.currentRun?.id == runID {
                session.currentRun = nil
                sessions[sessionID] = session
            }
        }
        let report = SessionStopReport(
            sessionID: sessionID, runID: runID,
            elapsedSeconds: Date().timeIntervalSince(start), signals: attempts,
            remaining: remaining, errors: errors, outsideOwnership: outside
        )
        lastStopReports[sessionID] = report
        return report
    }

    /// The one escalation loop for both a session stop and the final app-wide
    /// recovery sweep. The caller supplies only the ownership scope.
    private func terminate(
        graceSeconds: Double,
        sample: () throws -> [ProcessRecord]
    ) async -> (attempts: [SignalAttempt], remaining: [ProcessRecord], errors: [String]) {
        var attempts: [SignalAttempt] = []
        var errors: [String] = []
        var remaining: [ProcessRecord] = []
        for signal in [SIGHUP, SIGTERM, SIGKILL] {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.02, graceSeconds)
            var signaled: Set<ProcessIdentity> = []
            repeat {
                do {
                    remaining = try sample()
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
                    errors.append(String(describing: error))
                    break
                }
                if remaining.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(10))
            } while ProcessInfo.processInfo.systemUptime < deadline
            if remaining.isEmpty { break }
        }
        do { remaining = try sample() }
        catch { errors.append(String(describing: error)) }
        return (attempts, remaining, errors)
    }

    @discardableResult
    private func sampleOwnership() throws -> [ProcessRecord] {
        let before = ledger
        let snapshot = try ProcessTable.snapshot()
        let records = ledger.observe(snapshot)
        if ledger != before { try persistLedger() }
        return records
    }

    private func persistLedger() throws {
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    private func recordLeaderExit(runID: UUID, status: Int32) async {
        guard var runtime = runtimes[runID] else { return }
        runtime.run.exitStatus = status
        if runtime.run.state == .running { runtime.run.state = .exited }
        runtimes[runID] = runtime
        if var session = sessions[runtime.sessionID], session.currentRun?.id == runID {
            session.currentRun = runtime.run
            sessions[runtime.sessionID] = session
        }
        let reason: ManagedRunEndReason = stopping ? .applicationQuit : .processExited
        _ = await stop(sessionID: runtime.sessionID, runID: runID,
                       graceSeconds: 0.2, endReason: reason, waitForCatalog: true)
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
        if let error { catalogWriteErrors[runID] = error }
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
