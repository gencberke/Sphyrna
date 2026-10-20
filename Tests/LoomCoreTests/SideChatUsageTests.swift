import Foundation
import Testing
@testable import LoomCore

/// V22 part 2: a fork's transcript starts with a copy of its parent's records (same message ids, new session id). The usage index
/// counts a message once; the copy must never take it from the parent, whichever file is read first, so that forgetting a side
/// chat (discarding it) never unlinks the parent's messages from the parent.
@Suite struct SideChatUsageTests {
    private func line(_ id: String, session: String, output: Int = 20) -> String {
        UsageLine(id: id, request: "req_\(id)", session: session, output: output).json
    }

    /// The parent holds `msg_a` and `msg_b`; the side chat's file copies both and has `msg_own` of its own.
    private func files(_ fixture: UsageFixture) throws -> (parent: URL, side: URL) {
        let parent = try fixture.write([line("msg_a", session: "parent-1"), line("msg_b", session: "parent-1")],
                                       to: fixture.transcript(session: "parent-1"))
        let side = try fixture.write([line("msg_a", session: "side-1"), line("msg_b", session: "side-1"),
                                      line("msg_own", session: "side-1")], to: fixture.transcript(session: "side-1"))
        return (parent, side)
    }

    private func check(_ index: ClaudeUsageIndex) async throws {
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 3, "a copied message counts once")
        #expect(snapshot.tokens.input == 30)
        #expect(snapshot.sessionCount == 2)
        // Discarding the side chat drops only its own message's link: the copies stay the parent's.
        let unlinked = try await index.forget(sessionIDs: ["side-1"])
        #expect(unlinked == 1)
        let after = try await index.all()
        #expect(after.messageCount == 3, "forgetting keeps the tokens")
        #expect(after.sessionCount == 1, "the parent is still linked to its messages")
    }

    @Test func aCopyReadBeforeTheParentsOwnRecordsStaysTheParents() async throws {
        let fixture = try UsageFixture()
        let (_, side) = try files(fixture)
        let index = fixture.makeIndex(sideChats: { ["side-1"] })
        try await index.refresh(paths: [side])
        try await index.refresh()
        try await check(index)
    }

    @Test func aCopyReadAfterTheParentsOwnRecordsStaysTheParents() async throws {
        let fixture = try UsageFixture()
        let (parent, _) = try files(fixture)
        let index = fixture.makeIndex(sideChats: { ["SIDE-1"] })
        try await index.refresh(paths: [parent])
        try await index.refresh()
        try await check(index)
    }

    @Test func aCopyWithLargerTotalsDoesNotTakeAMessageEither() async throws {
        let fixture = try UsageFixture()
        let parent = try fixture.write([line("msg_a", session: "parent-1")], to: fixture.transcript(session: "parent-1"))
        let side = try fixture.write([line("msg_a", session: "side-1", output: 99)], to: fixture.transcript(session: "side-1"))
        let index = fixture.makeIndex(sideChats: { ["side-1"] })
        try await index.refresh(paths: [parent])
        try await index.refresh(paths: [side])
        let snapshot = try await index.all()
        #expect(snapshot.tokens.output == 20, "the parent's record stays")
        #expect(try await index.forget(sessionIDs: ["side-1"]) == 0)
        #expect(try await index.all().sessionCount == 1)
    }

    @Test func theIdsAreAskedAtEveryRefreshSoANewSideChatIsKnownBeforeItsFileIsRead() async throws {
        let fixture = try UsageFixture()
        let (parent, side) = try files(fixture)
        let known = Box()
        let index = fixture.makeIndex(sideChats: { await known.ids })
        try await index.refresh(paths: [parent])
        await known.set(["side-1"])
        try await index.refresh()
        _ = side
        try await check(index)
    }

    @Test func aSessionThatIsNotASideChatKeepsTheOrdinaryRules() async throws {
        let fixture = try UsageFixture()
        let first = try fixture.write([line("msg_a", session: "one", output: 10)], to: fixture.transcript(session: "one"))
        let second = try fixture.write([line("msg_a", session: "two", output: 40)], to: fixture.transcript(session: "two"))
        let index = fixture.makeIndex(sideChats: { ["some-side-chat"] })
        try await index.refresh(paths: [first])
        try await index.refresh(paths: [second])
        let snapshot = try await index.all()
        #expect(snapshot.tokens.output == 40, "the larger streaming copy still wins between ordinary sessions")
    }
}

private actor Box {
    var ids: Set<String> = []
    func set(_ new: Set<String>) { ids = new }
}
