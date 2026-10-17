import Foundation

/// Long text kept as its head and its tail. Tool output can be megabytes; the model keeps `budgetBytes` of it in
/// memory and the rest stays in the transcript ("Show all" reads it from there, by the entry's `sourceOffset`).
public struct ClippedText: Sendable, Equatable {
    public static let budgetBytes = 64 * 1024

    public var head: String
    /// Empty when the text was not clipped.
    public var tail: String
    /// The whole text's length in UTF-8 bytes.
    public var totalBytes: Int

    public init(_ text: String, budgetBytes: Int = ClippedText.budgetBytes) {
        let utf8 = text.utf8
        totalBytes = utf8.count
        guard totalBytes > budgetBytes else {
            head = text
            tail = ""
            return
        }
        let half = budgetBytes / 2
        var headEnd = utf8.index(utf8.startIndex, offsetBy: half)
        while headEnd > utf8.startIndex, utf8[headEnd] & 0xC0 == 0x80 { headEnd = utf8.index(before: headEnd) }
        var tailStart = utf8.index(utf8.endIndex, offsetBy: -half)
        while tailStart < utf8.endIndex, utf8[tailStart] & 0xC0 == 0x80 { tailStart = utf8.index(after: tailStart) }
        head = String(text[..<headEnd])
        tail = String(text[tailStart...])
    }

    public var isClipped: Bool { !tail.isEmpty }

    /// Bytes left out between the head and the tail.
    public var omittedBytes: Int { isClipped ? totalBytes - head.utf8.count - tail.utf8.count : 0 }

    /// The text as kept: the whole of it, or head, a gap line, and tail.
    public var text: String {
        isClipped ? head + "\n… \(omittedBytes) bytes omitted …\n" + tail : head
    }
}
