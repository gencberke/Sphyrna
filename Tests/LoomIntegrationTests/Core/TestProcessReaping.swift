import Darwin
import Foundation
import LoomTestSupport

extension Process {
    /// Teardown for a child a test spawned: signal it, then await its end with a deadline.
    ///
    /// `Process.waitUntilExit()` parks forever when something else in the shared
    /// test process already reaped the pid (Foundation never observes the exit).
    /// This only polls: `kill(pid, 0)` keeps succeeding for an unreaped zombie
    /// and fails with ESRCH once anyone has reaped it, so Foundation's own
    /// reaper is never raced. Returns false when the child is still there after
    /// `timeout`; teardown must not hang the suite on that.
    @discardableResult
    func terminateAndAwaitExit(signal: Int32 = SIGKILL, timeout: TimeInterval = 5) async -> Bool {
        let pid = processIdentifier
        guard pid > 0, isRunning else { return true }
        _ = kill(pid, signal)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        while clock.now < deadline {
            if !isRunning || kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: waitPoll) // sleep: the poll of a child's end; nothing else tells an async caller
        }
        return !isRunning || kill(pid, 0) != 0
    }

    /// The teardown for a `defer`, which cannot await, when a test ends early: the signal only, while the child is still
    /// Foundation's to reap. A test that reaches its end awaits `terminateAndAwaitExit`.
    func signalForTeardown(_ signal: Int32 = SIGKILL) {
        if isRunning { _ = kill(processIdentifier, signal) }
    }
}
