import Foundation

// A child process a test starts is waited for without holding a thread of the cooperative pool (DEVELOPMENT §3.1): its
// pipes are read to the end on threads of their own and its exit is awaited, never `readDataToEndOfFile()` or
// `waitUntilExit()` on the pool. The product's `onOwnThread` does the same for product code; this support target keeps no
// product dependency, so it has its own thread here.

/// How a child ended and what it wrote.
public struct ChildResult: Sendable {
    public let status: Int32
    public let reason: Process.TerminationReason
    public let output: Data
    public let error: Data

    public var outputText: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: error, as: UTF8.self) }
}

/// Starts `process`, which has not been started, and returns once it has ended and its output and error pipes are read to
/// the end. Pipes are made for standard output and error unless the process has its own; `input` is written to standard
/// input and closed.
public func runToEnd(_ process: Process, input: Data? = nil) async throws -> ChildResult {
    let output = (process.standardOutput as? Pipe) ?? Pipe()
    let error = (process.standardError as? Pipe) ?? Pipe()
    process.standardOutput = output
    process.standardError = error
    let stdin = input.map { _ in Pipe() }
    if let stdin { process.standardInput = stdin }
    try process.run()
    if let stdin, let input {
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
    }
    async let out = readToEnd(output.fileHandleForReading)
    async let err = readToEnd(error.fileHandleForReading)
    let (outData, errData) = await (out, err)
    let status = await exitStatus(of: process)
    return ChildResult(status: status, reason: process.terminationReason, output: outData, error: errData)
}

/// Runs `executable` with `arguments` to its end (`runToEnd`).
public func runToEnd(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                     directory: URL? = nil, input: Data? = nil) async throws -> ChildResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = directory }
    return try await runToEnd(process, input: input)
}

/// Runs blocking work that cannot fail (a product's synchronous command, a blocking read) on a thread of its own and awaits
/// it, as `onOwnThread` does for work that throws.
public func onTestThread<Value: Sendable>(_ name: String, _ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.name = name
        thread.start()
    }
}

/// Reads `handle` to its end on a thread of its own.
public func readToEnd(_ handle: FileHandle) async -> Data {
    await onTestThread("test child read") { handle.readDataToEndOfFile() }
}

/// The exit status of a started process, once it has ended: looked at every `waitPoll`, never blocking.
public func exitStatus(of process: Process) async -> Int32 {
    while process.isRunning {
        try? await Task.sleep(for: waitPoll) // sleep: the poll of a child's exit; nothing else tells an async caller
    }
    return process.terminationStatus
}

/// Whether a started process ended within `within`; it is left running when it did not.
public func childEnded(_ process: Process, within: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + within
    while process.isRunning {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: waitPoll) // sleep: the poll of a child's exit against a deadline
    }
    return true
}
