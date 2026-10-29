import Darwin
import Dispatch
import Foundation

/// The two output streams of a pipe child.
public enum PipeStream: Sendable {
    case standardOutput
    case standardError
}

/// Synchronous consumer of a pipe child's output, called on the process's own
/// IO queue. Implementations must bound their own storage and return promptly:
/// the pipes are always drained, whatever the consumer does with the bytes.
public protocol PipeOutputSink: Sendable {
    func receive(_ data: Data, from stream: PipeStream)
    /// The stream reached end-of-file: the child and everything it passed the
    /// descriptor to have closed it.
    func ended(_ stream: PipeStream)
}

enum PipeInputError: Error, CustomStringConvertible, Sendable {
    /// Input was closed, by `closeInput` or by an earlier failure.
    case closed
    case writeFailed(Int32)

    var description: String {
        switch self {
        case .closed: "Pipe input is closed"
        case let .writeFailed(code): "Pipe write failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

/// Orders task cancellation with one nonblocking input syscall. A cancellation
/// that wins this lock prevents the syscall; one after it cannot undo a write.
private final class ManagedPipeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func attempt(_ write: () throws -> Int) rethrows -> Int? {
        try lock.withLock {
            guard !cancelled else { return nil }
            return try write()
        }
    }
}

/// The parent's ends of a pipe child's three streams. All are close-on-exec;
/// the output ends and `input` are non-blocking.
struct PipeDescriptors: Sendable {
    let input: Int32
    let output: Int32
    let error: Int32

    func closeAll() {
        for descriptor in [input, output, error] where descriptor >= 0 { Darwin.close(descriptor) }
    }
}

/// Pipe sibling of `EventDrivenPTYProcess` for a child a run host started with
/// stdin, stdout and stderr pipes. All descriptor access and reaping happen on
/// one queue; each descriptor is closed exactly once, by its source's cancel
/// handler. Both outputs are always drained, so a child that fills one pipe
/// while the parent writes to another cannot deadlock. Stdin is written through
/// a bounded queue: `write` returns when the bytes have been handed to the pipe,
/// and a write that does not fit the queue waits for room (backpressure).
final class StdioProcess: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "dev.loom.pipe-events", qos: .userInitiated, attributes: .concurrent
    )

    private struct PendingWrite {
        let data: Data
        var offset = 0
        let continuation: CheckedContinuation<Void, any Error>
        var remaining: Int { data.count - offset }
    }

    private struct Admission {
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    let pid: Int32
    private let ioQueue: DispatchQueue
    private let inputLimit: Int
    private let sink: any PipeOutputSink
    private let onExit: @Sendable (Int32?) -> Void
    /// waitpid-shaped, as for the PTY transport: pid with status, 0 while
    /// running, or -2 when the process is gone but its status is unknowable.
    private let reap: @Sendable (Int32, UnsafeMutablePointer<Int32>) -> Int32
    private let reapGrace: Double

    private let writeSource: DispatchSourceWrite
    private let outputSource: DispatchSourceRead
    private let errorSource: DispatchSourceRead
    private let processSource: DispatchSourceProcess
    private let inputCancellation = CompletionLatch()
    private let outputCancellation = CompletionLatch()
    private let errorCancellation = CompletionLatch()
    private let processCancellation = CompletionLatch()
    private let processExit = CompletionLatch()

    // Access only on ioQueue.
    private let inputFD: Int32
    private let outputFD: Int32
    private let errorFD: Int32
    private var inputOpen = true
    private var outputOpen = true
    private var errorOpen = true
    private var writeSourceSuspended = true
    private var pending: [PendingWrite] = []
    private var pendingBytes = 0
    private var admission: [Admission] = []
    private var status: Int32?
    private var exitedWithoutStatus = false
    private var failure: TerminalTransportError?
    private var readBuffer = [UInt8](repeating: 0, count: 65_536)

