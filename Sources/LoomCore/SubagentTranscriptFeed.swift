import Darwin
import Dispatch
import Foundation

/// One batch of a subagent transcript's entries, parsed off the main thread.
public struct SubagentTranscriptBatch: Equatable, Sendable {
    public var entries: [SubagentTranscriptEntry]
    /// What was delivered before no longer applies: the first batch, or the file shrank or was replaced.
    public var replacesEarlier: Bool
    /// Earlier entries exist that this batch does not carry (the read began inside the file).
    public var omitsEarlier: Bool

    public init(entries: [SubagentTranscriptEntry], replacesEarlier: Bool, omitsEarlier: Bool) {
        self.entries = entries
        self.replacesEarlier = replacesEarlier
        self.omitsEarlier = omitsEarlier
    }
}

/// One consumer follows a feed. Asking for the next batch acknowledges the previous one; leaving the iterator stops it.
public struct SubagentTranscriptBatches: AsyncSequence, Sendable {
    public typealias Element = SubagentTranscriptBatch

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let lease: SubagentTranscriptLease?

        public mutating func next() async -> SubagentTranscriptBatch? {
            guard let lease else { return nil }
            return await lease.next()
        }
    }

    fileprivate let delivery: SubagentTranscriptDelivery

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(lease: delivery.claim()) }
}

/// A shared lease survives value-iterator copies and ends the feed when its last copy leaves scope.
fileprivate final class SubagentTranscriptLease: @unchecked Sendable {
    private let delivery: SubagentTranscriptDelivery
    init(_ delivery: SubagentTranscriptDelivery) { self.delivery = delivery }
    deinit { delivery.abandon() }
    func next() async -> SubagentTranscriptBatch? { await delivery.next() }
}

/// A one-batch handoff; no callback or continuation is resumed while holding its lock.
fileprivate final class SubagentTranscriptDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var closed = false
    private var pending: SubagentTranscriptBatch?
    private var waiter: CheckedContinuation<SubagentTranscriptBatch?, Never>?
    private var acknowledgementDue = false
    private var onAcknowledgement: (@Sendable () -> Void)?
    private var onAbandonment: (@Sendable () -> Void)?

    func install(acknowledge: @escaping @Sendable () -> Void, abandon: @escaping @Sendable () -> Void) {
        lock.withLock { onAcknowledgement = acknowledge; onAbandonment = abandon }
    }

    func claim() -> SubagentTranscriptLease? {
        lock.withLock {
            guard !claimed else { return nil }
            claimed = true
            return SubagentTranscriptLease(self)
        }
    }

    func next() async -> SubagentTranscriptBatch? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var acknowledge: (@Sendable () -> Void)?
                var result: SubagentTranscriptBatch??
                lock.withLock {
                    if acknowledgementDue {
                        acknowledgementDue = false
                        acknowledge = onAcknowledgement
                    }
                    if let batch = pending {
                        pending = nil
                        acknowledgementDue = true
                        result = .some(batch)
                    } else if closed || waiter != nil {
                        result = .some(nil)
                    } else {
                        waiter = continuation
                    }
                }
                acknowledge?()
                if let result { continuation.resume(returning: result) }
            }
        } onCancel: { self.abandon() }
    }

    func offer(_ batch: SubagentTranscriptBatch) {
        let waiting: CheckedContinuation<SubagentTranscriptBatch?, Never>? = lock.withLock {
            guard !closed else { return nil }
            if let waiting = waiter {
                waiter = nil
                acknowledgementDue = true
                return waiting
            }
            precondition(pending == nil, "the producer must wait for acknowledgement")
            pending = batch
            return nil
        }
        waiting?.resume(returning: batch)
    }

    /// A normal stop lets a batch already handed off drain before the stream ends.
    func finish() {
        let waiting: CheckedContinuation<SubagentTranscriptBatch?, Never>? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: nil)
    }

    func abandon() {
        var callback: (@Sendable () -> Void)?
        let waiting: CheckedContinuation<SubagentTranscriptBatch?, Never>? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            pending = nil
            callback = onAbandonment
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: nil)
        callback?()
    }
}

