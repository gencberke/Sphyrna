import Foundation
import Testing
@testable import LoomRemora

/// L2a: the journal, its folding, and removing from it.
struct RemoraJournalTests {
    @Test func aLineIsMechanicalCutAndMaskedAndReadsBack() throws {
        let fixture = try RemoraMemoryFixture()
        let id = UUID()
        let question = "Where did I \"leave off\" with the \\ importer? " + String(repeating: "x", count: 300) + " sk-abcdefghijklmnopqrstuv"
        let entry = RemoraJournalEntry.make(
            kind: .question, question: question, answerText: "Look at the importer. It is flaky.\nMore text.", sessions: [id, id],
            model: "claude sonnet", tokens: 2_532, summary: nil, date: fixture.daysAgo(0, hour: 9, minute: 14))
        #expect(entry.question?.count == RemoraJournalEntry.Limits.question)
        #expect(entry.question?.hasSuffix("\u{2026}") == true)
        #expect(entry.answer == "Look at the importer.")
        #expect(entry.sessions == [id], "repeats go")
        #expect(entry.model == "claudesonnet", "no white space in the model")

        let line = entry.line(timeZone: fixture.zone)
        #expect(line.hasPrefix("- 09:14 \(entry.id) question model=claudesonnet tokens=2532 sessions=\(id.uuidString) q=\""))
        #expect(!line.contains("\n"))
        let back = try #require(RemoraJournalEntry(line: line, day: RemoraDay(entry.date, calendar: fixture.calendar), calendar: fixture.calendar))
        #expect(back == entry)

        let secret = RemoraJournalEntry.make(kind: .question, question: "key sk-abcdefghijklmnopqrstuvwxyz1234 here", answerText: "ok",
                                             sessions: [], model: nil, tokens: 0, summary: nil, date: fixture.now)
        #expect(secret.question?.contains("sk-") == false)
    }

