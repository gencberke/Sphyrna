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

    public init() {}

    public func register(runID: UUID, queue: TerminalInputQueue) {
        lock.withLock { queues[runID] = queue }
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

    func establishFreshCleanInput(runID: UUID) -> Bool {
        lock.withLock { queues[runID]?.establishFreshCleanInput() ?? false }
    }

    func enqueueAutomatic(runID: UUID, bytes: Data) -> TerminalInputQueue.AutomaticInputTicket? {
        lock.withLock { queues[runID]?.enqueueAutomatic(bytes) }
    }

    func confirmAutomaticInput(runID: UUID, ticket: TerminalInputQueue.AutomaticInputTicket) -> Bool {
        lock.withLock { queues[runID]?.confirmAutomaticInput(ticket) ?? false }
    }
}
