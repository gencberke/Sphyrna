import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3b: Remora's memory sheet as plain values and over a host that holds a temporary memory: the 560 width beside 420 and 480, the
/// day labels, the keys, the note's text and what Clear asks. No Claude call, no panel, no real profile or vault.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RemoraMemoryTests {
    // MARK: Width

    @Test func theMemorySheetIs560WideBesideTheFamilysOther() {
        #expect(SheetLayout.width(.standard) == 420 && SheetLayout.width(.files) == 480 && SheetLayout.width(.memory) == 560)
        #expect(SheetLayout.width(listsFiles: false) == 420 && SheetLayout.width(listsFiles: true) == 480)
        #expect(Set(SheetWidth.allCases.map { SheetLayout.width($0) }).count == SheetWidth.allCases.count, "three widths, three values")
        #expect(LoomTheme.Sheet.memoryWidth == 560)
    }

    // MARK: Days and weeks

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// Wednesday 21 October 2026, noon.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: now)!)
    }

    private func entry(_ id: String, on date: Date, hour: Int = 9, question: String? = nil, answer: String = "Answer.") -> RemoraJournalEntry {
        RemoraJournalEntry(id: id, date: calendar.date(byAdding: .hour, value: hour, to: date)!, kind: question == nil ? .brief : .question,
                           question: question, answer: answer)
    }

    @Test func theDayLabelsAreTodayYesterdayThenTheDay() {
        #expect(RemoraJournal.dayLabel(day(0), now: now, calendar: calendar) == "Today")
        #expect(RemoraJournal.dayLabel(day(-1), now: now, calendar: calendar) == "Yesterday")
        #expect(RemoraJournal.dayLabel(day(-2), now: now, calendar: calendar) == "Monday 19 October")
        #expect(RemoraJournal.dayLabel(day(-13), now: now, calendar: calendar) == "Thursday 8 October")
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        #expect(RemoraJournal.weekLabel(monday, calendar: calendar) == "Week of 12 October")
    }

    @Test func theJournalKeepsFourteenDaysThenTwelveWeeksNewestFirst() {
        let days = (0..<20).map { offset in (day: day(-offset), entries: [entry("d\(offset)", on: day(-offset))]) }
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let weeks = (0..<15).map { index in
            RemoraJournalWeek(start: calendar.date(byAdding: .day, value: -7 * index, to: monday)!,
                              lines: [.init(id: "2026-w\(index)", text: "Week \(index)")])
        }
        let groups = RemoraJournal.groups(days: days.reversed(), weeks: weeks.reversed(), now: now, calendar: calendar)
        #expect(groups.count == 14 + 12)
        #expect(groups.prefix(3).map(\.label) == ["Today", "Yesterday", "Monday 19 October"])
        #expect(groups[13].label == "Thursday 8 October", "the fourteenth day is the last by day")
        #expect(groups[14].label == "Week of 12 October" && groups[14].lines.map(\.time) == ["week"])
        #expect(groups.last?.label == "Week of 27 July", "the twelfth week back")
        #expect(RemoraJournal.keptDays == 14 && RemoraJournal.keptWeeks == 12)
    }

    @Test func aDayShowsItsLinesNewestFirstWithTheirTimeAndAnEmptyDayIsLeftOut() {
        let today = day(0)
        let groups = RemoraJournal.groups(
            days: [(today, [entry("a", on: today, hour: 9), entry("b", on: today, hour: 11, question: "Which session touched auth?",
                                                                 answer: "Migrate auth to JWT.")]),
                   (day(-1), [])],
            weeks: [], now: now, calendar: calendar)
        #expect(groups.count == 1)
        #expect(groups[0].lines.map(\.time) == ["11:00", "09:00"])
        #expect(groups[0].lines.map(\.id) == ["b", "a"])
        #expect(groups[0].lines[0].text == "Asked “Which session touched auth?” Migrate auth to JWT.", "no full stop after the question's own mark")
        #expect(groups[0].lines[1].text == "Brief: Answer.")
        let plain = RemoraJournalEntry(date: today, kind: .question, question: "what moved in loom", answer: "Nothing.")
        #expect(RemoraJournal.text(of: plain) == "Asked “what moved in loom”. Nothing.")
    }

    // MARK: Keys and buttons

    private func navigationAndModel() -> (SettingsNavigation, CatalogModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-memory-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        return (SettingsNavigation(section: .remora), model)
    }

    @Test func escAndDoneCloseTheSheetAndReturnDoesNothing() {
        let (navigation, model) = navigationAndModel()
        navigation.openRemoraMemory()
        let chrome = RemoraMemorySheet.chrome(catalog: model, navigation: navigation) { Color.clear }
        #expect(chrome.width == .memory && chrome.title == "Remora's memory")
        #expect(chrome.cancelTitle == "Done", "Done is the way out, as Esc is")
        #expect(chrome.actions.isEmpty && !chrome.actions.contains(where: \.isFilled), "nothing is filled: nothing waits for a save")
        let filled = chrome.actions.contains(where: \.isFilled)
        #expect(SheetKeys.reaction(to: .escape, hasFilledButton: filled) == .cancel)
        #expect(SheetKeys.reaction(to: .return, hasFilledButton: filled) == .swallow)
        #expect(chrome.leading?.title == "Clear Working Memory…" && chrome.leading?.tint.isPlain == true)
        // Done (the cancel) closes the sheet.
        chrome.cancel()
        #expect(navigation.openSheet == nil)
    }

    @Test func theTabsAreJournalProjectNotesAndRemoraMd() {
        #expect(RemoraMemoryTab.allCases.map(\.title) == ["Journal", "Project notes", "Remora.md"])
        #expect(RemoraMemoryTab.allCases.map(\.evidenceName) == ["journal", "notes", "vault"])
        #expect(LoomTheme.MemorySheet.paneMaxHeight == 404)
        #expect(RemoraMemoryText.line == "What Remora keeps between answers. Every change is written at once.")
    }

    // MARK: A note's text

    private let session = UUID()

    private var note: RemoraProjectNote {
        RemoraProjectNote(text: "- 2026-10-20 · The importer moved to async. (sessions: \(session.uuidString))\n- 2026-10-21 · Next: the fixtures.\n")
    }

    @Test func aNoteIsShownInItsOwnFormAndSizedAgainstItsKilobyteAndAHalf() {
        #expect(RemoraNoteText.display(note) == "- 2026-10-20 · The importer moved to async.\n- 2026-10-21 · Next: the fixtures.")
        #expect(RemoraNoteText.size(note) == "0.1 of 1.5 KB")
    }

    @Test func anEditKeepsTheCitationsOfTheLinesItDidNotChange() {
        let shown = RemoraNoteText.display(note)
        #expect(RemoraNoteText.fileText(edited: shown, original: note)
            == "- 2026-10-20 · The importer moved to async. (sessions: \(session.uuidString))\n- 2026-10-21 · Next: the fixtures.")
        let edited = shown.replacingOccurrences(of: "moved to async", with: "moved to actors") + "\nA line of my own"
        #expect(RemoraNoteText.fileText(edited: edited, original: note)
            == "- 2026-10-20 · The importer moved to actors.\n- 2026-10-21 · Next: the fixtures.\nA line of my own",
            "a line the user changed cites nothing")
    }

    // MARK: Over a host

    @Test func clearAsksFirstAndKeepsRemoraMd() async throws {
        let rig = try RemoraMemoryRig()
        defer { rig.finish() }
        try await rig.seed(journal: [RemoraJournalEntry(date: Date(), kind: .question, question: "q", answer: "a")])
        let navigation = SettingsNavigation(section: .remora)

        // Clear… from Settings only asks.
        navigation.askToClearRemoraMemory(fromMemorySheet: false)
        #expect(navigation.openSheet == .remoraClear(returnsToMemory: false))
        await rig.model.remoraMemoryChanged()
        let keptNotes = await rig.model.remoraNotes().count, keptDays = await rig.model.remoraJournalDays().count
        #expect(keptNotes == 1 && keptDays == 1, "asking cleared nothing")

        // So does the memory sheet's button, and Cancel brings the sheet back with the memory as it was.
        navigation.askToClearRemoraMemory(fromMemorySheet: true)
        #expect(navigation.openSheet == .remoraClear(returnsToMemory: true))
        RemoraClearSheet.leave(presenter: navigation.sheets, returnsToMemory: true)
        #expect(navigation.openSheet == .remoraMemory)
        let afterCancel = await rig.model.remoraNotes().count
        #expect(afterCancel == 1)

        // The question's own button clears the journal and the notes, closes the question (or returns to the memory), keeps Remora.md.
        navigation.askToClearRemoraMemory(fromMemorySheet: true)
        RemoraClearSheet.confirm(model: rig.model, presenter: navigation.sheets, returnsToMemory: true)
        #expect(navigation.openSheet == .remoraMemory)
        await rig.model.remoraMemoryChanged()
        let leftNotes = await rig.model.remoraNotes().count, leftDays = await rig.model.remoraJournalDays().count
        #expect(leftNotes == 0 && leftDays == 0)
        #expect(FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent("Remora.md").path))
        navigation.askToClearRemoraMemory(fromMemorySheet: false)
        RemoraClearSheet.confirm(model: rig.model, presenter: navigation.sheets, returnsToMemory: false)
        #expect(navigation.openSheet == nil)
    }

    @Test func aRemovedLineIsGoneFromTheSheetAndFromTheMemory() async throws {
        let rig = try RemoraMemoryRig()
        defer { rig.finish() }
        try await rig.seed(journal: [RemoraJournalEntry(id: "aaaa0001", date: Date(), kind: .question, question: "q1", answer: "a1"),
                                     RemoraJournalEntry(id: "bbbb0002", date: Date(), kind: .question, question: "q2", answer: "a2")],
                           notes: [])
        let memory = RemoraMemoryModel(catalog: rig.model)
        await memory.load()
        try #require(memory.groups.count == 1)
        #expect(Set(memory.groups[0].lines.map(\.id)) == ["aaaa0001", "bbbb0002"])
        memory.removeLine("bbbb0002")
        #expect(memory.groups[0].lines.map(\.id) == ["aaaa0001"])
        await memory.load()
        #expect(memory.groups[0].lines.map(\.id) == ["aaaa0001"], "the host no longer has it")
        memory.removeLine("aaaa0001")
        #expect(memory.groups.isEmpty)
    }

    @Test func closingTheSheetWhileEditingWritesWhatIsInTheEditor() async throws {
        let rig = try RemoraMemoryRig()
        defer { rig.finish() }
        try await rig.seed()
        let memory = RemoraMemoryModel(catalog: rig.model)
        await memory.load()
        let card = try #require(memory.cards.first)
        memory.toggleEditing(card)
        memory.draft += "\nAlso: typed, then Esc"
        memory.commitEditing()
        #expect(memory.editing == nil)
        await rig.model.remoraMemoryChanged()
        await memory.load()
        #expect(memory.cards.first?.text.hasSuffix("· Also: typed, then Esc") == true)
        // With no edit open it does nothing.
        memory.commitEditing()
        #expect(memory.cards.count == 1)
    }

    @Test func aRemovedNoteCanComeBackAndAnEditedOneIsSavedWhereItStands() async throws {
        // A catalog with the project: the card's name is the model's project name (the notes read no catalog maps).
        let rig = try await RemoraMemoryRig.withProjects(["loom"])
        defer { rig.finish() }
        try await rig.seed()
        let memory = RemoraMemoryModel(catalog: rig.model)
        await memory.load()
        let card = try #require(memory.cards.first)
        #expect(card.name == "loom" && card.text.hasSuffix("· Waits on review"))

        // Edit: the editor holds the note's text; Done Editing writes it.
        memory.toggleEditing(card)
        #expect(memory.isEditing(card) && memory.draft == card.text)
        memory.draft += "\nAlso: check the fixtures"
        memory.toggleEditing(card)
        #expect(memory.editing == nil)
        await rig.model.remoraMemoryChanged()
        await memory.load()
        let edited = try #require(memory.cards.first)
        #expect(edited.text.contains("Waits on review") && edited.text.hasSuffix("· Also: check the fixtures"))

        // Remove: the card becomes a line with Undo, once the host has the token.
        memory.removeNote(edited)
        #expect(memory.cards.isEmpty && memory.noteRows.count == 1)
        for _ in 0..<100 where memory.removed[card.id]?.token == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(memory.removed[card.id]?.token != nil)
        memory.undoRemoval(card.id)
        await rig.model.remoraMemoryChanged()
        await memory.load()
        #expect(memory.removed.isEmpty && memory.cards.count == 1)
    }
}

private extension SheetAction.Tint {
    var isPlain: Bool { if case .plain = self { true } else { false } }
}
