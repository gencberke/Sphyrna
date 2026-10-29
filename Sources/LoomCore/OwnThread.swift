import Foundation

/// Runs blocking work (a child's sleep-and-poll capture, a socket's `poll` against a deadline) on a thread of its own and
/// awaits it, never on a thread of Swift's cooperative pool. The pool has one thread per CPU: a few such waits at once held
/// all of them, and every other async task of the process stood still until they ended. `GitWorkspace.run` waits the same way.
func onOwnThread<Value: Sendable>(_ name: String, _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
        let thread = Thread { continuation.resume(with: Result { try work() }) }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
