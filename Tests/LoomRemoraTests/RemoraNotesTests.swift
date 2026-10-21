import Foundation
import LoomCore
import Testing
@testable import LoomRemora

/// L2a: project notes, forgetting, exclusion, clearing.
struct RemoraNotesTests {
    private func item(_ text: String, _ sessions: UUID...) -> RemoraNoteItem { RemoraNoteItem(text: text, sessions: sessions) }

    @Test func aReplacedNoteIsDatedTodayAndShowsItsSessionIds() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let project = UUID(), session = UUID()
        try await memory.replaceNote(project: project, items: [item("Importer is async now.\nOne test is flaky.", session), item("  "), item("Next: release")])
        let note = try #require(await memory.note(for: project))
        #expect(note.readableItems.map(\.date) == ["2026-10-21", "2026-10-21"])
        #expect(note.readableItems.map(\.text) == ["Importer is async now. One test is flaky.", "Next: release"])
        #expect(note.readableItems.first?.sessions == [session])
        let raw = try #require(fixture.text("projects/\(project.uuidString).md"))
        #expect(raw == "- 2026-10-21 \u{00B7} Importer is async now. One test is flaky. (sessions: \(session.uuidString))\n- 2026-10-21 \u{00B7} Next: release\n")
        #expect(fixture.mode("projects/\(project.uuidString).md") == 0o600)
        #expect(await memory.noteProjects() == [project])

