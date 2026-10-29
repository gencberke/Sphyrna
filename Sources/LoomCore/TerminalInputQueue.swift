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
    enum AutomaticWriteOutcome: Equatable, Sendable { case written, notWritten, unknown }
    struct AutomaticInputTicket: Equatable, Sendable {
        let id = UUID()
        fileprivate let completion = AutomaticWriteCompletion()
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func writeOutcome() async -> AutomaticWriteOutcome { await completion.value() }
    }
    private struct AutomaticSegment: Sendable {
        let end: Int
        let ticket: AutomaticInputTicket
        let permit: @Sendable () -> Bool
    }
    private enum DrainChunk: Sendable {
        case automatic(Data, AutomaticSegment)
        case ordinary(Data)
    }
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
    // Mixed terminal input is not evidence of a clean editor. Automatic input
    // is admitted only at an explicitly established fresh/verified boundary.
    private var unclassifiedGeneration: UInt64 = 0
    private var automaticClean = false
    private var automaticEverUsed = false
    private var automaticOutstanding: (ticket: AutomaticInputTicket, generation: UInt64)?
    private var automaticSegment: AutomaticSegment?

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
            unclassifiedGeneration &+= 1
            automaticClean = false
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

    /// Only the owner of a freshly started terminal may establish this first
    /// boundary. Any earlier mixed input makes its editor state unknown.
    func establishFreshCleanInput() -> Bool {
        lock.withLock {
            guard unclassifiedGeneration == 0, !automaticEverUsed, !draining,
                  pending.count == sent, failure == nil, closedReason == nil else { return false }
            automaticClean = true
            return true
        }
    }

    /// Admit a single printable pointer and Return atomically with the clean
    /// check. Anything else, including a multiline payload, is deferred whole.
    func enqueueAutomatic(_ bytes: Data, permit: @escaping @Sendable () -> Bool = { true }) -> AutomaticInputTicket? {
        guard bytes.count > 1, bytes.count <= 16 * 1024, bytes.last == 0x0d,
              bytes.dropLast().allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        let ticket = lock.withLock { () -> AutomaticInputTicket? in
            guard automaticClean, automaticOutstanding == nil, failure == nil, closedReason == nil,
                  !draining, pending.count == sent, bytes.count <= capacity else { return nil }
            let ticket = AutomaticInputTicket()
            automaticOutstanding = (ticket, unclassifiedGeneration)
            automaticClean = false
            automaticEverUsed = true
            pending.append(bytes)
            automaticSegment = AutomaticSegment(end: pending.count, ticket: ticket, permit: permit)
            lastAcceptedUptime = ProcessInfo.processInfo.systemUptime
            lastAccepted = Date()
            draining = true
            return ticket
        }
        if ticket != nil { Task.detached { [self] in await drain() } }
        return ticket
    }

    /// The owner calls this only after an exact provider-input observation.
    /// Later mixed bytes make the editor unknown again, even if that proof is late.
    func confirmAutomaticInput(_ ticket: AutomaticInputTicket) -> Bool {
        lock.withLock {
            guard let outstanding = automaticOutstanding, outstanding.ticket == ticket else { return false }
            automaticOutstanding = nil
            guard outstanding.generation == unclassifiedGeneration, failure == nil, closedReason == nil else { return false }
            automaticClean = true
            return true
        }
    }

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

    /// Refuses all later input at once, whatever is queued (a deletion: the conversation is going
    /// away, so nothing more may be typed). Bytes already accepted still drain. `reopen` undoes it.
    public func close(reason: String) {
        lock.withLock { closedReason = closedReason ?? reason }
    }

    /// Wall-clock time of the last accepted input (scheduling).
    public var lastAcceptedInput: Date? { lock.withLock { lastAccepted } }

    public func reopen() { lock.withLock { closedReason = nil } }

    /// True while bytes are queued or a write is in flight.
    public var isDraining: Bool { lock.withLock { draining } }

    private func drain() async {
        var idleWrites = 0
        while true {
            let work: DrainChunk? = lock.withLock {
                guard failure == nil, sent < pending.count else {
                    pending.removeAll(keepingCapacity: false)
                    sent = 0
                    draining = false
                    return nil
                }
                let start = pending.startIndex + sent
                if let segment = automaticSegment, sent < segment.end {
                    let end = pending.startIndex + segment.end
                    return .automatic(Data(pending[start..<end]), segment)
                }
                return .ordinary(Data(pending[start..<min(start + 64 * 1024, pending.endIndex)]))
            }
            guard let work else { return }
            let chunk: Data
            switch work {
            case let .ordinary(bytes): chunk = bytes
            case let .automatic(bytes, segment):
                guard segment.permit() else {
                    let outcome: AutomaticWriteOutcome? = lock.withLock {
                        guard automaticSegment?.ticket == segment.ticket else { return nil }
                        let started = sent > 0
                        let start = pending.startIndex + sent, end = pending.startIndex + segment.end
                        pending.removeSubrange(start..<end)
                        automaticSegment = nil
                        if let outstanding = automaticOutstanding, outstanding.ticket == segment.ticket {
                            automaticOutstanding = nil
                            automaticClean = !started && outstanding.generation == unclassifiedGeneration
                                && failure == nil && closedReason == nil
                        }
                        return started ? .unknown : .notWritten
                    }
                    if let outcome { segment.ticket.completion.finish(outcome) }
                    continue
                }
                chunk = bytes
            }
            do {
                let written = try await writer(chunk)
                if written > 0 {
                    idleWrites = 0
                    lock.withLock {
                        sent = min(pending.count, sent + min(written, chunk.count))
                        if let segment = automaticSegment, sent >= segment.end {
                            automaticSegment = nil
                            segment.ticket.completion.finish(.written)
                        }
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
                let automatic = lock.withLock {
                    let automatic = automaticSegment?.ticket
                    automaticSegment = nil
                    self.failure = failure
                    pending.removeAll()
                    sent = 0
                    draining = false
                    return automatic
                }
                automatic?.completion.finish(.unknown)
                onError(failure)
                return
            }
        }
    }
}

private final class AutomaticWriteCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<TerminalInputQueue.AutomaticWriteOutcome>
    private let continuation: AsyncStream<TerminalInputQueue.AutomaticWriteOutcome>.Continuation
    private var finished = false

    init() {
        let pair = AsyncStream<TerminalInputQueue.AutomaticWriteOutcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func finish(_ value: TerminalInputQueue.AutomaticWriteOutcome) {
        let first = lock.withLock { if finished { return false }; finished = true; return true }
        if first { continuation.yield(value); continuation.finish() }
    }
    func value() async -> TerminalInputQueue.AutomaticWriteOutcome {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .unknown
    }
}
