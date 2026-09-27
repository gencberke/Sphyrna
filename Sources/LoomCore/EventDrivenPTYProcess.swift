import Darwin
import Dispatch
import Foundation

enum TerminalTransportError: Error, CustomStringConvertible, Sendable {
    case closed
    case readFailed(Int32)
    case waitFailed(Int32)

    var description: String {
        switch self {
        case .closed:
            "Terminal is closed"
        case let .readFailed(code):
            "Terminal read failed: \(String(cString: strerror(code))) (\(code))"
        case let .waitFailed(code):
            "Terminal process wait failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

private actor CompletionLatch {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if completed { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !completed else { return }
        completed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Single-reader PTY transport for ProcessSupervisor. All descriptor access and
/// waitpid calls happen on one queue. The read descriptor is closed exactly once
/// by its DispatchSource cancel handler.
final class EventDrivenPTYProcess: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "dev.loom.pty-events", qos: .userInitiated, attributes: .concurrent
    )
    private static let outputLimit = 4 * 1024 * 1024

    let pid: Int32
    private let terminalQueue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let processSource: DispatchSourceProcess
    private let readCancellation = CompletionLatch()
    private let processCancellation = CompletionLatch()
    private let processExit = CompletionLatch()
    private let onExit: @Sendable (Int32) -> Void

    // Access only on terminalQueue.
    private var terminalFD: Int32
    private var terminalOpen = true
    private var readSuspended = false
    private var output = Data()
    private var status: Int32?
    private var failure: TerminalTransportError?

    init(process: PTYProcess, onExit: @escaping @Sendable (Int32) -> Void) {
        pid = process.pid
        terminalFD = process.detachTerminal()
        self.onExit = onExit
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
        processSource.setEventHandler { [weak self] in self?.reapIfExited() }
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
        if readSuspended { readSource.resume() }
        readSource.cancel()
        processSource.cancel()
    }

    func drainOutput() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            terminalQueue.async { [self] in
                if output.isEmpty, let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                let result = output
                output.removeAll(keepingCapacity: true)
                if readSuspended && terminalOpen {
                    readSuspended = false
                    readSource.resume()
                }
                continuation.resume(returning: result)
            }
        }
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

    func closeTerminal() async {
        await withCheckedContinuation { continuation in
            terminalQueue.async { [self] in
                if terminalOpen {
                    terminalOpen = false
                    if readSuspended {
                        readSuspended = false
                        readSource.resume()
                    }
                    readSource.cancel()
                }
                continuation.resume()
            }
        }
        await readCancellation.wait()
    }

    /// Call only after ownership sampling says the leader no longer exists.
    func finish() async throws -> Int32 {
        await closeTerminal()
        await processExit.wait()
        processSource.cancel()
        await processCancellation.wait()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
            terminalQueue.async { [self] in
                if let failure { continuation.resume(throwing: failure) }
                else if let status { continuation.resume(returning: status) }
                else { continuation.resume(throwing: TerminalTransportError.waitFailed(ECHILD)) }
            }
        }
    }

    private func readReady() {
        guard terminalOpen else { return }
        for _ in 0..<16 {
            let capacity = Self.outputLimit - output.count
            if capacity == 0 {
                readSuspended = true
                readSource.suspend()
                return
            }
            var bytes = [UInt8](repeating: 0, count: min(16_384, capacity))
            let count = Darwin.read(terminalFD, &bytes, bytes.count)
            if count > 0 {
                output.append(contentsOf: bytes.prefix(count))
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

    private func reapIfExited() {
        guard status == nil else { return }
        var childStatus: Int32 = 0
        while true {
            let result = waitpid(pid, &childStatus, WNOHANG)
            if result == pid {
                status = childStatus
                onExit(childStatus)
                Task { await processExit.finish() }
                return
            }
            if result == 0 { return }
            if errno == EINTR { continue }
            failure = .waitFailed(errno)
            Task { await processExit.finish() }
            return
        }
    }
}
