import Foundation
import Synchronization

extension ProcessSupervisor {
    /// A one-shot child that is fed a stdin and answers as a stream: an owned helper like `captureHelper` (registered
    /// with the supervisor, in a run scope of its own when a scope launcher exists, one deadline, bounded output,
    /// cancelled and awaited by `shutdown`; after a successful Quit none is left), but its stdout reaches the caller in
    /// chunks as they come instead of whole at the end. Remora's `claude -p` call is the user.
    ///
    /// `input` is written to the child's stdin and the pipe is then closed (it never goes on argv). The stream yields
    /// the stdout bytes in the order and pieces they arrive in, and finishes when the child exited with status 0 and its
    /// output is drained. It finishes with an error instead when
    /// - the child exited with another status (`LoomError.helperExit`; the head of stderr is the detail),
    /// - stdout passed `outputLimit` or stderr passed `errorLimit` (`LoomError.outputTooLarge`; the child is stopped),
    /// - `timeout` passed since the call began (`StreamHelperError.timedOut`),
    /// - the supervisor is shutting down (`SessionManagementError.shutdownStarted`; the child is killed at once).
    /// The caller ends the call by cancelling its task or by dropping the stream: the child gets SIGTERM at once and
    /// SIGKILL after `terminationGrace` (the same two steps follow the deadline), and nothing more is yielded. The job
    /// stays registered until the child and anything it left are gone. The child's output and stderr are never logged.
    public nonisolated func streamHelper(
        _ executable: String, _ arguments: [String], environment: [String: String], workingDirectory: String? = nil,
        input: Data = Data(), timeout: TimeInterval, terminationGrace: TimeInterval = 2,
        outputLimit: Int = LaunchEnvironment.defaultOutputLimit, errorLimit: Int = 256 * 1024
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let flag = StreamCancelFlag()
            let call = Task {
                do {
                    try await withTaskCancellationHandler {
                        try await self.runOwnedJob(scope: .perCall) { _, job, spawner in
                            try LaunchEnvironment.streamHelper(
                                executable, arguments, environment: environment, directory: workingDirectory,
                                input: input, timeout: timeout, terminationGrace: terminationGrace,
                                outputLimit: outputLimit, errorLimit: errorLimit, spawner: spawner,
                                cancelled: { flag.isSet }, onChunk: { continuation.yield($0) },
                                onSpawn: job.register, onPoll: job.sample
                            )
                        }
                    } onCancel: { flag.set() }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // The consumer stopped (cancelled its task or dropped the stream): end the child.
            continuation.onTermination = { _ in flag.set(); call.cancel() }
        }
    }

    /// The processes the in-flight helpers of the supervisor have been seen to own (a test's window into the
    /// ownership a streamed or captured helper has while it runs; with a scope launcher the scope holds them instead).
    func liveHelperIdentities() -> Set<ProcessIdentity> {
        environmentJobs.values.reduce(into: Set<ProcessIdentity>()) { $0.formUnion($1.observedIdentities()) }
    }

    /// Helper jobs registered with the supervisor right now.
    var helperJobCount: Int { environmentJobs.count }
}

private final class StreamCancelFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
