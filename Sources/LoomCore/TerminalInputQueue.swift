import CryptoKit
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

/// A short synchronous fence around one actual nonblocking write. A nil
/// result means no write was attempted.
typealias TerminalWriteTransaction = @Sendable (@Sendable () throws -> Int) throws -> Int?
private struct AutomaticInputWithdrawn: Error {}

/// One ordered write path per run for keystrokes, paste and terminal replies.
/// `enqueue` appends synchronously, so caller order is byte order; one drain
/// task finishes short writes before taking the next bytes. Memory is bounded
/// by `capacity`; there is no work while the queue is empty.
public final class TerminalInputQueue: @unchecked Sendable {
    enum AutomaticWriteOutcome: Equatable, Sendable { case written, notWritten, unknown }
    enum ManualInputConfirmation: Sendable { case confirmed, pendingDrain, unverified }
    struct AutomaticInputTicket: Equatable, Sendable {
        let id = UUID()
        fileprivate let completion = AutomaticWriteCompletion()
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func writeOutcome() async -> AutomaticWriteOutcome { await completion.value() }
    }
    private struct AutomaticSegment: Sendable {
        let end: Int
        let ticket: AutomaticInputTicket
        let transaction: TerminalWriteTransaction
    }
    private enum DrainChunk: Sendable {
        case automatic(Data, AutomaticSegment)
        case ordinary(Data)
    }
    public typealias Writer = @Sendable (Data) async throws -> Int
    typealias AutomaticWriter = @Sendable (Data, @escaping TerminalWriteTransaction) async throws -> Int?

    public let capacity: Int
    private let writer: Writer
    private let automaticWriter: AutomaticWriter?
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
    // A bounded streaming digest of one plain submitted line. Control/edit
    // sequences invalidate it; no prompt text is retained here.
    private var manualDigest = SHA256()
    private var manualBytes = 0
    private var manualValid = true
    private var manualSubmission: (digest: Data, generation: UInt64, end: Int, writtenAt: UInt64?)?
    private var automaticClean = false
    private var automaticEverUsed = false
    private var automaticOutstanding: (ticket: AutomaticInputTicket, generation: UInt64)?
    private var automaticExternalEffect = false
    private var automaticSegment: AutomaticSegment?
    private var idleWaiter: (@Sendable () -> Void)?