    init(pid: Int32, descriptors: PipeDescriptors, sink: any PipeOutputSink,
         inputLimit: Int = PipeEndpoint.defaultInputLimit,
         reap: @escaping @Sendable (Int32, UnsafeMutablePointer<Int32>) -> Int32,
         reapGrace: Double = 10,
         onExit: @escaping @Sendable (Int32?) -> Void) {
        self.pid = pid
        self.sink = sink
        self.inputLimit = max(1, inputLimit)
        self.reap = reap
        self.reapGrace = reapGrace
        self.onExit = onExit
        inputFD = descriptors.input
        outputFD = descriptors.output
        errorFD = descriptors.error
        ioQueue = DispatchQueue(label: "dev.loom.pipe-events.\(pid)", target: Self.queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: inputFD, queue: ioQueue)
        outputSource = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: ioQueue)
        errorSource = DispatchSource.makeReadSource(fileDescriptor: errorFD, queue: ioQueue)
        processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)

        let (input, output, error) = (inputFD, outputFD, errorFD)
        let (inputLatch, outputLatch, errorLatch) = (inputCancellation, outputCancellation, errorCancellation)
        writeSource.setEventHandler { [weak self] in self?.pump() }
        writeSource.setCancelHandler { Darwin.close(input); Task { await inputLatch.finish() } }
        outputSource.setEventHandler { [weak self] in self?.readReady(.standardOutput) }
        outputSource.setCancelHandler { Darwin.close(output); Task { await outputLatch.finish() } }
        errorSource.setEventHandler { [weak self] in self?.readReady(.standardError) }
        errorSource.setCancelHandler { Darwin.close(error); Task { await errorLatch.finish() } }
        let processLatch = processCancellation
        let grace = DispatchTimeInterval.milliseconds(Int(reapGrace * 1_000))
        processSource.setEventHandler { [weak self] in
            self?.reapIfExited(retryDeadline: .now() + grace)
        }
        processSource.setCancelHandler { Task { await processLatch.finish() } }

