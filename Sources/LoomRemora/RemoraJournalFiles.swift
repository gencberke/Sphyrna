import Foundation

/// A week's file: one line per folded day.
public struct RemoraWeekSummary: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// `YYYY-MM-DD`, which is also the line's id.
        public var id: String
        public var text: String
    }

    /// `YYYY-Www`.
    public var week: String
    public var lines: [Line]
}

/// The journal folder: `YYYY-MM-DD.md` for the last 14 days, `YYYY-Www.md` for the 12 weeks before them. Plain file work
/// on lines; `RemoraMemory` is the one writer.
struct RemoraJournalFiles {
    static let keptDays = 14
    static let keptWeeks = 12

    let directory: URL
    let calendar: Calendar

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".md") }

    private func stems(_ matches: (String) -> Bool) -> [String] {
        RemoraFiles.names(in: directory).filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(3)) }.filter(matches)
    }

    var days: [RemoraDay] { stems { RemoraDay($0) != nil }.compactMap { RemoraDay($0) } }
    var weeks: [RemoraWeek] { stems { RemoraWeek($0) != nil }.compactMap { RemoraWeek($0) } }

    // MARK: Read

    func entries(on day: RemoraDay) -> [RemoraJournalEntry] {
        guard let text = RemoraFiles.readText(url(day.string)) else { return [] }
        return RemoraFiles.lines(of: text).compactMap { RemoraJournalEntry(line: $0, day: day, calendar: calendar) }
    }

    func summary(of week: RemoraWeek) -> RemoraWeekSummary {
        let text = RemoraFiles.readText(url(week.string)) ?? ""
        let items = RemoraFiles.lines(of: text).compactMap(RemoraDatedItem.init(line:))
        return RemoraWeekSummary(week: week.string, lines: items.map { .init(id: $0.day.string, text: $0.text) })
    }

    // MARK: Write

    func append(_ entry: RemoraJournalEntry) throws {
        let day = RemoraDay(entry.date, calendar: calendar)
        let file = url(day.string)
        var text = RemoraFiles.readText(file) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += entry.line(timeZone: calendar.timeZone) + "\n"
        try RemoraFiles.writeAtomically(Data(text.utf8), to: file)
    }

    /// Removes the line with this id (a day's line by its id, a week's by the day it holds). False when none has it.
    func removeLine(id: String) throws -> Bool {
        var removed = false
        try rewriteAll { line, kind in
            switch kind {
            case let .entry(entry) where entry.id == id: removed = true; return .remove
            case let .item(item) where item.day.string == id: removed = true; return .remove
            default: return .keep
            }
        }
        return removed
    }

    /// A permanently deleted session takes every journal line that cites it, a day's line or a folded week's, whatever else
    /// the line cites: the line holds a question and the first sentence of an answer that may be about it (LOMBOT §3.5,
    /// "the journal lines that cite it are removed"). Idempotent.
    func forget(_ session: UUID) throws {
        try rewriteAll { _, kind in
            switch kind {
            case let .entry(entry) where entry.sessions.contains(session): return .remove
            case let .item(item) where item.sessions.contains(session): return .remove
            default: return .keep
            }
        }
    }

    /// Deletes every day's and every week's file.
    func removeAll() {
        for stem in stems({ RemoraDay($0) != nil || RemoraWeek($0) != nil }) { RemoraFiles.remove(url(stem)) }
    }

    private enum Kind {
        case entry(RemoraJournalEntry)
        case item(RemoraDatedItem)
        case other
    }

    private enum Change {
        case keep
        case remove
        case replace(String)
    }

    /// Runs `change` over every parsed line of every file; lines it does not parse stay as they are. A file left with no
    /// line is deleted.
    private func rewriteAll(_ change: (String, Kind) -> Change) throws {
        for day in days {
            try rewrite(url(day.string)) { line in
                change(line, RemoraJournalEntry(line: line, day: day, calendar: calendar).map(Kind.entry) ?? .other)
            }
        }
        for week in weeks {
            try rewrite(url(week.string)) { line in
                change(line, RemoraDatedItem(line: line).map(Kind.item) ?? .other)
            }
        }
    }

    private func rewrite(_ file: URL, _ change: (String) -> Change) throws {
        guard let text = RemoraFiles.readText(file) else { return }
        var output: [String] = []
        var changed = false
        for line in RemoraFiles.lines(of: text) {
            switch change(line) {
            case .keep: output.append(line)
            case .remove: changed = true
            case let .replace(new): changed = true; output.append(new)
            }
        }
        guard changed else { return }
        if output.isEmpty { RemoraFiles.remove(file) } else { try RemoraFiles.writeAtomically(Data((output.joined(separator: "\n") + "\n").utf8), to: file) }
    }

    // MARK: Fold

    /// Days from the 15th back fold into their week's file (one line per day: its summary, or "n questions"); weeks past
    /// the 12th are deleted. Idempotent: a second run changes nothing.
    func fold(now: Date) throws {
        let today = RemoraDay(now, calendar: calendar)
        let thisWeekStart = RemoraWeek(of: today, calendar: calendar).firstDay(calendar: calendar)
        func weekIsTooOld(_ week: RemoraWeek) -> Bool {
            week.firstDay(calendar: calendar).days(since: thisWeekStart, calendar: calendar) <= -Self.keptWeeks * 7
        }
        for day in days where today.days(since: day, calendar: calendar) >= Self.keptDays {
            let week = RemoraWeek(of: day, calendar: calendar)
            if !weekIsTooOld(week) { try foldDay(day, into: week) }
            RemoraFiles.remove(url(day.string))
        }
        for week in weeks where weekIsTooOld(week) { RemoraFiles.remove(url(week.string)) }
    }

    private func foldDay(_ day: RemoraDay, into week: RemoraWeek) throws {
        let entries = entries(on: day)
        guard !entries.isEmpty else { return }
        let questions = entries.filter { $0.kind == .question }.count
        let text = entries.last(where: { $0.summary != nil })?.summary
            ?? (questions == 0 ? "a brief" : "\(questions) question\(questions == 1 ? "" : "s")")
        var seen = Set<UUID>()
        let sessions = entries.flatMap(\.sessions).filter { seen.insert($0).inserted }
        let file = url(week.string)
        let existing = (RemoraFiles.readText(file).map(RemoraFiles.lines(of:)) ?? [])
        var items = existing.compactMap(RemoraDatedItem.init(line:)).filter { $0.day != day }
        let others = existing.filter { RemoraDatedItem(line: $0) == nil }
        items.append(RemoraDatedItem(day: day, text: text, sessions: sessions))
        items.sort { $0.day < $1.day }
        let lines = items.map(\.line) + others
        try RemoraFiles.writeAtomically(Data((lines.joined(separator: "\n") + "\n").utf8), to: file)
    }
}
