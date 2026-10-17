import Darwin
import Foundation

/// One whole line of a transcript, with where it lies in the file.
public struct TranscriptLineRecord: Equatable, Sendable {
    /// The file offset of the line's first byte.
    public let offset: UInt64
    /// The line's length in bytes, without its newline.
    public let length: Int
    /// The line, or nil when it is over the cap it was read with: it was not read, and `readRecord(offset:length:)`
    /// reads it on demand.
    public let bytes: Data?

    public var isOversized: Bool { bytes == nil }

    public init(offset: UInt64, length: Int, bytes: Data?) {
        self.offset = offset
        self.length = length
        self.bytes = bytes
    }
}

/// A page read backward: whole lines in file order.
public struct TranscriptBackwardPage: Equatable, Sendable {
    public var records: [TranscriptLineRecord]
    /// Where the page begins; the next page ends here.
    public var startOffset: UInt64
    public var reachedStart: Bool
}

/// What a file gained since the last growth read.
public struct TranscriptGrowth: Equatable, Sendable {
    public var records: [TranscriptLineRecord]
    /// The file shrank or was replaced: lines read earlier no longer apply, and both cursors moved to the new end.
    public var restarted: Bool
}

/// Reads a Claude transcript (a main session's or a subagent's) from the end of the file backward in bounded pages,
/// and forward for what it gains afterwards. The history cursor and the growth cursor start together at the last
/// complete line, so the two reads never overlap or leave a gap.
///
/// - A page is at most `pageBytes` of whole lines (a line longer than that is a page of its own). Memory per call is
///   bounded by the page, or by `maximumLineBytes` for a single line.
/// - A line over the cap is not read: its record carries its offset and length (`bytes == nil`), so the caller can mark
///   it and read it later with `readRecord(offset:length:)`.
/// - Claude appends with `O_APPEND` and flushes every 100 ms, so bytes after the last newline are held back until their
///   newline arrives.
///
/// Calls are serialized by an internal lock; reads are short and run on whatever thread the caller chooses.
public final class ClaudeTranscriptReader: @unchecked Sendable {
    public static let defaultPageBytes = 256 * 1024
    public static let defaultMaximumLineBytes = 16 * 1024 * 1024
    static let chunkBytes = 64 * 1024

    private let lock = NSLock()
    private let path: String
    private var descriptor: Int32
    private var device: dev_t = 0
    private var inode: ino_t = 0
    private var started = false
    /// Backward reads end here (always a line start, or 0).
    private var historyCursor: UInt64 = 0
    /// The next byte forward reads begin at.
    private var growthOffset: UInt64 = 0
    private var splitter: TranscriptLineSplitter
    private var bytesReadValue = 0

    public convenience init?(file: ClaudeTranscriptFile, maximumGrowthLineBytes: Int = defaultMaximumLineBytes) {
        self.init(path: file.path, maximumGrowthLineBytes: maximumGrowthLineBytes)
    }

    public convenience init?(file: SubagentTranscriptFile, maximumGrowthLineBytes: Int = defaultMaximumLineBytes) {
        self.init(path: file.path, maximumGrowthLineBytes: maximumGrowthLineBytes)
    }