        // The next day's rewrite keeps the date of an item whose text did not change.
        fixture.now = fixture.now.addingTimeInterval(86_400)
        try await memory.replaceNote(project: project, items: [item("Next: release"), item("New thing", session)])
        #expect(await memory.note(for: project)?.readableItems.map(\.date) == ["2026-10-21", "2026-10-22"])
        try await memory.replaceNote(project: project, items: [])
        #expect(await memory.note(for: project) == nil, "no items removes it")
    }

    @Test func aNoteNeverPassesTwoKiB() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let project = UUID()
        var items: [RemoraNoteItem] = []
        for index in 0..<30 { items.append(item("Item \(index) " + String(repeating: "w", count: 120), UUID())) }
        try await memory.replaceNote(project: project, items: items)
        let size = try #require(fixture.text("projects/\(project.uuidString).md")).utf8.count
        #expect(size <= RemoraProjectNote.Limits.bytes && size > 1_500, "\(size)")
        #expect(await memory.note(for: project)?.readableItems.first?.text.hasPrefix("Item 0 ") == true, "same-day items: the earlier ones stay")

        // A long edit is cut too, and the newest items win.
        var lines = (0..<30).map { "- 2026-10-\(String(format: "%02d", 1 + $0 % 20)) \u{00B7} Edited \($0) " + String(repeating: "e", count: 100) }
        lines.append("- 2026-10-21 \u{00B7} Newest")
        try await memory.editNote(project: project, text: lines.joined(separator: "\n"))
        let edited = try #require(fixture.text("projects/\(project.uuidString).md"))
        #expect(edited.utf8.count <= RemoraProjectNote.Limits.bytes)
        #expect(edited.contains("Newest"))

        // One huge item is cut, not refused.
        try await memory.editNote(project: project, text: String(repeating: "z", count: 5_000))
        let huge = try #require(fixture.text("projects/\(project.uuidString).md"))
        #expect(huge.utf8.count <= RemoraProjectNote.Limits.bytes && huge.contains("\u{2026}"))
    }

    @Test func anEditKeepsCitationsTheTextKeepsAndNothingElse() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let project = UUID(), kept = UUID(), dropped = UUID()
        try await memory.replaceNote(project: project, items: [item("Alpha", kept), item("Beta", dropped)])
        let text = try #require(fixture.text("projects/\(project.uuidString).md"))
        let edited = text
            .replacingOccurrences(of: "Alpha", with: "Alpha, reworded")
            .replacingOccurrences(of: " (sessions: \(dropped.uuidString))", with: "")
            + "- my own line\nplain line\n"
        try await memory.editNote(project: project, text: edited)
        let items = try #require(await memory.note(for: project)).readableItems
        #expect(items.map(\.text) == ["Alpha, reworded", "Beta", "my own line", "plain line"])
        #expect(items.map(\.sessions) == [[kept], [], [], []])
        #expect(items.map(\.date) == ["2026-10-21", "2026-10-21", "2026-10-21", "2026-10-21"])

        // The user's own lines survive the deletion of any session; the cited item does not.
        try await memory.forget(session: kept)
        #expect(await memory.note(for: project)?.readableItems.map(\.text) == ["Beta", "my own line", "plain line"])
        try await memory.editNote(project: project, text: "")
        #expect(await memory.note(for: project) == nil)
    }

    @Test func removingANoteCanBeUndoneOnce() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let project = UUID()
        #expect(try await memory.removeNote(project: project) == nil)
        try await memory.replaceNote(project: project, items: [item("Keep me", UUID())])
        let before = fixture.text("projects/\(project.uuidString).md")
        let token = try #require(try await memory.removeNote(project: project))
        #expect(await memory.note(for: project) == nil && fixture.text("projects/\(project.uuidString).md") == nil)
        #expect(try await memory.undo(token))
        #expect(fixture.text("projects/\(project.uuidString).md") == before)
        #expect(try await !memory.undo(token), "spent")

        let second = try #require(try await memory.removeNote(project: project))
        try await memory.replaceNote(project: project, items: [item("A newer note")])
        #expect(try await !memory.undo(second), "a note exists again")
        #expect(await memory.note(for: project)?.readableItems.map(\.text) == ["A newer note"])
    }

    @Test func aSessionDeletedWhileANoteIsRemovedIsNotBroughtBackByUndo() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let project = UUID(), doomed = UUID(), other = UUID()
        try await memory.replaceNote(project: project, items: [item("Only doomed", doomed), item("Both", doomed, other)])
        let token = try #require(try await memory.removeNote(project: project))
        try await memory.forget(session: doomed)
        #expect(try await memory.undo(token))
        let items = try #require(await memory.note(for: project)).readableItems
        #expect(items.map(\.text) == ["Both"] && items.first?.sessions == [other])
    }

    @Test func excludingAProjectDeletesItsNoteAndItsUndo() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let excluded = UUID(), other = UUID()
        try await memory.replaceNote(project: excluded, items: [item("Secret plans", UUID())])
        try await memory.replaceNote(project: other, items: [item("Fine", UUID())])
        let token = try #require(try await memory.removeNote(project: excluded))
        try await memory.replaceNote(project: excluded, items: [item("Again", UUID())])
        await memory.excludeProject(excluded)
        #expect(fixture.names("projects") == ["\(other.uuidString).md"])
        #expect(try await !memory.undo(token))
        #expect(await memory.note(for: excluded) == nil)
    }

    @Test func clearingTakesTheJournalAndTheNotesAndKeepsTheUse() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        try await memory.appendJournal(fixture.entry(0))
        try fixture.writeDay(20, [fixture.entry(20)])
        try await memory.replaceNote(project: UUID(), items: [item("x", UUID())])
        memory.usage.recordStart(.question)
        memory.usage.recordResult(tokens: RemoraTokenUsage(input: 3, output: 4), costUSD: 0.5)
        await memory.clearWorkingMemory()
        #expect(fixture.names("journal").isEmpty && fixture.names("projects").isEmpty)
        let reopened = try fixture.open()
        #expect(reopened.usage.today.questions == 1 && reopened.usage.today.tokens.total == 7)
        #expect(fixture.text("usage.json") != nil)
    }

    @Test func theForgetterRegistersWithTheDeletionFlowAndRemovesWhatCitesTheSession() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let project = UUID(), session = UUID()
        try await memory.replaceNote(project: project, items: [item("Cited", session), item("Kept", UUID())])
        try await memory.appendJournal(fixture.entry(0, sessions: [session]))
        let forgetters = ConversationForgetters()
        forgetters.register(RemoraMemoryForgetter(memory: memory))
        let forgetter: any ConversationForgetting = RemoraMemoryForgetter(memory: memory)
        try await forgetter.forget(sessionID: session, providerIDs: ["provider-id"])
        try await forgetter.forget(sessionID: session, providerIDs: ["provider-id"])
        #expect(await memory.note(for: project)?.readableItems.map(\.text) == ["Kept"])
        #expect(await memory.journal(on: fixture.now).isEmpty)
    }
}
