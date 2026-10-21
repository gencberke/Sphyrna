import Foundation

/// One session Remora names for the user to open, with the reason.
public struct RemoraChip: Equatable, Sendable {
    public var sessionID: String
    public var why: String
}

/// An unsent line for a session's composer.
public struct RemoraDraft: Equatable, Sendable {
    public var sessionID: String
    public var text: String
}

/// What the closing fenced block of an answer holds, validated: `` ```remora `` and a JSON object
///
///     {"cited":["<id>"],"chips":[{"session":"<id>","why":"..."}],"drafts":[{"session":"<id>","text":"..."}],"facts":["..."]}
///
/// closed by a line of three backticks. Every field is optional. Session ids that are not in the pack's set are dropped
/// (with the chip or draft that carries them), repeated ids and empty strings go, and sizes are bounded (see `Limits`).
/// A block that is not one JSON object, has a field of the wrong type or is over `Limits.blockBytes` is invalid as a
/// whole: the answer keeps its text and loses only these fields.
public struct RemoraBlock: Equatable, Sendable {
    public enum Limits {
        public static let blockBytes = 16 * 1024
        public static let cited = 12
        public static let chips = 6
        public static let drafts = 3
        public static let facts = 3
        public static let whyCharacters = 140
        public static let draftCharacters = 600
        public static let factCharacters = 240
    }

    public var cited: [String] = []
    public var chips: [RemoraChip] = []
    public var drafts: [RemoraDraft] = []
    public var facts: [String] = []

    /// `blockText` is everything from the opening fence on. Nil when the block is invalid.
    static func parse(_ blockText: String, knownSessionIDs known: Set<String>) -> RemoraBlock? {
        guard let body = body(of: blockText), body.utf8.count <= Limits.blockBytes,
              let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return nil }
        var block = RemoraBlock()
        func array(_ key: String) -> [Any]?? {
            guard let value = object[key] else { return .some(nil) }
            if value is NSNull { return .some(nil) }
            guard let array = value as? [Any] else { return nil }
            return .some(array)
        }
        guard let cited = array("cited"), let chips = array("chips"), let drafts = array("drafts"),
              let facts = array("facts") else { return nil }

        var seen = Set<String>()
        for case let id as String in cited ?? [] where known.contains(id) && seen.insert(id).inserted {
            if block.cited.count < Limits.cited { block.cited.append(id) }
        }
        seen = []
        for case let entry as [String: Any] in chips ?? [] {
            guard block.chips.count < Limits.chips, let id = entry["session"] as? String, known.contains(id),
                  seen.insert(id).inserted else { continue }
            block.chips.append(RemoraChip(sessionID: id, why: clean(entry["why"] as? String, Limits.whyCharacters)))
        }
        seen = []
        for case let entry as [String: Any] in drafts ?? [] {
            guard block.drafts.count < Limits.drafts, let id = entry["session"] as? String, known.contains(id),
                  !seen.contains(id) else { continue }
            let text = clean(entry["text"] as? String, Limits.draftCharacters)
            guard !text.isEmpty else { continue }
            seen.insert(id)
            block.drafts.append(RemoraDraft(sessionID: id, text: text))
        }
        for case let fact as String in facts ?? [] where block.facts.count < Limits.facts {
            let text = clean(fact, Limits.factCharacters)
            if !text.isEmpty, !block.facts.contains(text) { block.facts.append(text) }
        }
        return block
    }

    /// The JSON between the opening fence line and the closing one (or the end of the text, for a block the model never
    /// closed: the JSON then stands or falls on its own). Anything after the closing fence is ignored.
    private static func body(of blockText: String) -> String? {
        var lines = blockText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.hasPrefix("```") == true else { return nil }
        lines.removeFirst()
        var body: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "```" { break }
            body.append(line)
        }
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// One line, trimmed, at most `limit` characters.
    private static func clean(_ value: String?, _ limit: Int) -> String {
        guard let value else { return "" }
        let line = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(limit))
    }
}

/// Splits the model's text into what the user sees and the closing block, as the text streams in. The block starts at
/// a line that begins with `` ```remora ``; everything from there on is the block and is never shown. Text that could
/// still turn into the marker, and whitespace at the end of what is known so far, is held back until the next piece
/// settles it, so a half-arrived fence never flashes in the answer and the shown text never ends in blank lines.
struct AnswerSplitter {
    static let marker = "```" + RemoraRules.blockInfoString

    private var held = ""
    private var emitted = 0
    private(set) var block: String?

    var hasBlock: Bool { block != nil }

    /// The part of the text that is now settled as visible.
    mutating func feed(_ piece: String) -> String {
        if block != nil {
            block! += piece
            return ""
        }
        let text = held + piece
        held = ""
        if let start = markerStart(in: text) {
            block = String(text[start...])
            return Self.trimmedEnd(String(text[..<start]), counting: &emitted)
        }
        var cut = text.endIndex
        let lineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let line = text[lineStart...]
        if !line.isEmpty, Self.marker.hasPrefix(line), lineStart != text.startIndex || emitted == 0 { cut = lineStart }
        while cut > text.startIndex {
            let before = text.index(before: cut)
            guard text[before].isWhitespace else { break }
            cut = before
        }
        held = String(text[cut...])
        let visible = String(text[..<cut])
        emitted += visible.count
        return visible
    }

    /// The end of the text: what was held back and is not a fence is text after all (minus trailing whitespace).
    mutating func finish() -> String {
        guard block == nil else { return "" }
        let rest = held
        held = ""
        return Self.trimmedEnd(rest, counting: &emitted)
    }

    private func markerStart(in text: String) -> String.Index? {
        var search = text.startIndex
        while let range = text.range(of: Self.marker, range: search..<text.endIndex) {
            let atLineStart = range.lowerBound == text.startIndex
                ? emitted == 0 : text[text.index(before: range.lowerBound)] == "\n"
            let end = range.upperBound
            let closesInfoString = end == text.endIndex || text[end].isWhitespace
            if atLineStart, closesInfoString { return range.lowerBound }
            search = range.upperBound
        }
        return nil
    }

    private static func trimmedEnd(_ text: String, counting emitted: inout Int) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        let visible = String(text[..<end])
        emitted += visible.count
        return visible
    }
}