    private init?(path: String, maximumGrowthLineBytes: Int) {
        guard let descriptor = openOwnRegularFile(path) else { return nil }
        self.path = path
        self.descriptor = descriptor
        splitter = TranscriptLineSplitter(maximumLineBytes: maximumGrowthLineBytes)
        remember(descriptor)
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    /// Bytes read from the file so far (a test measures a cold open with it).
    public var bytesRead: Int { lock.withLock { bytesReadValue } }

    /// Where the next backward page ends.
    public var historyOffset: UInt64 { lock.withLock { prepare(); return historyCursor } }

    public func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// Moves the history cursor to `offset` (a line start the caller got from a record), so the next backward page ends
    /// there. A cold open that keeps only the end of its last page uses this to leave the rest for the next page.
    public func setHistoryOffset(_ offset: UInt64) {
        lock.withLock { prepare(); historyCursor = offset }
    }

    /// The next page backward: whole lines that lie within `pageBytes` before the cursor.
    public func readBackward(pageBytes: Int = defaultPageBytes, maximumLineBytes: Int = defaultMaximumLineBytes) -> TranscriptBackwardPage {
        lock.withLock {
            prepare()
            let upper = historyCursor
            guard descriptor >= 0, upper > 0 else {
                return TranscriptBackwardPage(records: [], startOffset: 0, reachedStart: true)
            }
            let lower = upper > UInt64(max(1, pageBytes)) ? upper - UInt64(max(1, pageBytes)) : 0
            guard let region = read(from: lower, count: Int(upper - lower)) else {
                return TranscriptBackwardPage(records: [], startOffset: upper, reachedStart: true)
            }
            if let skip = firstLineStart(in: region, regionOffset: lower) {
                let records = Self.lines(in: region, from: skip, regionOffset: lower, maximumLineBytes: maximumLineBytes)
                historyCursor = lower + UInt64(skip)
                return TranscriptBackwardPage(records: records, startOffset: historyCursor, reachedStart: historyCursor == 0)
            }
            // One line fills the page or straddles its start: find where it begins. The scan keeps the bytes it reads
            // while the line can still be within the cap, so the line is not read twice.
            let before = scanBack(from: lower, keepingUpTo: maximumLineBytes)
            let length = Int(upper - 1 - before.start)
            historyCursor = before.start
            var records: [TranscriptLineRecord] = []
            if length > 0 {
                if length <= maximumLineBytes, var bytes = before.bytes {
                    bytes.append(contentsOf: region.dropLast())
                    records.append(TranscriptLineRecord(offset: before.start, length: length, bytes: bytes))
                } else {
                    records.append(TranscriptLineRecord(offset: before.start, length: length, bytes: nil))
                }
            }
            return TranscriptBackwardPage(records: records, startOffset: before.start, reachedStart: before.start == 0)
        }
    }

    /// The whole lines the file gained since the last call (or since the cursors were set, for the first call).
    public func readGrowth() -> TranscriptGrowth {
        lock.withLock {
            guard descriptor >= 0 else { return TranscriptGrowth(records: [], restarted: false) }
            var restarted = false
            if started {
                var onDisk = stat()
                if stat(path, &onDisk) == 0, onDisk.st_dev != device || onDisk.st_ino != inode,
                   let replacement = openOwnRegularFile(path) {
                    Darwin.close(descriptor)
                    descriptor = replacement
                    remember(replacement)
                    started = false
                    restarted = true
                }
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { return TranscriptGrowth(records: [], restarted: restarted) }
            if started, UInt64(info.st_size) < growthOffset { started = false; restarted = true }
            prepare()
            var records: [TranscriptLineRecord] = []
            let size = UInt64(info.st_size)
            let chunk = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkBytes, alignment: 16)
            defer { chunk.deallocate() }
            while growthOffset < size {
                let wanted = Int(min(UInt64(Self.chunkBytes), size - growthOffset))
                let count = pread(descriptor, chunk, wanted, off_t(growthOffset))
                guard count > 0 else { break }
                bytesReadValue += count
                splitter.consume(UnsafeRawBufferPointer(start: chunk, count: count), at: growthOffset, line: { offset, bytes in
                    records.append(TranscriptLineRecord(offset: offset, length: bytes.count, bytes: Data(bytes)))
                }, oversized: { offset, length in
                    records.append(TranscriptLineRecord(offset: offset, length: length, bytes: nil))
                })
                growthOffset += UInt64(count)
            }
            return TranscriptGrowth(records: records, restarted: restarted)
        }
    }

    /// Reads the line that begins at `offset` (a record's offset), however long, up to `maximumLineBytes`: "Show all" for
    /// a clipped tool result, or a line that was over the cap. Nil when it cannot be read or is longer than the cap.
    public func readLine(at offset: UInt64, maximumLineBytes: Int = 256 * 1024 * 1024) -> Data? {
        lock.withLock {
            guard descriptor >= 0 else { return nil }
            var line = Data()
            var position = offset
            let chunk = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkBytes, alignment: 16)
            defer { chunk.deallocate() }
            while true {
                let count = pread(descriptor, chunk, Self.chunkBytes, off_t(position))
                guard count > 0 else { return line.isEmpty ? nil : line }
                bytesReadValue += count
                if let newline = memchr(chunk, 0x0A, count) {
                    let length = UnsafeRawPointer(chunk).distance(to: UnsafeRawPointer(newline))
                    guard line.count + length <= maximumLineBytes else { return nil }
                    line.append(chunk.assumingMemoryBound(to: UInt8.self), count: length)
                    return line
                }
                guard line.count + count <= maximumLineBytes else { return nil }
                line.append(chunk.assumingMemoryBound(to: UInt8.self), count: count)
                position += UInt64(count)
            }
        }
    }

