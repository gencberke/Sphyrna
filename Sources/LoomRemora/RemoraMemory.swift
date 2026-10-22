import Foundation
import LoomCore

/// What an undo needs to know it is the right one. Opaque to the caller.
public struct RemoraUndoToken: Hashable, Sendable {
    let id = UUID()
}

/// An item a project note is rewritten with: its text and the sessions it cites. The app dates it.
public struct RemoraNoteItem: Equatable, Sendable {
    public var text: String
    public var sessions: [UUID]

    public init(text: String, sessions: [UUID] = []) {
        self.text = text
        self.sessions = sessions
    }
}

/// Remora's working memory (design/DESIGN.md §20; LOMBOT §3.4, §3.5): the journal, the project notes and the persisted use,
/// in one folder the caller gives (the app: `<data root>/remora/`; tests: a temporary one):
///
///     journal/YYYY-MM-DD.md   one line per call, the last 14 days   (`RemoraJournalEntry`)
///     journal/YYYY-Www.md     one line per older day, the last 12 weeks
///     projects/<project id>.md   at most 2 KiB of dated items, each citing its sessions   (`RemoraProjectNote`)
///     usage.json              today's and the last 13 days' use     (`RemoraUsage`)
///
/// This actor is the one writer. Every file is written atomically (a temporary file, then a rename) with mode 0600 in
/// folders of 0700; nothing here logs, and a failure is an error that names an operation, never content. Day and week
/// boundaries are local midnights in `timeZone`. The journal folds when the store opens and after each write.
public actor RemoraMemory {
    public static let journalName = "journal"
    public static let projectsName = "projects"
    public static let usageName = "usage.json"

    public let directory: URL
    /// The persisted counter: give it to `RemoraCall` as its `usage`. (It is the one counter; `apply` does not add a
    /// call's tokens a second time.)
    public nonisolated let usage: RemoraUsage

    private let journalDirectory: URL
    private let projectsDirectory: URL
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private var durableNote: RemoraDurableNote?
    /// Sessions permanently deleted while this process ran: `apply` leaves them out of what it writes, so a call that was
    /// running when `forget(session:)` came cannot bring their words back. Not persisted.
    private var forgotten: Set<UUID>
    /// A removed note with the time its file had, so an undo puts it back as it was (not as a fresh rewrite).
    private var undoable: [RemoraUndoToken: (project: UUID, note: RemoraProjectNote, rewrittenAt: Date?)] = [:]

    /// - Parameter durableNote: `Remora.md`, when the app has a path for it: the share carries its text and `apply` does not
    ///   propose a fact it already holds.
    public init(directory: URL, timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() },
                durableNote: RemoraDurableNote? = nil, forgotten: Set<UUID> = []) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.directory = directory
        self.calendar = calendar
        self.clock = clock
        self.durableNote = durableNote
        self.forgotten = forgotten
        journalDirectory = directory.appendingPathComponent(Self.journalName, isDirectory: true)
        projectsDirectory = directory.appendingPathComponent(Self.projectsName, isDirectory: true)
        try RemoraFiles.ensureDirectory(directory)
        try RemoraFiles.ensureDirectory(journalDirectory)
        try RemoraFiles.ensureDirectory(projectsDirectory)
        usage = RemoraUsage(calendar: calendar, clock: clock, persistedAt: directory.appendingPathComponent(Self.usageName))
        try? RemoraJournalFiles(directory: journalDirectory, calendar: calendar).fold(now: clock())
    }

    /// `Remora.md` moved (Settings' Choose…): the share and `apply` read the new note from now on. The store itself stays
    /// the same, so its use counters, undo tokens and the forgetters that reach it are not replaced.
    public func setDurableNote(_ note: RemoraDurableNote?) { durableNote = note }

    private var journalFiles: RemoraJournalFiles { RemoraJournalFiles(directory: journalDirectory, calendar: calendar) }

    private func noteURL(_ project: UUID) -> URL { projectsDirectory.appendingPathComponent(project.uuidString + ".md") }

    private var today: RemoraDay { RemoraDay(clock(), calendar: calendar) }

    // MARK: Journal

    /// Appends the call's line to its day's file, then folds. Returns the line's id.
    @discardableResult
    public func appendJournal(_ entry: RemoraJournalEntry) throws -> String {
        try journalFiles.append(entry)
        try journalFiles.fold(now: clock())
        return entry.id
    }

    /// The day's lines, oldest first.
    public func journal(on date: Date) -> [RemoraJournalEntry] {
        journalFiles.entries(on: RemoraDay(date, calendar: calendar))
    }

    /// The days that have a file, oldest first.
    public func journalDays() -> [Date] {
        journalFiles.days.sorted().map { $0.start(in: calendar) }
    }

    /// The folded weeks, oldest first.
    public func weeklySummaries() -> [RemoraWeekSummary] {
        journalFiles.weeks.sorted { $0.string < $1.string }.map(journalFiles.summary(of:))
    }

    /// Removes one line (the × on Home): a day's line by its id, a folded day by its date. False when none has the id.
    @discardableResult
    public func removeJournalLine(id: String) throws -> Bool {
        try journalFiles.removeLine(id: id)
    }

    // MARK: Project notes

    public func note(for project: UUID) -> RemoraProjectNote? {
        RemoraFiles.readText(noteURL(project)).map(RemoraProjectNote.init(text:)).flatMap { $0.items.isEmpty ? nil : $0 }
    }

    /// When the project's note file was last written: the morning brief's rewrite and the user's Edit move it, an undo of a
    /// removal puts back the time the note had. Nil when there is no note.
    public func noteRewrittenAt(for project: UUID) -> Date? {
        note(for: project) == nil ? nil : RemoraFiles.modificationDate(noteURL(project))
    }

    /// When the working memory (the journal and the project notes) was last written: the newest modification date of their
    /// files and of the two folders (a folder's date moves when a file in it is written, removed or put back). Nil when
    /// neither holds a journal or note file. Read from the disk each time, so it survives a relaunch.
    public func workingMemoryUpdatedAt() -> Date? {
        var newest: Date?
        var holdsAFile = false
        for folder in [journalDirectory, projectsDirectory] {
            let files = RemoraFiles.names(in: folder).filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            guard !files.isEmpty else { continue }
            holdsAFile = true
            let dates = ([folder] + files.map { folder.appendingPathComponent($0) }).compactMap(RemoraFiles.modificationDate)
            for date in dates where newest.map({ date > $0 }) ?? true { newest = date }
        }
        return holdsAFile ? newest : nil
    }

    /// The projects that have a note.
    public func noteProjects() -> [UUID] {
        RemoraFiles.names(in: projectsDirectory).filter { $0.hasSuffix(".md") }
            .compactMap { UUID(uuidString: String($0.dropLast(3))) }
    }

    /// The daily update: the project's note becomes these items, dated today (an item whose text the note already had
    /// keeps its date), cut to 2 KiB (the newest items stay). No items removes the note.
    public func replaceNote(project: UUID, items: [RemoraNoteItem]) throws {
        let known = Dictionary(note(for: project)?.items.map { ($0.text, $0.day) } ?? [], uniquingKeysWith: { first, _ in first })
        let day = today
        var seen = Set<String>()
        let dated: [RemoraDatedItem] = items.compactMap { item in
            let text = RemoraText.line(item.text, limit: RemoraProjectNote.Limits.itemCharacters)
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            var cited = Set<UUID>()
            return RemoraDatedItem(day: known[text] ?? day, text: text, sessions: item.sessions.filter { cited.insert($0).inserted })
        }
        try write(RemoraProjectNote.fitted(dated), for: project)
    }

    /// Edit: `text` is the note as the user left it. A line that is an item (`- YYYY-MM-DD · text (sessions: …)`) keeps
    /// its date and the citations it still has; any other line becomes an item dated today that cites nothing (it is the
    /// user's own text, so no deleted session can take it away). The result is cut to 2 KiB. Empty text removes the note.
    public func editNote(project: UUID, text: String) throws {
        let day = today
        let items: [RemoraDatedItem] = text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let item = RemoraDatedItem(line: line) {
                let clean = RemoraText.flatten(RemoraSecretMask.mask(item.text))
                return clean.isEmpty ? nil : RemoraDatedItem(day: item.day, text: clean, sessions: item.sessions)
            }
            var free = line
            for bullet in ["- ", "* "] where free.hasPrefix(bullet) { free = String(free.dropFirst(bullet.count)) }
            let clean = RemoraText.flatten(RemoraSecretMask.mask(free))
            return clean.isEmpty ? nil : RemoraDatedItem(day: day, text: clean)
        }
        try write(RemoraProjectNote.fitted(items), for: project)
    }

    /// Deletes the note; the token restores it with `undo(_:)`. Nil when there was none.
    public func removeNote(project: UUID) throws -> RemoraUndoToken? {
        guard let note = note(for: project) else { return nil }
        let rewrittenAt = RemoraFiles.modificationDate(noteURL(project))
        RemoraFiles.remove(noteURL(project))
        let token = RemoraUndoToken()
        undoable[token] = (project, note, rewrittenAt)
        if undoable.count > 20, let oldest = undoable.keys.first(where: { $0 != token }) { undoable[oldest] = nil }
        return token
    }

    /// Puts a removed note back, with the time its file had before the removal. False when the token is spent or unknown, or
    /// the project has a note again.
    @discardableResult
    public func undo(_ token: RemoraUndoToken) throws -> Bool {
        guard let entry = undoable[token], note(for: entry.project) == nil else { return false }
        try write(entry.note, for: entry.project)
        if let rewrittenAt = entry.rewrittenAt, !entry.note.items.isEmpty {
            RemoraFiles.setModificationDate(rewrittenAt, of: noteURL(entry.project))
        }
        undoable[token] = nil
        return true
    }

    private func write(_ note: RemoraProjectNote, for project: UUID) throws {
        if note.items.isEmpty {
            RemoraFiles.remove(noteURL(project))
        } else {
            try RemoraFiles.writeAtomically(Data(note.text.utf8), to: noteURL(project))
        }
    }

    // MARK: Forgetting and exclusion

    /// A session was permanently deleted: every journal line that cites it goes, whatever else it cites; a note item that
    /// cites only it goes, and one that cites others too loses the id (the next brief rewrites the note). Idempotent.
    public func forget(session: UUID) throws {
        forgotten.insert(session)
        try journalFiles.forget(session)
        for project in noteProjects() {
            guard let note = note(for: project), note.sessionIDs.contains(session) else { continue }
            try write(note.forgetting(session), for: project)
        }
        for (token, entry) in undoable { undoable[token] = (entry.project, entry.note.forgetting(session), entry.rewrittenAt) }
    }

    /// The project is excluded from Remora: its note is deleted now. Journal lines that cite only its sessions stay on
    /// disk and are kept out of the memory share (`share`).
    public func excludeProject(_ project: UUID) {
        RemoraFiles.remove(noteURL(project))
        for token in undoable.keys where undoable[token]?.project == project { undoable[token] = nil }
    }

    /// Settings' Clear: the journal and the notes go. The use counters stay (and `Remora.md`, which this store does not
    /// own).
    public func clearWorkingMemory() {
        journalFiles.removeAll()
        for name in RemoraFiles.names(in: projectsDirectory) where name.hasSuffix(".md") {
            RemoraFiles.remove(projectsDirectory.appendingPathComponent(name))
        }
        undoable = [:]
    }

    // MARK: Share

    /// The memory a request carries (see `RemoraMemoryShare`). `sessionProjects` maps every session the caller knows to
    /// its project (the excluded projects' sessions included): the share needs it to find a session's project and to keep
    /// the journal lines of excluded projects out. `durableNote` is `Remora.md`'s text (by default, the store's note read now). `projectNames` are the projects Remora may name (a brief writes notes by project id): the stable part lists those in scope, so the caller passes the ones with a session in the index.
    public func share(for scope: RemoraScope, excludedProjects: Set<UUID> = [], sessionProjects: [UUID: UUID] = [:],
                      projectNames: [UUID: String] = [:], durableNote: String? = nil) async -> RemoraMemoryShare {
        let durableText: String
        if let durableNote { durableText = durableNote } else { durableText = await self.durableNote?.text() ?? "" }
        let now = clock()
        let day = RemoraDay(now, calendar: calendar)
        let yesterday = RemoraDay(calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)
        let inScope: Set<UUID>? = switch scope {
        case .allProjects: nil
        case let .project(id): [id]
        case let .session(id): sessionProjects[id].map { [$0] } ?? []
        }
        let notes: [RemoraMemoryShare.ProjectNote] = noteProjects().compactMap { project in
            guard !excludedProjects.contains(project), inScope?.contains(project) ?? true,
                  let note = note(for: project) else { return nil }
            return .init(project: project, name: projectNames[project], note: note)
        }
        let named = projectNames.filter { !excludedProjects.contains($0.key) && (inScope?.contains($0.key) ?? true) }
        let lines = (journalFiles.entries(on: yesterday) + journalFiles.entries(on: day)).filter { entry in
            !entry.sessions.contains { session in sessionProjects[session].map(excludedProjects.contains) ?? false }
        }
        return RemoraMemoryShare.build(notes: notes, projects: named, journal: lines, durableNote: durableText,
                                       timeZone: calendar.timeZone)
    }

    // MARK: Applying an answer

    /// After a call: writes the journal line (both kinds); for a brief, replaces the note of each project the pack read
    /// (the projects of `pack.readSessionIDs` through `sessionProjects`; never one outside it, never an excluded one) with
    /// the block's items and writes the summary on the line. Returns the facts the answer proposes (the ones `Remora.md`
    /// does not hold yet) for the caller to offer as "Remember this?"; it never saves one.
    ///
    /// A note's items keep only the sessions the pack names or the project's earlier note cited (an item that keeps none is
    /// dropped); a project whose items all go keeps its note. A question's notes and summary are ignored. The call's
    /// tokens are not added to the use again: `usage` is the counter `RemoraCall` adds them to. A failed write does not stop
    /// the others; the first error is thrown at the end (the facts are then `answer.proposedFacts`).
    public func apply(answer: RemoraAnswer, request: RemoraPackRequest, pack: RemoraPack, sessionProjects: [UUID: UUID] = [:],
                      excludedProjects: Set<UUID> = []) async throws -> [String] {
        let isBrief = request.kind == .brief
        var firstError: (any Error)?
        var sessions = pack.readSessionIDs
        for id in answer.cited.compactMap(UUID.init(uuidString:)) where !sessions.contains(id) { sessions.append(id) }
        // A session deleted while the call ran is left out: a line that names only such sessions is not written at all.
        let named = sessions
        sessions.removeAll { forgotten.contains($0) }
        var question: String?
        if case let .question(text, _, _) = request { question = text }
        if request.isDraft { question = "Draft Brief" }
        let entry = RemoraJournalEntry.make(
            kind: request.kind, question: question, answerText: answer.text, sessions: sessions, model: answer.model,
            tokens: answer.usage.total, summary: isBrief ? answer.summary : nil, date: clock(), isDraft: request.isDraft)
        if sessions.isEmpty, !named.isEmpty {
            // Nothing to write: every session this call rests on is gone.
        } else {
            do { try appendJournal(entry) } catch { firstError = error }
        }

        if isBrief {
            let moved = Set(pack.readSessionIDs.compactMap { sessionProjects[$0] }).subtracting(excludedProjects)
            for update in answer.notes {
                guard let project = UUID(uuidString: update.project), moved.contains(project) else { continue }
                let allowed = pack.namedSessionIDs.union(note(for: project)?.sessionIDs ?? [])
                let items: [RemoraNoteItem] = update.items.compactMap { item in
                    var cited = Set<UUID>()
                    let ids = item.sessions.compactMap(UUID.init(uuidString:)).filter { allowed.contains($0) && !forgotten.contains($0) && cited.insert($0).inserted }
                    return ids.isEmpty ? nil : RemoraNoteItem(text: item.text, sessions: ids)
                }
                guard !items.isEmpty else { continue }
                do { try replaceNote(project: project, items: items) } catch { firstError = firstError ?? error }
            }
        }
        if let firstError { throw firstError }
        var offered: [String] = []
        for fact in answer.proposedFacts {
            if let durableNote, await durableNote.alreadyRemembers(fact) { continue }
            offered.append(fact)
        }
        return offered
    }
}
