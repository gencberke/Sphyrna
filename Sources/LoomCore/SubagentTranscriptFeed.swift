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

/// Follows one subagent transcript while someone looks at it (FB4-5). A vnode source watches the file;
/// nothing runs while it is idle. A burst of writes is read once, `coalescing` after the first of them,
/// so a busy agent costs at most 1 / `coalescing` reads a second. Reading, parsing and entry building happen
/// on a utility queue; the batches arrive on `batches`.
///
/// A feed is used once: `start()` begins it, `stop()` ends it (cancels the source, closes the files and
/// finishes `batches`), and neither does anything a second time. `stop()` returns at once, so a caller on the
/// main actor never waits for a read in flight; a batch yielded before the teardown ran may still arrive.
public final class SubagentTranscriptFeed: @unchecked Sendable {
    public static let defaultCoalescing: TimeInterval = 0.2
    /// The most entries one batch carries; a larger burst keeps its newest.
    static let maximumEntriesPerBatch = 1_000

    public let batches: AsyncStream<SubagentTranscriptBatch>
    private let continuation: AsyncStream<SubagentTranscriptBatch>.Continuation
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
    /// The descriptor the vnode source watches (it has its own: the tail reads through another).
    private var watched: Int32 = -1

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
        (batches, continuation) = AsyncStream.makeStream(of: SubagentTranscriptBatch.self)
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
        continuation.finish()
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
        guard scheduled == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, phase == .running else { return }
            scheduled = nil
            deliver()
            if reattachNeeded {
                reattachNeeded = false
                attachSource()
            }
        }
        scheduled = item
        queue.asyncAfter(deadline: .now() + coalescing, execute: item)
    }

    /// Reads what is new and yields it: nothing when there is nothing new and nothing restarted.
    private func deliver() {
        guard let tail else { return }
        var entries: [SubagentTranscriptEntry] = []
        let outcome = tail.read(oversized: { entries.append(.tooLong) }) { entries.append(contentsOf: parser.parse($0)) }
        var omitted = outcome.omittedEarlier
        if entries.count > Self.maximumEntriesPerBatch {
            entries.removeFirst(entries.count - Self.maximumEntriesPerBatch)
            omitted = true
        }
        guard !entries.isEmpty || outcome.restarted else { return }
        continuation.yield(SubagentTranscriptBatch(
            entries: entries, replacesEarlier: outcome.restarted, omitsEarlier: omitted))
    }
}