    // MARK: Private

    private func remember(_ descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        device = info.st_dev
        inode = info.st_ino
    }

    /// Sets both cursors to the end of the last complete line, once (and again after a restart).
    private func prepare() {
        guard !started, descriptor >= 0 else { return }
        started = true
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        let end = lineStart(before: UInt64(info.st_size), chunkBytes: 4 * 1024)
        historyCursor = end
        growthOffset = end
        splitter.reset(at: end)
    }

    /// The position after the last newline before `offset` (0 when there is none), found by scanning backward in
    /// `chunkBytes` steps without keeping what it reads: the start of the line that ends at or after `offset`.
    private func lineStart(before offset: UInt64, chunkBytes: Int = ClaudeTranscriptReader.chunkBytes) -> UInt64 {
        var position = offset
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkBytes)
        defer { chunk.deallocate() }
        while position > 0 {
            let wanted = Int(min(UInt64(chunkBytes), position))
            let from = position - UInt64(wanted)
            guard pread(descriptor, chunk, wanted, off_t(from)) == wanted else { return 0 }
            bytesReadValue += wanted
            var index = wanted - 1
            while index >= 0 {
                if chunk[index] == 0x0A { return from + UInt64(index) + 1 }
                index -= 1
            }
            position = from
        }
        return 0
    }

    /// Scans backward from `offset` for the start of the line that contains the byte at `offset - 1`. Returns the bytes
    /// from that start up to `offset` when they are at most `keepingUpTo`, else nil (the scan reads them but keeps none).
    private func scanBack(from offset: UInt64, keepingUpTo limit: Int) -> (start: UInt64, bytes: Data?) {
        var pieces: [Data] = []
        var kept = 0
        var keeping = true
        var position = offset
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkBytes)
        defer { chunk.deallocate() }
        while position > 0 {
            let wanted = Int(min(UInt64(Self.chunkBytes), position))
            let from = position - UInt64(wanted)
            guard pread(descriptor, chunk, wanted, off_t(from)) == wanted else { return (0, nil) }
            bytesReadValue += wanted
            var index = wanted - 1
            while index >= 0, chunk[index] != 0x0A { index -= 1 }
            let first = index + 1 // the piece of this chunk that belongs to the line
            if keeping {
                if kept + (wanted - first) > limit {
                    keeping = false
                    pieces = []
                } else {
                    pieces.append(Data(bytes: chunk + first, count: wanted - first))
                    kept += wanted - first
                }
            }
            if index >= 0 {
                return (from + UInt64(first), keeping ? Data(pieces.reversed().joined()) : nil)
            }
            position = from
        }
        return (0, keeping ? Data(pieces.reversed().joined()) : nil)
    }

    private func read(from offset: UInt64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let got = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            guard got > 0 else { return nil }
            done += got
        }
        bytesReadValue += count
        return buffer
    }

    /// Where the first whole line of a region read from `regionOffset` begins, or nil when it holds none.
    private func firstLineStart(in region: [UInt8], regionOffset: UInt64) -> Int? {
        if regionOffset == 0 { return 0 }
        var before: UInt8 = 0
        guard pread(descriptor, &before, 1, off_t(regionOffset) - 1) == 1 else { return nil }
        bytesReadValue += 1
        if before == 0x0A { return 0 }
        guard let newline = region.firstIndex(of: 0x0A), newline + 1 < region.count else { return nil }
        return newline + 1
    }

    private static func lines(in region: [UInt8], from start: Int, regionOffset: UInt64, maximumLineBytes: Int) -> [TranscriptLineRecord] {
        var records: [TranscriptLineRecord] = []
        var lineStart = start
        region.withUnsafeBufferPointer { buffer in
            while lineStart < buffer.count {
                let rest = buffer.count - lineStart
                let base = buffer.baseAddress! + lineStart
                let length = memchr(base, 0x0A, rest).map { UnsafeRawPointer(base).distance(to: UnsafeRawPointer($0)) } ?? rest
                if length > 0 {
                    let offset = regionOffset + UInt64(lineStart)
                    records.append(length > maximumLineBytes
                        ? TranscriptLineRecord(offset: offset, length: length, bytes: nil)
                        : TranscriptLineRecord(offset: offset, length: length,
                                               bytes: Data(bytes: base, count: length)))
                }
                lineStart += length + 1
            }
        }
        return records
    }
}
