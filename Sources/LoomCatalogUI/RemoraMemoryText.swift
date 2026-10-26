import Foundation
import LoomRemora

/// The words and the rules of Remora's memory sheet (DESIGN §20 Memory; the reference's `remora/sections.html` "03 Memory"), as plain
/// values so tests pin them.
enum RemoraMemoryText {
    static let title = "Remora's memory"
    static let line = "What Remora keeps between answers. Every change is written at once."
    static let clear = "Clear Working Memory…"
    static let done = "Done"

    static let emptyJournal = "Nothing yet. Remora writes a line here after each answer."
    static let emptyNotes = "No project notes yet. Remora writes one for each project after its next session."
    static let remove = "Remove"
    static let edit = "Edit"
    static let doneEditing = "Done Editing"
    static let removed = "Removed. Remora writes it again after the project's next session."
    static let undo = "Undo"

    /// The vault note: what it holds, where it is, and that Remora writes there only when asked.
    static let noteFileHolds = "Who Remora is, how you want answers, and what you asked it to remember, with dates."
    static let openInObsidian = "Open in Obsidian"

    /// The note's button: Obsidian's name only when the note sits in a vault; elsewhere it opens in the app that opens the file.
    static func openTitle(note: URL?) -> String {
        note.flatMap { RemoraNoteChoice.vault(containing: $0) } != nil ? openInObsidian : RemoraSettingsText.open
    }
    static let honesty = "Remora writes here only when you ask it to remember, or confirm a proposal, and only under its own headings. Edit the note itself in your vault."
    static let noNoteFile = "Remora has no memory note yet."
}

/// The sheet's three tabs, a segment under the head.
public enum RemoraMemoryTab: CaseIterable, Hashable, Sendable {
    case journal, notes, noteFile

    public var title: String {
        switch self {
        case .journal: "Journal"
        case .notes: "Project notes"
        case .noteFile: "Remora.md"
        }
    }

    /// The word the evidence command `remora-memory:<tab>` uses.
    public var evidenceName: String {
        switch self {
        case .journal: "journal"
        case .notes: "notes"
        case .noteFile: "vault"
        }
    }
}

// MARK: The journal

/// One group of the journal: a day (Today, Yesterday, "Monday 19 October") or a week ("Week of 12 October"), with its lines, newest
/// first.
struct RemoraJournalGroup: Identifiable, Equatable {
    struct Line: Identifiable, Equatable {
        /// The id the × removes by: a day's line by its id, a folded day by its date.
        let id: String
        /// "11:20"; "week" for a line that stands for a folded day.
        let time: String
        let text: String
    }

    let id: String
    let label: String
    var lines: [Line]
}

/// A week that was folded: its first day and one line for each day.
struct RemoraJournalWeek: Equatable {
    struct Line: Equatable {
        let id: String
        let text: String
    }

    let start: Date
    let lines: [Line]
}

extension RemoraJournalWeek {
    /// A week as the host folds it: a line for each folded day, its id the day (`YYYY-MM-DD`) the × removes it by.
    init(summary: RemoraWeekSummary) {
        self.init(start: summary.start, lines: summary.lines.map { Line(id: $0.id, text: $0.text) })
    }
}

