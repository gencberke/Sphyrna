import Darwin
import Foundation

/// Reads the whole lines a subagent transcript gains, and only those (FB4-5). Claude appends with
/// `O_APPEND` and flushes every 100 ms, so the last line can be half written: bytes after the last newline
/// are held back and consumed once their newline arrives.
///
/// - A first read starts in the last `coldWindowBytes` of the file, at a line start, and also delivers the
///   file's first line when it lies before that window (the brief).
/// - A file that shrinks, or whose path now names another inode, is read again from its tail.
/// - A line over `maximumLineBytes` is skipped up to its newline, and `oversized` is told (the view says "an entry too long
///   to show"); no buffer grows past that bound.
///
/// Not thread safe: one owner, normally the feed's queue.
final class SubagentTranscriptTail {
    static let defaultColdWindowBytes = 512 * 1024
    static let defaultMaximumLineBytes = 128 * 1024
    static let chunkBytes = 64 * 1024
    /// How much of the file's start is searched for the first line when the cold window skips it.
    static let headBytes = 16 * 1024

    struct Outcome: Equatable {
        /// Earlier lines no longer apply: the first read, or the file shrank or was replaced.
        var restarted = false
        /// The read began inside the file, so earlier lines (after the brief) are not delivered.
        var omittedEarlier = false
    }

    private let file: SubagentTranscriptFile
    private let coldWindowBytes: Int
    private var descriptor: Int32
    private var device: dev_t = 0
    private var inode: ino_t = 0
    /// The file offset of the next byte to read.
    private var position: off_t = 0
    private var splitter: TranscriptLineSplitter
    private var started = false
    private let chunk = UnsafeMutableRawPointer.allocate(byteCount: SubagentTranscriptTail.chunkBytes, alignment: 16)
    /// Bytes read from the file so far (a test measures a cold open with it).
    private(set) var bytesRead = 0

    init?(file: SubagentTranscriptFile, coldWindowBytes: Int = defaultColdWindowBytes,
          maximumLineBytes: Int = defaultMaximumLineBytes) {
        guard let descriptor = file.openDescriptor() else { return nil }
        self.file = file
        self.coldWindowBytes = coldWindowBytes
        splitter = TranscriptLineSplitter(maximumLineBytes: maximumLineBytes)
        self.descriptor = descriptor
        remember(descriptor)
    }

    deinit {
        chunk.deallocate()
        close()
    }

    var isOpen: Bool { descriptor >= 0 }
    /// The open descriptor (tests check that it is closed).
    var openDescriptor: Int32 { descriptor }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    /// Calls `line` with each new whole line (without its newline). The buffer is valid only during the call.
    func read(oversized: () -> Void = {}, _ line: (UnsafeRawBufferPointer) -> Void) -> Outcome {
        guard descriptor >= 0 else { return Outcome() }
        var outcome = Outcome()
        var info = stat()
        // The path names another file now (replaced by a rename): follow it.
        var onDisk = stat()
        if stat(file.path, &onDisk) == 0, onDisk.st_dev != device || onDisk.st_ino != inode,
           let replacement = file.openDescriptor() {
            Darwin.close(descriptor)
            descriptor = replacement
            remember(replacement)
            started = false
        }
        guard fstat(descriptor, &info) == 0 else { return outcome }
        let size = info.st_size
        if started, size < position { started = false } // shrunk: its tail again
        if !started {
            outcome.restarted = true
            outcome.omittedEarlier = start(size: size, line)
        }
        while position < size {
            let wanted = Int(min(off_t(Self.chunkBytes), size - position))
            let count = pread(descriptor, chunk, wanted, position)
            guard count > 0 else { break }
            bytesRead += count
            splitter.consume(UnsafeRawBufferPointer(start: chunk, count: count), at: UInt64(position),
                             line: { _, bytes in line(bytes) }, oversized: { _, _ in oversized() })
            position += off_t(count)
        }
        return outcome
    }

    // MARK: Private

    private func remember(_ descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        device = info.st_dev
        inode = info.st_ino
    }

    /// Positions the first read; true when it starts inside the file.
    private func start(size: off_t, _ line: (UnsafeRawBufferPointer) -> Void) -> Bool {
        started = true
        splitter.reset(at: 0)
        guard size > off_t(coldWindowBytes) else { position = 0; return false }
        let window = size - off_t(coldWindowBytes)
        // The window starts at a line start only when the byte before it ends a line; otherwise the line
        // it cuts is skipped up to its newline.
        var before: UInt8 = 0
        if pread(descriptor, &before, 1, window - 1) == 1 { bytesRead += 1 }
        splitter.reset(at: UInt64(window), cutMidLine: before != 0x0A)
        position = window
        deliverFirstLine(before: window, line)
        return true
    }

    /// The file's first line, when it lies wholly before `limit` (the brief a cold window would skip).
    private func deliverFirstLine(before limit: off_t, _ line: (UnsafeRawBufferPointer) -> Void) {
        let wanted = Int(min(off_t(Self.headBytes), limit))
        let head = UnsafeMutableRawPointer.allocate(byteCount: wanted, alignment: 16)
        defer { head.deallocate() }
        let count = pread(descriptor, head, wanted, 0)
        guard count > 0 else { return }
        bytesRead += count
        guard let newline = memchr(head, 0x0A, count) else { return }
        let length = UnsafeRawPointer(head).distance(to: UnsafeRawPointer(newline))
        if length > 0 { line(UnsafeRawBufferPointer(start: head, count: length)) }
    }
}