    public init(capacity: Int = 4 * 1024 * 1024, writer: @escaping Writer,
                onError: @escaping @Sendable (TerminalInputError) -> Void) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.writer = writer
        self.automaticWriter = nil
        self.onError = onError
    }

    init(capacity: Int, writer: @escaping Writer, automaticWriter: @escaping AutomaticWriter,
         onError: @escaping @Sendable (TerminalInputError) -> Void) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.writer = writer
        self.automaticWriter = automaticWriter
        self.onError = onError
    }

    public convenience init(endpoint: TerminalEndpoint, capacity: Int = 4 * 1024 * 1024,
                            onError: @escaping @Sendable (TerminalInputError) -> Void) {
        self.init(capacity: capacity, writer: { try await endpoint.write($0) },
                  automaticWriter: { bytes, transaction in
                      try await endpoint.writeAutomatically(bytes, transaction: transaction)
                  }, onError: onError)
    }

    /// Returns false when the payload was not accepted; the reason is reported
    /// through `onError` so the UI can show it instead of dropping input silently.
    @discardableResult
    public func enqueue<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        enqueue(bytes, unclassified: true)
    }

    /// Fence a user or otherwise unclassified input as soon as it enters the
    /// terminal's delivery path, before a later main-actor callback queues it.
    public func noteUnclassifiedInput() {
        lock.withLock {
            unclassifiedGeneration &+= 1
            automaticClean = false
            manualSubmission = nil
        }
    }

    /// Only for a trusted protocol response identified by the terminal.
    /// It still shares the same ordered, bounded write path.
    @discardableResult
    public func enqueueTerminalResponse<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        enqueue(bytes, unclassified: false)
    }

    private func enqueue<Bytes: Collection>(_ bytes: Bytes, unclassified: Bool) -> Bool where Bytes.Element == UInt8 {
        guard !bytes.isEmpty else { return true }
        let outcome: (accepted: Bool, startDrain: Bool, error: TerminalInputError?) = lock.withLock {
            if let failure { return (false, false, failure) }
            if let closedReason { return (false, false, .closed(closedReason)) }
            let queued = pending.count - sent
            guard queued + bytes.count <= capacity else {
                return (false, false, .overflow(pending: queued, rejected: bytes.count,
                                                capacity: capacity))
            }
            let start = pending.count
            pending.append(contentsOf: bytes)
            if unclassified {
                unclassifiedGeneration &+= 1
                automaticClean = false
                recordManualInput(bytes, start: start)
            }
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

    /// One bounded, one-shot notification, including the race where draining
    /// finishes just before registration. The callback always rechecks state.
    @discardableResult
    func notifyWhenIdle(_ callback: @escaping @Sendable () -> Void) -> Bool {
        let result = lock.withLock { () -> (accepted: Bool, immediate: Bool) in
            guard idleWaiter == nil else { return (false, false) }
            if !draining { return (true, true) }
            idleWaiter = callback
            return (true, false)
        }
        if result.immediate { callback() }
        return result.accepted
    }

    /// Retry only for a drain that can make the queue admissible. A dirty idle
    /// composer must not turn a deferred task into a busy loop.
    func notifyWhenAutomaticMayProceed(_ callback: @escaping @Sendable () -> Void) -> Bool {
        let result = lock.withLock { () -> (accepted: Bool, immediate: Bool) in
            guard idleWaiter == nil, failure == nil, closedReason == nil else { return (false, false) }
            if draining { idleWaiter = callback; return (true, false) }
            guard automaticClean, automaticOutstanding == nil, pending.count == sent else { return (false, false) }
            return (true, true)
        }
        if result.immediate { callback() }
        return result.accepted
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

    /// Called under the queue lock as bytes enter the single ordered path.
    /// A native input observation must later match the final digest and the
    /// same generation; a write acknowledgement alone proves nothing.
    private func recordManualInput<Bytes: Collection>(_ bytes: Bytes, start: Int) where Bytes.Element == UInt8 {
        guard bytes.count <= SessionTaskLimits.payloadBytes + 1 else {
            manualValid = false; manualSubmission = nil
            return
        }
        for (offset, value) in bytes.enumerated() {
            if value == 0x0d {
                manualSubmission = manualValid && manualBytes > 0
                    ? (Data(manualDigest.finalize()), unclassifiedGeneration, start + offset + 1, nil) : nil
                manualDigest = SHA256(); manualBytes = 0; manualValid = true
            } else {
                manualSubmission = nil
                guard value >= 0x20, value != 0x7f, manualBytes < SessionTaskLimits.payloadBytes else {
                    manualValid = false
                    continue
                }
                if manualValid {
                    var byte = value
                    withUnsafeBytes(of: &byte) { manualDigest.update(bufferPointer: $0) }
                    manualBytes += 1
                }
            }
        }
    }

    /// A first message passed to the CLI as a launch argument is the run's first submission, though no terminal
    /// byte carried it. Record its digest as typed input is recorded, written at `launchedAt` (before the spawn), so
    /// its provider observation proves the same clean boundary. Any earlier mixed input wins: then it stays unknown.
    /// Bytes still draining here can only be the terminal's answers to the CLI's early queries (queued at attach, with
    /// no typed or automatic byte before them); they are not input, and `confirmManualInput` waits for them.
    func expectLaunchSubmission(digest: Data, launchedAt: UInt64) {
        lock.withLock {
            guard digest.count == 32, unclassifiedGeneration == 0, !automaticEverUsed, manualSubmission == nil,
                  manualBytes == 0, failure == nil, closedReason == nil else { return }
            manualSubmission = (digest, unclassifiedGeneration, sent, launchedAt)
        }
    }

    func confirmManualInput(digest: Data, observedAt: UInt64) -> ManualInputConfirmation {
        lock.withLock {
            guard digest.count == 32, let submission = manualSubmission, submission.digest == digest,
                  submission.generation == unclassifiedGeneration, automaticOutstanding == nil,
                  failure == nil, closedReason == nil else { return .unverified }
            guard !draining, pending.count == sent else { return .pendingDrain }
            guard let writtenAt = submission.writtenAt, observedAt > writtenAt else { return .unverified }
            manualSubmission = nil
            automaticClean = true
            return .confirmed
        }
    }

    /// Reserve the same clean composer for an external provider request. The
    /// reservation precedes proof registration, so a fast provider event can
    /// never arrive before its ticket exists.
    func reserveAutomaticInput() -> AutomaticInputTicket? {
        lock.withLock {
            guard automaticClean, automaticOutstanding == nil, failure == nil, closedReason == nil,
                  !draining, pending.count == sent else { return nil }
            let ticket = AutomaticInputTicket()
            automaticOutstanding = (ticket, unclassifiedGeneration)
            automaticExternalEffect = false
            automaticClean = false
            automaticEverUsed = true
            return ticket
        }
    }

    /// Invoke only around the short external write. A user edit, an in-flight
    /// terminal response, Stop, or a replaced ticket wins before the syscall.
    func writeReservedAutomatic(_ ticket: AutomaticInputTicket, _ write: () throws -> Int) rethrows -> Int? {
        try lock.withLock {
            guard let outstanding = automaticOutstanding, outstanding.ticket == ticket,
                  outstanding.generation == unclassifiedGeneration, failure == nil, closedReason == nil,
                  !draining, pending.count == sent else { return nil }
            do {
                let count = try write()
                if count > 0 { automaticExternalEffect = true }
                return count
            } catch {
                automaticExternalEffect = true
                throw error
            }
        }
    }

    /// Only a caller that proved no external write occurred may release this.
    func releaseReservedAutomatic(_ ticket: AutomaticInputTicket) {
        lock.withLock {
            guard let outstanding = automaticOutstanding, outstanding.ticket == ticket,
                  automaticSegment?.ticket != ticket, !automaticExternalEffect else { return }
            automaticOutstanding = nil
            if outstanding.generation == unclassifiedGeneration, failure == nil, closedReason == nil {
                automaticClean = true
            }
        }
    }

    func enqueueReservedAutomatic(_ ticket: AutomaticInputTicket, bytes: Data,
                                  transaction: @escaping TerminalWriteTransaction) -> Bool {
        guard bytes.count > 1, bytes.count <= 16 * 1024, bytes.last == 0x0d,
              bytes.dropLast().allSatisfy({ (0x20...0x7e).contains($0) }) else { return false }
        return enqueueReservedBytes(ticket, bytes: bytes, transaction: transaction)
    }

    /// The default native Claude turn interrupt is precisely one Escape byte.
    /// Its result still needs separate current-prompt/idle evidence.
    func enqueueReservedTaskInterrupt(_ ticket: AutomaticInputTicket,
                                      transaction: @escaping TerminalWriteTransaction) -> Bool {
        enqueueReservedBytes(ticket, bytes: Data([0x1b]), transaction: transaction)
    }

    private func enqueueReservedBytes(_ ticket: AutomaticInputTicket, bytes: Data,
                                      transaction: @escaping TerminalWriteTransaction) -> Bool {
        let accepted = lock.withLock {
            guard let outstanding = automaticOutstanding, outstanding.ticket == ticket,
                  outstanding.generation == unclassifiedGeneration, !automaticExternalEffect, automaticWriter != nil,
                  failure == nil, closedReason == nil, !draining, pending.count == sent,
                  bytes.count <= capacity else { return false }
            pending.append(bytes)
            automaticSegment = AutomaticSegment(end: pending.count, ticket: ticket, transaction: transaction)
            lastAcceptedUptime = ProcessInfo.processInfo.systemUptime
            lastAccepted = Date()
            draining = true
            return true
        }
        if accepted { Task.detached { [self] in await drain() } }
        return accepted
    }

    /// Admit a single printable pointer and Return atomically with the clean
    /// check. Anything else, including a multiline payload, is deferred whole.
    func enqueueAutomatic(_ bytes: Data, transaction: @escaping TerminalWriteTransaction) -> AutomaticInputTicket? {
        guard bytes.count > 1, bytes.count <= 16 * 1024, bytes.last == 0x0d,
              bytes.dropLast().allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        let ticket = lock.withLock { () -> AutomaticInputTicket? in
            guard automaticWriter != nil, automaticClean, automaticOutstanding == nil, failure == nil, closedReason == nil,
                  !draining, pending.count == sent, bytes.count <= capacity else { return nil }
            let ticket = AutomaticInputTicket()
            automaticOutstanding = (ticket, unclassifiedGeneration)
            automaticExternalEffect = false
            automaticClean = false
            automaticEverUsed = true
            pending.append(bytes)
            automaticSegment = AutomaticSegment(end: pending.count, ticket: ticket, transaction: transaction)
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
        confirmAutomaticInputGeneration(ticket) != nil
    }

    /// Return the user-input generation in the same critical section as the
    /// clean confirmation, so later use of this proof can detect any edit.
    func confirmAutomaticInputGeneration(_ ticket: AutomaticInputTicket) -> UInt64? {
        lock.withLock {
            guard let outstanding = automaticOutstanding, outstanding.ticket == ticket else { return nil }
            automaticOutstanding = nil
            automaticExternalEffect = false
            guard outstanding.generation == unclassifiedGeneration, failure == nil, closedReason == nil else { return nil }
            automaticClean = true
            return unclassifiedGeneration
        }
    }

    func hasInputGeneration(_ generation: UInt64) -> Bool {
        lock.withLock { unclassifiedGeneration == generation && failure == nil && closedReason == nil }
    }

    /// Called only inside the caller's run/read lease, directly around the
    /// nonblocking write. A queued user edit wins before this lock is acquired.
    private func writeAutomaticIfStillClean(_ ticket: AutomaticInputTicket,
                                             _ write: () throws -> Int) throws -> Int {
        try lock.withLock {
            guard let outstanding = automaticOutstanding, outstanding.ticket == ticket,
                  outstanding.generation == unclassifiedGeneration, failure == nil, closedReason == nil else {
                throw AutomaticInputWithdrawn()
            }
            do {
                let count = try write()
                if count > 0 { automaticExternalEffect = true }
                return count
            } catch {
                automaticExternalEffect = true
                throw error
            }
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
            let next: (work: DrainChunk?, onIdle: (@Sendable () -> Void)?) = lock.withLock {
                guard failure == nil, sent < pending.count else {
                    pending.removeAll(keepingCapacity: false)
                    sent = 0
                    draining = false
                    let callback = idleWaiter
                    idleWaiter = nil
                    return (nil, callback)
                }
                let start = pending.startIndex + sent
                if let segment = automaticSegment, sent < segment.end {
                    let end = pending.startIndex + segment.end
                    return (.automatic(Data(pending[start..<end]), segment), nil)
                }
                return (.ordinary(Data(pending[start..<min(start + 64 * 1024, pending.endIndex)])), nil)
            }
            next.onIdle?()
            guard let work = next.work else { return }
            do {
                let chunk: Data
                let written: Int
                switch work {
                case let .ordinary(bytes):
                    chunk = bytes
                    written = try await writer(bytes)
                case let .automatic(bytes, segment):
                    chunk = bytes
                    let guarded: TerminalWriteTransaction = { [self] write in
                        do {
                            return try segment.transaction {
                                try self.writeAutomaticIfStillClean(segment.ticket, write)
                            }
                        } catch is AutomaticInputWithdrawn { return nil }
                    }
                    guard let automaticWriter,
                          let count = try await automaticWriter(bytes, guarded) else {
                        let outcome: AutomaticWriteOutcome? = lock.withLock {
                            guard automaticSegment?.ticket == segment.ticket else { return nil }
                            let started = sent > 0
                            let start = pending.startIndex + sent, end = pending.startIndex + segment.end
                            pending.removeSubrange(start..<end)
                            if var submission = manualSubmission, submission.writtenAt == nil {
                                if submission.end > segment.end { submission.end -= segment.end - sent; manualSubmission = submission }
                                else if submission.end > sent { manualSubmission = nil }
                            }
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
                    written = count
                }
                if written > 0 {
                    idleWrites = 0
                    lock.withLock {
                        sent = min(pending.count, sent + min(written, chunk.count))
                        if var submission = manualSubmission, submission.writtenAt == nil, sent >= submission.end {
                            submission.writtenAt = DispatchTime.now().uptimeNanoseconds
                            manualSubmission = submission
                        }
                        if let segment = automaticSegment, sent >= segment.end {
                            automaticSegment = nil
                            segment.ticket.completion.finish(.written)
                        }
                        // Compact occasionally instead of shifting on every write.
                        if sent >= 256 * 1024, sent * 2 >= pending.count {
                            if var submission = manualSubmission, submission.writtenAt == nil {
                                submission.end -= sent
                                manualSubmission = submission
                            }
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
                let stopped = lock.withLock { () -> (AutomaticInputTicket?, (@Sendable () -> Void)?) in
                    let automatic = automaticSegment?.ticket
                    let callback = idleWaiter
                    automaticSegment = nil
                    idleWaiter = nil
                    self.failure = failure
                    pending.removeAll()
                    sent = 0
                    draining = false
                    return (automatic, callback)
                }
                stopped.0?.completion.finish(.unknown)
                onError(failure)
                stopped.1?()
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
