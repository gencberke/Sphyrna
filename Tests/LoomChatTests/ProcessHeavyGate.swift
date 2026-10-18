import Darwin
import Foundation
import Testing

// One copy per test target (they share no test module); keep them identical.

/// Suites that start supervisors, run scopes, the hook server and fake providers run one at a time, across the test
/// targets (all of them run in one test process). Side by side they load the machine enough to make the timing of
/// stop, quit and hook tests flaky. Each such suite takes the gate for its whole run: a lock file named after the test
/// process, so the targets' copies of this trait share it.
struct ProcessHeavy: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // Held already by the suite around this test: taking it again would wait for itself.
        guard !ProcessHeavyGate.held else { return try await function() }
        let descriptor = await ProcessHeavyGate.acquire()
        defer { ProcessHeavyGate.release(descriptor) }
        try await ProcessHeavyGate.$held.withValue(true) { try await function() }
    }
}

extension Trait where Self == ProcessHeavy {
    /// Runs the suite alone among the process-heavy suites of every test target.
    static var processHeavy: Self { ProcessHeavy() }
}

enum ProcessHeavyGate {
    @TaskLocal static var held = false

    static var path: String { NSTemporaryDirectory() + "loom-process-heavy-tests-\(getpid()).lock" }

    /// A descriptor holding the lock (-1 when the file cannot be opened: the suite then runs ungated).
    static func acquire() async -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
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
