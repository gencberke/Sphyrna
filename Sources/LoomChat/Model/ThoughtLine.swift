import Foundation

/// The live thought line of the Normal view: a short line taken from the latest thinking block while Claude works
/// (T3 Code's `liveThoughtLine`, packages/client-runtime/src/work-log/presentation.ts, MIT; see THIRD-PARTY-NOTICES.md).
///
/// - its first `**bold**` line, or else its first sentence;
/// - links, heading marks and list markers removed;
/// - at most 4 lines.
public enum ThoughtLine {
    public static let maximumLines = 4

    public static func extract(from thinking: String) -> String? {
        var paragraphs: [[String]] = [[]]
        for raw in thinking.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !paragraphs[paragraphs.count - 1].isEmpty { paragraphs.append([]) }
            } else {
                paragraphs[paragraphs.count - 1].append(line)
            }
        }
        let lines = paragraphs.flatMap { $0 }
        guard !lines.isEmpty else { return nil }

        for line in lines {
            let plain = strippingBlockMarks(line)
            guard plain.hasPrefix("**") else { continue }
            let afterOpen = plain.index(plain.startIndex, offsetBy: 2)
            if let close = plain.range(of: "**", range: afterOpen..<plain.endIndex) {
                let inner = cleaned(String(plain[afterOpen..<close.lowerBound]))
                if !inner.isEmpty { return inner }
            }
        }

        let first = paragraphs.first(where: { !$0.isEmpty }) ?? []
        let text = first.map(strippingBlockMarks).joined(separator: "\n")
        let sentence = firstSentence(of: text)
        let result = cleaned(sentence).components(separatedBy: "\n").prefix(maximumLines).joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    private static func firstSentence(of text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace { return String(text[..<next]) }
            }
            index = text.index(after: index)
        }
        return text
    }

    private static func strippingBlockMarks(_ line: String) -> String {
        line.replacingOccurrences(of: #"^\s*(#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s*)"#, with: "", options: .regularExpression)
    }

    private static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension TurnModel {
    /// The thought line of a turn: taken from its newest main-thread thinking block that shows text.
    public func thoughtLine(in turn: ChatTurn) -> String? {
        guard let start = index[turn.firstEntryID] else { return nil }
        var found: String?
        for entry in entries[start...] where entry.turnID == turn.id && entry.thread == .main {
            if case let .thinking(thinking) = entry.body, !thinking.isHidden, let line = ThoughtLine.extract(from: thinking.text) {
                found = line
            }
        }
        return found
    }
}
