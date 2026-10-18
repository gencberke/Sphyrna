import Foundation
import SQLite3
import Testing
@testable import LoomCore

/// The project page's week: what a project's sessions used in a range, read from the usage index's own
/// database with one indexed seek per session (no transcript, no scan).
@Suite struct ProjectUsageTests {
    private func usage(_ index: ClaudeUsageIndex, _ sessions: [String], range: UsageRange = .days(7)) async throws -> ProjectUsage {
        try await index.projectUsage(sessions: sessions, range: range, now: UsageFixture.now, timeZone: UsageFixture.utc)
    }

    /// Two projects' sessions in one profile: a and b belong to the project asked about, c does not.
    private func fixture() throws -> UsageFixture {
        let fixture = try UsageFixture()
        // a: two messages inside the week (Oct 1 to Oct 7) and one before it.
        try fixture.write([
            UsageLine(id: "a1", request: "ra1", session: "sess-a", ts: "2026-10-05T10:00:00.000Z", input: 10, output: 20).json,
            UsageLine(id: "a2", request: "ra2", session: "sess-a", ts: "2026-10-06T10:00:00.000Z", input: 100, output: 200, cacheRead: 1_000).json,
            UsageLine(id: "a0", request: "ra0", session: "sess-a", ts: "2026-09-20T10:00:00.000Z", input: 7_000, output: 7_000).json,
        ], to: fixture.transcript(project: "-tmp-p1", session: "sess-a"))
        try fixture.write([UsageLine(id: "b1", request: "rb1", session: "sess-b", ts: "2026-10-02T08:00:00.000Z", input: 3, output: 4).json],
                          to: fixture.transcript(project: "-tmp-p1", session: "sess-b"))
        try fixture.write([UsageLine(id: "c1", request: "rc1", session: "sess-c", ts: "2026-10-05T11:00:00.000Z", input: 50_000, output: 50_000).json],
                          to: fixture.transcript(project: "-tmp-p2", session: "sess-c"))
        return fixture
    }

    @Test func aProjectsWeekIsTheSumOfItsSessionsInsideTheRangeAndNothingElse() async throws {
        let fixture = try fixture()
        let index = fixture.makeIndex()
        try await index.refresh()
        let week = try await usage(index, ["sess-a", "sess-b"])
        #expect(week.tokens.input == 10 + 100 + 3)
        #expect(week.tokens.output == 20 + 200 + 4)
        #expect(week.tokens.cacheRead == 1_000)
        #expect(week.messageCount == 3)
        #expect(week.sessionCount == 2)
        // The older message of sess-a is outside the seven days; sess-c belongs to another project.
        let wide = try await usage(index, ["sess-a", "sess-b"], range: .all)
        #expect(wide.tokens.input == 10 + 100 + 3 + 7_000 && wide.messageCount == 4)
    }

    @Test func theAnswerEqualsTheSnapshotOfTheSameSessions() async throws {
        let fixture = try fixture()
        let index = fixture.makeIndex()
        try await index.refresh()
        let every = try await usage(index, ["sess-a", "sess-b", "sess-c"], range: .all)
        let snapshot = try await index.all()
        #expect(every.tokens == snapshot.tokens)
        #expect(every.messageCount == snapshot.messageCount && every.sessionCount == snapshot.sessionCount)
        #expect(every.estimatedCostUSD == snapshot.estimatedCostUSD)
        let week = try await usage(index, ["sess-a", "sess-b", "sess-c"])
        let weekSnapshot = try await index.snapshot(range: .days(7), now: UsageFixture.now, timeZone: UsageFixture.utc)
        #expect(week.tokens == weekSnapshot.tokens && week.estimatedCostUSD == weekSnapshot.estimatedCostUSD)
    }