    @Test func aBriefHasNoQuestionAndKeepsItsSummary() throws {
        let fixture = try RemoraMemoryFixture()
        let brief = RemoraJournalEntry.make(kind: .brief, question: "ignored", answerText: "Three sessions need you.", sessions: [],
                                            model: nil, tokens: 5, summary: "  Importer\nfixed;  tests pending ", date: fixture.now)
        #expect(brief.question == nil)
        #expect(brief.summary == "Importer fixed; tests pending")
        let back = try #require(RemoraJournalEntry(line: brief.line(timeZone: fixture.zone), day: RemoraDay(fixture.now, calendar: fixture.calendar),
                                                   calendar: fixture.calendar))
        #expect(back.kind == .brief && back.summary == brief.summary && back.question == nil)
    }

    @Test func linesAreAppendedAndFilesAreProtected() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let first = try await memory.appendJournal(fixture.entry(0, hour: 9))
        _ = try await memory.appendJournal(fixture.entry(0, hour: 11, question: "Second?"))
        let lines = await memory.journal(on: fixture.now)
        #expect(lines.map(\.question) == ["What moved?", "Second?"])
        #expect(lines.first?.id == first)
        let name = "journal/" + RemoraDay(fixture.now, calendar: fixture.calendar).string + ".md"
        #expect(fixture.mode(name) == 0o600)
        for folder in ["", "journal", "projects"] { #expect(fixture.mode(folder) == 0o700, "folder \(folder)") }
        #expect(!fixture.names("journal").contains { $0.hasSuffix(".tmp") }, "no temporary file is left")
    }

    @Test func thirtyDaysFoldToFourteenDaysAndWeeklyFilesAndOldWeeksGo() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let session = UUID()
        for age in 0..<30 {
            var entries = [fixture.entry(age, hour: 9), fixture.entry(age, hour: 15, question: "Again?")]
            if age == 20 { entries.append(fixture.entry(age, hour: 16, kind: .brief, question: nil, sessions: [session], summary: "Brief day")) }
            try fixture.writeDay(age, entries)
        }
        try fixture.writeDay(100, [fixture.entry(100)])
        for week in ["2026-W01", "2026-W31", "2026-W32"] {
            try "- 2026-01-01 \u{00B7} an old day\n".write(to: fixture.file("journal/\(week).md"), atomically: true, encoding: .utf8)
        }

        let memory = try fixture.open()
        let days = fixture.names("journal").filter { RemoraDay(String($0.dropLast(3))) != nil }
        #expect(days.count == 14, "\(days)")
        let today = RemoraDay(fixture.now, calendar: fixture.calendar)
        #expect(days.first == RemoraDay(fixture.daysAgo(13), calendar: fixture.calendar).string + ".md")
        #expect(days.last == today.string + ".md")

        let weeks = await memory.weeklySummaries()
        let folded = weeks.flatMap(\.lines).filter { $0.id >= "2026-09" }  // not the hand-made week files' lines
        #expect(folded.count == 16, "ages 14 through 29")
        #expect(Set(folded.map(\.id)).count == 16)
        #expect(folded.first { $0.id == RemoraDay(fixture.daysAgo(14), calendar: fixture.calendar).string }?.text == "2 questions")
        #expect(folded.first { $0.id == RemoraDay(fixture.daysAgo(20), calendar: fixture.calendar).string }?.text == "Brief day")
        #expect(weeks.map(\.week).contains("2026-W32") && !weeks.map(\.week).contains("2026-W31") && !weeks.map(\.week).contains("2026-W01"),
                "a week 11 weeks back stays, 12 goes: \(weeks.map(\.week))")
        #expect(!fixture.names("journal").contains(RemoraDay(fixture.daysAgo(100), calendar: fixture.calendar).string + ".md"))
        for week in weeks.map(\.week) where !["2026-W32"].contains(week) { #expect(fixture.mode("journal/\(week).md") == 0o600) }

        // Folding is idempotent: a reopen and a write change nothing.
        let before = Dictionary(uniqueKeysWithValues: fixture.names("journal").map { ($0, fixture.text("journal/\($0)")) })
        let again = try fixture.open()
        _ = again
        #expect(Dictionary(uniqueKeysWithValues: fixture.names("journal").map { ($0, fixture.text("journal/\($0)")) }) == before)
        try await memory.appendJournal(fixture.entry(1))
        #expect(await memory.weeklySummaries() == weeks)
    }

    @Test func aLaterDayTurnsYesterdayIntoOlderHistoryAndTheFoldFollowsTheClock() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        try await memory.appendJournal(fixture.entry(0))
        #expect(await memory.weeklySummaries().isEmpty)
        fixture.now = fixture.now.addingTimeInterval(14 * 86_400)
        try await memory.appendJournal(fixture.entry(0))
        let weeks = await memory.weeklySummaries()
        #expect(weeks.flatMap(\.lines).map(\.text) == ["1 question"])
        #expect(await memory.journalDays().count == 1)
    }

    @Test func oneLineIsRemovedById() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let first = try await memory.appendJournal(fixture.entry(0, hour: 9, question: "One"))
        let second = try await memory.appendJournal(fixture.entry(0, hour: 10, question: "Two"))
        #expect(try await memory.removeJournalLine(id: first))
        #expect(await memory.journal(on: fixture.now).map(\.id) == [second])
        #expect(try await !memory.removeJournalLine(id: first), "nothing left to remove")
        #expect(try await memory.removeJournalLine(id: second))
        #expect(fixture.names("journal").isEmpty, "an empty day's file goes")

        try fixture.writeDay(20, [fixture.entry(20, summary: nil)])
        let reopened = try fixture.open()
        let folded = try #require(await reopened.weeklySummaries().first?.lines.first)
        #expect(try await reopened.removeJournalLine(id: folded.id))
        #expect(await reopened.weeklySummaries().isEmpty)
    }

    @Test func aDeletedSessionTakesExactlyItsLines() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let doomed = UUID(), other = UUID(), unrelated = UUID()
        let memory = try fixture.open()
        let only = try await memory.appendJournal(fixture.entry(0, hour: 8, question: "only", sessions: [doomed]))
        let both = try await memory.appendJournal(fixture.entry(0, hour: 9, question: "both", sessions: [doomed, other]))
        let brief = try await memory.appendJournal(fixture.entry(1, hour: 9, kind: .brief, question: nil, sessions: [doomed, other], summary: "Day"))
        let none = try await memory.appendJournal(fixture.entry(0, hour: 10, question: "none"))
        let kept = try await memory.appendJournal(fixture.entry(0, hour: 11, question: "kept", sessions: [unrelated]))
        try fixture.writeDay(20, [fixture.entry(20, sessions: [doomed]), fixture.entry(20, question: "x", sessions: [other, doomed])])
        let reopened = try fixture.open()
        let foldedBefore = await reopened.weeklySummaries().flatMap(\.lines)
        #expect(foldedBefore.count == 1)

        try await reopened.forget(session: doomed)
        // Every line that cites it goes, whatever else it cites: a line holds a question and an answer that may be about it.
        let today = await reopened.journal(on: fixture.now)
        #expect(today.map(\.id) == [none, kept] && !today.map(\.id).contains(only) && !today.map(\.id).contains(both))
        #expect(today.last?.sessions == [unrelated])
        #expect(await reopened.journal(on: fixture.daysAgo(1)).allSatisfy { $0.id != brief }, "the brief that cited it goes too")
        #expect(await reopened.weeklySummaries().isEmpty, "the folded day cited it, so the week's line goes")
        let raw = (fixture.names("journal").compactMap { fixture.text("journal/\($0)") }).joined()
        #expect(!raw.contains(doomed.uuidString))

        try await reopened.forget(session: doomed)  // idempotent
        #expect(await reopened.journal(on: fixture.now).map(\.id) == [none, kept])
    }

    @Test func linesThatAreNotOursStayWhenALineIsRemoved() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let id = try await memory.appendJournal(fixture.entry(0))
        let url = fixture.file("journal/" + RemoraDay(fixture.now, calendar: fixture.calendar).string + ".md")
        try ((try String(contentsOf: url, encoding: .utf8)) + "a hand-written note\n").write(to: url, atomically: true, encoding: .utf8)
        _ = try await memory.removeJournalLine(id: id)
        #expect(try String(contentsOf: url, encoding: .utf8) == "a hand-written note\n")
    }
}
