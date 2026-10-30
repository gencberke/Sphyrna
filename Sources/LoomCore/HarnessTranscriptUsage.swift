import Darwin
import Dispatch
import Foundation

/// Readings from known Sphyrna sessions only, not an account-wide total.
public struct CodexUsageIndexReport: Equatable, Sendable {
    public let sessions: [String: CodexUsageReading]
    public let complete: Bool
    public let sessionsRequested: Int
    /// New rollout content bytes parsed; excludes bounded header and tail-guard checks.
    public let bytesRead: Int
}

/// A bounded, incremental in-memory index of the known sessions under one resolved Codex home.
/// Callers decide when to refresh. It does not watch, poll, launch a provider or retain transcript text.
public actor CodexUsageIndex {
    private struct State {
        var path: String
        var device: dev_t
        var inode: ino_t
        var offset: Int64 = 0
        var lastSize: Int64 = 0
        var lastMtime: timespec
        var wholeTail = true
        var guardBytes: [UInt8] = []
        var splitter = TranscriptLineSplitter(maximumLineBytes: 128 * 1024)
        var parser = CodexUsageParser()
    }
    private let queue = DispatchSerialQueue(label: "loom.codex.usage", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let home: URL
    private var states: [String: State] = [:]
    private var order: [String] = []
    public static let maximumSessions = 128
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumSeconds = 2.0
    /// Ids handed to the rollout locator so far (tests count lookups, not time).
    package private(set) var locatedIDs = 0

    public init(home: URL) { self.home = home }

    public func refresh(sessionIDs: [String], catalogTruncated: Bool = false) throws -> CodexUsageIndexReport {
        var seen: Set<String> = []
        let normalized = sessionIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }
            .filter { seen.insert($0).inserted }
        let ids = Array(normalized.prefix(Self.maximumSessions))
        var cached: [String: State] = [:]
        var known: [String: String] = [:]
        var needsLookup: [String] = []
        for id in ids {
            if let state = states[id], isUnchanged(state) { cached[id] = state }
            else if let state = states[id], onlyGrew(state) { known[id] = state.path }
            else { needsLookup.append(id) }
        }
        locatedIDs += needsLookup.count
        // A file that only grew is read again where it was found; only new or replaced ones are looked up.
        let lookup = CodexRolloutLocator.locate(sessionIDs: needsLookup, home: home)
        var complete = lookup.complete && !catalogTruncated && normalized.count <= Self.maximumSessions
            && sessionIDs.allSatisfy { UUID(uuidString: $0) != nil }
        let start = DispatchTime.now().uptimeNanoseconds
        var readBytes = 0
        var result: [String: CodexUsageReading] = [:]
        for id in ids {
            try Task.checkCancellation()
            if let state = cached[id] {
                let reading = state.parser.reading
                result[id] = reading
                if !state.wholeTail || !reading.complete { complete = false }
                order.removeAll { $0 == id }
                order.append(id)
                continue
            }
            guard let path = known[id] ?? lookup.files[id]?.path, let descriptor = openOwnRegularFile(path) else {
                if known[id] != nil { states[id] = nil }
                complete = false
                continue
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { complete = false; continue }
            var state: State
            if let old = states[id], old.path == path, old.device == info.st_dev, old.inode == info.st_ino,
               info.st_size >= old.offset, info.st_size >= old.lastSize,
               !(info.st_size == old.lastSize && (info.st_mtimespec.tv_sec != old.lastMtime.tv_sec
                    || info.st_mtimespec.tv_nsec != old.lastMtime.tv_nsec)),
               tailGuard(descriptor, offset: old.offset) == old.guardBytes {
                state = old
            } else if known[id] != nil {
                // Changed between the check and the open, or rewritten in place: not the file that was found. The next
                // refresh looks it up again.
                states[id] = nil
                complete = false
                continue
            } else {
                state = State(path: path, device: info.st_dev, inode: info.st_ino, lastMtime: info.st_mtimespec)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while state.offset < info.st_size {
                try Task.checkCancellation()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
                if readBytes >= Self.maximumBytes || elapsed >= Self.maximumSeconds { complete = false; break }
                let amount = min(chunk.count, Self.maximumBytes - readBytes, Int(info.st_size - state.offset))
                let count = pread(descriptor, &chunk, amount, off_t(state.offset))
                guard count > 0 else { complete = false; break }
                readBytes += count
                let offset = state.offset
                var parser = state.parser
                chunk.withUnsafeBytes { bytes in
                    state.splitter.consume(UnsafeRawBufferPointer(rebasing: bytes[..<count]), at: UInt64(offset), line: { _, line in
                        parser.consume(Data(line))
                    }, oversized: { _, _ in parser.markIncomplete() })
                }
                state.parser = parser
                state.offset += Int64(count)
            }
            state.lastSize = info.st_size
            state.lastMtime = info.st_mtimespec
            state.guardBytes = tailGuard(descriptor, offset: state.offset)
            states[id] = state
            order.removeAll { $0 == id }
            order.append(id)
            if order.count > Self.maximumSessions { states[order.removeFirst()] = nil }
            let reading = state.parser.reading
            result[id] = reading
            var lastByte: UInt8 = 0
            let hasWholeTail = info.st_size == 0 || (pread(descriptor, &lastByte, 1, off_t(info.st_size - 1)) == 1 && lastByte == 0x0A)
            state.wholeTail = hasWholeTail
            states[id] = state
            if state.offset < info.st_size || !hasWholeTail || !reading.complete { complete = false }
        }
        return CodexUsageIndexReport(sessions: result, complete: complete, sessionsRequested: normalized.count, bytesRead: readBytes)
    }

    private func isUnchanged(_ state: State) -> Bool {
        var info = stat()
        return lstat(state.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
            && info.st_dev == state.device && info.st_ino == state.inode && info.st_size == state.lastSize
            && state.offset == state.lastSize && info.st_mtimespec.tv_sec == state.lastMtime.tv_sec
            && info.st_mtimespec.tv_nsec == state.lastMtime.tv_nsec
    }

    /// The same file, still where it was found, that has only grown since the last read.
    private func onlyGrew(_ state: State) -> Bool {
        var info = stat()
        return lstat(state.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
            && info.st_dev == state.device && info.st_ino == state.inode && info.st_size > state.lastSize
    }

    private func tailGuard(_ descriptor: Int32, offset: Int64) -> [UInt8] {
        let count = Int(min(64, offset))
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let read = pread(descriptor, &bytes, count, off_t(offset - Int64(count)))
        return read == count ? bytes : []
    }
}
