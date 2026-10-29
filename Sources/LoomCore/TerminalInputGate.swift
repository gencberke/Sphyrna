import Foundation

/// Connects live terminal input to the idle/stop decision. A surface registers
/// the input queue of its run; the lifecycle controller closes that queue
/// atomically before an automatic stop. Input is then either already written to
/// the live process, or rejected whole with a visible error: never accepted and
/// silently dropped, never delivered twice.
public final class TerminalInputGate: @unchecked Sendable {
    public enum CloseResult: Equatable, Sendable {
        /// No terminal registered for this run; nothing can race.
        case noTerminal
        case closed
        case pending
        /// Input was accepted within the quiet period: it may not have reached
        /// the provider yet, and the run's last use is older than that input.
        case recentInput
    }

    private let lock = NSLock()
    private var queues: [UUID: TerminalInputQueue] = [:]
    private var registrationObserver: (@Sendable (UUID) -> Void)?

    public init() {}

    public func register(runID: UUID, queue: TerminalInputQueue) {
        let observer = lock.withLock {
            queues[runID] = queue
            return registrationObserver
        }
        observer?(runID)
    }

    /// Lets the runtime retry deferred work when its actual terminal attaches.
    func observeRegistrations(_ observer: (@Sendable (UUID) -> Void)?) {
        lock.withLock { registrationObserver = observer }
    }

    public func unregister(runID: UUID) {
        lock.withLock { queues[runID] = nil }
    }

    public func closeIfIdle(runID: UUID, reason: String, quietFor: TimeInterval = 0) -> CloseResult {
        guard let queue = lock.withLock({ queues[runID] }) else { return .noTerminal }
        switch queue.closeIfIdle(reason: reason, quietFor: quietFor) {
        case .closed: return .closed
        case .pending: return .pending
        case .recentInput: return .recentInput
        }
    }

    /// Refuses all later input of the run, busy or not (deletion of its conversation).
    public func close(runID: UUID, reason: String) {
        lock.withLock { queues[runID] }?.close(reason: reason)
    }

    public func lastInputDate(runID: UUID) -> Date? {
        lock.withLock { queues[runID] }?.lastAcceptedInput
    }

    public func reopen(runID: UUID) {
        lock.withLock { queues[runID] }?.reopen()
    }

    public func pendingByteCount(runID: UUID) -> Int {
        lock.withLock { queues[runID] }?.pendingByteCount ?? 0
    }

    @discardableResult
    func notifyWhenIdle(runID: UUID, _ callback: @escaping @Sendable () -> Void) -> Bool {
        guard let queue = lock.withLock({ queues[runID] }) else { return false }
        return queue.notifyWhenIdle(callback)
    }

    func notifyWhenAutomaticMayProceed(runID: UUID, _ callback: @escaping @Sendable () -> Void) -> Bool {
        guard let queue = lock.withLock({ queues[runID] }) else { return false }
        return queue.notifyWhenAutomaticMayProceed(callback)
    }

    func noteUnclassifiedInput(runID: UUID) {
        lock.withLock { queues[runID] }?.noteUnclassifiedInput()
    }

    func establishFreshCleanInput(runID: UUID) -> Bool {
        lock.withLock { queues[runID]?.establishFreshCleanInput() ?? false }
    }

    func reserveAutomaticInput(runID: UUID) -> TerminalInputQueue.AutomaticInputTicket? {
        lock.withLock { queues[runID] }?.reserveAutomaticInput()
    }

    func writeReservedAutomatic(runID: UUID, ticket: TerminalInputQueue.AutomaticInputTicket,
                                _ write: () throws -> Int) rethrows -> Int? {
        guard let queue = lock.withLock({ queues[runID] }) else { return nil }
        return try queue.writeReservedAutomatic(ticket, write)
    }

    func releaseReservedAutomatic(runID: UUID, ticket: TerminalInputQueue.AutomaticInputTicket) {
        lock.withLock { queues[runID] }?.releaseReservedAutomatic(ticket)
    }

    func enqueueReservedAutomatic(runID: UUID, ticket: TerminalInputQueue.AutomaticInputTicket, bytes: Data,
                                  transaction: @escaping TerminalWriteTransaction) -> Bool {
        lock.withLock { queues[runID] }?.enqueueReservedAutomatic(ticket, bytes: bytes, transaction: transaction) ?? false
    }

    func enqueueAutomatic(runID: UUID, bytes: Data,
                          transaction: @escaping TerminalWriteTransaction) -> TerminalInputQueue.AutomaticInputTicket? {
        lock.withLock { queues[runID]?.enqueueAutomatic(bytes, transaction: transaction) }
    }

    func confirmAutomaticInput(runID: UUID, ticket: TerminalInputQueue.AutomaticInputTicket) -> Bool {
        lock.withLock { queues[runID]?.confirmAutomaticInput(ticket) ?? false }
    }

    func confirmAutomaticInputGeneration(runID: UUID, ticket: TerminalInputQueue.AutomaticInputTicket) -> UInt64? {
        lock.withLock { queues[runID]?.confirmAutomaticInputGeneration(ticket) }
    }

    func hasInputGeneration(runID: UUID, generation: UInt64) -> Bool {
        lock.withLock { queues[runID]?.hasInputGeneration(generation) ?? false }
    }

    func confirmManualInput(runID: UUID, digest: Data, observedAt: UInt64) -> TerminalInputQueue.ManualInputConfirmation {
        lock.withLock { queues[runID]?.confirmManualInput(digest: digest, observedAt: observedAt) ?? .unverified }
    }
}
