import AppKit
import Foundation
import Observation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// F5: list loads and refreshes keep Git file reads off the main thread and
/// write no observed property when nothing changed.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CatalogHotPathTests {
    /// Records which thread each branch read ran on.
    final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(path: String, onMain: Bool)] = []
        var count: Int { lock.withLock { entries.count } }
        var mainThreadReads: Int { lock.withLock { entries.filter(\.onMain).count } }
        func reader() -> @Sendable (String) -> GitBranch {
            { [self] path in
                lock.withLock { entries.append((path, Thread.isMainThread)) }
                return GitBranch.read(directory: path)
            }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    struct Fixture {
        let root: URL
        let repoA: URL
        let repoB: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let model: CatalogModel
        let log: ReadLog
    }

    private func makeRepo(_ root: URL, _ name: String, branch: String) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try setBranch(repo, branch)
        return repo
    }

    private func setBranch(_ repo: URL, _ branch: String) throws {
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
    }

    private func makeFixture(rows: Int = 6) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-hot-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repoA = try makeRepo(root, "repo-a", branch: "main")
        let repoB = try makeRepo(root, "repo-b", branch: "develop")
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        for index in 0..<rows {
            try await catalog.insertSession(
                ManagedSession(provider: .claude, workingDirectory: (index % 2 == 0 ? repoA : repoB).path),
                title: "\(index % 2 == 0 ? "Alpha" : "Beta") \(index)",
                createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle
            )
        }
        let hub = SessionEventHub()
        let model = CatalogModel(
            catalog: catalog, events: hub,
            preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        )
        let log = ReadLog()
        model.branchReader = log.reader()
        return Fixture(root: root, repoA: repoA, repoB: repoB, catalog: catalog, hub: hub, model: model, log: log)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.model.stop()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func waitUntil(_ seconds: TimeInterval = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    @Test func branchesAreReadOffTheMainThreadAndShownWithTheFirstPage() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        await fixture.model.start()
        // The branch is known as soon as the first page is: no "unavailable" flash.
        #expect(fixture.model.branches[fixture.repoA.path] == .named("main"))
        #expect(fixture.model.branches[fixture.repoB.path] == .named("develop"))
        #expect(fixture.log.count > 0)
        #expect(fixture.log.mainThreadReads == 0)
    }

    @Test func reloadsDoNotReadGitMetadataAgain() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        await fixture.model.start()
        let reads = fixture.log.count
        for _ in 0..<3 {
            fixture.model.scheduleRefresh()
            await fixture.model.settle()
        }
        // "a" matches both folders' rows: nothing is pruned, so nothing needs a read.
        fixture.model.setSearchText("a")
        await fixture.model.settle()
        fixture.model.setSearchText("")
        await fixture.model.settle()
        #expect(fixture.log.count == reads)
        #expect(fixture.log.mainThreadReads == 0)
    }

    @Test func equalValueRefreshWritesNoObservedProperty() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        await fixture.model.start()
        let model = fixture.model
        let list = model.list(for: .activity)
        let flag = Flag()
        withObservationTracking {
            _ = model.now
            _ = model.branches
            _ = model.projects
            _ = model.sessionCounts
            _ = list.rows
            _ = list.hasMore
        } onChange: { flag.raise() }
        fixture.model.scheduleRefresh()
        await fixture.model.settle()
        #expect(flag.isRaised == false)
    }

    @Test func aChangedBranchIsPublishedAtWindowActivationAndTurnCompletion() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        await model.start()
        await model.stopAndWait() // the test feeds frames itself

        // Window activation re-reads every known folder, in the background.
        try setBranch(fixture.repoA, "feature/one")
        model.setWindowActive(true)
        await model.settle()
        #expect(model.branches[fixture.repoA.path] == .named("feature/one"))
        #expect(model.branches[fixture.repoB.path] == .named("develop"))

        // A turn boundary re-reads the folder of that conversation only.
        let stream = await fixture.hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next())) // initial snapshot
        let betaID = try #require(model.list(for: .activity).rows.first { $0.record.session.workingDirectory == fixture.repoB.path }?.id)
        try setBranch(fixture.repoB, "feature/two")
        try setBranch(fixture.repoA, "feature/three")
        await fixture.hub.publish(sessionID: betaID, change: .status(ProviderWorkState(activity: .turnComplete)))
        model.apply(try #require(await iterator.next()))
        await model.settle()
        #expect(model.branches[fixture.repoB.path] == .named("feature/two"))
        #expect(model.branches[fixture.repoA.path] == .named("feature/one"))
        #expect(fixture.log.mainThreadReads == 0)
    }

    @Test func branchesOfRowsThatLeftTheListsArePruned() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        await model.start()
        #expect(Set(model.branches.keys) == [fixture.repoA.path, fixture.repoB.path])
        model.setSearchText("Alpha")
        await model.settle()
        #expect(await waitUntil { Set(model.branches.keys) == [fixture.repoA.path] })
    }

    /// Records the intents the model forwards.
    @MainActor final class IntentsStub: ConversationIntents {
        var viewedIDs: [UUID] = []
        func start(provider: ManagedSession.Provider, projectID: UUID?) {}
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) { viewedIDs.append(sessionID) }
        func terminalView(sessionID: UUID) -> NSView? { nil }
    }

    /// The runtime starts alongside the model now, so it can attach after the first page.
    @Test func aRuntimeThatAttachesAfterTheFirstPageStillCountsTheSelectionAsViewed() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        let selected = try #require(try await fixture.catalog.sessionPage(CatalogQuery()).sessions.first?.session.id)
        model.select(selected)
        model.setWindowActive(true)
        await model.start()
        let stub = IntentsStub()
        model.intents = stub
        #expect(stub.viewedIDs == [selected])
        await model.settle()
    }

    /// The first page is published before the runtime attaches; views that read
    /// `actionsAvailable` must be told when the attach makes the actions available.
    @Test func attachingTheRuntimeAfterStartNotifiesObserversOfActionsAvailable() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let model = fixture.model
        await model.start()
        #expect(model.actionsAvailable == false)
        let flag = Flag()
        withObservationTracking {
            _ = model.actionsAvailable
        } onChange: { flag.raise() }
        let stub = IntentsStub()
        model.intents = stub
        #expect(flag.isRaised)
        #expect(model.actionsAvailable)
        await model.settle()
    }
}
