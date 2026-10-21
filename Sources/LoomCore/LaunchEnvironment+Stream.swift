import Darwin
import Foundation

/// Why a streamed helper (`ProcessSupervisor.streamHelper`) ended without its output being complete.
public enum StreamHelperError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The one deadline passed: the child was sent SIGTERM and, if it stayed, SIGKILL after the grace.
    case timedOut

    public var description: String {
        switch self {
        case .timedOut: "The helper did not finish in time"
        }
    }
}

extension LaunchEnvironment {
    /// The blocking half of `ProcessSupervisor.streamHelper`: writes `input` to the child's stdin (then closes it),
    /// hands every piece of stdout to `onChunk` as it arrives, and returns when the child exited with status 0 and its
    /// output is drained. Throws `LoomError.outputTooLarge` past a stream's limit, `LoomError.helperExit` for another
    /// status, `StreamHelperError.timedOut` at the deadline and `CancellationError` when `cancelled` turns true; in
    /// the last two the child gets SIGTERM at once and SIGKILL after `terminationGrace`. A hook that throws (the
    /// supervisor's shutdown) kills the child at once. Whatever the child left in its group or scope is killed before
    /// returning, as `runHelper` does. Nothing the child writes is logged.
    static func streamHelper(
        _ executable: String, _ arguments: [String], environment: [String: String], directory: String?, input: Data,
        timeout: TimeInterval, terminationGrace: TimeInterval, outputLimit: Int, errorLimit: Int,
        spawner: HelperSpawner, cancelled: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (Data) -> Void,
        onSpawn: @escaping (pid_t) throws -> Void, onPoll: @escaping () throws -> Void
    ) throws {
        if cancelled() { throw CancellationError() }
        var stdin: [Int32] = [-1, -1], output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        func closeAll() { (stdin + output + errors).filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        defer { closeAll() }
        guard pipe(&stdin) == 0 else { throw LoomError.system("Helper input pipe", errno) }
        guard pipe(&output) == 0 else { throw LoomError.system("Helper output pipe", errno) }
        guard pipe(&errors) == 0 else { throw LoomError.system("Helper error pipe", errno) }
        for fd in stdin + output + errors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw LoomError.system("Helper pipe flags", errno) }
        }
        for fd in [stdin[1], output[0], errors[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw LoomError.system("Helper pipe mode", errno) }
        }
        _ = fcntl(stdin[1], F_SETNOSIGPIPE, 1) // a child that closed its input is no signal for Loom
        let pid = try spawner.spawn(executable, arguments, environment, directory, stdin[0], output[1], errors[1])
        // Only the child keeps its ends; EOF on a read end then means it closed (or exited).
        Darwin.close(stdin[0]); stdin[0] = -1
        Darwin.close(output[1]); output[1] = -1
        Darwin.close(errors[1]); errors[1] = -1
        // Every way out (end, failure, shutdown) stops what the child left and collects it; the polite SIGTERM comes
        // before, in the two cases that have time for it.
        defer { spawner.abort(pid) }
        try onSpawn(pid)

        let now = { ProcessInfo.processInfo.systemUptime }
        let deadline = now() + timeout
        var nextObservation = now()
        var pending = input
        var inputOpen = true
        func finishInput() { if inputOpen { Darwin.close(stdin[1]); stdin[1] = -1; inputOpen = false } }
        if input.isEmpty { finishInput() }
        var stdoutOpen = true, stderrOpen = true
        var received = 0
        var stderr = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)

        func feedInput() {
            while inputOpen, !pending.isEmpty {
                let count = pending.withUnsafeBytes { Darwin.write(stdin[1], $0.baseAddress, min($0.count, 65_536)) }
                if count > 0 { pending.removeFirst(count); continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                pending.removeAll() // the child closed its input (EPIPE): nothing more to deliver
            }
            if pending.isEmpty { finishInput() }
        }
        func readOutput() throws {
            for _ in 0..<16 where stdoutOpen {
                let count = Darwin.read(output[0], &bytes, bytes.count)
                if count > 0 {
                    received += count
                    guard received <= outputLimit else { throw LoomError.outputTooLarge(limit: outputLimit) }
                    onChunk(Data(bytes.prefix(count)))
                } else if count == 0 { stdoutOpen = false }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else if errno != EINTR { throw LoomError.system("Helper output read", errno) }
            }
        }
        func readErrors() throws {
            for _ in 0..<16 where stderrOpen {
                let count = Darwin.read(errors[0], &bytes, bytes.count)
                if count > 0 {
                    stderr.append(contentsOf: bytes.prefix(count))
                    guard stderr.count <= errorLimit else { throw LoomError.outputTooLarge(limit: errorLimit) }
                } else if count == 0 { stderrOpen = false }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else if errno != EINTR { throw LoomError.system("Helper error read", errno) }
            }
        }
        /// SIGTERM now, SIGKILL (the deferred abort) if the child is still there after the grace.
        func endGently() throws {
            spawner.terminate(pid)
            let limit = now() + max(0, terminationGrace)
            while now() < limit {
                if try spawner.status(pid) != nil { return }
                usleep(5_000)
            }
        }

        feedInput()
        while true {
            if cancelled() { try endGently(); throw CancellationError() }
            if now() >= nextObservation {
                try onPoll()
                nextObservation = now() + 0.02
            }
            feedInput()
            try readOutput()
            try readErrors()
            if let status = try spawner.status(pid) {
                try onPoll()
                // The child is gone: what its pipes still hold is all there will be (a grandchild holding them open
                // does not stretch the call; the abort below removes it).
                for _ in 0..<257 where stdoutOpen { try readOutput() }
                try readErrors()
                if status != 0 {
                    let signal = status & 0x7f
                    let detail = String(decoding: stderr.prefix(300), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw LoomError.helperExit(status: signal != 0 ? 128 + signal : status >> 8, detail: detail)
                }
                return
            }
            guard now() < deadline else { try endGently(); throw StreamHelperError.timedOut }
            if stdoutOpen {
                // Wakes at once for output; the short timeout keeps cancellation, the deadline and the exit check prompt.
                var watched = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)]
                if stderrOpen { watched.append(pollfd(fd: errors[0], events: Int16(POLLIN), revents: 0)) }
                _ = poll(&watched, nfds_t(watched.count), 10)
            } else {
                usleep(5_000)
            }
        }
    }
}
