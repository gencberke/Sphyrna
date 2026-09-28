import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class DelayedReap: @unchecked Sendable {
    private let lock = NSLock()
    private var zeroReplies = 20
    private var recordedCalls = 0

    func wait(_ pid: Int32, _ status: UnsafeMutablePointer<Int32>) -> Int32 {
        lock.lock()
        recordedCalls += 1
        if zeroReplies > 0 {
            zeroReplies -= 1
            lock.unlock()
            return 0
        }
        lock.unlock()
        return Darwin.waitpid(pid, status, WNOHANG)
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct EventDrivenPTYProcessTests {
    @Test func earlyExitNoticeRetriesUntilChildCanBeReaped() async throws {
        let process = try PTYProcess(
            executable: "/usr/bin/true", arguments: [],
            environment: ["PATH": "/usr/bin:/bin"], directory: "/tmp",
            rows: 24, columns: 80
        )
        defer {
            _ = Darwin.kill(process.pid, SIGKILL)
            _ = Darwin.waitpid(process.pid, nil, WNOHANG)
        }
        let delayed = DelayedReap()
        let transport = EventDrivenPTYProcess(
            process: process, onOutput: { _ in }, onExit: { _ in },
            reap: { delayed.wait($0, $1) }
        )
        let status = try await transport.finish(outputDrainSeconds: 0.1)
        #expect(status == 0)
        #expect(delayed.calls >= 21)
    }

    @Test func latchTimeoutAndCancellationResumeWaiters() async throws {
        let timeoutLatch = CompletionLatch()
        await #expect(throws: TerminalTransportError.self) {
            try await timeoutLatch.wait(
                operation: "test timeout", timeoutSeconds: 0.05
            )
        }

        let cancellationLatch = CompletionLatch()
        let waiter = Task {
            try await cancellationLatch.wait(
                operation: "test cancellation", timeoutSeconds: 5
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await cancellationLatch.finish()
    }
}
