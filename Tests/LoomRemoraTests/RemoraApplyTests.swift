import Foundation
import Testing
@testable import LoomRemora

/// L2b: the brief's block (notes and summary), applying an answer, the share with `Remora.md`, and the cache drift count.
struct RemoraApplyTests {
    // MARK: The block

    private func parse(_ json: String, known: Set<String> = ["a", "b"]) -> RemoraBlock? {
        RemoraBlock.parse("```remora\n\(json)\n```", knownSessionIDs: known)
    }

    private let p1 = UUID(), p2 = UUID(), s1 = UUID(), s2 = UUID()

    @Test func aBriefsNotesAndSummaryAreParsedAndBounded() throws {
        let long = String(repeating: "t", count: 500)
        let items = (0..<12).map { "{\"text\":\"Item \($0)\",\"sessions\":[\"\(s1.uuidString)\"]}" }.joined(separator: ",")
        let block = try #require(parse("""
        {"cited":["a"],"summary":"  Importer\\nfixed  ","notes":[
          {"project":"\(p1.uuidString)","items":[{"text":"\(long)","sessions":["\(s1.uuidString)","\(s1.uuidString)","nope","\(s2.uuidString)"]},
            {"text":"no session","sessions":[]},{"text":"bad session","sessions":["x"]},{"text":"  ","sessions":["\(s1.uuidString)"]},{"sessions":["\(s1.uuidString)"]}]},
          {"project":"not-a-uuid","items":[{"text":"x","sessions":["\(s1.uuidString)"]}]},
          {"project":"\(p1.uuidString)","items":[{"text":"duplicate project","sessions":["\(s1.uuidString)"]}]},
          {"project":"\(p2.uuidString)","items":[\(items)]},
          "not an object", 7
        ]}
        """))
        #expect(block.cited == ["a"] && block.summary == "Importer fixed")
        #expect(block.notes.map(\.project) == [p1.uuidString, p2.uuidString])
        let first = block.notes[0].items
        #expect(first.count == 1, "only the item with a real session and text stays")
        #expect(first[0].text.count == RemoraBlock.Limits.noteItemCharacters)
        #expect(first[0].sessions == [s1.uuidString, s2.uuidString], "ids that are not UUIDs and repeats go")
        #expect(block.notes[1].items.count == RemoraBlock.Limits.noteItems)
    }

    @Test func aBadNotesCostsOnlyTheNotes() throws {
        for json in ["{\"cited\":[\"a\"],\"notes\":\"oops\",\"summary\":\"S\"}", "{\"cited\":[\"a\"],\"notes\":{\"project\":1},\"summary\":\"S\"}",
                     "{\"cited\":[\"a\"],\"notes\":[[1,2],{\"project\":5}],\"summary\":\"S\"}"] {
            let block = try #require(parse(json), "\(json)")
            #expect(block.cited == ["a"] && block.notes.isEmpty && block.summary == "S", "\(json)")
        }
        let wrongSummary = try #require(parse("{\"cited\":[\"a\"],\"summary\":[1]}"))
        #expect(wrongSummary.summary == nil && wrongSummary.cited == ["a"])
        #expect(parse("{\"cited\":[\"a\"],\"notes\":[],\"summary\":\"S\"") == nil, "an unclosed object is still invalid as a whole")
        let many = (0..<10).map { _ in "{\"project\":\"\(UUID().uuidString)\",\"items\":[]}" }.joined(separator: ",")
        #expect(try #require(parse("{\"notes\":[\(many)]}")).notes.count == RemoraBlock.Limits.noteProjects)
    }

    // MARK: apply

    private func pack(kind: RemoraKind = .brief, read: [UUID], named: [UUID] = []) -> RemoraPack {
        RemoraPack(kind: kind, text: "", stablePrefix: "", readSessionIDs: read, namedSessionIDs: Set(read + named), estimatedTokens: 0,
                   facts: RemoraPackFacts(sessionsRead: read.count, sessionsUnread: 0, projectNotes: 0), droppedExcerpts: [],
                   excerptBytes: 0, omittedIndexRows: 0)
    }

    private func answer(text: String = "Two projects moved. The rest is quiet.", cited: [String] = [], notes: [RemoraNoteUpdate] = [],
                        summary: String? = nil, facts: [String] = []) -> RemoraAnswer {
        RemoraAnswer(text: text, cited: cited, chips: [], drafts: [], proposedFacts: facts, notes: notes, summary: summary, block: .valid,
                     model: "claude-haiku-5-5", usage: RemoraTokenUsage(input: 10, cacheCreation: 20, cacheRead: 30, output: 40), costUSD: 0.01,
                     duration: .zero)
    }

    private func update(_ project: UUID, _ items: [(String, [UUID])]) -> RemoraNoteUpdate {
        RemoraNoteUpdate(project: project.uuidString, items: items.map { .init(text: $0.0, sessions: $0.1.map(\.uuidString)) })
    }

    @Test func aBriefReplacesOnlyTheNotesOfTheProjectsThePackReadAndWritesItsLineAndSummary() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let a = UUID(), b = UUID(), c = UUID(), excluded = UUID(), outside = UUID()
        let sa = UUID(), sb = UUID(), sb2 = UUID(), sx = UUID(), sOld = UUID(), sNamedOnly = UUID(), sUnknown = UUID()
        try await memory.replaceNote(project: a, items: [RemoraNoteItem(text: "Old A item", sessions: [sOld]), RemoraNoteItem(text: "Dropped", sessions: [sOld])])
        try await memory.replaceNote(project: c, items: [RemoraNoteItem(text: "C stays", sessions: [UUID()])])
        let cBefore = fixture.text("projects/\(c.uuidString).md")
        let map = [sa: a, sb: b, sb2: b, sx: excluded, sNamedOnly: outside]
        let reply = answer(cited: [sa.uuidString, "junk"], notes: [
            update(a, [("New A item", [sa]), ("Old A item", [sOld]), ("Cites nothing real", [sUnknown]), ("Cites a named session", [sNamedOnly])]),
            update(b, [("B item", [sb])]),
            update(c, [("Tries to rewrite C", [sa])]),
            update(excluded, [("Excluded", [sx])]),
            update(outside, [("Outside the pack", [sNamedOnly])]),
            update(UUID(), [("Unknown project", [sa])]),
            update(a, []),
        ], summary: "A and B moved")
        let proposed = try await memory.apply(answer: reply, request: .brief(since: fixture.daysAgo(1)), pack: pack(read: [sa, sb, sb2, sx], named: [sNamedOnly]),
                                              sessionProjects: map, excludedProjects: [excluded])
        #expect(proposed.isEmpty)

        let noteA = try #require(await memory.note(for: a)).readableItems
        #expect(noteA.map(\.text) == ["New A item", "Old A item", "Cites a named session"], "a session the earlier note cited stays citable")
        #expect(noteA[1].date == "2026-10-21" && noteA.first?.sessions == [sa])
        #expect(await memory.note(for: b)?.readableItems.map(\.text) == ["B item"])
        #expect(fixture.text("projects/\(c.uuidString).md") == cBefore, "a project the pack did not read is never rewritten")
        #expect(await memory.note(for: excluded) == nil)
        #expect(await memory.note(for: outside) == nil)
        #expect(Set(await memory.noteProjects()) == [a, b, c])

        let line = try #require(await memory.journal(on: fixture.now).first)
        #expect(line.kind == .brief && line.question == nil && line.summary == "A and B moved")
        #expect(line.answer == "Two projects moved.")
        #expect(line.sessions == [sa, sb, sb2, sx], "the sessions it read; a cited id that is no UUID is not kept")
        #expect(line.model == "claude-haiku-5-5" && line.tokens == 100)
        #expect(memory.usage.today.calls == 0, "apply adds nothing to the use: the call already did")
    }

    @Test func aProjectWithOneSessionReadGetsNoNoteUnlessItAlreadyHasOne() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let one = UUID(), two = UUID(), kept = UUID()
        let s1 = UUID(), s2a = UUID(), s2b = UUID(), sk = UUID()
        try await memory.replaceNote(project: kept, items: [RemoraNoteItem(text: "Durable", sessions: [sk])])
        let reply = answer(notes: [
            update(one, [("Too soon to know", [s1])]),
            update(two, [("Two sessions read", [s2a, s2b])]),
            update(kept, [("Durable, refreshed", [sk])]),
        ], summary: "The day")
        _ = try await memory.apply(answer: reply, request: .brief(since: fixture.daysAgo(1)),
                                   pack: pack(read: [s1, s2a, s2b, sk]),
                                   sessionProjects: [s1: one, s2a: two, s2b: two, sk: kept])
        #expect(await memory.note(for: one) == nil, "one session read is no note")
        #expect(await memory.note(for: two)?.readableItems.map(\.text) == ["Two sessions read"])
        #expect(await memory.note(for: kept)?.readableItems.map(\.text) == ["Durable, refreshed"], "an existing note is rewritten")
    }

    @Test func aBadNotesKeepsTheAnswerTheJournalLineAndTheOldNotes() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let project = UUID(), session = UUID()
        try await memory.replaceNote(project: project, items: [RemoraNoteItem(text: "Keep me", sessions: [session])])
        let block = try #require(parse("{\"cited\":[\"a\"],\"notes\":\"oops\",\"summary\":\"The day\",\"facts\":[\"A fact\"]}"))
        var reply = answer(cited: block.cited, notes: block.notes, summary: block.summary, facts: block.facts)
        reply.block = .valid
        let proposed = try await memory.apply(answer: reply, request: .brief(since: fixture.daysAgo(1)), pack: pack(read: [session]),
                                              sessionProjects: [session: project])
        #expect(proposed == ["A fact"])
        #expect(await memory.note(for: project)?.readableItems.map(\.text) == ["Keep me"])
        let line = try #require(await memory.journal(on: fixture.now).first)
        #expect(line.summary == "The day" && line.answer == "Two projects moved.")

        // An answer with no block at all is journaled too.
        var plain = answer()
        plain.block = .missing
        _ = try await memory.apply(answer: plain, request: .brief(since: fixture.daysAgo(1)), pack: pack(read: []))
        #expect(await memory.journal(on: fixture.now).count == 2)
    }

    @Test func aQuestionIsJournaledWithItsQuestionAndNeverTouchesNotesAndItsFactsAreOnlyProposed() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let root = fixture.directory.deletingLastPathComponent().appendingPathComponent("remora-apply-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = RemoraDurableNote(url: root.appendingPathComponent("Remora.md"), timeZone: fixture.zone, clock: { fixture.now })
        try await durable.remember("I prefer short answers")
        let before = try Data(contentsOf: root.appendingPathComponent("Remora.md"))
        let memory = try RemoraMemory(directory: fixture.directory, timeZone: fixture.zone, clock: { fixture.now }, durableNote: durable)
        let project = UUID(), session = UUID()
        try await memory.replaceNote(project: project, items: [RemoraNoteItem(text: "Untouched", sessions: [session])])

        let reply = answer(text: "It is on Friday. More words follow.", cited: [session.uuidString],
                           notes: [update(project, [("Rewritten by a question", [session])])], summary: "ignored",
                           facts: ["I prefer short answers", "The release is on Friday"])
        let proposed = try await memory.apply(
            answer: reply, request: .question("When is the \"release\"? sk-abcdefghijklmnopqrstuvwxyz1234", scope: .allProjects, previous: nil),
            pack: pack(kind: .question, read: []), sessionProjects: [session: project])
        #expect(proposed == ["The release is on Friday"], "what Remora.md already holds is not proposed again")
        #expect(try Data(contentsOf: root.appendingPathComponent("Remora.md")) == before, "nothing is saved by apply")
        #expect(await memory.note(for: project)?.readableItems.map(\.text) == ["Untouched"])
        let line = try #require(await memory.journal(on: fixture.now).first)
        #expect(line.kind == .question && line.summary == nil && line.sessions == [session], "cited ids are kept when the pack read none")
        #expect(line.question?.hasPrefix("When is the \"release\"?") == true && line.question?.contains("sk-abc") == false)
        #expect(line.answer == "It is on Friday.")
    }

    @Test func theShareCarriesRemoraMdFromTheStoresNoteAndItsStablePartIgnoresTheJournal() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let root = fixture.directory.deletingLastPathComponent().appendingPathComponent("remora-share-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = RemoraDurableNote(url: root.appendingPathComponent("Remora.md"), timeZone: fixture.zone, clock: { fixture.now })
        let memory = try RemoraMemory(directory: fixture.directory, timeZone: fixture.zone, clock: { fixture.now }, durableNote: durable)
        #expect(await memory.share(for: .allProjects) == RemoraMemoryShare(), "no Remora.md yet")
        try await durable.remember("Release is Friday", project: "edd")
        let first = await memory.share(for: .allProjects)
        #expect(first.text.contains("Release is Friday") && first.text.contains("Remora.md"))
        try await memory.appendJournal(fixture.entry(0))
        let second = await memory.share(for: .allProjects)
        #expect(second.text == first.text && second.recent != first.recent)
    }

    // MARK: Cache drift

    private func lines(_ objects: [[String: Any]]) -> Data {
        Data((objects.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0)) ?? Data(), as: UTF8.self) }.joined(separator: "\n") + "\n").utf8)
    }

    /// The tokens of a scripted `result` frame, read the way a call reads them.
    private func scripted(input: Int, created5m: Int, created1h: Int, read: Int) throws -> RemoraTokenUsage {
        var reader = RemoraStreamReader(knownSessionIDs: [])
        let usage: [String: Any] = ["input_tokens": input, "output_tokens": 100, "cache_creation_input_tokens": created5m + created1h,
                                    "cache_read_input_tokens": read,
                                    "cache_creation": ["ephemeral_5m_input_tokens": created5m, "ephemeral_1h_input_tokens": created1h]]
        _ = reader.feed(lines([["type": "result", "subtype": "success", "is_error": false, "result": "Hi", "terminal_reason": "completed", "usage": usage]]))
        guard case let .answer(answer)? = reader.outcome else { throw CocoaError(.fileReadUnknown) }
        return answer.usage
    }

    @Test func aCallThatWroteMoreThanThreeTimesItsSystemPromptUnderAnHourIsCountedAsDrift() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let suffix = String(repeating: "m", count: 6_000)
        let request = RemoraRequest(kind: .question, pack: "p", systemSuffix: suffix)
        let system = RemoraCall.systemPromptTokens(for: request)
        #expect(system == RemoraPack.estimate(RemoraRules.text + suffix))
        let usage = RemoraUsage(calendar: fixture.calendar, clock: { fixture.now }, persistedAt: fixture.file("usage.json"))

        // Normal: the system part at one hour (about 1.7x its estimate), the tail at five minutes.
        usage.recordStart(.question)
        usage.recordResult(tokens: try scripted(input: 3, created5m: 1_500, created1h: Int(Double(system) * 1.7), read: 0), costUSD: 0.01, systemPromptTokens: system)
        #expect(usage.today.cacheDriftCalls == 0)
        // Ignored key: the whole input, 15k tokens, went under the hour.
        usage.recordStart(.question)
        usage.recordResult(tokens: try scripted(input: 3, created5m: 0, created1h: 15_000, read: 0), costUSD: 0.01, systemPromptTokens: system)
        #expect(usage.today.cacheDriftCalls == 1)
        // A cache read and no one-hour write: nothing to compare.
        usage.recordStart(.question)
        usage.recordResult(tokens: try scripted(input: 3, created5m: 1_500, created1h: 0, read: Int(Double(system) * 1.7)), costUSD: 0.01, systemPromptTokens: system)
        #expect(usage.today.cacheDriftCalls == 1 && usage.today.calls == 3)
        // The line at three times is not drift; one token over it is.
        usage.recordResult(tokens: RemoraTokenUsage(cacheCreation: 3 * system, cacheCreation1h: 3 * system), costUSD: nil, systemPromptTokens: system)
        #expect(usage.today.cacheDriftCalls == 1)
        usage.recordResult(tokens: RemoraTokenUsage(cacheCreation: 3 * system + 1, cacheCreation1h: 3 * system + 1), costUSD: nil, systemPromptTokens: system)
        #expect(usage.today.cacheDriftCalls == 2)
        // A result with no system size (a caller that does not know it) is not checked.
        usage.recordResult(tokens: RemoraTokenUsage(cacheCreation1h: 1_000_000), costUSD: nil)
        #expect(usage.today.cacheDriftCalls == 2)

        // It is persisted with the other counters, by day.
        let reopened = RemoraUsage(calendar: fixture.calendar, clock: { fixture.now }, persistedAt: fixture.file("usage.json"))
        #expect(reopened.today.cacheDriftCalls == 2)
        fixture.now = fixture.now.addingTimeInterval(86_400)
        #expect(reopened.today.cacheDriftCalls == 0 && reopened.days.first?.cacheDriftCalls == 2)
    }
}
