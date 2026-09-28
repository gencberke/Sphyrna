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
    private var storage: [UInt8] = []
    private var writeIndex = 0
    private var storedCount = 0

    public init(capacity: Int = 4 * 1024 * 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.withUnsafeBytes { rawBytes in
            let source = rawBytes.bindMemory(to: UInt8.self)
            let kept = min(source.count, capacity)
            let sourceStart = source.count - kept
            ensureStorage(forAdditionalBytes: kept)
            let firstCount = min(kept, storage.count - writeIndex)
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
            writeIndex = (writeIndex + kept) % storage.count
            storedCount = min(storage.count, storedCount + kept)
        }
    }

    public func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard storedCount > 0 else { return Data() }
        let start = (writeIndex - storedCount + storage.count) % storage.count
        let firstCount = min(storedCount, storage.count - start)
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

    /// Logical backing allocation, exposed so idle-memory acceptance can be
    /// tested without relying on noisy process-wide footprint measurements.
    public var allocatedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    private func ensureStorage(forAdditionalBytes count: Int) {
        let required = min(capacity, storedCount + count)
        guard required > storage.count else { return }
        let target = min(
            capacity,
            max(required, storage.isEmpty ? min(16 * 1024, capacity) : storage.count * 2)
        )
        var expanded = [UInt8](repeating: 0, count: target)
        if storedCount > 0 {
            let start = (writeIndex - storedCount + storage.count) % storage.count
            for offset in 0..<storedCount {
                expanded[offset] = storage[(start + offset) % storage.count]
            }
        }
        storage = expanded
        writeIndex = storedCount % storage.count
    }
}

/// Run-scoped IO capability. Callers obtain it once at launch; subsequent IO
/// never enters ProcessSupervisor and an old endpoint cannot target a new run.
public final class TerminalEndpoint: @unchecked Sendable {
    public let pid: Int32
    /// Nil when the supplied sink owns terminal history, avoiding a duplicate
    /// byte scrollback beside the future terminal engine's own bounded state.
    public let scrollback: TerminalScrollback?
    private let transport: EventDrivenPTYProcess

    init(process: PTYProcess, outputSink: (any TerminalOutputSink)?,
        onExit: @escaping @Sendable (Int32) -> Void) {
        pid = process.pid
        let scrollback = outputSink == nil ? TerminalScrollback() : nil
        self.scrollback = scrollback
        transport = EventDrivenPTYProcess(
            process: process,
            onOutput: { data in
                scrollback?.receive(data)
                outputSink?.receive(data)
            },
            onExit: onExit
        )
    }

    public func readAvailable() -> Data { scrollback?.drain() ?? Data() }

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
