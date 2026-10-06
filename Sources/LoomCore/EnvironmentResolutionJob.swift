import Foundation

/// Thread-safe ownership state for the blocking terminal-environment capture.
/// It never mutates ProcessSupervisor actor state from its worker thread.
final class EnvironmentResolutionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var shell: ProcessIdentity?
    private var ledger: OwnershipLedger

    /// In run-scope mode the scope already owns everything the shell starts;
    /// the job then only provides cancellation, not process observation.
    private let observes: Bool

    init(runID: UUID, observes: Bool) {
        ledger = OwnershipLedger(runID: runID)
        self.observes = observes
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func register(pid: Int32) throws {
        try checkCancellation()
        guard let record = try ProcessTable.snapshot().first(where: { $0.identity.pid == pid }) else {
            throw LoomError.message("Environment shell identity unavailable")
        }
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw SessionManagementError.shutdownStarted }
        shell = record.identity
        ledger.recordDescendants([record.identity])
    }

    func sample() throws {
        try checkCancellation()
        guard observes else { return }
        let snapshot = try ProcessTable.snapshot()
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw SessionManagementError.shutdownStarted }
        if let shell, snapshot.contains(where: { $0.identity == shell }) {
            ledger.recordDescendants(
                snapshot.filter { $0.processGroup == shell.pid }.map(\.identity)
            )
        }
        _ = ledger.observe(snapshot)
    }

    func observedIdentities() -> Set<ProcessIdentity> {
        lock.lock()
        defer { lock.unlock() }
        return ledger.descendants
    }

    private func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw SessionManagementError.shutdownStarted }
    }
}
