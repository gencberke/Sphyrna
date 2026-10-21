import Foundation
import Testing
@testable import LoomRemora

/// A session permanently deleted while a call ran: the memory's `apply`, which a call ends with, leaves it out of what it writes.
/// (`RemoraHostForgetterTests` holds the host-level cases, with a slow brief and a real runtime deletion.)
struct RemoraForgottenSessionTests {
    private func pack(read: [UUID]) -> RemoraPack {
        RemoraPack(kind: .brief, text: "", stablePrefix: "", readSessionIDs: read, namedSessionIDs: Set(read), estimatedTokens: 0,
                   facts: RemoraPackFacts(sessionsRead: read.count, sessionsUnread: 0, projectNotes: 0), droppedExcerpts: [],
                   excerptBytes: 0, omittedIndexRows: 0)
    }

    private func answer(cited: [UUID], notes: [RemoraNoteUpdate]) -> RemoraAnswer {
        RemoraAnswer(text: "Two projects moved.", cited: cited.map(\.uuidString), chips: [], drafts: [], proposedFacts: [], notes: notes,
                     summary: "Moved", block: .valid, model: "claude-haiku-5-5",
                     usage: RemoraTokenUsage(input: 1, cacheCreation: 1, cacheRead: 1, output: 1), costUSD: 0, duration: .zero)
    }

    private func update(_ project: UUID, _ items: [(String, [UUID])]) -> RemoraNoteUpdate {
        RemoraNoteUpdate(project: project.uuidString, items: items.map { .init(text: $0.0, sessions: $0.1.map(\.uuidString)) })
    }

    @Test func aLineKeepsOnlyTheSessionsThatAreNotForgottenAndAnItemLosesTheForgottenOnes() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let (project, kept, gone) = (UUID(), UUID(), UUID())
        try await memory.forget(session: gone)
        _ = try await memory.apply(
            answer: answer(cited: [kept, gone], notes: [update(project, [("Both", [gone, kept]), ("Only the gone one", [gone]), ("Only kept", [kept])])]),
            request: .brief(since: fixture.daysAgo(1)), pack: pack(read: [kept, gone]), sessionProjects: [kept: project, gone: project])
        let line = try #require(await memory.journal(on: fixture.now).first)
        #expect(line.sessions == [kept], "the forgotten id stayed in the line")
        let items = try #require(await memory.note(for: project)).readableItems
        #expect(items.map(\.text) == ["Both", "Only kept"])
        #expect(items.allSatisfy { !$0.sessions.contains(gone) })
    }

    @Test func aLineThatRestsOnlyOnForgottenSessionsAndTheirNoteAreNotWritten() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let memory = try fixture.open()
        let (project, gone) = (UUID(), UUID())
        try await memory.forget(session: gone)
        _ = try await memory.apply(
            answer: answer(cited: [gone], notes: [update(project, [("Gone", [gone])])]), request: .brief(since: fixture.daysAgo(1)),
            pack: pack(read: [gone]), sessionProjects: [gone: project])
        #expect(await memory.journal(on: fixture.now).isEmpty)
        #expect(await memory.note(for: project) == nil)
    }

    @Test func aMemoryOpenedAfterTheDeletionIsToldAboutItAndACallThatNamesNothingStillWritesItsLine() async throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        let gone = UUID()
        let memory = try RemoraMemory(directory: fixture.directory, timeZone: fixture.zone, clock: { [fixture] in fixture.now }, forgotten: [gone])
        _ = try await memory.apply(answer: answer(cited: [gone], notes: []), request: .brief(since: fixture.daysAgo(1)), pack: pack(read: [gone]))
        #expect(await memory.journal(on: fixture.now).isEmpty)
        // A call that read and cited no session had none to lose: its line is written as before.
        _ = try await memory.apply(answer: answer(cited: [], notes: []), request: .brief(since: fixture.daysAgo(1)), pack: pack(read: []))
        #expect(await memory.journal(on: fixture.now).count == 1)
    }
}