/// Follows one subagent transcript while someone looks at it (FB4-5). A vnode source watches the file;
/// nothing runs while it is idle. A burst of writes is read once, `coalescing` after the first of them,
/// so a busy agent costs at most 1 / `coalescing` reads a second. Reading, parsing and entry building happen
/// on a utility queue; the batches arrive on `batches`. One consumer acknowledges a batch by asking for the next;
/// while it is busy, writes are coalesced without parsing or queuing further batches.
///
/// A feed is used once: `start()` begins it, `stop()` ends it (cancels the source, closes the files and
/// finishes `batches`), and neither does anything a second time. `stop()` returns at once, so a caller on the
/// main actor never waits for a read in flight; a batch yielded before the teardown ran may still arrive.
public final class SubagentTranscriptFeed: @unchecked Sendable {
    public static let defaultCoalescing: TimeInterval = 0.2
    /// The most entries one batch carries; a larger burst keeps its newest.
    static let maximumEntriesPerBatch = 1_000
    /// An additional retained-byte bound for unusually large parsed entries.
    static let maximumEntryBytesPerBatch = 1 * 1024 * 1024

    public let batches: SubagentTranscriptBatches
    private let delivery: SubagentTranscriptDelivery
    private let queue = DispatchQueue(label: "loom.subagent.transcript", qos: .utility)
    private let coalescing: TimeInterval
    private let parser: SubagentTranscriptParser
    private let file: SubagentTranscriptFile

    private enum Phase { case idle, running, stopped }
    // Everything below is confined to `queue`.
    private var phase = Phase.idle
    private var tail: SubagentTranscriptTail?
    private var source: (any DispatchSourceFileSystemObject)?
    /// Left when a source's cancel handler has closed its descriptor; `stopAndWait` waits on it (any number of times).
    private let sourcesClosed = DispatchGroup()
    private var scheduled: DispatchWorkItem?
    /// The file was moved or removed: watch whatever has its name once the pending read is done.
    private var reattachNeeded = false
    /// Work that arrived while a previously delivered batch awaited the consumer's next request.
    private var dirty = false
    private var awaitingConsumer = false
    /// The first brief can arrive after an initially empty file was read.
    private var deliveredBrief = false
    /// The descriptor the vnode source watches (it has its own: the tail reads through another).
    private var watched: Int32 = -1
    /// Completed read attempts, for verifying that a stalled consumer does not cause more work.
    private var reads = 0

    /// Nil when the file cannot be opened.
    public convenience init?(file: SubagentTranscriptFile, coalescing: TimeInterval = defaultCoalescing) {
        self.init(file: file, coalescing: coalescing, coldWindowBytes: SubagentTranscriptTail.defaultColdWindowBytes,
                  maximumLineBytes: SubagentTranscriptTail.defaultMaximumLineBytes)
    }

    init?(file: SubagentTranscriptFile, coalescing: TimeInterval, coldWindowBytes: Int, maximumLineBytes: Int) {
        guard let tail = SubagentTranscriptTail(
            file: file, coldWindowBytes: coldWindowBytes, maximumLineBytes: maximumLineBytes) else { return nil }
        self.file = file
        self.coalescing = coalescing
        parser = SubagentTranscriptParser()
        self.tail = tail
        let delivery = SubagentTranscriptDelivery()
        self.delivery = delivery
        batches = SubagentTranscriptBatches(delivery: delivery)
        delivery.install(acknowledge: { [weak self] in self?.acknowledge() }, abandon: { [weak self] in self?.stop() })
    }

    deinit { teardown() }

    /// Begins watching and delivers the first batch (the file's tail) at once. Idempotent.
    public func start() {
        queue.async { [self] in
            guard phase == .idle else { return }
            phase = .running
            attachSource()
            deliver()
        }
    }

    /// Stops for good and returns at once: the teardown runs on the feed's queue (the block keeps the feed
    /// alive until it has), after any read in flight. Idempotent.
    public func stop() {
        queue.async { [self] in teardown() }
    }

    /// `stop()`, then waits until no callback is pending, the files are closed and `batches` has ended (tests).
    func stopAndWait() {
        queue.sync { teardown() }
        sourcesClosed.wait()
    }

    /// Descriptors still open, for tests: the read descriptor and the watched one.
    var openDescriptors: [Int32] { queue.sync { [tail?.openDescriptor, watched >= 0 ? watched : nil].compactMap { $0 } } }

    var readCount: Int { queue.sync { reads } }

    // MARK: Queue

    private func teardown() {
        guard phase != .stopped else { return }
        phase = .stopped
        scheduled?.cancel()
        scheduled = nil
        source?.cancel()
        source = nil
        tail?.close()
        tail = nil
        watched = -1
        delivery.finish()
    }

