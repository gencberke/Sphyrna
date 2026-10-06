import Foundation
import LoomCore

/// A-slice run and quit state, kept out of AppKit so it can be tested.
/// One terminal at a time: the reservation is taken synchronously, before
/// the first suspension point, so repeated requests cannot start a second run.
@MainActor
public final class TerminalRunController {
    public enum State: Equatable {
        case idle
        case launching(sessionID: UUID)
        case live(sessionID: UUID, runID: UUID)
        case ended(sessionID: UUID)
    }

    public enum QuitState: Equatable {
        case idle
        case running
        /// Verified; the app is exiting and admits no new work.
        case finished
        /// The last shutdown could not be verified; the app must stay open.
        case failed(remaining: Int, errors: [String])
    }

    public typealias Launch = @MainActor (
        _ sessionID: UUID, _ arguments: [String], _ surface: TerminalSurface
    ) async throws -> ManagedSessionLaunch
    public typealias Shutdown = @Sendable () async -> ShutdownReport

    public private(set) var state: State = .idle
    public private(set) var quitState: QuitState = .idle
    public private(set) var surface: TerminalSurface?
    public var terminalFontSize: Double = 14 {
        didSet { surface?.setFontSize(terminalFontSize) }
    }
    public var onStateChange: ((State) -> Void)?
    public var onLaunchError: ((any Error) -> Void)?

    private let launchRun: Launch
    private let shutdown: Shutdown
    private let events: SessionEventHub
    private var eventTask: Task<Void, Never>?

    public init(events: SessionEventHub, launch: @escaping Launch, shutdown: @escaping Shutdown) {
        self.events = events
        self.launchRun = launch
        self.shutdown = shutdown
    }

    /// Production wiring: synthetic fixture under the shared supervisor.
    public convenience init(supervisor: ProcessSupervisor, executable: String, directory: String) {
        self.init(events: supervisor.events,
                  launch: Self.syntheticLaunch(supervisor: supervisor, executable: executable,
                                               directory: directory),
                  shutdown: { await supervisor.shutdown() })
    }

    public static func syntheticLaunch(supervisor: ProcessSupervisor, executable: String,
                                       directory: String) -> Launch {
        { sessionID, arguments, surface in
            let size = surface.gridSize
            try await supervisor.createSession(ManagedSession(
                id: sessionID, provider: .synthetic, workingDirectory: directory
            ))
            return try await supervisor.launch(
                sessionID: sessionID, executable: executable, arguments: arguments,
                environment: LaunchEnvironment.make(
                    path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
                ),
                rows: size.rows, columns: size.columns, outputSink: surface.outputSink
            )
        }
    }

    /// Returns the new surface, or nil when a run is launching or live, or
    /// quit has started. The caller shows the surface immediately.
    @discardableResult
    public func newTerminal(arguments: [String]) -> TerminalSurface? {
        switch state {
        case .launching, .live: return nil
        case .idle, .ended: break
        }
        // A started shutdown never admits new work, even after it failed.
        guard quitState == .idle else { return nil }
        let sessionID = UUID()
        let surface = TerminalSurface(fontSize: terminalFontSize)
        self.surface = surface
        set(.launching(sessionID: sessionID))
        Task {
            do {
                let launch = try await launchRun(sessionID, arguments, surface)
                guard let runID = launch.session.currentRun?.id else {
                    throw LoomError.message("Managed run identity missing after launch")
                }
                surface.attach(runID: runID, endpoint: launch.terminal)
                // Only this launch's reservation can become live.
                guard state == .launching(sessionID: sessionID) else { return }
                set(.live(sessionID: sessionID, runID: runID))
                observe(sessionID: sessionID, runID: runID, surface: surface)
            } catch {
                surface.runEnded()
                guard state == .launching(sessionID: sessionID) else { return }
                set(.ended(sessionID: sessionID))
                onLaunchError?(error)
            }
        }
        return surface
    }

    /// Starts one shared shutdown. `reply` is delivered through a run-loop
    /// perform in common modes: AppKit may wait for it in a nested run loop
    /// inside a main-queue block, where MainActor tasks cannot run.
    public func requestQuit(
        prepareReply: (@Sendable (ShutdownReport) async -> Void)? = nil,
        reply: @escaping @MainActor (ShutdownReport) -> Void
    ) {
        guard quitState != .running, quitState != .finished else { return }
        quitState = .running
        let shutdown = shutdown
        Task.detached {
            let report = await shutdown()
            // Collect diagnostics off the main actor before the final delivery.
            // A nested AppKit termination wait cannot service main-actor tasks.
            await prepareReply?(report)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.quitState = report.succeeded ? .finished
                        : .failed(remaining: report.remaining.count, errors: report.errors)
                    reply(report)
                }
            }
        }
    }

    /// Recovers from the latest frame only; missed intermediate changes are fine.
    private func observe(sessionID: UUID, runID: UUID, surface: TerminalSurface) {
        eventTask?.cancel()
        let events = events
        eventTask = Task { [weak self] in
            for await frame in await events.subscribe() {
                guard frame.sessions[sessionID]?.runID != runID else { continue }
                surface.runEnded()
                guard let self, self.state == .live(sessionID: sessionID, runID: runID) else { return }
                self.set(.ended(sessionID: sessionID))
                return
            }
        }
    }

    private func set(_ state: State) {
        self.state = state
        onStateChange?(state)
    }
}
