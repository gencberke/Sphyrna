import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

private typealias Log = RenderProbeExclusiveShared.Log

// The trait that keeps two tests from watching a render probe at once (RenderProbeExclusive.swift), and the scopes that
// keep a watching test from counting another suite's views (fix round 3, G).

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
