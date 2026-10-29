import Foundation

/// Runs blocking work (a child's sleep-and-poll capture, a socket's `poll` against a deadline) on a thread of its own and
/// awaits it, never on a thread of Swift's cooperative pool. The pool has one thread per CPU: a few such waits at once held
/// all of them, and every other async task of the process stood still until they ended. `GitWorkspace.run` waits the same way.
/// Public so tests and their fixtures run blocking work the same way (DEVELOPMENT §3.1). Background work passes a lower
/// `qualityOfService` (the plan-limits exchange runs at `.utility`), so the thread costs no more energy than it needs.
public func onOwnThread<Value: Sendable>(
    _ name: String, qualityOfService: QualityOfService = .userInitiated,
    _ work: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
        let thread = Thread { continuation.resume(with: Result { try work() }) }
        thread.name = name
        thread.qualityOfService = qualityOfService
        thread.start()
    }
}
