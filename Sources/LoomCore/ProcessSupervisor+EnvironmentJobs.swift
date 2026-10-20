import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

extension ProcessSupervisor {
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
    /// cancelled and awaited by `shutdown`, one deadline, bounded output (4 MiB
    /// per stream unless the caller sets `outputLimit`; more throws
    /// `LoomError.outputTooLarge`). After a successful Quit no helper of this
    /// kind is left running.
    public func captureHelper(
        _ executable: String, _ arguments: [String], environment: [String: String],
        timeout: TimeInterval = 15, outputLimit: Int = LaunchEnvironment.defaultOutputLimit
    ) async throws -> String {
        try await runOwnedJob(scope: .perCall) { _, job, spawner in
            try LaunchEnvironment.runHelper(
                executable, arguments, environment: environment, timeout: timeout, outputLimit: outputLimit,
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
    /// running until Quit, so its scope is kept while forked work is alive in
    /// it and released once no job uses it and it is verified empty; a later
    /// job opens a new scope. A one-shot helper's scope is stopped and
    /// released when it returns.
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
            if kind == .environment, let scope {
                environmentScopeJobs[scope.coalitionID, default: 0] += 1
            }
        }
        let spawner = scope.map(HelperSpawner.scoped) ?? .local
        var finished = false // the environment job's use of its scope ends exactly once
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
            if kind == .environment, let scope { finished = true; await finishEnvironmentJob(in: scope) }
            guard !stopping else { throw SessionManagementError.shutdownStarted }
            return result
        } catch {
            if scopeLauncher == nil { ledger.recordDescendants(Array(job.observedIdentities())) }
            _ = try? sampleOwnership()
            if kind == .perCall, let scope { _ = await releaseScope(scope) }
            if kind == .environment, !finished, let scope { await finishEnvironmentJob(in: scope) }
            throw error
        }
    }

    /// Ends an environment job's use of its scope. The scope is released only
    /// when no other job uses it and it holds no forked process; startup work
    /// left running keeps it until Quit, which still verifies and releases it.
    /// A failed release leaves the scope registered for Quit to retry.
    private func finishEnvironmentJob(in scope: RunScope) async {
        let remaining = (environmentScopeJobs[scope.coalitionID] ?? 1) - 1
        environmentScopeJobs[scope.coalitionID] = remaining > 0 ? remaining : nil
        guard remaining <= 0, !stopping, liveScopes[scope.coalitionID] != nil,
              (try? scope.forkedMembers().isEmpty) == true else { return }
        if environmentScope === scope { environmentScope = nil }
        _ = await releaseScope(scope)
    }
}
