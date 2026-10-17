import Foundation

/// Cuts a stream of file bytes into whole lines, holding back a partial last line until its newline arrives
/// (Claude appends with `O_APPEND`, so the last line can be half written). Shared by the subagent tail and the
/// main-session reader. A line over `maximumLineBytes` is never buffered: it is reported once, at its newline, with
/// its file offset and total length, so a caller can mark it instead of losing it silently.
struct TranscriptLineSplitter {
    private enum Skip { case none, cutLine, oversizedLine }

    let maximumLineBytes: Int
    /// Bytes read after the last newline: a line that is not complete yet.
    private var carry: [UInt8] = []
    private var skip = Skip.none
    /// The file offset of the line being assembled, and how many of its bytes were seen.
    private var lineStart: UInt64 = 0
    private var lineLength = 0

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// Begins at `offset`. `cutMidLine`: the offset lies inside a line, so that line is skipped up to its newline.
    mutating func reset(at offset: UInt64, cutMidLine: Bool = false) {
        carry.removeAll(keepingCapacity: true)
        skip = cutMidLine ? .cutLine : .none
        lineStart = offset
        lineLength = 0
    }

    /// Feeds the next bytes of the file (`fileOffset` is where they start). Calls `line` with each whole line
    /// (without its newline; the buffer is valid only during the call) and `oversized` with the offset and length of
    /// each line over the cap. Empty lines are not delivered.
    mutating func consume(_ bytes: UnsafeRawBufferPointer, at fileOffset: UInt64,
                          line: (UInt64, UnsafeRawBufferPointer) -> Void,
                          oversized: (UInt64, Int) -> Void) {
        var rest = bytes
        var restOffset = fileOffset
        while rest.count > 0 {
            guard let newline = memchr(rest.baseAddress, 0x0A, rest.count) else {
                lineLength += rest.count
                if skip == .none {
                    if carry.count + rest.count > maximumLineBytes {
                        carry.removeAll(keepingCapacity: true)
                        skip = .oversizedLine
                    } else {
                        carry.append(contentsOf: rest)
                    }
                }
                return
            }
            let length = rest.baseAddress!.distance(to: UnsafeRawPointer(newline))
            lineLength += length
            let whole = UnsafeRawBufferPointer(rebasing: rest[..<length])
            switch skip {
            case .cutLine:
                break
            case .oversizedLine:
                oversized(lineStart, lineLength)
            case .none:
                if carry.isEmpty {
                    if length > maximumLineBytes { oversized(lineStart, length) } else if length > 0 { line(lineStart, whole) }
                } else if carry.count + length <= maximumLineBytes {
                    carry.append(contentsOf: whole)
                    carry.withUnsafeBytes { line(lineStart, $0) }
                } else {
                    oversized(lineStart, lineLength)
                }
            }
            carry.removeAll(keepingCapacity: true)
            skip = .none
            restOffset += UInt64(length + 1)
            lineStart = restOffset
            lineLength = 0
            rest = UnsafeRawBufferPointer(rebasing: rest[(length + 1)...])
        }
    }
}