enum RemoraJournal {
    /// The days the journal keeps by day, and the weeks it keeps after them (design/DESIGN.md §20).
    static let keptDays = 14
    static let keptWeeks = 12

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// "Today", "Yesterday", else "Monday 19 October".
    static func dayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return formatter("EEEE d MMMM", calendar: calendar).string(from: day)
    }

    /// "Week of 12 October": the week's Monday.
    static func weekLabel(_ start: Date, calendar: Calendar) -> String {
        "Week of " + formatter("d MMMM", calendar: calendar).string(from: start)
    }

    /// The time of a line, "11:20".
    static func time(_ date: Date, calendar: Calendar) -> String { formatter("HH:mm", calendar: calendar).string(from: date) }

    /// When the memory was written: "today 09:12", "yesterday 09:12", else the day, "19 October".
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today " + time(date, calendar: calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday " + time(date, calendar: calendar)
        }
        return formatter("d MMMM", calendar: calendar).string(from: date)
    }

    /// What a journal line says: a question with the first sentence of its answer, or the brief's one-line summary.
    static func text(of entry: RemoraJournalEntry) -> String {
        switch entry.kind {
        case .question:
            // A question that ends in its own mark takes no full stop after the quote.
            let asked = entry.question.map { "Asked “\($0)”" + ($0.last.map { "?!.".contains($0) } == true ? "" : ".") }
                ?? "Asked a question."
            return entry.answer.isEmpty ? asked : asked + " " + entry.answer
        case .brief:
            let said = entry.summary ?? entry.answer
            return said.isEmpty ? "Wrote a brief." : "Brief: " + said
        }
    }

    /// The journal as groups: the days that are kept (newest first, at most 14), then the weeks (newest first, at most 12). A day
    /// with no line and a week with none are left out.
    static func groups(days: [(day: Date, entries: [RemoraJournalEntry])], weeks: [RemoraJournalWeek], now: Date,
                       calendar: Calendar) -> [RemoraJournalGroup] {
        var result: [RemoraJournalGroup] = []
        let kept = days.sorted { $0.day > $1.day }.prefix(keptDays)
        for (day, entries) in kept where !entries.isEmpty {
            let lines = entries.sorted { $0.date > $1.date }.map {
                RemoraJournalGroup.Line(id: $0.id, time: time($0.date, calendar: calendar), text: text(of: $0))
            }
            result.append(RemoraJournalGroup(id: "day-\(day.timeIntervalSince1970)", label: dayLabel(day, now: now, calendar: calendar),
                                             lines: lines))
        }
        for week in weeks.sorted(by: { $0.start > $1.start }).prefix(keptWeeks) where !week.lines.isEmpty {
            let lines = week.lines.sorted { $0.id > $1.id }.map { RemoraJournalGroup.Line(id: $0.id, time: "week", text: $0.text) }
            result.append(RemoraJournalGroup(id: "week-\(week.start.timeIntervalSince1970)",
                                             label: weekLabel(week.start, calendar: calendar), lines: lines))
        }
        return result
    }
}

// MARK: A project's note

/// A project's note as the sheet shows and edits it: one `- YYYY-MM-DD · text` line for each item (the note's own form), and the size
/// against the 1.5 KB the note is cut to (`RemoraProjectNote.Limits.bytes`).
enum RemoraNoteText {
    static func display(_ note: RemoraProjectNote) -> String {
        note.readableItems.map { "- \($0.date) · \($0.text)" }.joined(separator: "\n")
    }

    /// "1.4 of 1.5 KB".
    static func size(_ note: RemoraProjectNote) -> String {
        String(format: "%.1f of %.1f KB", Double(note.text.utf8.count) / 1024, Double(RemoraProjectNote.Limits.bytes) / 1024)
    }

    /// A card's head: "rewritten 09:12 · 1.4 of 1.5 KB" (the reference's form for today), "rewritten yesterday 09:12 · …",
    /// "rewritten 19 October · …"; the size alone when the time is not known.
    static func meta(_ note: RemoraProjectNote, rewrittenAt: Date?, now: Date, calendar: Calendar) -> String {
        guard let rewrittenAt else { return size(note) }
        let when = calendar.isDate(rewrittenAt, inSameDayAs: now)
            ? RemoraJournal.time(rewrittenAt, calendar: calendar) : RemoraJournal.when(rewrittenAt, now: now, calendar: calendar)
        return "rewritten " + when + " · " + size(note)
    }

    /// The text to save for what the user left in the editor. A line that is still an item of the note as it was keeps the sessions it
    /// cites, so that a deleted session can still take it away; a line the user changed or wrote is theirs and cites nothing.
    static func fileText(edited: String, original: RemoraProjectNote) -> String {
        var cited: [String: [UUID]] = [:]
        for item in original.readableItems where !item.sessions.isEmpty { cited["- \(item.date) · \(item.text)"] = item.sessions }
        return edited.split(whereSeparator: \.isNewline).map { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let sessions = cited[line] else { return line }
            return line + " (sessions: " + sessions.map(\.uuidString).joined(separator: ", ") + ")"
        }.joined(separator: "\n")
    }
}
