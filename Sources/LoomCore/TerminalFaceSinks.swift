import Foundation

/// The place a new terminal run will draw: the grid it starts with, the sink its output goes to, and the UI's own handle
/// for it (given back when the run is adopted or its start failed).
@MainActor
public struct TerminalRunSink {
    public let rows: UInt16
    public let columns: UInt16
    public let output: any TerminalOutputSink
    public let handle: AnyObject

    public init(rows: UInt16, columns: UInt16, output: any TerminalOutputSink, handle: AnyObject) {
        self.rows = rows
        self.columns = columns
        self.output = output
        self.handle = handle
    }
}

/// What `SessionService` needs from the UI's terminal surfaces (no AppKit here): a sink for a new run, taking the run in
/// once it launched, letting a sink go when its start failed, and the screen the user saw at Stop.
@MainActor
public protocol TerminalFaceSinks: AnyObject {
    /// A sink for a run about to start; nil when the UI has none to give.
    func newRunSink() -> TerminalRunSink?
    /// The run launched: its terminal is shown from now on, as the owner's.
    func adopt(_ launch: RuntimeLaunch, into sink: TerminalRunSink)
    /// The start failed (or an approval could not be answered): nothing will ever draw into the sink.
    func runFailedToStart(_ sink: TerminalRunSink)
    /// Brings the surfaces in line with the hub's current states (a failed start, a verified Stop).
    func reconcile() async
    /// Stop begins: keeps what the user sees on the session's terminal, before any signal, so whatever the program draws
    /// while it exits cannot replace it. Returns the run that screen belongs to, nil when the session has no terminal here.
    func captureForStop(sessionID: UUID) -> UUID?
    /// The Stop is over: the run's end took the capture, or it is let go (a stop that failed took none).
    func releaseStopCapture(run: UUID)
}
