import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

extension ProcessSupervisor {
    /// Stops exactly one managed run: its own processes, or its whole run scope
    /// when it is the scope's last run.
    ///
    /// `graceSeconds` separates the signals (terminal: hang-up, terminate, kill;
    /// pipes: terminate, kill). A pipe child is first given
    /// `inputCloseGraceSeconds` to leave on its own after its stdin closes.
    public func stop(sessionID: UUID, graceSeconds: Double = 0.2,
                     inputCloseGraceSeconds: Double = ProcessSupervisor.defaultInputCloseGraceSeconds
    ) async throws -> SessionStopReport {
        guard !shutdownInProgress else { throw SessionManagementError.shutdownStarted }
        guard let session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard let runID = session.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        return await stop(sessionID: sessionID, runID: runID, graceSeconds: graceSeconds,
                          endReason: .requested, inputCloseGraceSeconds: inputCloseGraceSeconds)
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

    /// Keeps the query-able last report and carries an unverified stop to every
    /// event consumer as part of the session's latest state, so a skipped frame
    /// cannot hide it.
    func recordStopReport(_ report: SessionStopReport) async {
        lastStopReports[report.sessionID] = report
        if recentStopDiagnostics.count == 256 { recentStopDiagnostics.removeFirst() }
        recentStopDiagnostics.append(StopDiagnostic(
            sessionID: report.sessionID, runID: report.runID,
            providerStages: report.providerStages ?? [],
            remainingCount: report.remainingCountVerified == false ? nil : report.remaining.count,
            succeeded: report.succeeded
        ))
        var summary: String?
        if report.succeeded {
            LoomLog.notice(.lifecycle, "Run \(report.runID.uuidString.prefix(8)) stopped and verified in \(Int(report.elapsedSeconds * 1000)) ms")
        } else {
            LoomLog.error(.lifecycle, "Run \(report.runID.uuidString.prefix(8)) stop could not be verified: \(report.remaining.count) remaining, \(report.outsideOwnership.count) outside ownership, \(report.errors.count) error(s)")
        }
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

    func settledStopReport(sessionID: UUID, runID: UUID, started: Date) -> SessionStopReport {
        if let report = lastStopReports.values.first(where: { $0.runID == runID }) { return report }
        return SessionStopReport(sessionID: sessionID, runID: runID,
                                 elapsedSeconds: Date().timeIntervalSince(started),
                                 signals: [], remaining: [], errors: ["Managed run not found"], outsideOwnership: [])
    }

    func stop(sessionID: UUID, runID: UUID, graceSeconds: Double,
              endReason: ManagedRunEndReason,
              inputCloseGraceSeconds: Double = ProcessSupervisor.defaultInputCloseGraceSeconds
    ) async -> SessionStopReport {
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
            var errors = ["Timed out waiting for session transition before stop"]
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
        // A pipe child is asked to leave the way its protocol says: its owner
        // ends the work under way (`leave`: the Chat face interrupts and waits
        // for the turn's result), stdin closes, and only a child still alive
        // after its own, longer grace period gets signals (SIGTERM, then
        // SIGKILL). Never a signal in the middle of a turn.
        let isPipe = runtime.endpoint.isPipe
        if isPipe {
            // A leader that already exited cannot be asked anything (and its owner must not take its end for a
            // stop it asked for).
            if endReason != .processExited, runtime.run.exitStatus == nil, let leave = stopHooks[runID]?.leave {
                await leave(ManagedRunLeave(graceSeconds: inputCloseGraceSeconds, reason: endReason))
            }
            await runtime.endpoint.closeInput()
            await awaitExit(of: [runID], graceSeconds: inputCloseGraceSeconds)
        }
        let termination = await terminate(graceSeconds: graceSeconds,
                                          signals: isPipe ? Self.pipeSignals : Self.terminalSignals) {
            try sample(runID: runID)
        }
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

    func finishStoppedRunResources(runID: UUID, reason: ManagedRunEndReason,
                                            catalogDeadline: Double) async -> [String] {
        guard let runtime = runtimes[runID] else { return ["Managed run not found during finalization"] }
        let exitStatus: Int32?
        do { exitStatus = try await runtime.endpoint.finish() }
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

    func releaseFinalizedRun(runID: UUID, reason: ManagedRunEndReason) async {
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
        if internalSessionIDs.contains(runtime.activeSessionID) {
            LoomLog.notice(.lifecycle, "Helper run \(runID.uuidString.prefix(8)) ended (\(Self.faceName(pipe: runtime.endpoint.isPipe)), reason \(reason.rawValue), \(Self.exitName(runtime.run.exitStatus)))")
        } else {
            LoomLog.notice(.lifecycle, "Run \(runID.uuidString.prefix(8)) ended (\(LoomLog.ref(runtime.activeSessionID)), \(Self.faceName(pipe: runtime.endpoint.isPipe)), reason \(reason.rawValue), \(Self.exitName(runtime.run.exitStatus)))")
        }
        if !internalSessionIDs.contains(runtime.activeSessionID) {
            await events.publish(sessionID: runtime.activeSessionID, change: .runEnded(runID, reason))
        }
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

    /// How long a pipe child gets to exit after its stdin closes. A CLI that
    /// is idle takes up to about half a second (spike S1); the margin keeps
    /// the common stop free of signals. Callers may pass their own.
    public static let defaultInputCloseGraceSeconds = 2.0

    static let terminalSignals = [SIGHUP, SIGTERM, SIGKILL]
    /// A hang-up means nothing to a child without a terminal.
    static let pipeSignals = [SIGTERM, SIGKILL]

    /// Waits up to the grace period for every owned process of the runs to
    /// exit on its own. Sampling errors end the wait: the signal schedule that
    /// follows samples again and reports them.
    func awaitExit(of runIDs: [UUID], graceSeconds: Double) async {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.02, graceSeconds)
        repeat {
            guard let live = try? anyProcessLives(of: runIDs), live else { return }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
    }

    /// Whether a process of the runs still lives. A run alone in its run scope (every pipe run has one) is read
    /// from the scope's own members, so a 10 ms wait does not take a process-table snapshot per pass; other runs
    /// are sampled from one snapshot. A run that is gone throws, which ends the wait.
    func anyProcessLives(of runIDs: [UUID]) throws -> Bool {
        var sampled: [UUID] = []
        for runID in runIDs {
            if let members = try exclusiveScopeMembers(of: runID) {
                if members.contains(where: { !$0.zombie }) { return true }
            } else {
                sampled.append(runID)
            }
        }
        guard !sampled.isEmpty else { return false }
        let snapshot = try ProcessTable.snapshot()
        for runID in sampled where try sample(runID: runID, snapshot: snapshot).contains(where: { !$0.zombie }) {
            return true
        }
        return false
    }

    /// The forked members of the run's scope when the run is the scope's only one (then they are exactly what it
    /// owns); nil otherwise.
    func exclusiveScopeMembers(of runID: UUID) throws -> [RunScopeMember]? {
        guard let runtime = runtimes[runID] else { throw SessionManagementError.runNotFound(runID) }
        guard let scope = runtime.scope, scopeRuns[scope.coalitionID] == [runID] else { return nil }
        return try scope.forkedMembers()
    }

    /// The one escalation loop for both a session stop and the final app-wide
    /// recovery sweep. The caller supplies only the ownership scope.
    func terminate(
        graceSeconds: Double,
        signals: [Int32] = ProcessSupervisor.terminalSignals,
        hangupExempt: () -> Set<ProcessIdentity> = { [] },
        sample: () throws -> [ProcessRecord]
    ) async -> (attempts: [SignalAttempt], remaining: [ProcessRecord], errors: [String], countVerified: Bool) {
        var attempts: [SignalAttempt] = []
        var errors: [String] = []
        var remaining: [ProcessRecord] = []
        var countVerified = false
        for signal in signals {
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
                    // Processes that never take a hang-up (pipe children) are
                    // left for the next signal in a Quit that also hangs up
                    // terminals.
                    let exempt = signal == SIGHUP ? hangupExempt() : []
                    for record in remaining where !record.zombie
                        && !signaled.contains(record.identity)
                        && !exempt.contains(record.identity) {
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
}
