import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

extension ProcessSupervisor {
    func awaitCatalogFinish(runID: UUID, deadline: Double) async -> [String] {
        while pendingCatalogWrites[runID] != nil, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        if pendingCatalogWrites[runID] != nil { return ["Timed out waiting for catalog run \(runID)"] }
        if let error = catalogWriteErrors.removeValue(forKey: runID) { return [error] }
        return []
    }

    func persistLedger() throws {
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    func recordLeaderExit(runID: UUID, status: Int32?) async {
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

    func queueCatalogFinish(
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

    func restoreCatalogSessions() async throws {
        guard let catalog else { return }
        let records = try await catalog.sessions()
        for record in records {
            var session = record.session
            session.currentRun = nil
            sessions[session.id] = session
        }
    }
}
