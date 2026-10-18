import Foundation
import LoomCore
import Synchronization

/// The output side of a Chat-face child: stdout is framed and decoded here, on the process's IO queue, so no UI thread
/// parses JSON; the frames go to the driver in order, stamped with Loom's clock (the 40 s no-activity rule counts any
/// stdout line). Stderr keeps only its first bytes, for diagnostics.
///
/// Memory is bounded. Lines are bounded by the decoder's line limit; what the driver has not taken yet is bounded by
/// `maximumBacklog` bytes of stdout: past it, the read waits (on this run's own IO queue) until the driver catches up,
/// so the child's stdout pipe fills and the child waits to write. Nothing is dropped.
final class ChatPipeSink: PipeOutputSink {
    enum Input: Sendable {
        /// Frames of one read; `bytes` is the stdout they came from (the backlog the driver gives back with `taken`).
        case frames([StreamFrame], at: Date, bytes: Int)
        /// Stdout reached end-of-file: the child (and anything it passed the pipe to) is gone.
        case ended
    }

    static let stderrLimit = 16 * 1024
    static let defaultBacklog = 16 << 20

    let inputs: AsyncStream<Input>
    private let continuation: AsyncStream<Input>.Continuation
    private let decoder = Mutex(StreamJSONDecoder())
    private let errorHead = Mutex(Data())
    private let clock: @Sendable () -> Date
    let maximumBacklog: Int
    /// Stdout bytes handed on and not yet taken by the driver; `closed` once nobody will take them.
    private let backlog = Mutex((bytes: 0, closed: false))
    private let room = DispatchSemaphore(value: 0)

    init(clock: @escaping @Sendable () -> Date = { Date() }, maximumBacklog: Int = ChatPipeSink.defaultBacklog) {
        self.clock = clock
        self.maximumBacklog = maximumBacklog
        (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
    }

    func receive(_ data: Data, from stream: PipeStream) {
        switch stream {
        case .standardOutput:
            waitForRoom()
            let frames = decoder.withLock { $0.feed(data) }
            backlog.withLock { $0.bytes += data.count }
            if frames.isEmpty {
                // A partial line: the decoder holds it (bounded by its line limit), nothing waits in the stream.
                taken(data.count)
            } else {
                continuation.yield(.frames(frames, at: clock(), bytes: data.count))
            }
        case .standardError:
            errorHead.withLock { head in
                if head.count < Self.stderrLimit { head.append(data.prefix(Self.stderrLimit - head.count)) }
            }
        }
    }

    /// Blocks the read (this run's IO queue only) while the driver is `maximumBacklog` bytes behind.
    private func waitForRoom() {
        while backlog.withLock({ !$0.closed && $0.bytes >= maximumBacklog }) {
            _ = room.wait(timeout: .now() + .milliseconds(50))
        }
    }

    /// The driver applied a read of `bytes` stdout bytes.
    func taken(_ bytes: Int) {
        let wake = backlog.withLock { state -> Bool in
            let wasFull = state.bytes >= maximumBacklog
            state.bytes = max(0, state.bytes - bytes)
            return wasFull && state.bytes < maximumBacklog
        }
        if wake { room.signal() }
    }

    /// Nobody will take more (the driver let go of the run): a waiting read goes on.
    func close() {
        backlog.withLock { $0.closed = true }
        room.signal()
    }

    /// Stdout bytes handed on that the driver has not taken yet.
    var pendingBytes: Int { backlog.withLock { $0.bytes } }

    func ended(_ stream: PipeStream) {
        guard stream == .standardOutput else { return }
        let frames = decoder.withLock { $0.finish() }
        if !frames.isEmpty { continuation.yield(.frames(frames, at: clock(), bytes: 0)) }
        continuation.yield(.ended)
        continuation.finish()
    }

    /// The first bytes the child wrote to stderr (a resume that fails at once says why there). Never logged as is.
    var standardErrorHead: String { String(decoding: errorHead.withLock { $0 }, as: UTF8.self) }

    /// The first non-empty line of stderr, clipped: what an issue may show of a child that ended at once.
    var standardErrorFirstLine: String? {
        let line = standardErrorHead.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
    }
}
