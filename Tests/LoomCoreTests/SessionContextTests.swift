import Foundation
import SQLite3
import Testing
@testable import LoomCore

/// The context ring's data: the latest main-thread message per session, read from the index's own
/// database, and the context figure and share made of it.
@Suite struct SessionContextTests {
    private func context(_ index: ClaudeUsageIndex, _ sessions: String...) async throws -> [String: SessionContextSample] {
        try await index.latestMainMessages(sessions: sessions)
    }

    // MARK: the latest main-thread message

    @Test func contextTokensAreInputPlusBothCacheClassesAndLeaveOutputAndSearches() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(input: 6, output: 900, cw5: 1_000, cw1: 250, cacheRead: 83_000, web: 3).json],
                          to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let sample = try #require(try await context(index, "sess-1")["sess-1"])
        #expect(sample.contextTokens == 6 + 1_000 + 250 + 83_000)
        #expect(sample.tokens.output == 900)
        #expect(sample.model == "claude-haiku-4-5-20251001")
        #expect(sample.timestamp == UsageFixture.date("2026-10-05T10:00:00.000Z"))
    }

    @Test func theLatestMessageWinsNotTheLargestOrTheLastWritten() async throws {
        let fixture = try UsageFixture()
        // Written out of order and with a bigger earlier message: only the timestamp decides.
        try fixture.write([
            UsageLine(id: "m3", request: "r3", ts: "2026-10-05T10:03:00.000Z", input: 3, cacheRead: 3_000).json,
            UsageLine(id: "m1", request: "r1", ts: "2026-10-05T10:01:00.000Z", input: 1, cacheRead: 90_000).json,
            UsageLine(id: "m2", request: "r2", ts: "2026-10-05T10:02:00.000Z", input: 2, cacheRead: 2_000).json,
        ], to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await context(index, "sess-1")["sess-1"]?.contextTokens == 3_003)
    }

    @Test func aSubagentsMessagesNeverCountAsTheSessionsContext() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(id: "main", request: "rm", ts: "2026-10-05T10:00:00.000Z", input: 5, cacheRead: 40_000).json],
                          to: fixture.transcript())
        // Newer and bigger, but it runs in the subagent's own context.
        try fixture.write([UsageLine(id: "sub", request: "rs", ts: "2026-10-05T10:09:00.000Z", input: 9, cacheRead: 150_000,
                                     sidechain: true).json], to: fixture.subagent())
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await context(index, "sess-1")["sess-1"]?.contextTokens == 40_005)
    }

    @Test func aSessionWithOnlySidechainMessagesAndAnUnknownSessionHaveNone() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(id: "sub", request: "rs", session: "sess-2", sidechain: true).json],
                          to: fixture.transcript(session: "sess-2"))
        let index = fixture.makeIndex()
        try await index.refresh()
        let found = try await context(index, "sess-2", "never-seen")
        #expect(found.isEmpty)
    }

    @Test func growthIsReadIncrementallyAndMovesTheContext() async throws {
        let fixture = try UsageFixture()
        let url = try fixture.write([UsageLine(id: "m1", request: "r1", ts: "2026-10-05T10:00:00.000Z", input: 1, cacheRead: 10_000).json],
                                    to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await context(index, "sess-1")["sess-1"]?.contextTokens == 10_001)
        try fixture.append([UsageLine(id: "m2", request: "r2", ts: "2026-10-05T10:05:00.000Z", input: 2, cacheRead: 12_000).json], to: url)
        let report = try await index.refresh(paths: [url])
        #expect(try await context(index, "sess-1")["sess-1"]?.contextTokens == 12_002)
        // Only the appended line was read, not the file again.
        #expect(report.recordsAccepted == 1)
    }

    @Test func aCompactedSessionShowsTheSmallerContextAgain() async throws {
        let fixture = try UsageFixture()
        try fixture.write([
            UsageLine(id: "m1", request: "r1", ts: "2026-10-05T10:00:00.000Z", cacheRead: 180_000).json,
            UsageLine(id: "m2", request: "r2", ts: "2026-10-05T10:10:00.000Z", cacheRead: 12_000).json,
        ], to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await context(index, "sess-1")["sess-1"]?.contextTokens == 12_010)
    }

    @Test func aForgottenSessionHasNoContext() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(cacheRead: 5_000).json], to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await context(index, "sess-1")["sess-1"] != nil)
        try await index.forget(sessionIDs: ["sess-1"])
        #expect(try await context(index, "sess-1").isEmpty)
    }

    @Test func aSessionIdInAnotherCaseFindsItsRows() async throws {
        let fixture = try UsageFixture()
        let id = "0a1b2c3d-0000-4000-8000-00000000abcd"
        try fixture.write([UsageLine(session: id, cacheRead: 5_000).json], to: fixture.transcript(session: id))
        let index = fixture.makeIndex()
        try await index.refresh()
        let found = try await context(index, id.uppercased())
        #expect(found[id.uppercased()]?.contextTokens == 5_010)
    }

    // MARK: no scan

    /// The ring asks for a handful of sessions on every refresh; each ask must be an index seek.
    private func plan(_ fixture: UsageFixture) throws -> String {
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(fixture.databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + UsageDatabase.latestMainMessageSQL, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { details.append(String(cString: sqlite3_column_text(statement, 3))) }
        return details.joined(separator: "; ")
    }

    @Test func theLookupIsAnIndexSeekNotATableScan() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine().json], to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        _ = try await context(index, "sess-1")
        let plan = try plan(fixture)
        #expect(plan.contains("msg_session_main"), "\(plan)")
        #expect(!plan.contains("SCAN"), "\(plan)")
    }

    @Test func anIndexFileFromBeforeTheLookupGetsItsIndexOnOpen() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(cacheRead: 7_000).json], to: fixture.transcript())
        let first = fixture.makeIndex()
        try await first.refresh()
        _ = try await context(first, "sess-1")

        // The file as schema 2 shipped it: no such index.
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(fixture.databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "DROP INDEX msg_session_main", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let reopened = fixture.makeIndex()
        #expect(try await context(reopened, "sess-1")["sess-1"]?.contextTokens == 7_010)
        let plan = try plan(fixture)
        #expect(plan.contains("msg_session_main"), "\(plan)")
    }

    @Test func ifTheIndexCannotBeCreatedUsageStillOpensAndContextIsSimplyAbsent() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(cacheRead: 7_000).json], to: fixture.transcript())
        let first = fixture.makeIndex()
        try await first.refresh()

        // A name clash makes `CREATE INDEX` fail on open (a full disk or a busy file fails it the same way).
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(fixture.databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "DROP INDEX msg_session_main; CREATE TABLE msg_session_main (x)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let reopened = fixture.makeIndex()
        #expect(try await reopened.all().messageCount == 1)               // usage itself still works
        #expect(try await context(reopened, "sess-1").isEmpty)             // no index: no context, and no scan
    }

    // MARK: ContextUsage

    @Test func aPercentageNeedsAKnownWindow() {
        let known = ContextUsage(tokens: 84_200, window: 200_000, model: "m")
        #expect(known.fraction == 0.421)
        #expect(known.percent == 42)
        let unknown = ContextUsage(tokens: 84_200, window: nil, model: "m")
        #expect(unknown.fraction == nil)
        #expect(unknown.percent == nil)
        // A window of zero or less is no window.
        #expect(ContextUsage(tokens: 10, window: 0, model: "m").fraction == nil)
        #expect(ContextUsage(tokens: 10, window: -5, model: "m").percent == nil)
    }

    @Test func theShareStaysInsideTheRingAtBothEnds() {
        #expect(ContextUsage(tokens: 0, window: 200_000, model: "m").percent == 0)
        #expect(ContextUsage(tokens: 250_000, window: 200_000, model: "m").fraction == 1)
        #expect(ContextUsage(tokens: -4, window: 200_000, model: "m").tokens == 0)
        #expect(ContextUsage(tokens: 199_999, window: 200_000, model: "m").percent == 100)
    }

    @Test func aUsageIsMadeOfASampleAndAWindow() {
        let sample = SessionContextSample(
            model: "claude-opus-5-5", timestamp: Date(timeIntervalSince1970: 0),
            tokens: UsageTokens(input: 4, output: 999, cacheWrite5m: 1, cacheWrite1h: 2, cacheRead: 93))
        let usage = ContextUsage(sample: sample, window: 1_000)
        #expect(usage.tokens == 100)
        #expect(usage.percent == 10)
        #expect(usage.model == "claude-opus-5-5")
    }
}
