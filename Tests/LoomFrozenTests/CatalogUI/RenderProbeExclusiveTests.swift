import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

private typealias Log = RenderProbeExclusiveShared.Log

// The trait that keeps two tests from watching a render probe at once (RenderProbeExclusive.swift), and the scopes that
// keep a watching test from counting another suite's views (fix round 3, G).

private extension Log {
    func add(_ entry: String) { entries.append(entry) }
}

/// The counts a test reads take only what that test hosts, whatever else is alive in the process. A suite that hosts a
/// chat at the same time is stood in for by streams of other scopes (and of none) that are drawn while the test watches.
@MainActor @Suite(.serialized) struct RenderProbeScopeTests {
    @Test(.renderProbe) func aChatWatcherCountsOnlyTheStreamsOfItsScope() async {
        let mine = UUID().uuidString
        let own = ChatHostedStream(context: ChatRowContext(probeScope: mine))
        let someoneElse = ChatHostedStream(context: ChatRowContext(probeScope: UUID().uuidString))
        let nobody = ChatHostedStream()
        defer { own.controller.stop(); someoneElse.controller.stop(); nobody.controller.stop(); ChatRenderProbe.stop() }

        RenderProbeExclusive.watchChat(scope: mine)
        // Streams other suites make and draw while this test counts (their rows are never this test's).
        let lateElse = ChatHostedStream(context: ChatRowContext(probeScope: UUID().uuidString))
        let lateNobody = ChatHostedStream()
        defer { lateElse.controller.stop(); lateNobody.controller.stop() }
        #expect(ChatRenderProbe.controllersCreated == 0, "streams of other owners made: \(ChatRenderProbe.controllersCreated)")
        someoneElse.controller.apply(ChatHosted.ChatStreamTests.rows(100..<108), hasOlder: false)
        nobody.controller.apply(ChatHosted.ChatStreamTests.rows(200..<208), hasOlder: false)
        lateElse.controller.apply(ChatHosted.ChatStreamTests.rows(300..<308), hasOlder: false)
        let ownRows = ChatHosted.ChatStreamTests.rows(0..<4)
        own.controller.apply(ownRows, hasOlder: false)
        let late = ChatHostedStream(context: ChatRowContext(probeScope: mine))
        defer { late.controller.stop() }
        for stream in [someoneElse, nobody, lateElse, own, late] { await stream.settle(5) }

        #expect(ChatRenderProbe.controllersCreated == 1, "only the stream of this scope is counted: \(ChatRenderProbe.controllersCreated)")
        let ownIDs = Set(ownRows.map(\.id))
        #expect(!ChatRenderProbe.configured.isEmpty, "the test's own rows are counted")
        #expect(Set(ChatRenderProbe.configured.keys).isSubset(of: ownIDs), "rows of others: \(Set(ChatRenderProbe.configured.keys).subtracting(ownIDs).sorted())")
        #expect(Set(ChatRenderProbe.measuredRows.keys).isSubset(of: ownIDs), "rows of others measured: \(Set(ChatRenderProbe.measuredRows.keys).subtracting(ownIDs).sorted())")
    }

    /// The same ids on two owners (fixture uuids repeat across tests): only the watched owner's draws count.
    @Test(.renderProbe) func theSameRowIdsOfAnotherOwnerAreNotCounted() async {
        let mine = UUID().uuidString
        let rows = ChatHosted.ChatStreamTests.rows(0..<6)
        let own = ChatHostedStream(context: ChatRowContext(probeScope: mine))
        let other = ChatHostedStream(context: ChatRowContext(probeScope: UUID().uuidString))
        defer { own.controller.stop(); other.controller.stop(); ChatRenderProbe.stop() }
        RenderProbeExclusive.watchChat(scope: mine)
        other.controller.apply(rows, hasOlder: false)
        await other.settle(5)
        #expect(ChatRenderProbe.configured.isEmpty && ChatRenderProbe.measuredRows.isEmpty,
                "rows of another owner with the same ids: \(ChatRenderProbe.configured.keys.sorted())")
        own.controller.apply(rows, hasOlder: false)
        await own.settle(5)
        #expect(!ChatRenderProbe.configured.isEmpty)
        for id in ChatRenderProbe.configured.keys { #expect((ChatRenderProbe.configured[id] ?? 0) <= 2, "\(id) drawn \(ChatRenderProbe.configured[id] ?? 0) times") }
    }
}
