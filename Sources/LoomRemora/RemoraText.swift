import Foundation

/// The one-line, masked, bounded text the stores keep.
enum RemoraText {
    /// Secrets masked, every run of white space (line breaks included) one space, trimmed, at most `limit` characters
    /// (the last one is "…" when something was cut).
    static func line(_ text: String, limit: Int) -> String {
        cut(flatten(RemoraSecretMask.mask(text)), limit)
    }

    static func flatten(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character.isNewline || character.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Up to the first sentence end (. ! ? followed by white space or the end) or line break.
    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var end = trimmed.startIndex
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            let next = trimmed.index(after: index)
            if character.isNewline { end = index; break }
            end = next
            if ".!?".contains(character), next == trimmed.endIndex || trimmed[next].isWhitespace { break }
            index = next
        }
        return String(trimmed[..<end])
    }
}
