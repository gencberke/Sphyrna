import Darwin
import Foundation
import Testing

/// Suites that start supervisors, run scopes, the hook server and fake providers run one at a time within a test
/// target's process. Side by side they load the machine enough to make the timing of stop, quit and hook tests flaky.
/// Each such suite takes the gate for its whole run: a lock file named after the test process. SwiftPM runs each test
/// target in a process of its own, one after another, so the gate orders the suites of one target, not of all of them.
///
/// Each test of such a suite also runs under the pool sentinel (`PoolSentinel`): a test whose run starves the cooperative
/// pool fails once, by name, instead of the timing of the tests beside it failing at random.
public struct ProcessHeavy: TestTrait, SuiteTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        guard test.isSuite else { return try await PoolSentinel.watch(function, at: test.sourceLocation) }
        // Held already by the suite around this one: taking it again would wait for itself.
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

/// Hops on the cooperative pool every `interval` while a test runs. A hop needs a free pool thread to wake, so a hop that
/// wakes late measures how long every pool thread was held: by a blocking wait in this test, in a fake it drives, or in a
/// test beside it. A hop late by more than `tolerance` makes one issue for the test, with the longest stall; that one
/// named failure stands for the timeouts the stall causes in the tests around it.
public enum PoolSentinel {
    public static let interval = Duration.milliseconds(50)
    public static let tolerance = Duration.seconds(1)

    /// Runs `function` under the sentinel; a stall is recorded at `location` (the test).
    public static func watch(_ function: @Sendable () async throws -> Void, at location: SourceLocation) async throws {
        let hops = Task.detached { await longestStall() }
        do {
            try await function()
        } catch {
            hops.cancel()
            report(await hops.value, at: location)
            throw error
        }
        hops.cancel()
        report(await hops.value, at: location)
    }

    /// The longest a hop woke after it was due, until cancelled.
    static func longestStall() async -> Duration {
        let clock = ContinuousClock()
        var longest = Duration.zero
        while !Task.isCancelled {
            let due = clock.now + interval
            // sleep: the hop itself; the time it wakes after `due` is the measure.
            do { try await Task.sleep(until: due, clock: clock) } catch { break }
            longest = max(longest, clock.now - due)
        }
        return longest
    }

    static func report(_ stall: Duration, at location: SourceLocation) {
        guard stall > tolerance else { return }
        let seconds = Double(stall.components.seconds) + Double(stall.components.attoseconds) / 1e18
        Issue.record("the pool stalled \(String(format: "%.1f", seconds)) s while this test ran (this test or one beside it holds pool threads)",
                     sourceLocation: location)
    }
}
