import Foundation

/// Synchronous consumers run on the terminal's serial IO queue. Implementations
/// must bound their own storage and return promptly; visibility must not control
/// whether the PTY is drained.
public protocol TerminalOutputSink: Sendable {
    func receive(_ data: Data)
}

/// Bounded byte scrollback used until the terminal engine owns this sink. New
/// output always replaces the oldest bytes instead of applying PTY backpressure.
public final class TerminalScrollback: TerminalOutputSink, @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var storage: [UInt8]
    private var writeIndex = 0
    private var storedCount = 0

    public init(capacity: Int = 4 * 1024 * 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = [UInt8](repeating: 0, count: capacity)
    }

    public func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.withUnsafeBytes { rawBytes in
            let source = rawBytes.bindMemory(to: UInt8.self)
            let kept = min(source.count, capacity)
            let sourceStart = source.count - kept
            let firstCount = min(kept, capacity - writeIndex)
            storage.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return }
                destinationBase.advanced(by: writeIndex).copyMemory(
                    from: sourceBase.advanced(by: sourceStart), byteCount: firstCount
                )
                let secondCount = kept - firstCount
                if secondCount > 0 {
                    destinationBase.copyMemory(
                        from: sourceBase.advanced(by: sourceStart + firstCount),
                        byteCount: secondCount
                    )
                }
            }
            writeIndex = (writeIndex + kept) % capacity
            storedCount = min(capacity, storedCount + kept)
        }
    }

    public func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard storedCount > 0 else { return Data() }
        let start = (writeIndex - storedCount + capacity) % capacity
        let firstCount = min(storedCount, capacity - start)
        var result = Data(storage[start..<(start + firstCount)])
        if firstCount < storedCount {
            result.append(contentsOf: storage[0..<(storedCount - firstCount)])
        }
        storedCount = 0
        return result
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }
}

/// Run-scoped IO capability. Callers obtain it once at launch; subsequent IO
/// never enters ProcessSupervisor and an old endpoint cannot target a new run.
public final class TerminalEndpoint: @unchecked Sendable {
    public let pid: Int32
    public let scrollback: TerminalScrollback
    private let transport: EventDrivenPTYProcess

    init(process: PTYProcess, outputSink: (any TerminalOutputSink)?,
         onExit: @escaping @Sendable (Int32) -> Void) {
        pid = process.pid
        let scrollback = TerminalScrollback()
        self.scrollback = scrollback
        transport = EventDrivenPTYProcess(
            process: process,
            onOutput: { data in
                scrollback.receive(data)
                outputSink?.receive(data)
            },
            onExit: onExit
        )
    }

    public func readAvailable() -> Data { scrollback.drain() }

    public func write(_ data: Data) async throws -> Int {
        try await transport.write(data)
    }

    public func resize(rows: UInt16, columns: UInt16) async throws {
        try await transport.resize(rows: rows, columns: columns)
    }

    func closeTerminal() async { await transport.closeTerminal() }

    func finish(outputDrainSeconds: Double = 0.5) async throws -> Int32 {
        try await transport.finish(outputDrainSeconds: outputDrainSeconds)
    }

    func exitStatus() async -> Int32? { await transport.exitStatus() }
}
