import Foundation

/// "Remember …" typed on Home: a question that starts with this word is an order to save a fact, and makes no call. Pure.
///
/// The question's language is free, so a fixed word is the least this can be: the English `remember` and the Turkish
/// `hatırla` (also `hatirla`, as typed without the dotless ı), at the start, whatever the case, followed by a space, a
/// colon or a comma. Any other language is an ordinary question (the model may still propose the fact, which the user
/// confirms). A line that ends with `?` is a question about remembering ("Remember when we fixed the importer?"), not an
/// order, and is not taken. A leading "that" is dropped; nothing else is rewritten.
public enum RemoraRemember {
    public static let prefixes = ["remember", "hatırla", "hatirla"]

    /// The fact to save, or nil when the question is not an order to remember something.
    public static func fact(in question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("?"), !trimmed.hasSuffix("\u{FF1F}") else { return nil }
        for prefix in prefixes where trimmed.prefix(prefix.count).lowercased() == prefix {
            var rest = trimmed.dropFirst(prefix.count)
            guard let first = rest.first, first.isWhitespace || ":,".contains(first) else { continue }
            rest = rest.drop { $0.isWhitespace || ":,".contains($0) }
            if rest.lowercased().hasPrefix("that "), let space = rest.firstIndex(of: " ") { rest = rest[space...].drop { $0.isWhitespace } }
            let fact = RemoraText.flatten(String(rest))
            return fact.isEmpty ? nil : fact
        }
        return nil
    }
}
