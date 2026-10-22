import Foundation
import LoomCore
import LoomRemora
import Observation

extension CatalogModel {
    /// Waits for the memory changes made so far (an edit, a removal, Clear, an undo), not for a call in progress: the host takes each
    /// of them as a task of its own, and a read made before they end would see the memory as it was.
    func remoraMemoryChanged() async {
        for item in remora.pending { await item.value }
    }

    /// The deletions under way and those that did not finish. It changes when a deletion ends, after Remora has forgotten the
    /// session (the forgetters run inside the deletion's call), so what shows the memory reads it again then and nothing of a
    /// deleted session stays on screen (the product contract).
    var openDeletions: Set<UUID> { Set(deletions.pending.keys).union(deletions.inProgress) }

    /// Where the memory note is: the file the user chose, else `Remora.md` in Remora's folder; nil with no host and no chosen file.
    var remoraNoteURL: URL? {
        if let path = remora.preferences.noteFilePath { return URL(fileURLWithPath: path) }
        return remora.host.map { remora.preferences.noteURL(defaultIn: $0.directory) }
    }
}

/// What Remora's memory sheet shows and does: the journal and the notes as the host holds them, the edit in progress and the notes
/// removed in this sitting (each with its Undo). Every change goes to the host at once; nothing waits for a save.
@MainActor @Observable
final class RemoraMemoryModel {
    /// A project's note as a card.
    struct NoteCard: Identifiable, Equatable {
        let id: UUID
        let name: String
        let tone: ProjectTone?
        let note: RemoraProjectNote
        /// When the note's file was last written (the morning brief's rewrite, an Edit); nil when the host does not know.
        var rewrittenAt: Date? = nil

        var text: String { RemoraNoteText.display(note) }
        var size: String { RemoraNoteText.size(note) }
        /// "rewritten 09:12 · 1.4 of 2 KB".
        func meta(now: Date, calendar: Calendar) -> String {
            RemoraNoteText.meta(note, rewrittenAt: rewrittenAt, now: now, calendar: calendar)
        }
    }

    /// A card that was removed here and can come back.
    struct RemovedCard: Equatable {
        let card: NoteCard
        /// The undo of this removal; nil until the host has taken it.
        var token: RemoraUndoToken?
    }

    /// One place in the notes list: a card, or the line a removed card left.
    enum NoteRow: Identifiable {
        case card(NoteCard)
        case removed(RemovedCard)

        var id: UUID {
            switch self {
            case let .card(card): card.id
            case let .removed(removed): removed.card.id
            }
        }

        var name: String {
            switch self {
            case let .card(card): card.name
            case let .removed(removed): removed.card.name
            }
        }
    }

    let catalog: CatalogModel
    private let now: () -> Date
    private let calendar: Calendar

    private(set) var groups: [RemoraJournalGroup] = []
    private(set) var cards: [NoteCard] = []
    private(set) var removed: [UUID: RemovedCard] = [:]
    private(set) var loaded = false
    /// The note being edited and what is in the editor.
    var editing: UUID?
    var draft = ""

    init(catalog: CatalogModel, now: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.catalog = catalog
        self.now = now
        self.calendar = calendar
    }

    /// Reads the memory again (after the changes made so far have ended).
    func load() async {
        await catalog.remoraMemoryChanged()
        var days: [(day: Date, entries: [RemoraJournalEntry])] = []
        for day in await catalog.remoraJournalDays() { days.append((day, await catalog.remoraJournal(on: day))) }
        let weeks = await catalog.remoraJournalWeeks().map(RemoraJournalWeek.init(summary:))
        groups = RemoraJournal.groups(days: days, weeks: weeks, now: now(), calendar: calendar)
        cards = await catalog.remoraNotes().map {
            NoteCard(id: $0.project, name: $0.name ?? "Project", tone: catalog.projectTone(forProject: $0.project), note: $0.note,
                     rewrittenAt: $0.rewrittenAt)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loaded = true
    }

    /// "rewritten 09:12 · 1.4 of 2 KB" for a card, read against the sheet's clock.
    func meta(of card: NoteCard) -> String { card.meta(now: now(), calendar: calendar) }

    /// The notes by name, a removed one in its place.
    var noteRows: [NoteRow] {
        (cards.map(NoteRow.card) + removed.values.map(NoteRow.removed))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: The journal

    /// The × on a line: gone at once from the sheet, and from what Remora's next calls see.
    func removeLine(_ id: String) {
        catalog.removeRemoraJournalLine(id: id)
        groups = groups.compactMap { group in
            var kept = group
            kept.lines.removeAll { $0.id == id }
            return kept.lines.isEmpty ? nil : kept
        }
    }

    // MARK: The notes

    func isEditing(_ card: NoteCard) -> Bool { editing == card.id }

    /// Edit starts the editor on the note's text; Done Editing writes what the user left.
    func toggleEditing(_ card: NoteCard) {
        if editing == card.id {
            let text = RemoraNoteText.fileText(edited: draft, original: card.note)
            editing = nil
            catalog.editRemoraNote(project: card.id, text: text)
            Task { await load() }
        } else {
            editing = card.id
            draft = card.text
        }
    }

    /// The sheet is closing (Done, Esc, or the Clear question over it) with an edit still open: what is in the editor is written, so
    /// that nothing the user typed is lost and nothing waits for a save.
    func commitEditing() {
        if let id = editing, let card = cards.first(where: { $0.id == id }) { toggleEditing(card) }
    }

    /// Remove: the card becomes a line with Undo. The Undo is this removal's own token, so a second removal (or a remembered fact)
    /// made before the host answers cannot take its place.
    func removeNote(_ card: NoteCard) {
        if editing == card.id { editing = nil }
        removed[card.id] = RemovedCard(card: card)
        cards.removeAll { $0.id == card.id }
        Task {
            let token = await catalog.removeRemoraNoteWithUndo(project: card.id)
            removed[card.id]?.token = token
        }
    }

    func undoRemoval(_ id: UUID) {
        guard let token = removed[id]?.token else { return }
        catalog.undoRemora(token)
        removed[id] = nil
        Task { await load() }
    }
}
