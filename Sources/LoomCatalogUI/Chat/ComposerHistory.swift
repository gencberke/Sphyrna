import Foundation

/// The composer's recall of earlier messages of the session (CHAT-SPEC → Keys, ↑ and ↓) [T3].
///
/// ↑ recalls the newest, then older ones, while the composer is empty or holds a recall nobody edited; ↓ walks forward
/// and, past the newest, clears the composer. Editing a recalled message makes it a normal draft: the walk ends and the
/// text is never replaced by the next ↑. Recall is text only.
struct ComposerHistory: Equatable {
    /// The most messages kept (the newest).
    static let capacity = 200

    private(set) var messages: [String] = []
    /// The position of the message shown now, while a recall is under way.
    private(set) var position: Int?
    /// What the composer held when the recall began: kept so that nothing typed is lost (the recall only starts from
    /// an empty composer or an unedited recall, so this is empty; it is the text ↓ goes back to).
    private(set) var shown: String?

    var isEmpty: Bool { messages.isEmpty }
    var isRecalling: Bool { position != nil }

    /// Replaces the messages (the session's earlier messages, oldest first). Consecutive repeats count once.
    mutating func load(_ texts: [String]) {
        messages = []
        for text in texts { append(text) }
        position = nil
        shown = nil
    }

    /// A message the user sent: it becomes the newest, and a recall in progress ends.
    mutating func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if messages.last != text { messages.append(text) }
        if messages.count > Self.capacity { messages.removeFirst(messages.count - Self.capacity) }
        position = nil
        shown = nil
    }

    /// The composer's text was edited by the user (not by a recall): the recall ends.
    mutating func noteEdit() {
        position = nil
        shown = nil
    }

    /// Whether `text` is exactly the recall shown now (an edit makes it differ).
    func isUneditedRecall(_ text: String) -> Bool {
        shown != nil && shown == text
    }

    /// ↑: the next older message, or nil when there is none (the composer stays as it is).
    mutating func older() -> String? {
        guard !messages.isEmpty else { return nil }
        let next: Int
        if let position {
            guard position > 0 else { return nil }
            next = position - 1
        } else {
            next = messages.count - 1
        }
        position = next
        shown = messages[next]
        return messages[next]
    }

    enum Newer: Equatable {
        case text(String)
        /// Past the newest: the composer is cleared.
        case clear
    }

    /// ↓: the next newer message; past the newest, clear.
    mutating func newer() -> Newer? {
        guard let position else { return nil }
        if position + 1 < messages.count {
            self.position = position + 1
            shown = messages[position + 1]
            return .text(messages[position + 1])
        }
        self.position = nil
        shown = nil
        return .clear
    }
}
