import Foundation

/// One dated item of the working memory with the sessions it cites: a project note's item, or a journal day folded into
/// its week. Written as one line:
///
///     - 2026-10-20 · The importer moved to async; one test is flaky. (sessions: 3F2A…, 91C0…)
///
/// The citation list is last and is left out for an item that cites nothing (the user's own text, typed in Edit).
struct RemoraDatedItem: Equatable, Sendable {
    var day: RemoraDay
    var text: String
    var sessions: [UUID]

    private static let separator = " \u{00B7} "
    private static let citationOpen = " (sessions: "

    var line: String {
        var line = "- \(day.string)\(Self.separator)\(text)"
        if !sessions.isEmpty { line += Self.citationOpen + sessions.map(\.uuidString).joined(separator: ", ") + ")" }
        return line
    }

    init(day: RemoraDay, text: String, sessions: [UUID] = []) {
        self.day = day
        self.text = text
        self.sessions = sessions
    }

    /// Nil for a line that is not an item.
    init?(line: String) {
        guard line.hasPrefix("- "), line.count > 12 else { return nil }
        let rest = line.dropFirst(2)
        guard let day = RemoraDay(String(rest.prefix(10))) else { return nil }
        let afterDay = rest.dropFirst(10)
        guard afterDay.hasPrefix(Self.separator) else { return nil }
        var text = String(afterDay.dropFirst(Self.separator.count))
        var sessions: [UUID] = []
        if text.hasSuffix(")"), let open = text.range(of: Self.citationOpen, options: .backwards) {
            let ids = text[open.upperBound...].dropLast().components(separatedBy: ", ").map { UUID(uuidString: $0) }
            if !ids.isEmpty, !ids.contains(where: { $0 == nil }) {
                sessions = ids.compactMap { $0 }
                text = String(text[..<open.lowerBound])
            }
        }
        self.init(day: day, text: text, sessions: sessions)
    }

    /// The same item without `id`; nil when nothing is left of it (it cited only that session).
    func forgetting(_ id: UUID) -> Self? {
        guard sessions.contains(id) else { return self }
        let rest = sessions.filter { $0 != id }
        return rest.isEmpty ? nil : Self(day: day, text: text, sessions: rest)
    }
}