        outputSource.activate()
        errorSource.activate()
        processSource.activate()
        // Created active and kept suspended until a write meets a full pipe.
        writeSource.activate()
        writeSource.suspend()
        // A very short-lived child may already be a zombie before the process
        // source is activated. Its PID stays reserved until this queue reaps it.
        ioQueue.async { [weak self] in self?.reapIfExited() }
    }

    deinit {
        // The supervisor finishes every process before dropping it; this only
        // keeps an abandoned one from leaking descriptors. No other reference
        // exists, so the state needs no queue.
        if inputOpen { releaseInput() }
        if outputOpen { outputSource.cancel() }
        if errorOpen { errorSource.cancel() }
        processSource.cancel()
    }

    // MARK: - Input

    /// Completes when every byte has been written to the pipe. A message is
    /// never withdrawn once queued, so a cancelled caller still gets it sent.
    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ioQueue.async { [self] in
                guard inputOpen else {
                    continuation.resume(throwing: PipeInputError.closed)
                    return
                }
                if admission.isEmpty, pendingBytes == 0 || pendingBytes + data.count <= inputLimit {
                    accept(PendingWrite(data: data, continuation: continuation))
                } else {
                    admission.append(Admission(data: data, continuation: continuation))
                }
            }
        }
    }

    /// Managed task input is never accepted into the ordinary pending queue.
    /// The lease and cancellation token both guard the actual nonblocking
    /// syscall. A partial write is an unknown effect: close stdin and require
    /// the owner to stop the run rather than ever replaying its remainder.
    func writeManaged(_ data: Data, admission gate: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome {
        guard !data.isEmpty, data.count <= 64 * 1_024 else { return .deferred }
        let cancellation = ManagedPipeCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ManagedTaskWriteOutcome, Never>) in
                ioQueue.async { [self] in
                    guard inputOpen, pending.isEmpty, admission.isEmpty else {
                        continuation.resume(returning: .deferred)
                        return
                    }
                    do {
                        let written = try gate {
                            try cancellation.attempt {
                                let count = data.withUnsafeBytes { Darwin.write(inputFD, $0.baseAddress!, $0.count) }
                                if count >= 0 { return count }
                                let code = errno
                                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { return 0 }
                                throw PipeInputError.writeFailed(code)
                            } ?? 0
                        }
                        guard let written, written != 0 else {
                            continuation.resume(returning: .deferred)
                            return
                        }
                        if written == data.count {
                            continuation.resume(returning: .submitted)
                        } else {
                            failInput(.closed)
                            continuation.resume(returning: .unknown)
                        }
                    } catch {
                        failInput(.closed)
                        continuation.resume(returning: .unknown)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Closes the child's stdin (it sees end-of-file) and fails writes still
    /// queued; a caller that needs them delivered awaits `write` first.
    func closeInput() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async { [self] in
                if inputOpen { failInput(PipeInputError.closed) }
                continuation.resume()
            }
        }
        try? await inputCancellation.wait(operation: "closing stdin of \(pid)", timeoutSeconds: 2)
    }

    private func accept(_ write: PendingWrite) {
        var write = write
        if pending.isEmpty {
            // Fast path: most messages fit the pipe at once.
            switch writeSome(&write) {
            case .complete:
                write.continuation.resume()
                return
            case .blocked:
                break
            case let .failed(code):
                write.continuation.resume(throwing: PipeInputError.writeFailed(code))
                failInput(PipeInputError.writeFailed(code))
                return
            }
        }
        pending.append(write)
        pendingBytes += write.remaining
        resumeWriteSource()
    }

    private enum WriteOutcome { case complete, blocked, failed(Int32) }

    private func writeSome(_ write: inout PendingWrite) -> WriteOutcome {
        while write.remaining > 0 {
            let count = write.data.withUnsafeBytes {
                Darwin.write(inputFD, $0.baseAddress! + write.offset, write.remaining)
            }
            if count > 0 { write.offset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .blocked }
            return .failed(errno)
        }
        return .complete
    }

    /// The write source fired: the pipe has room.
    private func pump() {
        guard inputOpen else { return }
        while !pending.isEmpty {
            let before = pending[0].remaining
            switch writeSome(&pending[0]) {
            case .complete:
                pendingBytes -= before
                pending.removeFirst().continuation.resume()
            case .blocked:
                pendingBytes -= before - pending[0].remaining
                admitWaiting()
                return
            case let .failed(code):
                failInput(PipeInputError.writeFailed(code))
                return
            }
        }
        suspendWriteSource()
        admitWaiting()
    }

    private func admitWaiting() {
        while let next = admission.first, pendingBytes == 0 || pendingBytes + next.data.count <= inputLimit {
            admission.removeFirst()
            accept(PendingWrite(data: next.data, continuation: next.continuation))
            if !inputOpen { return }
        }
    }

    /// Fails everything queued and closes the descriptor (once).
    private func failInput(_ error: PipeInputError) {
        guard inputOpen else { return }
        inputOpen = false
        let queued = pending.map(\.continuation) + admission.map(\.continuation)
        pending.removeAll()
        admission.removeAll()
        pendingBytes = 0
        releaseInput()
        for continuation in queued { continuation.resume(throwing: error) }
    }

    private func releaseInput() {
        inputOpen = false
        // A suspended source must be resumed before it can be cancelled.
        if writeSourceSuspended { writeSourceSuspended = false; writeSource.resume() }
        writeSource.cancel()
    }

    private func resumeWriteSource() {
        guard writeSourceSuspended else { return }
        writeSourceSuspended = false
        writeSource.resume()
    }

    private func suspendWriteSource() {
        guard !writeSourceSuspended else { return }
        writeSourceSuspended = true
        writeSource.suspend()
    }

    // MARK: - Output

    private func readReady(_ stream: PipeStream) {
        let descriptor = stream == .standardOutput ? outputFD : errorFD
        for _ in 0..<16 {
            guard isOpen(stream) else { return }
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                sink.receive(readBuffer.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) }, from: stream)
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            if count < 0, errno == EINTR { continue }
            if count < 0 { failure = .readFailed(errno) }
            closeOutput(stream)
            return
        }
    }

    private func isOpen(_ stream: PipeStream) -> Bool {
        stream == .standardOutput ? outputOpen : errorOpen
    }

    /// End-of-file (or a read failure): the stream is done; the descriptor goes.
    private func closeOutput(_ stream: PipeStream) {
        guard isOpen(stream) else { return }
        switch stream {
        case .standardOutput: outputOpen = false; outputSource.cancel()
        case .standardError: errorOpen = false; errorSource.cancel()
        }
        sink.ended(stream)
    }

    // MARK: - Finish

    /// Call only after ownership sampling says the leader no longer exists.
    /// Waits `outputDrainSeconds` for both outputs to reach end-of-file (a
    /// descendant may still hold a pipe), then closes everything and reaps.
    func finish(outputDrainSeconds: Double) async throws -> Int32? {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, outputDrainSeconds)
        while await outputsOpen(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        await closeInput()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async { [self] in
                closeOutput(.standardOutput)
                closeOutput(.standardError)
                continuation.resume()
            }
        }
        try await outputCancellation.wait(operation: "closing stdout of \(pid)", timeoutSeconds: 2)
        try await errorCancellation.wait(operation: "closing stderr of \(pid)", timeoutSeconds: 2)
        // A process event can arrive before the host's status does; an explicit
        // final reap also covers a missed or early one-shot event.
        ioQueue.async { [weak self] in
            guard let self else { return }
            reapIfExited(retryDeadline: .now() + .milliseconds(Int(reapGrace * 1_000)))
        }
        try await processExit.wait(operation: "reaping process \(pid)", timeoutSeconds: reapGrace + 0.5)
        processSource.cancel()
        try await processCancellation.wait(operation: "cancelling process source \(pid)", timeoutSeconds: 2)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32?, any Error>) in
            ioQueue.async { [self] in
                // A status that arrived after an earlier reap timed out still
                // finishes the run; a timeout is not a permanent verdict.
                if case .timedOut? = failure, status == nil, !exitedWithoutStatus { retryLateReap() }
                if let status { continuation.resume(returning: status) }
                else if exitedWithoutStatus { continuation.resume(returning: nil) }
                else if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume(throwing: TerminalTransportError.waitFailed(ECHILD)) }
            }
        }
    }

    func exitStatus() async -> Int32? {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in continuation.resume(returning: status) }
        }
    }

    private func outputsOpen() async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in continuation.resume(returning: outputOpen || errorOpen) }
        }
    }

    /// One immediate reap attempt on ioQueue after a timed-out wait.
    private func retryLateReap() {
        var childStatus: Int32 = 0
        let result = reap(pid, &childStatus)
        if result == pid {
            status = childStatus
            failure = nil
            onExit(childStatus)
        } else if result == -2 {
            exitedWithoutStatus = true
            failure = nil
            onExit(nil)
        }
    }

    private func reapIfExited(retryDeadline: DispatchTime? = nil) {
        guard status == nil, !exitedWithoutStatus else { return }
        var childStatus: Int32 = 0
        let result = reap(pid, &childStatus)
        if result == pid {
            status = childStatus
            if case .timedOut? = failure { failure = nil }
            onExit(childStatus)
            Task { await processExit.finish() }
        } else if result == -2 {
            exitedWithoutStatus = true
            if case .timedOut? = failure { failure = nil }
            onExit(nil)
            Task { await processExit.finish() }
        } else if let retryDeadline {
            if DispatchTime.now().uptimeNanoseconds < retryDeadline.uptimeNanoseconds {
                ioQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                    self?.reapIfExited(retryDeadline: retryDeadline)
                }
            } else {
                failure = failure ?? .timedOut("reaping process \(pid)")
                Task { await processExit.finish() }
            }
        }
    }
}
