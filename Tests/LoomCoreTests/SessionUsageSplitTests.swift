import Foundation
import Testing
@testable import LoomCore

/// The inspector's Usage block (RESCUE C2): a session's use, split by the transcript a row was read from. Its own file is the
/// main thread; `<session>/subagents/*.jsonl` are its subagents.
@Suite(.timeLimit(.minutes(1)))
struct SessionUsageSplitTests {
    @Test func aSubagentFilesUsageLandsInSubagentsAndTheMainFilesInMain() async throws {
        let fixture = try UsageFixture()
        try fixture.write([UsageLine(id: "m1", request: "r1", input: 100, output: 10, cacheRead: 1_000).json,
                           UsageLine(id: "m2", request: "r2", ts: "2026-10-05T10:01:00.000Z", input: 50, output: 5).json],
                          to: fixture.transcript())
        try fixture.write([UsageLine(id: "s1", request: "rs1", input: 7_000, output: 700, cw5: 300, sidechain: true).json],
                          to: fixture.subagent())
        // Another session's use stays out.
        try fixture.write([UsageLine(id: "o1", request: "ro1", session: "sess-2", input: 9).json],
                          to: fixture.transcript(session: "sess-2"))
        let index = fixture.makeIndex()
        try await index.refresh()

        let usage = try await index.sessionUsage(session: "sess-1")
        #expect(usage.main.tokens == UsageTokens(input: 150, output: 15, cacheRead: 1_000))
        #expect(usage.main.messageCount == 2)
        #expect(usage.subagents.tokens == UsageTokens(input: 7_000, output: 700, cacheWrite5m: 300))
        #expect(usage.subagents.messageCount == 1)
        #expect(usage.total.tokens.input == 7_150 && usage.total.messageCount == 3)
        #expect(usage.main.estimatedCostUSD.map { $0 > 0 } == true, "Haiku has a price: an API equivalent")

        // A subagent that starts later is found by the session's own refresh, without a walk of the profile.
        try fixture.write([UsageLine(id: "s2", request: "rs2", input: 1, output: 1, sidechain: true).json],
                          to: fixture.subagent(agent: "a2"))
        let refreshed = try await index.sessionUsage(session: "sess-1", refresh: true)
        #expect(refreshed.subagents.messageCount == 2 && refreshed.main.messageCount == 2)
        #expect(try await index.sessionUsage(session: "unknown").isEmpty)
    }
}
