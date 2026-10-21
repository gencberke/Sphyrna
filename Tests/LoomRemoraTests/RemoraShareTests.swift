import Foundation
import Testing
@testable import LoomRemora

/// L2a: the memory share, in its two parts (D-85): `text` (Remora.md, the project list, the notes) is stable, `recent` holds
/// the journal lines.
struct RemoraShareTests {
    private func filled(_ fixture: RemoraMemoryFixture, projects: Int = 3) async throws -> (RemoraMemory, [UUID]) {
        let memory = try fixture.open()
        var ids: [UUID] = []
        for index in 0..<projects {
            let id = UUID()
            ids.append(id)
            try await memory.replaceNote(project: id, items: [RemoraNoteItem(text: "Project \(index) is at step \(index).", sessions: [UUID()])])
        }
        try await memory.appendJournal(fixture.entry(1, hour: 17, question: "Yesterday's question", answer: "Yesterday's answer. More."))
        try await memory.appendJournal(fixture.entry(0, hour: 9, question: "Today's question", answer: "Today's answer."))
        return (memory, ids)
    }

    @Test func theShareHasNotesWithDatesAndTheJournalNewestLast() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let (memory, ids) = try await filled(fixture)
        let names = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "Proj \($0)") })
        let share = await memory.share(for: .allProjects, projectNames: names, durableNote: "## Remembered\n- 2026-10-18 \u{00B7} edd \u{00B7} Release is Friday\n")
        #expect(share.projectNotes == 3)
        #expect(share.text.hasPrefix("Remora.md (the user's own note"))
        #expect(share.text.contains("- 2026-10-18 \u{00B7} edd \u{00B7} Release is Friday"))
        #expect(share.text.contains("- as of 21 Oct: Project 1 is at step 1."))
        for id in ids { #expect(share.text.contains(id.uuidString)) }
        #expect(share.text.contains("\"Proj 2\""))
        let remoraAt = try #require(share.text.range(of: "Remora.md"))
        let notesAt = try #require(share.text.range(of: "Project notes"))
        #expect(remoraAt.lowerBound < notesAt.lowerBound)
        #expect(!share.text.contains("Today's question"), "the journal is not in the stable part")
        let lines = share.recent.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("- 20 Oct 17:00 asked: \"Yesterday's question\" | answered: \"Yesterday's answer.\""))
        #expect(lines[1].hasPrefix("- 21 Oct 09:00 asked: \"Today's question\""))
    }

    @Test func twoSharesFromTheSameStateAreByteIdenticalAndAJournalLineLeavesTheStablePartAlone() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let (memory, ids) = try await filled(fixture, projects: 5)
        let names = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "Proj \($0)") })
        let first = await memory.share(for: .allProjects, projectNames: names, durableNote: "Remora.md text")
        let second = await memory.share(for: .allProjects, projectNames: names, durableNote: "Remora.md text")
        #expect(first == second)
        fixture.now = fixture.now.addingTimeInterval(3 * 3_600)
        try await memory.appendJournal(fixture.entry(0, hour: 14, question: "A new line"))
        let third = await memory.share(for: .allProjects, projectNames: names, durableNote: "Remora.md text")
        #expect(third.text == first.text, "a journal line (and the hours) change nothing of the stable part")
        #expect(third.recent != first.recent && third.recent.hasSuffix(third.recent.split(separator: "\n").last.map(String.init) ?? "?"))
        #expect(third.recent.contains("A new line"))
        // A changed note does change it.
        try await memory.replaceNote(project: ids[0], items: [RemoraNoteItem(text: "Different", sessions: [UUID()])])
        #expect(await memory.share(for: .allProjects, projectNames: names, durableNote: "Remora.md text").text != first.text)
    }

    @Test func scopeChoosesTheNotes() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let (memory, ids) = try await filled(fixture)
        let session = UUID()
        let all = await memory.share(for: .allProjects)
        #expect(all.projectNotes == 3)
        let one = await memory.share(for: .project(ids[1]))
        #expect(one.projectNotes == 1 && one.text.contains(ids[1].uuidString) && !one.text.contains(ids[0].uuidString))
        let bySession = await memory.share(for: .session(session), sessionProjects: [session: ids[2]])
        #expect(bySession.projectNotes == 1 && bySession.text.contains(ids[2].uuidString))
        #expect(await memory.share(for: .session(UUID())).projectNotes == 0, "a session with no known project has no notes")
        #expect(await memory.share(for: .allProjects, excludedProjects: [ids[0]]).projectNotes == 2)
        #expect(await memory.share(for: .project(ids[0]), excludedProjects: [ids[0]]).projectNotes == 0)
    }

    @Test func linesOfAnExcludedProjectNeverReachTheShareButStayOnDisk() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let hidden = UUID(), shown = UUID(), hiddenProject = UUID(), shownProject = UUID()
        try await memory.appendJournal(fixture.entry(0, hour: 8, question: "About hidden", sessions: [hidden]))
        try await memory.appendJournal(fixture.entry(0, hour: 9, question: "About both", sessions: [shown, hidden]))
        try await memory.appendJournal(fixture.entry(0, hour: 10, question: "About shown", sessions: [shown]))
        try await memory.appendJournal(fixture.entry(0, hour: 11, question: "About nothing"))
        let map = [hidden: hiddenProject, shown: shownProject]
        let share = await memory.share(for: .allProjects, excludedProjects: [hiddenProject], sessionProjects: map)
        #expect(share.recent.contains("About shown") && share.recent.contains("About nothing"))
        #expect(!share.recent.contains("About hidden") && !share.recent.contains("About both"), "a line that cites an excluded session stays out")
        #expect(await memory.journal(on: fixture.now).count == 4, "on disk they stay")
        #expect(await memory.share(for: .allProjects, sessionProjects: map).recent.contains("About hidden"))
    }

    @Test func overTheCapOlderJournalLinesGoFirstThenTheNotesOfProjectsThatMovedLongAgoAndRemoraMdNeverGoes() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        // Eight projects, each with a note of about 0.9 KiB; project k last moved k days ago.
        var ids: [UUID] = []
        for k in 0..<8 {
            let id = UUID()
            ids.append(id)
            fixture.now = fixture.date(2026, 10, 21 - k, 12)
            try await memory.replaceNote(project: id, items: (0..<3).map {
                RemoraNoteItem(text: "Note \(k) item \($0) " + String(repeating: "n", count: 200), sessions: [UUID()])
            })
        }
        fixture.now = fixture.date(2026, 10, 21, 12)
        for index in 0..<40 {
            try await memory.appendJournal(fixture.entry(index % 2, hour: 1 + index % 20, question: "Question \(index) " + String(repeating: "q", count: 150), answer: "Answer \(index)."))
        }
        let share = await memory.share(for: .allProjects)
        let tokens = RemoraPack.estimate(share.text) + RemoraPack.estimate(share.recent)
        #expect(tokens <= RemoraMemoryShare.Caps.tokens, "\(tokens)")
        #expect(share.text.utf8.count <= RemoraMemoryShare.Caps.stableBytes && share.recent.utf8.count <= RemoraMemoryShare.Caps.recentBytes)
        #expect(tokens > 2_700, "the share fills the room it has: \(tokens)")
        // Journal lines went first, the oldest of them: the newest line is there, the oldest is not.
        #expect(share.recent.contains("Question 38 "))
        #expect(!share.recent.contains("Question 1 ") && !share.recent.contains("Question 3 "))
        #expect(share.recent.split(separator: "\n").count < 40)
        #expect(share.projectNotes == 8, "all notes stay while a journal line can go instead")

        // A big Remora.md leaves the notes less than the layout's 8 KiB: those of the projects that moved longest ago go.
        let big = "## Remembered\n" + String(repeating: "- 2026-10-01 \u{00B7} a fact that stays whole\n", count: 150)
        #expect(big.utf8.count < 8_000)
        let squeezed = await memory.share(for: .allProjects, durableNote: big)
        #expect(squeezed.text.contains(big.trimmingCharacters(in: .whitespacesAndNewlines)), "Remora.md is never cut")
        #expect(squeezed.text.utf8.count <= RemoraMemoryShare.Caps.stableBytes)
        #expect(!squeezed.recent.isEmpty && squeezed.recent.contains("Question 38 "), "the journal keeps what room the total leaves")
        #expect(RemoraPack.estimate(squeezed.text) + RemoraPack.estimate(squeezed.recent) <= RemoraMemoryShare.Caps.tokens)
        #expect(squeezed.projectNotes < 8)
        let again = await memory.share(for: .allProjects, durableNote: big)
        #expect(again == squeezed)
        let remaining = ids.enumerated().filter { squeezed.text.contains($0.element.uuidString) }.map(\.offset)
        #expect(remaining == Array(0..<remaining.count), "the projects that moved last stay: \(remaining)")
    }

    @Test func nothingToShareIsEmpty() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let share = try await fixture.open().share(for: .allProjects)
        #expect(share == RemoraMemoryShare())
    }
}
