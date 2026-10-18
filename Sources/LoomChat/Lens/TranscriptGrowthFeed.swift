import Darwin
import Dispatch
import Foundation
import LoomCore

/// Follows one transcript file while a view shows it, so a terminal session's chat view tails the file Claude is
/// writing. A vnode source watches the file: there is no polling and no timer while the file is quiet, and nothing
/// exists at all before `start()` or after `stop()`.
///
/// A burst of writes is read once, `coalescing` after the first of them (Claude flushes about every 100 ms, so a busy
/// session costs at most 1 / `coalescing` reads a second). Each read is `TranscriptLens.readGrowth()`, so the model
/// and the delta the view needs come from the lens, and the batches arrive on `updates`. Only one read is in flight; a
/// write that lands meanwhile schedules the next one.
///
/// The first read after `start()` is always yielded, even when it found nothing new: an earlier feed over the same lens
/// may have been stopped with a read in flight, and that read's bytes were consumed by the lens but never delivered.
///
/// A watch that cannot be made (the file was replaced and the new one does not exist yet) is retried after 0.25 s, then at
/// doubling intervals up to 5 s, and only while there is no watch.
///
/// A feed delivers either whole models (`updates`, the default) or `ModelChange`s (`changes`): `Delivery` is chosen when it is
/// made, and the stream of the other kind stays empty. A view that keeps its own copy of the model takes changes, so the
/// lens never copies a model the view still holds.
///
/// Changes are delivered one at a time: after one is yielded the next read waits for `acknowledge()`, which the consumer
/// calls once it has applied the change. While the consumer is busy (the main thread is blocked) the file goes on growing, and
/// the next read takes everything written meanwhile as one change, so a slow consumer costs one rebuild, not one for every
/// 50 ms. The first read after `start()` is always delivered, even when it found nothing: an empty change carries the lens's
/// current sequence number, so a receiver that lost a change when a feed was stopped (one was in flight) sees it is behind.
///
/// A feed is used once: `start()` begins it, `stop()` ends it (cancels the source, finishes `updates`), and neither does
/// anything a second time. `stop()` returns at once; an update yielded before the teardown ran may still arrive. The
/// feed never closes the lens; its owner does.
public final class TranscriptGrowthFeed: @unchecked Sendable, ModelChangeSource {
    public static let defaultCoalescing: TimeInterval = 0.05

    public enum Delivery: Sendable {
        case updates
        case changes
    }

    public let updates: AsyncStream<TranscriptLens.Update>
    public let changes: AsyncStream<ModelChange>
    private let continuation: AsyncStream<TranscriptLens.Update>.Continuation
    private let changeContinuation: AsyncStream<ModelChange>.Continuation
    private let delivery: Delivery
    private let queue = DispatchQueue(label: "loom.chat.transcript.growth", qos: .userInitiated)
    private let coalescing: TimeInterval
    private let path: String
    private let lens: TranscriptLens

    private enum Phase { case idle, running, stopped }
    // Everything below is confined to `queue`.
    private var phase = Phase.idle
    private var source: (any DispatchSourceFileSystemObject)?
    private let sourcesClosed = DispatchGroup()
    private var scheduled: DispatchWorkItem?
    private var readInFlight = false
    /// A write landed while a read was in flight.
    private var dirty = false
    /// The file was moved or removed: watch whatever has its name once the pending read is done.
    private var reattachNeeded = false
    private var reads = 0
    /// The next finished read is delivered even when empty (the first one after `start()`).
    private var deliverNext = false
    private var attachRetry: DispatchWorkItem?
    private var attachFailures = 0
    /// A change was yielded and the consumer has not acknowledged it (`.changes` only).
    private var awaitingConsumer = false

    public init(file: ClaudeTranscriptFile, lens: TranscriptLens, coalescing: TimeInterval = defaultCoalescing, delivery: Delivery = .updates) {
        path = file.path
        self.lens = lens
        self.coalescing = coalescing
        self.delivery = delivery
        (updates, continuation) = AsyncStream.makeStream(of: TranscriptLens.Update.self)
        (changes, changeContinuation) = AsyncStream.makeStream(of: ModelChange.self)
    }

    deinit { teardown() }

