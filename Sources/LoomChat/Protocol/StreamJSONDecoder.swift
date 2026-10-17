import Foundation

/// What one line of the output turned into.
public enum StreamFrame: Sendable, Equatable {
    case message(StreamMessage)
    /// A line over the decoder's limit. It was not buffered or parsed; `head` is its first bytes, for diagnostics.
    case oversized(byteCount: Int, head: String)
    /// A line that is not a JSON object (or not JSON at all).
    case malformed(head: String, reason: String)
}

/// NDJSON framing and decoding for Claude Code's stdout. Bytes arrive in chunks of any size; a line may span many of
/// them and may be tens of MB (a tool result, an image). Memory is bounded by the largest line: a line is held only
/// until its newline, and a line over `maximumLineBytes` is counted and skipped without being buffered. The buffer is
/// released after a large line so one big result does not keep its memory.
///
/// Unknown types and subtypes come out as `StreamMessage.unknown`; only bytes that are not a JSON object are
/// `.malformed`, and a decoder keeps going after one.
public struct StreamJSONDecoder: Sendable {
    public static let defaultMaximumLineBytes = 64 * 1024 * 1024
    static let headBytes = 256
    static let retainedCapacity = 1 << 20

    public let maximumLineBytes: Int
    /// The line being assembled.
    private var carry = Data()
    /// Inside a line over the limit: its bytes so far, and its first bytes.
    private var skipping = false
    private var skippedBytes = 0
    private var skippedHead = Data()

    public init(maximumLineBytes: Int = defaultMaximumLineBytes) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// Bytes held for the line in progress.
    public var bufferedByteCount: Int { carry.count }

    /// Feeds the next bytes and returns the frames of the lines they completed.
    public mutating func feed(_ chunk: Data) -> [StreamFrame] {
        var frames: [StreamFrame] = []
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var start = 0
            while start < raw.count {
                let rest = raw.count - start
                let base = raw.baseAddress! + start
                if let newline = memchr(base, 0x0A, rest) {
                    let length = base.distance(to: UnsafeRawPointer(newline))
                    let piece = UnsafeRawBufferPointer(start: base, count: length)
                    endLine(with: piece, into: &frames)
                    start += length + 1
                } else {
                    append(UnsafeRawBufferPointer(start: base, count: rest))
                    start = raw.count
                }
            }
        }
        return frames
    }

    /// The end of the stream: a last line without a newline is decoded too.
    public mutating func finish() -> [StreamFrame] {
        var frames: [StreamFrame] = []
        endLine(with: UnsafeRawBufferPointer(start: nil, count: 0), into: &frames)
        return frames
    }

    // MARK: Private

    private mutating func append(_ piece: UnsafeRawBufferPointer) {
        if skipping {
            skippedBytes += piece.count
            return
        }
        if carry.count + piece.count > maximumLineBytes {
            skipping = true
            skippedBytes = carry.count + piece.count
            skippedHead = carry.prefix(Self.headBytes)
            if skippedHead.count < Self.headBytes { skippedHead.append(contentsOf: piece.prefix(Self.headBytes - skippedHead.count)) }
            carry = Data()
            return
        }
        carry.append(contentsOf: piece)
    }

    private mutating func endLine(with piece: UnsafeRawBufferPointer, into frames: inout [StreamFrame]) {
        append(piece)
        defer {
            skipping = false
            skippedBytes = 0
            skippedHead = Data()
            if carry.count > Self.retainedCapacity { carry = Data() } else { carry.removeAll(keepingCapacity: true) }
        }
        if skipping {
            frames.append(.oversized(byteCount: skippedBytes, head: String(decoding: skippedHead, as: UTF8.self)))
            return
        }
        guard carry.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return }
        do {
            frames.append(.message(try StreamMessage(line: carry)))
        } catch {
            frames.append(.malformed(head: String(decoding: carry.prefix(Self.headBytes), as: UTF8.self),
                                     reason: error is StreamJSONError ? "not a JSON object" : "not valid JSON"))
        }
    }
}
