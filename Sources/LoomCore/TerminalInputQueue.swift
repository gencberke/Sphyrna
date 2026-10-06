import Foundation

public enum TerminalInputError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The payload was rejected whole; earlier and later payloads keep their order.
    case overflow(pending: Int, rejected: Int, capacity: Int)
    /// The run's terminal refused a write. Later input is rejected.
    case writeFailed(String)
    /// The conversation is being stopped; the payload was refused whole and
    /// nothing was written, so nothing is lost silently.
    case closed(String)

    public var description: String {
        switch self {
        case let .overflow(pending, rejected, capacity):
            "Terminal input rejected: \(rejected) bytes would exceed \(capacity) pending (\(pending) queued)"
        case let .writeFailed(detail):
            "Terminal input failed: \(detail)"
        case let .closed(reason):
            "Terminal input not sent: \(reason)"
        }
    }
}

/// One ordered write path per run for keystrokes, paste and terminal replies.
/// `enqueue` appends synchronously, so caller order is byte order; one drain
/// task finishes short writes before taking the next bytes. Memory is bounded
/// by `capacity`; there is no work while the queue is empty.
public final class TerminalInputQueue: @unchecked Sendable {
    public typealias Writer = @Sendable (Data) async throws -> Int

    public let capacity: Int
    private let writer: Writer
    private let onError: @Sendable (TerminalInputError) -> Void
    private let lock = NSLock()
    // Guarded by lock.
    private var pending = Data()
    private var sent = 0 // Prefix of `pending` already written.
    private var draining = false
    private var failure: TerminalInputError?
    private var closedReason: String?
    private var lastAcceptedUptime: TimeInterval?
    private var lastAccepted: Date?

    public init(capacity: Int = 4 * 1024 * 1024, writer: @escaping Writer,
                onError: @escaping @Sendable (TerminalInputError) -> Void) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.writer = writer
        self.onError = onError
    }

    public convenience init(endpoint: TerminalEndpoint, capacity: Int = 4 * 1024 * 1024,
                            onError: @escaping @Sendable (TerminalInputError) -> Void) {
        self.init(capacity: capacity, writer: { try await endpoint.write($0) }, onError: onError)
    }

    /// Returns false when the payload was not accepted; the reason is reported
    /// through `onError` so the UI can show it instead of dropping input silently.
    @discardableResult
    public func enqueue<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        guard !bytes.isEmpty else { return true }
        let outcome: (accepted: Bool, startDrain: Bool, error: TerminalInputError?) = lock.withLock {
            if let failure { return (false, false, failure) }
            if let closedReason { return (false, false, .closed(closedReason)) }
            let queued = pending.count - sent
            guard queued + bytes.count <= capacity else {
                return (false, false, .overflow(pending: queued, rejected: bytes.count,
                                                capacity: capacity))
            }
            pending.append(contentsOf: bytes)
            lastAcceptedUptime = ProcessInfo.processInfo.systemUptime
            lastAccepted = Date()
            guard !draining else { return (true, false, nil) }
            draining = true
            return (true, true, nil)
        }
        if let error = outcome.error { onError(error) }
        if outcome.startDrain { Task.detached { [self] in await drain() } }
        return outcome.accepted
    }

    public var pendingByteCount: Int { lock.withLock { pending.count - sent } }

    public enum CloseOutcome: Equatable, Sendable {
        case closed
        /// Bytes are queued or being written.
        case pending
        /// Input was accepted less than `quietFor` ago. Written bytes are not
        /// bytes the provider has read: the PTY may still hold them.
        case recentInput
    }

    /// Atomically refuses all later input if nothing is queued or in flight and
    /// no input was accepted within `quietFor`. Input that arrives after a
    /// successful close is rejected whole.
    public func closeIfIdle(reason: String, quietFor: TimeInterval = 0) -> CloseOutcome {
        lock.withLock {
            if closedReason != nil { return .closed }
            guard !draining, pending.count == sent else { return .pending }
            if let last = lastAcceptedUptime,
               ProcessInfo.processInfo.systemUptime - last < quietFor { return .recentInput }
            closedReason = reason
            return .closed
        }
    }

    /// Wall-clock time of the last accepted input (scheduling).
    public var lastAcceptedInput: Date? { lock.withLock { lastAccepted } }

    public func reopen() { lock.withLock { closedReason = nil } }

    /// True while bytes are queued or a write is in flight.
    public var isDraining: Bool { lock.withLock { draining } }

    private func drain() async {
        var idleWrites = 0
        while true {
            let chunk: Data? = lock.withLock {
                guard failure == nil, sent < pending.count else {
                    pending.removeAll(keepingCapacity: false)
                    sent = 0
                    draining = false
                    return nil
                }
                let start = pending.startIndex + sent
                return Data(pending[start..<min(start + 64 * 1024, pending.endIndex)])
            }
            guard let chunk else { return }
            do {
                let written = try await writer(chunk)
                if written > 0 {
                    idleWrites = 0
                    lock.withLock {
                        sent = min(pending.count, sent + written)
                        // Compact occasionally instead of shifting on every write.
                        if sent >= 256 * 1024, sent * 2 >= pending.count {
                            pending.removeFirst(sent)
                            sent = 0
                        }
                    }
                } else {
                    // The PTY input buffer is full; the child has not read yet.
                    // Back off only while bytes are actually pending.
                    idleWrites += 1
                    try? await Task.sleep(for: .milliseconds(min(20, idleWrites)))
                }
            } catch {
                let failure = TerminalInputError.writeFailed(String(describing: error))
                lock.withLock {
                    self.failure = failure
                    pending.removeAll()
                    sent = 0
                    draining = false
                }
                onError(failure)
                return
            }
        }
    }
}
