import Darwin
import Foundation
import Testing

/// Suites that start supervisors, run scopes, the hook server and fake providers run one at a time within a test
/// target's process. Side by side they load the machine enough to make the timing of stop, quit and hook tests flaky.
/// Each such suite takes the gate for its whole run: a lock file named after the test process. SwiftPM runs each test
/// target in a process of its own, one after another, so the gate orders the suites of one target, not of all of them.
public struct ProcessHeavy: SuiteTrait, TestScoping {
    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        // Held already by the suite around this test: taking it again would wait for itself.
        guard !ProcessHeavyGate.held else { return try await function() }
        let descriptor = await ProcessHeavyGate.acquire()
        defer { ProcessHeavyGate.release(descriptor) }
        try await ProcessHeavyGate.$held.withValue(true) { try await function() }
    }
}

extension Trait where Self == ProcessHeavy {
    /// Runs the suite alone among the process-heavy suites of its test target.
    public static var processHeavy: Self { ProcessHeavy() }
}

public enum ProcessHeavyGate {
    @TaskLocal public static var held = false

    static var path: String { NSTemporaryDirectory() + "loom-process-heavy-tests-\(getpid()).lock" }

    /// A descriptor holding the lock (-1 when the file cannot be opened: the suite then runs ungated).
    static func acquire() async -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            // sleep: flock has no async form; the poll is the wait for the suite before this one to end.
            try? await Task.sleep(for: .milliseconds(20))
        }
        return descriptor
    }

    static func release(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
