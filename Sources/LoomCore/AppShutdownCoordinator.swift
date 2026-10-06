import Foundation

/// The app's quit state machine, kept out of AppKit so it can be tested.
/// One shared shutdown at a time; the app maps the result to its own
/// termination reply.
@MainActor
public final class AppShutdownCoordinator {
    public enum State: Equatable {
        case idle
        case running
        /// Verified; the app is exiting and admits no new work.
        case finished
        /// The last shutdown could not be verified; the app must stay open.
        case failed(remaining: Int, errors: [String])
    }

    public typealias Shutdown = @Sendable () async -> ShutdownReport

    public private(set) var state: State = .idle
    private let shutdown: Shutdown

    public init(shutdown: @escaping Shutdown) {
        self.shutdown = shutdown
    }

    /// Starts one shared shutdown. `reply` is delivered through a run-loop
    /// perform in common modes: AppKit may wait for it in a nested run loop
    /// inside a main-queue block, where MainActor tasks cannot run.
    public func requestQuit(
        prepareReply: (@Sendable (ShutdownReport) async -> Void)? = nil,
        reply: @escaping @MainActor (ShutdownReport) -> Void
    ) {
        guard state != .running, state != .finished else { return }
        state = .running
        let shutdown = shutdown
        Task.detached {
            let report = await shutdown()
            // Collect diagnostics off the main actor before the final delivery.
            // A nested AppKit termination wait cannot service main-actor tasks.
            await prepareReply?(report)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.state = report.succeeded ? .finished
                        : .failed(remaining: report.remaining.count, errors: report.errors)
                    reply(report)
                }
            }
        }
    }
}
