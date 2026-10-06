import Foundation
import LoomCore

/// A-slice synthetic run state, kept out of AppKit so it can be tested.
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

    public typealias Launch = @MainActor (
        _ sessionID: UUID, _ arguments: [String], _ surface: TerminalSurface
    ) async throws -> ManagedSessionLaunch

    public private(set) var state: State = .idle
    public private(set) var surface: TerminalSurface?
    public var terminalFontSize: Double = 14 {
        didSet { surface?.setFontSize(terminalFontSize) }
    }
    public var onStateChange: ((State) -> Void)?
    public var onLaunchError: ((any Error) -> Void)?

    private let launchRun: Launch
    private let events: SessionEventHub
    private var eventTask: Task<Void, Never>?

    public init(events: SessionEventHub, launch: @escaping Launch) {
        self.events = events
        self.launchRun = launch
    }

    /// Production wiring: synthetic fixture under the shared supervisor.
    public convenience init(supervisor: ProcessSupervisor, executable: String, directory: String) {
        self.init(events: supervisor.events,
                  launch: Self.syntheticLaunch(supervisor: supervisor, executable: executable,
                                               directory: directory))
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

    /// Returns the new surface, or nil when a run is launching or live. The caller shows the surface immediately.
    @discardableResult
    public func newTerminal(arguments: [String]) -> TerminalSurface? {
        switch state {
        case .launching, .live: return nil
        case .idle, .ended: break
        }
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
