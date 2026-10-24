import Foundation
import LoomChat
import LoomCore
import Synchronization

/// The last thing Claude said in a session of a past run, read from the end of its transcript. The project
/// page asks for it only for rows that are on screen, one session at a time, and every ask is bounded: the
/// last `pageBytes` of the file, at most `maxPages` times, and no line over `maxLineBytes` is read.
enum ProjectLastLine {
    static let pageBytes = 64 * 1024
    static let maxPages = 2
    static let maxLineBytes = 64 * 1024
    /// The longest line kept; a longer one ends in an ellipsis.
    static let maxLength = 160

    /// The first line of Claude's last answer in the session, or nil when its transcript is missing, unreadable
    /// or holds no answer in the part read. Only the working directory's own project folder is looked in: a
    /// transcript elsewhere is a miss, so a miss never lists the profile's other folders.
    static func read(sessionID: String, configDirectory: URL, workingDirectory: String) -> String? {
        guard let file = ClaudeTranscriptLocator.locate(
            sessionID: sessionID, configDirectory: configDirectory, onlyIn: workingDirectory),
            let reader = ClaudeTranscriptReader(file: file) else { return nil }
        defer { reader.close() }
        return read(from: reader)
    }

    static func read(from reader: ClaudeTranscriptReader) -> String? {
        for _ in 0..<maxPages {
            let page = reader.readBackward(pageBytes: pageBytes, maximumLineBytes: maxLineBytes)
            for record in page.records.reversed() {
                if let bytes = record.bytes, let text = answer(in: bytes) { return summary(of: text) }
            }
            if page.reachedStart { break }
        }
        return nil
    }

    /// What the sidebar's Peek shows: the user's last ask and the first line of Claude's answer to it, each cut at `maxLength`.
    struct Peek: Equatable, Sendable {
        var ask: String?
        var answer: String?

        var isEmpty: Bool { ask == nil && answer == nil }
    }

    /// The last ask and the answer after it, from one bounded backward read (the same bounds and the same folder rule as
    /// `read(sessionID:configDirectory:workingDirectory:)`). Nil when the transcript is missing or unreadable.
    static func readPeek(sessionID: String, configDirectory: URL, workingDirectory: String) -> Peek? {
        guard let file = ClaudeTranscriptLocator.locate(
            sessionID: sessionID, configDirectory: configDirectory, onlyIn: workingDirectory),
            let reader = ClaudeTranscriptReader(file: file) else { return nil }
        defer { reader.close() }
        return peek(from: reader)
    }

    /// Reads from the end: the first answer met is the last one, and the first ask met is the last one. An answer older than
    /// the last ask belongs to an earlier turn and is not shown with it, so the read ends at the ask.
    static func peek(from reader: ClaudeTranscriptReader) -> Peek {
        var peek = Peek()
        var answered = false
        for _ in 0..<maxPages {
            let page = reader.readBackward(pageBytes: pageBytes, maximumLineBytes: maxLineBytes)
            for record in page.records.reversed() {
                guard let bytes = record.bytes else { continue }
                if !answered, let text = answer(in: bytes) {
                    answered = true
                    peek.answer = summary(of: text)
                } else if let text = TranscriptLens.humanPromptText(in: bytes) {
                    peek.ask = firstLine(of: text)
                    return peek
                }
            }
            if page.reachedStart { break }
        }
        return peek
    }

    /// The text of the last text block of a main-thread assistant line; nil for any other line.
    static func answer(in line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text.isEmpty ? nil : text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks.reversed() where block["type"] as? String == "text" {
            if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// The first non-empty line, without the heading, quote or list mark that opens it, cut at `maxLength`.
    /// A code fence line is skipped.
    static func summary(of text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            while let mark = line.range(of: #"^(#{1,6}|>|[-*\x{2022}]|\d+\.)\s+"#, options: .regularExpression) {
                line.removeSubrange(mark)
            }
            guard !line.isEmpty else { continue }
            return cut(line)
        }
        return nil
    }

    /// The first non-empty line of what the user typed, as it is, cut at `maxLength`.
    static func firstLine(of text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return cut(line) }
        }
        return nil
    }

    private static func cut(_ line: String) -> String {
        line.count > maxLength ? String(line.prefix(maxLength - 1)) + "\u{2026}" : line
    }
}

/// Which opening of the project page is current. The page bumps it when it opens and when it closes; the tail
/// reader looks at it from its own queue, so a read that waited behind others finds the page gone without
/// the main actor being asked.
final class ProjectPageGeneration: Sendable {
    private let value = Mutex(0)
    var current: Int { value.withLock { $0 } }
    @discardableResult
    func advance() -> Int { value.withLock { $0 &+= 1; return $0 } }
}

/// Reads the tails one after the other, off the main actor, so scrolling a long list never starts a crowd of
/// reads at once. An actor does not look at cancellation by itself, so each queued ask checks, when its turn
/// comes and before it locates or opens anything, that its row is still wanted (its task was not cancelled)
/// and that the page it was asked for is still the open one.
actor ProjectTailReader {
    private(set) var reads = 0

    func lastLine(sessionID: String, configDirectory: URL, workingDirectory: String,
                  generation: Int, page: ProjectPageGeneration) -> String? {
        guard !Task.isCancelled, page.current == generation else { return nil }
        reads += 1
        return ProjectLastLine.read(sessionID: sessionID, configDirectory: configDirectory, workingDirectory: workingDirectory)
    }
}