    /// Begins watching, then reads once at once: bytes written between the lens's cold open and the watch are not missed.
    public func start() {
        queue.async { [self] in
            guard phase == .idle else { return }
            phase = .running
            deliverNext = true
            attachSource()
            beginRead()
        }
    }

    /// Stops for good and returns at once. Idempotent.
    public func stop() {
        queue.async { [self] in teardown() }
    }

    /// The consumer applied the last change: the next read may begin (`.changes` only). Idempotent.
    public func acknowledge() {
        queue.async { [self] in
            guard awaitingConsumer else { return }
            awaitingConsumer = false
            guard phase == .running, dirty else { return }
            dirty = false
            schedule(reattach: false)
        }
    }

    /// `stop()`, then waits until the watched descriptor is closed and `updates` has ended (tests).
    public func stopAndWait() {
        queue.sync { teardown() }
        sourcesClosed.wait()
    }

    /// Reads done so far, the start-up read included (tests).
    public var readCount: Int { queue.sync { reads } }

    /// A source exists right now (tests).
    public var isWatching: Bool { queue.sync { source != nil } }

    // MARK: Queue

    private func teardown() {
        guard phase != .stopped else { return }
        phase = .stopped
        scheduled?.cancel()
        scheduled = nil
        attachRetry?.cancel()
        attachRetry = nil
        source?.cancel()
        source = nil
        continuation.finish()
        changeContinuation.finish()
    }

    private func attachSource() {
        source?.cancel()
        source = nil
        let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            scheduleAttachRetry()
            return
        }
        attachFailures = 0
        attachRetry?.cancel()
        attachRetry = nil
        sourcesClosed.enter()
        // `.attrib` is what a truncate with no write after it raises.
        let observed = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
        observed.setCancelHandler { [sourcesClosed] in
            close(descriptor)
            sourcesClosed.leave()
        }
        observed.setEventHandler { [weak self, weak observed] in
            guard let self, let observed, phase == .running else { return }
            if !observed.data.intersection([.rename, .delete, .revoke]).isEmpty {
                source = nil
                observed.cancel()
                schedule(reattach: true)
            } else {
                schedule(reattach: false)
            }
        }
        source = observed
        observed.resume()
    }

    private func scheduleAttachRetry() {
        guard phase == .running, attachRetry == nil else { return }
        let delay = min(0.25 * Double(1 << min(attachFailures, 5)), 5)
        attachFailures += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self, phase == .running else { return }
            attachRetry = nil
            attachSource()
            // Whatever the new file holds is read as soon as it can be watched.
            if source != nil { schedule(reattach: false) }
        }
        attachRetry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func schedule(reattach: Bool) {
        reattachNeeded = reattachNeeded || reattach
        guard scheduled == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, phase == .running else { return }
            scheduled = nil
            beginRead()
        }
        scheduled = item
        queue.asyncAfter(deadline: .now() + coalescing, execute: item)
    }

    private func beginRead() {
        guard phase == .running else { return }
        guard !readInFlight, !awaitingConsumer else {
            dirty = true
            return
        }
        readInFlight = true
        reads += 1
        let lens = lens
        let delivery = delivery
        Task.detached { [weak self] in
            switch delivery {
            case .updates:
                let update = await lens.readGrowth()
                guard let feed = self else { return }
                feed.queue.async { feed.finishRead { $0.continuation.yield(update) } deliver: { !update.delta.isEmpty || update.restarted } }
            case .changes:
                let change = await lens.readGrowthChange()
                guard let feed = self else { return }
                feed.queue.async { feed.finishRead { $0.changeContinuation.yield(change) } deliver: { !change.isEmpty } }
            }
        }
    }

    /// A read ended: hand it over when it has something (or it is the first after `start()`), then go on with what came meanwhile.
    private func finishRead(_ yield: (TranscriptGrowthFeed) -> Void, deliver hasNews: () -> Bool) {
        readInFlight = false
        guard phase == .running else { return }
        if hasNews() || deliverNext {
            yield(self)
            if delivery == .changes { awaitingConsumer = true }
        }
        deliverNext = false
        if reattachNeeded {
            reattachNeeded = false
            attachSource()
            // Whatever was written between the old file's last event and the new watch is read now.
            dirty = true
        }
        if dirty, !awaitingConsumer {
            dirty = false
            schedule(reattach: false)
        }
    }
}
