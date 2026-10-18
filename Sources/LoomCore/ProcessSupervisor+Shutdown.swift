import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

extension ProcessSupervisor {
    /// Applies one app-wide signal schedule, then records completion separately
    /// for every run. The ownership sweep also catches escaped marked processes.
    public func shutdown(graceSeconds: Double = 0.2,
                         pendingOperationGraceSeconds: Double = 2.1,
                         inputCloseGraceSeconds: Double = ProcessSupervisor.defaultInputCloseGraceSeconds
    ) async -> ShutdownReport {
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
                                           pendingOperationGraceSeconds: pendingOperationGraceSeconds,
                                           inputCloseGraceSeconds: inputCloseGraceSeconds)
        lastShutdownReport = report
        return report
    }

    private func performShutdown(graceSeconds: Double,
                                 pendingOperationGraceSeconds: Double,
                                 inputCloseGraceSeconds: Double) async -> ShutdownReport {
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
        // A pipe run's Stop takes longer by design (its owner's leave, then the input-close grace, then the
        // signals): Quit right after a Chat Stop waits for that stop to finish rather than failing.
        let pipeStopDeadline = pendingDeadline + 2 * inputCloseGraceSeconds + 4 * graceSeconds + 1
        while (!reservedSessions.isEmpty || !environmentJobs.isEmpty || !transitioningRuns.isEmpty || !stoppingRuns.isEmpty) {
            let onlyPipeStops = reservedSessions.isEmpty && environmentJobs.isEmpty && transitioningRuns.isEmpty
                // A run already released is finishing its stop.
                && stoppingRuns.allSatisfy { runtimes[$0]?.endpoint.isPipe ?? true }
            if ProcessInfo.processInfo.systemUptime >= (onlyPipeStops ? pipeStopDeadline : pendingDeadline) { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !reservedSessions.isEmpty || !environmentJobs.isEmpty {
            errors.append(
                "Timed out waiting for pending operations; sessions=\(reservedSessions.map(\.uuidString).sorted()), environmentJobs=\(environmentJobs.count)"
            )
        }
        if !transitioningRuns.isEmpty || !stoppingRuns.isEmpty {
            if !transitioningRuns.isEmpty {
                errors.append("Timed out waiting for session transitions: \(transitioningRuns.count)")
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
        // Pipe children are first asked to leave by closing their stdin, and
        // get the input-close grace period to do so. They never get a hang-up,
        // even when terminals are hung up in the same Quit: with only pipe
        // children the schedule starts at SIGTERM, and with both the hang-up
        // phase skips every process of a pipe run.
        let pipeRuns = active.map(\.1).filter { runtimes[$0]?.endpoint.isPipe == true }
        if !pipeRuns.isEmpty {
            // The order of a Stop, for all of them at once: each owner ends the
            // work under way (bounded by the same grace), then stdin closes.
            let leaving = pipeRuns.filter { runtimes[$0]?.run.exitStatus == nil }.compactMap { stopHooks[$0]?.leave }
            if !leaving.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    for leave in leaving {
                        group.addTask { await leave(ManagedRunLeave(graceSeconds: inputCloseGraceSeconds, reason: .applicationQuit)) }
                    }
                }
            }
            for runID in pipeRuns { await runtimes[runID]?.endpoint.closeInput() }
            await awaitExit(of: pipeRuns, graceSeconds: inputCloseGraceSeconds)
        }
        let onlyPipes = !active.isEmpty && pipeRuns.count == active.count
        let sharedTermination = await terminate(
            graceSeconds: graceSeconds,
            signals: onlyPipes ? Self.pipeSignals : Self.terminalSignals,
            hangupExempt: { [self] in
                var exempt: Set<ProcessIdentity> = []
                for runID in pipeRuns {
                    // A pipe run alone in its scope: its members, without a process-table snapshot per pass.
                    if let members = try? exclusiveScopeMembers(of: runID) {
                        exempt.formUnion(members.map(\.identity))
                        continue
                    }
                    _ = try? sample(runID: runID)
                    exempt.formUnion(runtimes[runID]?.run.descendants ?? [])
                }
                return exempt
            }
        ) {
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
}
