import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

// The trait that keeps two tests from watching a render probe at once (RenderProbeExclusive.swift), and the scopes that
// keep a watching test from counting another suite's views (fix round 3, G).

@MainActor
private final class Log {
    var entries: [String] = []
}

@Suite struct RenderProbeExclusiveTests {
    /// Two holders of the lock never run their bodies side by side, whoever asks first.
    @Test @MainActor func twoHoldersNeverOverlap() async throws {
        let log = Log()
        async let first: Void = RenderProbeLock.shared.exclusive {
            await log.add("a in"); try? await Task.sleep(for: .milliseconds(150)); await log.add("a out")
        }
        async let second: Void = RenderProbeLock.shared.exclusive {
            await log.add("b in"); try? await Task.sleep(for: .milliseconds(150)); await log.add("b out")
        }
        _ = try await (first, second)
        #expect(log.entries == ["a in", "a out", "b in", "b out"] || log.entries == ["b in", "b out", "a in", "a out"],
                "\(log.entries)")
    }

    @Test(.renderProbe) func aTestWithTheTraitHoldsTheLock() {
        #expect(RenderProbeExclusive.isHeld)
    }

    @Test func aTestWithoutItDoesNot() {
        #expect(!RenderProbeExclusive.isHeld)
    }
}

private extension Log {
    func add(_ entry: String) { entries.append(entry) }
}

/// Two suites that each watch the probes for a while: they run side by side unless the trait keeps them apart, and then
/// the second one's `watch` would replace what the first one counts (all three probes are watched, one lock covers them).
@MainActor
private func watchesAloneFor(_ id: UUID) async throws {
    let scope = UUID().uuidString
    SidebarRenderProbe.watch([id])
    SidebarRenderProbe.card(id)
    RenderProbeExclusive.watchChat(scope: scope)
    RenderProbeExclusive.watchHeader([id])
    HeaderRenderProbe.row(id)
    try await Task.sleep(for: .milliseconds(400))
    #expect(SidebarRenderProbe.watched == [id], "another test replaced what this one watches")
    #expect(SidebarRenderProbe.cardBodies[id] == 1)
    #expect(ChatRenderProbe.watchedScope == scope, "another test replaced what this one watches on the Chat probe")
    #expect(HeaderRenderProbe.watched == [id], "another test replaced what this one watches on the Header probe")
    #expect(HeaderRenderProbe.rowBodies == 1)
    SidebarRenderProbe.watch([])
    ChatRenderProbe.stop()
    HeaderRenderProbe.watch([])
}

@MainActor @Suite struct RenderProbeFirstWatcherTests {
    @Test(.renderProbe) func watchesAlone() async throws { try await watchesAloneFor(UUID()) }
}

@MainActor @Suite struct RenderProbeSecondWatcherTests {
    @Test(.renderProbe) func watchesAlone() async throws { try await watchesAloneFor(UUID()) }
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

    /// The totals that are not per session count the watched model and the watched sessions only.
    @Test(.renderProbe) func theSidebarTotalsCountOnlyTheWatchedModelAndSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-probe-scope-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func model(_ name: String) throws -> CatalogModel {
            CatalogModel(catalog: try SessionCatalog(url: root.appendingPathComponent("\(name).sqlite3")), events: SessionEventHub(),
                         preferences: UIPreferencesStore(url: root.appendingPathComponent("\(name).json")))
        }
        let mine = try model("mine"), other = try model("other")
        let session = UUID()
        defer { SidebarRenderProbe.watch([]) }
        #expect(RenderProbeExclusive.isHeld)
        SidebarRenderProbe.watch([session], model: mine)

        SidebarRenderProbe.projectList(of: other)
        SidebarRenderProbe.draftRow("draft", of: other)
        SidebarRenderProbe.appeared("resume", session: UUID())
        #expect(SidebarRenderProbe.projectListBodies == 0 && SidebarRenderProbe.draftRowBodies.isEmpty && SidebarRenderProbe.onScreen.isEmpty,
                "another model or session was counted")

        SidebarRenderProbe.projectList(of: mine)
        SidebarRenderProbe.draftRow("draft", of: mine)
        SidebarRenderProbe.appeared("resume", session: session)
        #expect(SidebarRenderProbe.projectListBodies == 1 && SidebarRenderProbe.draftRowBodies["draft"] == 1 && SidebarRenderProbe.onScreen["resume"] == 1)
    }
}
