import Foundation

/// What "Show all" made of a clipped tool result. The transcript can hold tens of MiB in one result; the row shows at
/// most about 1 MiB or 10,000 lines of it, with a line saying where it was cut. The cut is made off the main thread
/// (`prepared` is nonisolated and the model calls it from a detached task), so a huge result never blocks the stream.
enum ChatFullOutput: Equatable, Sendable {
    case text(String)
    /// The result could not be read: its line is too large or the file changed since.
    case missing

    static let maximumBytes = 1_048_576
    static let maximumLines = 10_000

    /// The text, cut at the line limit or the byte limit (at a line break when there is one), with a note when cut.
    static func prepared(_ text: String, maximumBytes: Int = maximumBytes, maximumLines: Int = maximumLines) -> ChatFullOutput {
        let utf8 = text.utf8
        let total = utf8.count
        var lines = 1
        var cutBytes: Int?
        var lastBreak: Int?
        var position = 0
        let limit = min(total, maximumBytes)
        var copy = text
        copy.withUTF8 { bytes in
            while position < limit {
                if bytes[position] == 10 {
                    if lines == maximumLines { cutBytes = position; return }
                    lines += 1
                    lastBreak = position
                }
                position += 1
            }
        }
        if cutBytes == nil, total > maximumBytes { cutBytes = lastBreak ?? maximumBytes }
        guard let cut = cutBytes else { return .text(text) }
        let shown = String(decoding: utf8.prefix(cut), as: UTF8.self)
        let note = "\n\u{2026} Cut here: showing the first \(ChatBytes.text(cut)) of \(ChatBytes.text(total)). The whole result is in the transcript file."
        return .text(shown + note)
    }
}
