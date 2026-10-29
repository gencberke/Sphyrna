import Foundation
import LoomCore

/// A bounded, run-local protocol inbox. Losing a proof frame invalidates the
/// run synchronously; progress cannot silently displace identity or approvals.
final class ManagedClaudeTaskSink: PipeOutputSink, @unchecked Sendable {
    struct Batch: Sendable {
        let id: UUID
        let frames: [StreamFrame]
    }

    let batches: AsyncStream<Batch>
    private let continuation: AsyncStream<Batch>.Continuation
    private let lock = NSLock()
    private let ingress: ManagedTaskIngress
    private var decoder = StreamJSONDecoder(maximumLineBytes: 1 << 20)
    private var fragments = 0
    private var outstanding: [UUID: Int] = [:]
    private var closed = false

    init(ingress: ManagedTaskIngress) {
        self.ingress = ingress
        (batches, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(4))
    }

    func receive(_ data: Data, from stream: PipeStream) {
        guard stream == .standardOutput, !data.isEmpty else { return }
        lock.withLock {
            guard !closed else { return }
            ingress.begin()
            fragments += 1
            guard data.count <= 64 * 1024 else { finishLocked(invalid: true); return }
            let frames = decoder.feed(data)
            let held = (decoder.bufferedByteCount > 0 || data.last != 10) ? 1 : 0
            let ends = fragments - held
            fragments = held
            if frames.isEmpty {
                for _ in 0..<ends { ingress.end() }
                return
            }
            let id = UUID()
            outstanding[id] = ends
            switch continuation.yield(Batch(id: id, frames: frames)) {
            case .enqueued: break
            case .dropped, .terminated: finishLocked(invalid: true)
            @unknown default: finishLocked(invalid: true)
            }
        }
    }

    /// End only after every event from the batch has been awaited by Core.
    func applied(_ id: UUID) {
        lock.withLock {
            guard let count = outstanding.removeValue(forKey: id) else { return }
            for _ in 0..<count { ingress.end() }
        }
    }

    func ended(_ stream: PipeStream) {
        guard stream == .standardOutput else { return }
        lock.withLock {
            // An incomplete final line is not native consumption evidence.
            if fragments > 0 { ingress.invalidate() }
            for _ in 0..<fragments { ingress.end() }
            fragments = 0
            continuation.finish()
        }
    }

    func close(invalid: Bool = false) {
        lock.withLock { finishLocked(invalid: invalid) }
    }

    private func finishLocked(invalid: Bool) {
        guard !closed else { return }
        closed = true
        if invalid { ingress.invalidate() }
        for _ in 0..<(fragments + outstanding.values.reduce(0, +)) { ingress.end() }
        fragments = 0
        outstanding.removeAll()
        continuation.finish()
    }
}

/// Retired before any await in close. Admission is checked again by the pipe
/// writer at the syscall, including when an actor call waited for its queue.
final class ManagedClaudeWriteFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func attempt(_ effect: () throws -> Int?) rethrows -> Int? {
        try lock.withLock { active ? try effect() : nil }
    }

    func revoke() { lock.withLock { active = false } }
}
