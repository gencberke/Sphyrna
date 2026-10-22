import Foundation

extension RemoraMemoryShare {
    /// The share's caps, in estimated tokens (UTF-8 bytes / 4), as `RemoraPack.estimate` counts them. The two parts go
    /// into the pack in different places: `text` is cut by the layout at 8 KiB (`<memory>`) and `recent` at 6 KiB
    /// (`<journal>`), so the share stays inside both and the layout never has to cut it.
    public enum Caps {
        /// `text` and `recent` together.
        public static let tokens = 3_000
        public static let stableBytes = 8 * 1024
        public static let recentBytes = 6 * 1024
        /// The projects named for a brief's notes.
        public static let namedProjects = 40
    }

    struct ProjectNote: Equatable, Sendable {
        var project: UUID
        var name: String?
        var note: RemoraProjectNote
    }

    /// Writes the share (L2; design/DESIGN.md §20, LOMBOT §3.4).
    ///
    /// `text`, the stable part, is a function of the notes and `Remora.md` alone: it has no time in it and does not change
    /// when a journal line is added.
    ///
    ///     Remora.md (the user's own note; what the user asked Remora to remember, each fact dated):
    ///     <its text, whole>
    ///
    ///     Projects (id and name), the ids a brief's notes use:
    ///     - <project id> "<name>"
    ///
    ///     Project notes (Remora's own, rewritten each morning; every item says when it was written):
    ///     Project <id> "<name>":
    ///     - as of 20 Oct: <text> (sessions: <id>, <id>)
    ///
    /// `recent` is today's and yesterday's calls, oldest first, one line each with its date and time. Over the cap the
    /// older journal lines go first; the notes of the projects that moved longest ago (a note's newest item is when its
    /// project last moved) go only when the stable part itself passes 8 KiB (never for the journal's sake, so the journal
    /// cannot change it); the project list goes after the notes; `Remora.md` is never cut. Both parts are written in a
    /// fixed order (notes by project id), so the same state gives the same bytes.
    static func build(notes: [ProjectNote], projects: [UUID: String], journal: [RemoraJournalEntry], durableNote: String,
                      timeZone: TimeZone) -> RemoraMemoryShare {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var recentLines = journal.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }.map { line(of: $0, calendar: calendar) }
        // Newest-moved first: the cut takes from the end. Ties go by project id.
        var kept = notes.sorted { left, right in
            let (one, two) = (left.note.newestDay, right.note.newestDay)
            if one != two { return (one ?? RemoraDay(year: 0, month: 1, day: 1)) > (two ?? RemoraDay(year: 0, month: 1, day: 1)) }
            return left.project.uuidString < right.project.uuidString
        }
        var named = projects.sorted { left, right in
            let order = left.value.localizedCaseInsensitiveCompare(right.value)
            return order != .orderedSame ? order == .orderedAscending : left.key.uuidString < right.key.uuidString
        }.prefix(Caps.namedProjects).map { ($0.key, $0.value) }
        let durable = durableNote.trimmingCharacters(in: .whitespacesAndNewlines)

        func stable() -> String { stableText(durable: durable, projects: named, notes: kept) }
        func recent() -> String { recentLines.joined(separator: "\n") }
        func tokens() -> Int { RemoraPack.estimate(stable()) + RemoraPack.estimate(recent()) }
        // The stable part first, and by its own limit alone (the layout cuts `<memory>` at 8 KiB, from its end): so it never
        // depends on the journal, and a journal line never changes it. Then the journal gives way to the total cap.
        while stable().utf8.count > Caps.stableBytes, !kept.isEmpty { kept.removeLast() }
        while stable().utf8.count > Caps.stableBytes, !named.isEmpty { named.removeLast() }
        while tokens() > Caps.tokens || recent().utf8.count > Caps.recentBytes, !recentLines.isEmpty { recentLines.removeFirst() }
        return RemoraMemoryShare(text: stable(), recent: recent(), projectNotes: kept.count)
    }

    private static func stableText(durable: String, projects: [(UUID, String)], notes: [ProjectNote]) -> String {
        var sections: [String] = []
        if !durable.isEmpty {
            sections.append("Remora.md (the user's own note; what the user asked Remora to remember, each fact dated):\n" + durable)
        }
        if !projects.isEmpty {
            sections.append("Projects (id and name), the ids a brief's notes use:\n"
                + projects.map { "- \($0.0.uuidString) \"\(label($0.1))\"" }.joined(separator: "\n"))
        }
        if !notes.isEmpty {
            let blocks = notes.sorted { $0.project.uuidString < $1.project.uuidString }.map { entry -> String in
                let name = entry.name.map { " \"\(label($0))\"" } ?? ""
                let items = entry.note.items.map { item in
                    "- as of \(item.day.short): \(item.text)"
                        + (item.sessions.isEmpty ? "" : " (sessions: " + item.sessions.map(\.uuidString).joined(separator: ", ") + ")")
                }
                return (["Project \(entry.project.uuidString)\(name):"] + items).joined(separator: "\n")
            }
            sections.append("Project notes (Remora's own, rewritten each morning; every item says when it was written):\n"
                + blocks.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func line(of entry: RemoraJournalEntry, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: entry.date)
        let when = "\(RemoraDay(entry.date, calendar: calendar).short) " + String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        switch entry.kind {
        case .question where entry.isDraft:
            return "- \(when) drafted a session's brief: \"\(entry.answer)\""
        case .question:
            return "- \(when) asked: \"\(entry.question ?? "")\" | answered: \"\(entry.answer)\""
        case .brief:
            return "- \(when) morning brief: \"\(entry.answer)\""
        }
    }

    private static func label(_ name: String) -> String {
        RemoraText.flatten(name).replacingOccurrences(of: "\"", with: "'").prefix(80).description
    }
}