    private func attachSource() {
        source?.cancel()
        source = nil
        watched = -1
        let descriptor = open(file.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        sourcesClosed.enter()
        let observed = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
        observed.setCancelHandler { [sourcesClosed] in
            close(descriptor)
            sourcesClosed.leave()
        }
        observed.setEventHandler { [weak self, weak observed] in
            guard let self, let observed, phase == .running else { return }
            if !observed.data.intersection([.rename, .delete, .revoke]).isEmpty {
                // The file was moved or removed: read what is there, then watch whatever has the name now.
                source = nil
                watched = -1
                observed.cancel()
                schedule(reattach: true)
            } else {
                schedule(reattach: false)
            }
        }
        source = observed
        watched = descriptor
        observed.resume()
    }

    private func schedule(reattach: Bool) {
        reattachNeeded = reattachNeeded || reattach
        dirty = true
        guard !awaitingConsumer else { return }
        guard scheduled == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, phase == .running else { return }
            scheduled = nil
            if reattachNeeded {
                reattachNeeded = false
                attachSource()
            }
            dirty = false
            deliver()
        }
        scheduled = item
        queue.asyncAfter(deadline: .now() + coalescing, execute: item)
    }

    private func acknowledge() {
        queue.async { [weak self] in
            guard let self, phase == .running, awaitingConsumer else { return }
            awaitingConsumer = false
            if dirty { schedule(reattach: false) }
        }
    }

    /// Reads what is new and yields it: nothing when there is nothing new and nothing restarted.
    private func deliver() {
        guard let tail else { return }
        reads += 1
        var entries = SubagentRecentEntries()
        let outcome = tail.read(oversized: { entries.append(.tooLong) }) {
            for entry in parser.parse($0) { entries.append(entry) }
        }
        if outcome.restarted { deliveredBrief = false }
        let newest = entries.result(preserveFirstBrief: !deliveredBrief)
        if newest.entries.contains(where: { if case .brief = $0 { true } else { false } }) { deliveredBrief = true }
        let omitted = outcome.omittedEarlier || newest.omitted
        guard !newest.entries.isEmpty || outcome.restarted else { return }
        awaitingConsumer = true
        delivery.offer(SubagentTranscriptBatch(
            entries: newest.entries, replacesEarlier: outcome.restarted, omitsEarlier: omitted))
    }
}

/// Bounded newest-entry ring, with the initial brief retained separately if it falls out of the ring.
private struct SubagentRecentEntries {
    private struct Slot {
        let ordinal: Int
        let entry: SubagentTranscriptEntry
        let bytes: Int
    }

    private let capacity = SubagentTranscriptFeed.maximumEntriesPerBatch
    private let byteLimit = SubagentTranscriptFeed.maximumEntryBytesPerBatch
    private var slots = Array<Slot?>(repeating: nil, count: SubagentTranscriptFeed.maximumEntriesPerBatch)
    private var head = 0
    private var count = 0
    private var bytes = 0
    private var ordinal = 0
    private var firstBrief: Slot?
    private var dropped = false

    mutating func append(_ entry: SubagentTranscriptEntry) {
        let slot = Slot(ordinal: ordinal, entry: entry, bytes: Self.estimate(entry))
        ordinal += 1
        if firstBrief == nil, case .brief = entry { firstBrief = slot }
        guard slot.bytes <= byteLimit else { dropped = true; return }
        while count == capacity || bytes > byteLimit - slot.bytes {
            let old = slots[head]!
            bytes -= old.bytes
            slots[head] = nil
            head = (head + 1) % capacity
            count -= 1
            dropped = true
        }
        slots[(head + count) % capacity] = slot
        count += 1
        bytes += slot.bytes
    }

    func result(preserveFirstBrief: Bool) -> (entries: [SubagentTranscriptEntry], omitted: Bool) {
        var entries: [SubagentTranscriptEntry] = []
        var skipped = 0
        var retainedBytes = bytes
        if preserveFirstBrief, let brief = firstBrief,
           count == 0 || brief.ordinal < slots[head]!.ordinal {
            while count - skipped >= capacity || retainedBytes > byteLimit - brief.bytes {
                let old = slots[(head + skipped) % capacity]!
                retainedBytes -= old.bytes
                skipped += 1
            }
            entries.append(brief.entry)
        }
        for index in skipped..<count { entries.append(slots[(head + index) % capacity]!.entry) }
        return (entries, dropped || skipped > 0)
    }

    private static func estimate(_ entry: SubagentTranscriptEntry) -> Int {
        let overhead = 64
        switch entry {
        case let .brief(text), let .text(text): return overhead + text.utf8.count
        case let .toolCall(name, argument): return overhead + name.utf8.count + argument.utf8.count
        case let .toolResult(lines, _, _): return overhead + lines.reduce(0) { $0 + 24 + $1.utf8.count }
        case .tooLong, .thought: return overhead
        }
    }
}
