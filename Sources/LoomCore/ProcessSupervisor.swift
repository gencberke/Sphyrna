import Darwin
import Foundation

/// Actor-isolated CP2 lifecycle entry point. It owns terminal objects and exposes
/// value snapshots, so process and PTY work never needs to execute on MainActor.
public actor ProcessSupervisor {
    public nonisolated let ownershipRunID: UUID

    private struct Runtime {
        var sessionID: UUID
        var run: ManagedRun
        var process: EventDrivenPTYProcess
        var outsideOwnership: [ProcessRecord]
        var catalogErrors: [String]
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
    private var environmentShell: ProcessIdentity?
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
        sessions[session.id] = session
    }

    public func session(id: UUID) -> ManagedSession? { sessions[id] }

    public func managedSessions() -> [ManagedSession] {
        sessions.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func ledgerSnapshot() -> OwnershipLedger { ledger }

    public func isStopping() -> Bool { stopping }

    /// Resolves the user's terminal environment on the supervisor actor rather
    /// than MainActor. The synchronous resolver remains bounded and its spawned
    /// shell participates in the same ownership ledger.
    public func terminalEnvironment(origin: LaunchEnvironment.LaunchOrigin) throws -> LaunchEnvironment.Resolution {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        defer { environmentShell = nil }
        return try LaunchEnvironment.terminal(
            origin: origin, runID: ownershipRunID,
            onSpawn: registerEnvironmentShell,
            onPoll: { _ = try self.sampleOwnership() }
        )
    }

    /// Launches a new OS run for an existing durable conversation. The caller
    /// provides the app ownership and conversation markers; the supervisor adds
    /// a fresh execution marker that callers cannot accidentally reuse.
    @discardableResult
    public func launch(sessionID: UUID, executable: String, arguments: [String] = [],
                       environment: [String: String], rows: UInt16 = 24,
                       columns: UInt16 = 80) async throws -> ManagedSession {
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
        do {
            if let catalog { try await catalog.startRun(run, sessionID: sessionID) }
        } catch {
            process.terminateUnregisteredChild()
            throw error
        }
        let transport = EventDrivenPTYProcess(process: process) { [weak self] status in
            Task { await self?.recordLeaderExit(runID: runID, status: status) }
        }
        session.currentRun = run
        sessions[sessionID] = session
        runtimes[runID] = Runtime(sessionID: sessionID, run: run, process: transport,
                                  outsideOwnership: [], catalogErrors: [])
        markerInspected.insert(leader.identity)
        managedRunMarkers[leader.identity] = runID

        // The CP1 ledger remains the app-run recovery and final-shutdown oracle.
        // Per-session stop below deliberately does not use its coalition scope.
        ledger.register(leader.identity)
        _ = ledger.observe(snapshot)
        do { try persistLedger() }
        catch {
            let persistenceError = error
            _ = await stop(sessionID: sessionID, runID: runID, graceSeconds: 0.2)
            throw persistenceError
        }
        return session
    }

    public func readAvailable(sessionID: UUID) async throws -> Data {
        try await runtime(for: sessionID).process.drainOutput()
    }

    /// Returns the accepted byte count; callers retain and retry the remainder.
    public func write(_ data: Data, sessionID: UUID) async throws -> Int {
        try await runtime(for: sessionID).process.write(data)
    }

    public func resize(sessionID: UUID, rows: UInt16, columns: UInt16) async throws {
        try await runtime(for: sessionID).process.resize(rows: rows, columns: columns)
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
        return await stop(sessionID: sessionID, runID: runID, graceSeconds: graceSeconds)
    }

    /// Applies the single-session contract to every run, then performs the CP1
    /// app-wide recovery sweep for anything a session-scoped marker could not see.
    public func shutdown(graceSeconds: Double = 0.2) async -> ShutdownReport {
        stopping = true
        // Actor methods are reentrant while catalog writes are awaited. Let any
        // create/launch that began before shutdown publish (or fail) first, so
        // its process cannot appear after the active-run snapshot below.
        while !reservedSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        LaunchEnvironment.forget(runID: ownershipRunID)
        let start = Date()
        var attempts: [SignalAttempt] = []
        var errors: [String] = []

        let active = sessions.values.compactMap { session in
            session.currentRun.map { (session.id, $0.id) }
        }
        for (sessionID, runID) in active {
            let report = await stop(sessionID: sessionID, runID: runID, graceSeconds: graceSeconds)
            attempts += report.signals
            errors += report.errors
            if !report.outsideOwnership.isEmpty {
                errors.append("Session \(sessionID) has processes outside the current user")
            }
        }

        var remaining = (try? sampleOwnership()) ?? []
        for signal in [SIGHUP, SIGTERM, SIGKILL] where !remaining.isEmpty {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.02, graceSeconds)
            var signaled: Set<ProcessIdentity> = []
            repeat {
                do {
                    remaining = try sampleOwnership()
                    for record in remaining where !record.zombie && !signaled.contains(record.identity) {
                        do {
                            try ProcessTable.signal(record.identity, signal)
                            attempts.append(SignalAttempt(identity: record.identity, signal: signal))
                            signaled.insert(record.identity)
                        } catch { errors.append(String(describing: error)) }
                    }
                } catch {
                    errors.append(String(describing: error))
                    break
                }
                if remaining.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(10))
            } while ProcessInfo.processInfo.systemUptime < deadline
        }
        do { remaining = try sampleOwnership() }
        catch { errors.append(String(describing: error)) }
        if let issue = ledger.observationIssue { errors.append(issue) }
        return ShutdownReport(
            elapsedSeconds: Date().timeIntervalSince(start), signals: attempts,
            remaining: remaining, errors: errors,
            outsideOwnership: ledger.outsideOwnership ?? [],
            ownershipGuarantee: ledger.observationIssue ?? ledger.coalition?.guarantee
                ?? "Narrowed ownership: legacy ledger has no coalition identity."
        )
    }

    private func runtime(for sessionID: UUID) throws -> Runtime {
        guard let session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard let runID = session.currentRun?.id, let runtime = runtimes[runID] else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        guard runtime.run.state != .stopping else {
            throw SessionManagementError.sessionStopping(sessionID)
        }
        return runtime
    }

    private func sample(runID: UUID) throws -> [ProcessRecord] {
        guard var runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        let snapshot = try ProcessTable.snapshot()
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

    private func stop(sessionID: UUID, runID: UUID, graceSeconds: Double) async -> SessionStopReport {
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
        await runtime.process.closeTerminal()

        for signal in [SIGHUP, SIGTERM, SIGKILL] {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.02, graceSeconds)
            var signaled: Set<ProcessIdentity> = []
            repeat {
                do {
                    remaining = try sample(runID: runID)
                    for record in remaining where !record.zombie && !signaled.contains(record.identity) {
                        do {
                            try ProcessTable.signal(record.identity, signal)
                            attempts.append(SignalAttempt(identity: record.identity, signal: signal))
                            signaled.insert(record.identity)
                        } catch { errors.append(String(describing: error)) }
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
        do { remaining = try sample(runID: runID) }
        catch { errors.append(String(describing: error)) }
        let outside = runtimes[runID]?.outsideOwnership ?? []

        if remaining.isEmpty && outside.isEmpty {
            var exitStatus = runtimes[runID]?.run.exitStatus
            if let process = runtimes[runID]?.process {
                do { exitStatus = try await process.finish() }
                catch { errors.append(String(describing: error)) }
            }
            if let catalog {
                let reason: ManagedRunEndReason = stopping ? .applicationQuit : .requested
                do { try await catalog.finishRun(runID, reason: reason, exitStatus: exitStatus) }
                catch { errors.append(String(describing: error)) }
            }
            errors += runtimes[runID]?.catalogErrors ?? []
            runtimes[runID] = nil
            if var session = sessions[sessionID], session.currentRun?.id == runID {
                session.currentRun = nil
                sessions[sessionID] = session
            }
        }
        return SessionStopReport(
            sessionID: sessionID, runID: runID,
            elapsedSeconds: Date().timeIntervalSince(start), signals: attempts,
            remaining: remaining, errors: errors, outsideOwnership: outside
        )
    }

    @discardableResult
    private func sampleOwnership() throws -> [ProcessRecord] {
        let before = ledger
        let snapshot = try ProcessTable.snapshot()
        if let shell = environmentShell, snapshot.contains(where: { $0.identity == shell }) {
            ledger.recordDescendants(snapshot.filter { $0.processGroup == shell.pid }.map(\.identity))
        }
        let records = ledger.observe(snapshot)
        if ledger != before { try persistLedger() }
        return records
    }

    private func registerEnvironmentShell(_ pid: Int32) throws {
        guard let record = try ProcessTable.snapshot().first(where: { $0.identity.pid == pid }) else {
            throw LoomError.message("Environment shell identity unavailable")
        }
        let before = ledger
        ledger.recordDescendants([record.identity])
        environmentShell = record.identity
        if ledger != before { try persistLedger() }
    }

    private func persistLedger() throws {
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    private func recordLeaderExit(runID: UUID, status: Int32) async {
        guard var runtime = runtimes[runID] else { return }
        runtime.run.exitStatus = status
        if runtime.run.state == .running { runtime.run.state = .exited }
        let reason: ManagedRunEndReason = runtime.run.state == .stopping
            ? (stopping ? .applicationQuit : .requested)
            : .processExited
        runtimes[runID] = runtime
        if var session = sessions[runtime.sessionID], session.currentRun?.id == runID {
            session.currentRun = runtime.run
            sessions[runtime.sessionID] = session
        }
        guard let catalog else { return }
        do { try await catalog.finishRun(runID, reason: reason, exitStatus: status) }
        catch {
            guard var current = runtimes[runID] else { return }
            current.catalogErrors.append(String(describing: error))
            runtimes[runID] = current
        }
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