    @Test func aSubagentsMessagesCountBecauseTheProjectPaidForThem() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(id: "m", request: "rm", ts: "2026-10-05T10:00:00.000Z", input: 5, output: 5).json],
                          to: fixture.transcript())
        try fixture.write([UsageLine(id: "s", request: "rs", ts: "2026-10-05T10:05:00.000Z", input: 40, output: 40, sidechain: true).json],
                          to: fixture.subagent())
        let index = fixture.makeIndex()
        try await index.refresh()
        let week = try await usage(index, ["sess-1"])
        #expect(week.tokens.input == 45 && week.messageCount == 2 && week.sessionCount == 1)
    }

    @Test func aModelWithoutAPriceMakesTheEstimateUnknownButKeepsTheTokens() async throws {
        let fixture = try UsageFixture()
        try fixture.write([
            UsageLine(id: "k", request: "rk", ts: "2026-10-05T10:00:00.000Z", input: 10, output: 10).json,
            UsageLine(id: "u", request: "ru", model: "some-future-model", ts: "2026-10-05T10:01:00.000Z", input: 90, output: 10).json,
        ], to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let week = try await usage(index, ["sess-1"])
        #expect(week.tokens.input == 100 && week.estimatedCostUSD == nil)
        let none = try await usage(index, [])
        #expect(none == .empty)
    }

    @Test func unknownDuplicateAndDifferentlyCasedIdsAreHandled() async throws {
        let fixture = try UsageFixture()
        let id = "0a1b2c3d-0000-4000-8000-00000000abcd"
        try fixture.write([UsageLine(session: id, ts: "2026-10-05T10:00:00.000Z", input: 12, output: 8).json], to: fixture.transcript(session: id))
        let index = fixture.makeIndex()
        try await index.refresh()
        let week = try await usage(index, [id.uppercased(), id, "never-seen"])
        #expect(week.tokens.input == 12 && week.sessionCount == 1 && week.messageCount == 1, "a session is counted once")
        #expect(try await usage(index, ["never-seen"]) == .empty)
    }

    @Test func aForgottenSessionIsNotCounted() async throws {
        let fixture = try fixture()
        let index = fixture.makeIndex()
        try await index.refresh()
        _ = try await index.forget(sessionIDs: ["sess-b"])
        let week = try await usage(index, ["sess-a", "sess-b"])
        #expect(week.sessionCount == 1 && week.tokens.input == 110)
    }

    @Test func atMostTheCapSessionsAreRead() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(id: "x", request: "rx", session: "sess-0", ts: "2026-10-05T10:00:00.000Z", input: 1, output: 1).json],
                          to: fixture.transcript(session: "sess-0"))
        let index = fixture.makeIndex()
        try await index.refresh()
        var ids = Array(repeating: "filler", count: ClaudeUsageIndex.maxProjectUsageSessions)
        ids.append("sess-0")
        let capped = try await usage(index, ids)
        #expect(capped.messageCount == 0, "the session after the cap is left out")
        #expect(try await usage(index, ["sess-0"]).messageCount == 1)
    }

    // MARK: no scan

    @Test func eachLookupIsAnIndexSeekNotATableScan() async throws {
        let fixture = try fixture()
        let index = fixture.makeIndex()
        try await index.refresh()
        _ = try await usage(index, ["sess-a"])
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(fixture.databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + UsageDatabase.sessionAggregatesSQL, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { details.append(String(cString: sqlite3_column_text(statement, 3))) }
        let plan = details.joined(separator: "; ")
        #expect(plan.contains("msg_session"), "\(plan)")
        #expect(!plan.contains("SCAN msg"), "\(plan)")
    }

    @Test func theLookupOpensNoTranscript() async throws {
        let fixture = try fixture()
        let index = fixture.makeIndex()
        try await index.refresh()
        // Without its transcripts the answer is the same: it comes from the index's database alone.
        try FileManager.default.removeItem(at: fixture.projects)
        let week = try await usage(index, ["sess-a", "sess-b"])
        #expect(week.messageCount == 3)
    }
}
