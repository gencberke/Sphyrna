import Foundation

/// Run-scoped IO capability for a child started with pipes, beside
/// `TerminalEndpoint`. Callers obtain it once at launch; subsequent IO never
/// enters ProcessSupervisor and an old endpoint cannot target a new run. The
/// output goes to the `PipeOutputSink` given at launch; the pipes are drained
/// whether or not anything looks at them.
public final class PipeEndpoint: @unchecked Sendable {
    /// Bytes queued for the child's stdin before further writes wait. A single
    /// message larger than this is still accepted, alone.
    public static let defaultInputLimit = 1 << 20

    public let pid: Int32
    private let transport: StdioProcess

    init(pid: Int32, descriptors: PipeDescriptors, sink: any PipeOutputSink,
         reap: @escaping @Sendable (Int32, UnsafeMutablePointer<Int32>) -> Int32,
         inputLimit: Int = PipeEndpoint.defaultInputLimit,
         onExit: @escaping @Sendable (Int32?) -> Void) {
        self.pid = pid
        transport = StdioProcess(pid: pid, descriptors: descriptors, sink: sink,
                                 inputLimit: inputLimit, reap: reap, onExit: onExit)
    }

    /// Returns when every byte is in the pipe. A write that does not fit the
    /// bounded queue waits for room, so a child that does not read stalls its
    /// writers instead of growing memory. Throws once input is closed.
    public func write(_ data: Data) async throws {
        try await transport.write(data)
    }

    /// Closes the child's stdin: it sees end-of-file. Queued writes fail.
    public func closeInput() async { await transport.closeInput() }

    func finish(outputDrainSeconds: Double = 0.5) async throws -> Int32? {
        try await transport.finish(outputDrainSeconds: outputDrainSeconds)
    }

    func exitStatus() async -> Int32? { await transport.exitStatus() }
}

/// What a run's IO capability is, for the supervisor's shared stop path.
enum RunEndpoint: Sendable {
    case terminal(TerminalEndpoint)
    case pipe(PipeEndpoint)

    func finish() async throws -> Int32? {
        switch self {
        case let .terminal(terminal): try await terminal.finish()
        case let .pipe(pipe): try await pipe.finish()
        }
    }

    func exitStatus() async -> Int32? {
        switch self {
        case let .terminal(terminal): await terminal.exitStatus()
        case let .pipe(pipe): await pipe.exitStatus()
        }
    }

    /// Stop and Quit close a pipe child's stdin before any signal. A terminal
    /// has no equivalent: it is hung up by the signal schedule.
    func closeInput() async {
        if case let .pipe(pipe) = self { await pipe.closeInput() }
    }

    var isPipe: Bool {
        if case .pipe = self { true } else { false }
    }
}
