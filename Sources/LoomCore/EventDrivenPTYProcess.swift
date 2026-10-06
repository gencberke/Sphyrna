import Darwin
import Dispatch
import Foundation

enum TerminalTransportError: Error, CustomStringConvertible, Sendable {
    case closed
    case readFailed(Int32)
    case waitFailed(Int32)
    case timedOut(String)

    var description: String {
        switch self {
        case .closed:
            "Terminal is closed"
        case let .readFailed(code):
            "Terminal read failed: \(String(cString: strerror(code))) (\(code))"
        case let .waitFailed(code):
            "Terminal process wait failed: \(String(cString: strerror(code))) (\(code))"
        case let .timedOut(operation):
            "Terminal timed out while \(operation)"
        }
    }
}

actor CompletionLatch {
    private var completed = false
    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
        let timer: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    func wait(operation: String, timeoutSeconds: Double) async throws {
        if completed { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task<Void, Never> { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0.01, timeoutSeconds)))
                    await self?.expire(id: id, operation: operation)
                }
                waiters[id] = Waiter(continuation: continuation, timer: timer)
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })
    }

    func finish() {
        guard !completed else { return }
        completed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values {
            waiter.timer.cancel()
            waiter.continuation.resume()
        }
    }

    private func expire(id: UUID, operation: String) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: TerminalTransportError.timedOut(operation))
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// Single-reader PTY transport for ProcessSupervisor. All descriptor access and
/// waitpid calls happen on one queue. The read descriptor is closed exactly once
/// by its DispatchSource cancel handler.
final class EventDrivenPTYProcess: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "dev.loom.pty-events", qos: .userInitiated, attributes: .concurrent
    )
    let pid: Int32
    private let terminalQueue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let processSource: DispatchSourceProcess
    private let readCancellation = CompletionLatch()
    private let processCancellation = CompletionLatch()
    private let processExit = CompletionLatch()
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32?) -> Void
    /// waitpid-shaped: pid with status, 0 while running, -1 with errno on
    /// failure, or -2 when the process is gone but its status is unknowable.
    private let reap: @Sendable (Int32, UnsafeMutablePointer<Int32>) -> Int32
    /// How long an exit event may precede a reapable status. A run host
    /// reports statuses over a socket, so its window is longer than waitpid's.
    private let reapGrace: Double

    // Access only on terminalQueue.
    private var terminalFD: Int32
    private var terminalOpen = true
    private var status: Int32?
    private var exitedWithoutStatus = false
    private var failure: TerminalTransportError?
    /// One read buffer for the process lifetime; the Data handed to onOutput
    /// is the only copy of each read.
    private var readBuffer = [UInt8](repeating: 0, count: 16_384)

    init(process: PTYProcess, onOutput: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32?) -> Void,
         reap: @escaping @Sendable (Int32, UnsafeMutablePointer<Int32>) -> Int32 = {
             waitpid($0, $1, WNOHANG)
         },
         reapGrace: Double = 1.5) {
        self.reapGrace = reapGrace
        pid = process.pid
        terminalFD = process.detachTerminal()
        self.onOutput = onOutput
        self.onExit = onExit
        self.reap = reap
        terminalQueue = DispatchQueue(
            label: "dev.loom.pty-events.\(process.pid)", target: Self.queue
        )
        readSource = DispatchSource.makeReadSource(fileDescriptor: terminalFD, queue: terminalQueue)
        processSource = DispatchSource.makeProcessSource(
            identifier: process.pid, eventMask: .exit, queue: terminalQueue
        )

        let descriptor = terminalFD
        let readCancellation = readCancellation
        readSource.setEventHandler { [weak self] in self?.readReady() }
        readSource.setCancelHandler {
            Darwin.close(descriptor)
            Task { await readCancellation.finish() }
        }

        let processCancellation = processCancellation
        let grace = DispatchTimeInterval.milliseconds(Int(reapGrace * 1_000))
        processSource.setEventHandler { [weak self] in
            self?.reapIfExited(retryDeadline: .now() + grace)
        }
        processSource.setCancelHandler {
            Task { await processCancellation.finish() }
        }

        readSource.activate()
        processSource.activate()
        // A very short-lived child may already be a zombie before the process
        // source is activated. Its PID remains reserved until this queue reaps it.
        terminalQueue.async { [weak self] in self?.reapIfExited() }
    }

    deinit {
        readSource.cancel()
        processSource.cancel()
    }

    func write(_ data: Data) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            terminalQueue.async { [self] in
                guard terminalOpen else {
                    continuation.resume(throwing: TerminalTransportError.closed)
                    return
                }
                let count = data.withUnsafeBytes { Darwin.write(terminalFD, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { continuation.resume(returning: 0) }
                    else { continuation.resume(throwing: LoomError.system("PTY write", errno)) }
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }

    func resize(rows: UInt16, columns: UInt16) async throws {
        guard rows > 0, columns > 0 else {
            throw LoomError.message("Terminal size must be positive")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            terminalQueue.async { [self] in
                guard terminalOpen else {
                    continuation.resume(throwing: TerminalTransportError.closed)
                    return
                }
                var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
                if ioctl(terminalFD, TIOCSWINSZ, &size) == 0 { continuation.resume() }
                else { continuation.resume(throwing: LoomError.system("PTY resize", errno)) }
            }
        }
    }

    func closeTerminal() async throws {
        await withCheckedContinuation { continuation in
            terminalQueue.async { [self] in
                if terminalOpen {
                    terminalOpen = false
                    readSource.cancel()
                }
                continuation.resume()
            }
        }
        try await readCancellation.wait(
            operation: "closing terminal \(pid)", timeoutSeconds: 2
        )
    }

    /// Call only after ownership sampling says the leader no longer exists.
    func finish(outputDrainSeconds: Double) async throws -> Int32? {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, outputDrainSeconds)
        while await isTerminalOpen(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        try await closeTerminal()
        // A process event can arrive before waitpid can collect the child. A
        // final explicit reap also covers a missed or early one-shot event.
        terminalQueue.async { [weak self] in
            guard let self else { return }
            self.reapIfExited(retryDeadline: .now() + .milliseconds(Int(self.reapGrace * 1_000)))
        }
        try await processExit.wait(
            operation: "reaping process \(pid)", timeoutSeconds: reapGrace + 0.5
        )
        processSource.cancel()
        try await processCancellation.wait(
            operation: "cancelling process source \(pid)", timeoutSeconds: 2
        )
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32?, any Error>) in
            terminalQueue.async { [self] in
                // A status that arrived after an earlier reap timed out still
                // finishes the run; a timeout is not a permanent verdict.
                if case .timedOut? = failure, status == nil, !exitedWithoutStatus { retryLateReap() }
                if let failure { continuation.resume(throwing: failure) }
                else if let status { continuation.resume(returning: status) }
                else if exitedWithoutStatus { continuation.resume(returning: nil) }
                else { continuation.resume(throwing: TerminalTransportError.waitFailed(ECHILD)) }
            }
        }
    }

    func exitStatus() async -> Int32? {
        await withCheckedContinuation { continuation in
            terminalQueue.async { [self] in continuation.resume(returning: status) }
        }
    }

    private func isTerminalOpen() async -> Bool {
        await withCheckedContinuation { continuation in
            terminalQueue.async { [self] in continuation.resume(returning: terminalOpen) }
        }
    }

    private func readReady() {
        guard terminalOpen else { return }
        for _ in 0..<16 {
            let descriptor = terminalFD
            let count = readBuffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                onOutput(readBuffer.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) })
                continue
            }
            if count == 0 || errno == EIO {
                terminalOpen = false
                readSource.cancel()
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            failure = .readFailed(errno)
            terminalOpen = false
            readSource.cancel()
            return
        }
    }

    /// One immediate reap attempt on terminalQueue after a timed-out wait.
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
        while true {
            let result = reap(pid, &childStatus)
            if result == pid {
                status = childStatus
                if case .timedOut? = failure { failure = nil }
                onExit(childStatus)
                Task { await processExit.finish() }
                return
            }
            if result == -2 {
                exitedWithoutStatus = true
                if case .timedOut? = failure { failure = nil }
                onExit(nil)
                Task { await processExit.finish() }
                return
            }
            if result == 0 {
                if let retryDeadline {
                    if DispatchTime.now().uptimeNanoseconds < retryDeadline.uptimeNanoseconds {
                        terminalQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                            self?.reapIfExited(retryDeadline: retryDeadline)
                        }
                    } else {
                        failure = failure ?? .timedOut("reaping process \(pid)")
                        Task { await processExit.finish() }
                    }
                }
                return
            }
            if errno == EINTR { continue }
            failure = .waitFailed(errno)
            Task { await processExit.finish() }
            return
        }
    }
}
