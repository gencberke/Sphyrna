import Darwin
import Foundation

extension Process {
    /// Teardown for a child a test spawned: signal it, then wait with a deadline.
    ///
    /// `Process.waitUntilExit()` parks forever when something else in the shared
    /// test process already reaped the pid (Foundation never observes the exit).
    /// This only polls: `kill(pid, 0)` keeps succeeding for an unreaped zombie
    /// and fails with ESRCH once anyone has reaped it, so Foundation's own
    /// reaper is never raced. Returns false when the child is still there after
    /// `timeout`; teardown must not hang the suite on that.
    @discardableResult
    func terminateAndAwaitExit(signal: Int32 = SIGKILL, timeout: TimeInterval = 5) -> Bool {
        let pid = processIdentifier
        guard pid > 0, isRunning else { return true }
        _ = kill(pid, signal)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning || kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return !isRunning || kill(pid, 0) != 0
    }
}
