import Foundation
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3b follow-ups: the memory sheet on the host's reads (L3a3), over a host that holds a temporary memory. The journal's folded
/// weeks, and a removal's own Undo with two removals in flight. No Claude call, no panel, no real profile or vault.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RemoraFollowUpMemoryTests {
    /// The memory's own calendar: Gregorian in the local time zone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: Date()))!.addingTimeInterval(12 * 3_600)
    }

    @Test func theJournalShowsItsDaysThenOneLineAWeekAndTheXRemovesAFoldedDay() async throws {
        let rig = try RemoraMemoryRig()
        defer { rig.finish() }
        // Today's line stays by day; the lines of 20 and 30 days ago are folded into their weeks as the memory writes them.
        try await rig.seed(journal: [
            RemoraJournalEntry(id: "aaaa0001", date: Date(), kind: .question, question: "q", answer: "a"),
            RemoraJournalEntry(id: "bbbb0002", date: daysAgo(20), kind: .question, question: "q20", answer: "a20"),
            RemoraJournalEntry(id: "cccc0003", date: daysAgo(30), kind: .brief, answer: "b30", summary: "Billing moved"),
        ], notes: [])
        let memory = RemoraMemoryModel(catalog: rig.model)
        await memory.load()

        #expect(memory.groups.first?.label == "Today" && memory.groups.first?.lines.map(\.id) == ["aaaa0001"])
        let weeks = memory.groups.filter { $0.label.hasPrefix("Week of ") }
        try #require(weeks.count == 2, "\(memory.groups.map(\.label))")
        #expect(memory.groups.suffix(2).map(\.id) == weeks.map(\.id), "the weeks come after the days, newest first")
        #expect(weeks.allSatisfy { $0.lines.count == 1 && $0.lines[0].time == "week" })
        #expect(weeks[0].lines[0].text == "1 question" && weeks[1].lines[0].text == "Billing moved")
        let dayID = RemoraDay(daysAgo(20), calendar: calendar).string
        #expect(weeks[0].lines[0].id == dayID, "a folded line's id is its day, which the × removes it by")

        // ×: gone from the sheet at once, and from the memory.
        memory.removeLine(dayID)
        #expect(memory.groups.filter { $0.label.hasPrefix("Week of ") }.count == 1)
        await memory.load()
        let left = memory.groups.filter { $0.label.hasPrefix("Week of ") }
        #expect(left.map { $0.lines.map(\.text) } == [["Billing moved"]], "the host no longer has the folded day")
    }

    @Test func twoRemovalsInFlightEachUndoBringsBackItsOwnNote() async throws {
        let rig = try await RemoraMemoryRig.withProjects(["api", "loom"])
        defer { rig.finish() }
        try await rig.seed(notes: ["Api waits on a test", "Loom waits on review"])
        let memory = RemoraMemoryModel(catalog: rig.model)
        await memory.load()
        let cards = memory.cards
        try #require(cards.map(\.name) == ["api", "loom"])

        // Both go before the host has answered either.
        memory.removeNote(cards[0])
        memory.removeNote(cards[1])
        #expect(memory.cards.isEmpty && memory.noteRows.count == 2)
        for _ in 0..<150 where memory.removed.values.contains(where: { $0.token == nil }) { try await Task.sleep(for: .milliseconds(20)) }
        let first = try #require(memory.removed[cards[0].id]?.token)
        let second = try #require(memory.removed[cards[1].id]?.token)
        #expect(first != second, "each removal holds its own Undo")

        // The first one's Undo brings back the first note only.
        memory.undoRemoval(cards[0].id)
        await rig.model.remoraMemoryChanged()
        await memory.load()
        #expect(memory.cards.map(\.name) == ["api"], "\(memory.cards.map(\.name))")
        #expect(memory.removed.keys.sorted() == [cards[1].id])
        memory.undoRemoval(cards[1].id)
        await rig.model.remoraMemoryChanged()
        await memory.load()
        #expect(memory.cards.map(\.name) == ["api", "loom"])
    }
}
