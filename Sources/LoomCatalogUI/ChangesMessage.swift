import Foundation
import LoomCore

/// The text one send carries: every comment of a scope as one plain-text message.
enum ChangesMessage {
    /// The sender a terminal session's `inbox` names, and its pointer line ("Sphyrna: message from You, in Changes.").
    static let senderTitle = "You, in Changes"
    /// The mailbox's bound on one message (F1's 16 KiB).
    static let byteLimit = SessionTaskLimits.payloadBytes

    /// The Chat face's message (frozen): "Comments on the changes (<scope name>):", then one block per comment: `path:line`,
    /// the line quoted, the comment. `comments` come in the order they should read; a line without a number (a notebook
    /// cell) names the file alone.
    static func text(scopeName: String, comments: [ChangeComment]) -> String {
        let blocks = comments.map { comment -> String in
            let place = comment.anchor.line.map { "\(comment.displayPath):\($0)" } ?? comment.displayPath
            return "\(place)\n> \(comment.anchor.text)\n\(comment.text)"
        }
        return (["Comments on the changes (\(scopeName)):"] + blocks).joined(separator: "\n\n")
    }

    /// The message a terminal session reads with `inbox`: "Comments on the changes (<scope name>):", then per file, in the
    /// order `comments` come (the file list's), its path and each of its comments: "line N: > <the line>" and the comment,
    /// indented under the path. It holds at most `limit` UTF-8 bytes: the oldest comments (`oldestFirst`, the order they
    /// were written) are left out first and the message says how many; a single comment longer than that is cut.
    static func terminalText(scopeName: String, comments: [ChangeComment], oldestFirst: [UUID],
                             limit: Int = byteLimit) -> String {
        var kept = comments
        var age = oldestFirst.filter { id in comments.contains { $0.id == id } }
        age += comments.map(\.id).filter { !age.contains($0) }
        var omitted = 0
        var text = terminalBody(scopeName, kept, omitted: omitted)
        while text.utf8.count > limit, kept.count > 1 {
            let oldest = age.removeFirst()
            kept.removeAll { $0.id == oldest }
            omitted += 1
            text = terminalBody(scopeName, kept, omitted: omitted)
        }
        if text.utf8.count > limit, var only = kept.first {
            cut(&only.text, by: text.utf8.count - limit)
            text = terminalBody(scopeName, [only], omitted: omitted)
            if text.utf8.count > limit {
                cut(&only.anchor.text, by: text.utf8.count - limit)
                text = terminalBody(scopeName, [only], omitted: omitted)
            }
        }
        return text
    }

    private static func terminalBody(_ scopeName: String, _ comments: [ChangeComment], omitted: Int) -> String {
        var files: [(path: String, blocks: [String])] = []
        for comment in comments {
            let place = comment.anchor.line.map { "line \($0)\(comment.anchor.removed ? " (removed)" : ""): " } ?? ""
            let body = comment.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }
            let block = (["  \(place)> \(comment.anchor.text)"] + body).joined(separator: "\n")
            if let index = files.firstIndex(where: { $0.path == comment.displayPath }) {
                files[index].blocks.append(block)
            } else {
                files.append((comment.displayPath, [block]))
            }
        }
        var parts = ["Comments on the changes (\(scopeName)):"]
        parts += files.map { ([$0.path] + [$0.blocks.joined(separator: "\n\n")]).joined(separator: "\n") }
        if omitted > 0 {
            parts.append("(\(omitted) older comment\(omitted == 1 ? " was" : "s were") left out: a message holds at most 16 KiB.)")
        }
        return parts.joined(separator: "\n\n").replacingOccurrences(of: "\0", with: "")
    }

    /// Shortens `text` by at least `bytes` UTF-8 bytes, on a character boundary, and marks the cut with "…".
    private static func cut(_ text: inout String, by bytes: Int) {
        let target = max(0, text.utf8.count - bytes - "…".utf8.count)
        while text.utf8.count > target, !text.isEmpty { text.removeLast() }
        text += "…"
    }
}
