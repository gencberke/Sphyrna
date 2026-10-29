import AppKit
import Foundation
import Observation
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

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

// MARK: One row patched instead of every list re-read, one search query instead of one per list

extension CatalogHotPathTests {
    private func delta(_ model: CatalogModel, since base: CatalogModelStatistics)
        -> (queries: Int, reloads: Int, patches: Int, searches: Int) {
        let now = model.statistics
        return (now.pageQueries - base.pageQueries, now.listReloads - base.listReloads,
                now.rowPatches - base.rowPatches, now.searchQueries - base.searchQueries)
    }

    // MARK: Item 2

    /// Before: every run frame of a known session re-read all five visible lists (4 projects and the
    /// sessions without a project); now it reads that one session.
    @Test func aRunFrameOfOneSessionInTheProjectViewReadsThatRowAndRereadsNoList() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 12, unassigned: 3, mode: .projects)
        defer { rig.cleanup() }
        let model = rig.model
        #expect(model.visibleListKeys().count == 5)
        let target = try #require(rig.ids[rig.projects[2].id]?[5])
        let before = rig.shape()

        // The runtime resumed the session: the catalog row moved first, then the frame came.
        let run = UUID()
        try await rig.catalog.markUsed(sessionID: target, at: Date(timeIntervalSince1970: 9_000_000), reactivate: true)
        let base = model.statistics
        try await rig.feed(.runStarted(run), for: target)
        await model.settle()
        let started = delta(model, since: base)
        #expect(started.reloads == 0, "list reloads for a run start: \(started.reloads)")
        #expect(started.queries == 1, "queries for a run start: \(started.queries)")
        #expect(started.patches == 1)
        let afterStart = rig.shape()
        #expect(afterStart != before, "the card took the new record")
        #expect(afterStart[.project(rig.projects[2].id)]?.ids == before[.project(rig.projects[2].id)]?.ids)

        // The run ends and the session goes idle again.
        try await rig.catalog.updateLifecycle(sessionID: target, lifecycle: .idle)
        let mid = model.statistics
        try await rig.feed(.runEnded(run, .processExited), for: target)
        await model.settle()
        let ended = delta(model, since: mid)
        #expect(ended.reloads == 0, "list reloads for a run end: \(ended.reloads)")
        #expect(ended.queries == 1, "queries for a run end: \(ended.queries)")

        // The same rows in the same order, with the same records, as after a full re-read.
        let patched = rig.shape()
        #expect(await rig.fullReload() == patched)
    }

    /// Before: an activity stamp (a prompt, a finished turn) re-read the list from the top, one query per loaded page.
    @Test func anActivityStampMovesOneRowToTheTopOfTheActivityViewWithOneRead() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 80, unassigned: 3, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let list = model.list(for: .activity)
        for loaded in [200, 300] {
            model.loadMore(.activity)
            #expect(await waitUntil { list.rows.count == loaded })
        }
        await model.settle()
        #expect(list.rows.count == 300 && list.hasMore)
        let target = list.rows[250].id

        try await rig.catalog.markActivity(sessionID: target, at: Date(timeIntervalSince1970: 9_000_000))
        let base = model.statistics
        try await rig.feedActivity(for: target)
        await model.settle()
        let counts = delta(model, since: base)
        #expect(counts.reloads == 0, "list reloads for an activity stamp: \(counts.reloads)")
        #expect(counts.queries == 1, "queries for an activity stamp over 300 loaded rows: \(counts.queries)")
        #expect(list.rows.first?.id == target)
        #expect(list.rows.count == 300 && list.hasMore)
        #expect(list.rows.first?.record.lastActivityAt == Date(timeIntervalSince1970: 9_000_000))

        let patched = rig.shape()
        #expect(await rig.fullReload() == patched)
    }

    @Test func aRowThatFallsPastTheLoadedRangeIsDroppedAndPagingStillDeliversItOnce() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 40, unassigned: 3, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let list = model.list(for: .activity)
        let last = try #require(list.rows.last?.id)

        try await rig.catalog.markActivity(sessionID: last, at: Date(timeIntervalSince1970: 1))
        let base = model.statistics
        try await rig.feedActivity(for: last)
        await model.settle()
        let counts = delta(model, since: base)
        #expect(counts.reloads == 0 && counts.queries == 1)
        #expect(list.rows.count == 99 && !list.rows.contains { $0.id == last })
        #expect(list.hasMore)

        // Paging reads on from where the list ended: every session once, in the catalog's order.
        for _ in 0..<4 {
            model.loadMore(.activity)
            _ = await waitUntil(2) { !list.hasMore }
        }
        await model.settle()
        let fresh = try await rig.catalog.sessionPage(CatalogQuery(limit: 100))
        var order = fresh.sessions.map(\.session.id)
        var cursor = fresh.next
        while let next = cursor {
            let page = try await rig.catalog.sessionPage(CatalogQuery(limit: 100), after: next)
            order += page.sessions.map(\.session.id)
            cursor = page.next
        }
        #expect(list.rows.map(\.id) == order)
        #expect(Set(list.rows.map(\.id)).count == rig.everyID.count)
        #expect(list.rows.last?.id == last)
    }

    @Test func frameChangesThatAreNotOneKnownRowStillReloadTheLists() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 40, unassigned: 3, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let list = model.list(for: .activity)

        // A session the lists do not hold (past the first page) that took activity: its place needs a read of the list.
        let unloaded = try #require(rig.everyID.first { id in !list.rows.contains { $0.id == id } })
        try await rig.catalog.markActivity(sessionID: unloaded, at: Date(timeIntervalSince1970: 9_000_000))
        var base = model.statistics
        try await rig.feedActivity(for: unloaded)
        await model.settle()
        #expect(delta(model, since: base).reloads >= 1)
        #expect(list.rows.first?.id == unloaded)

        // A batched lifecycle change (aging) carries no row.
        let aged = list.rows[3].id
        try await rig.catalog.updateLifecycle(sessionID: aged, lifecycle: .stale)
        base = model.statistics
        await rig.hub.publishCatalogLifecycle(.stale, ids: [aged])
        try await rig.applyNextFrame()
        await model.settle()
        #expect(delta(model, since: base).reloads >= 1)
        #expect(list.rows.first { $0.id == aged }?.record.lifecycle == .stale)

        // A skipped frame: the sequence is not contiguous, so the one frame cannot be trusted to be the only change.
        let skipped = list.rows[5].id
        let applied = list.rows[6].id
        try await rig.catalog.markActivity(sessionID: skipped, at: Date(timeIntervalSince1970: 9_100_000))
        await rig.hub.publishActivity(sessionID: skipped)
        try await rig.catalog.markActivity(sessionID: applied, at: Date(timeIntervalSince1970: 9_200_000))
        await rig.hub.publishActivity(sessionID: applied)
        try await rig.applyNextFrame() // the stream keeps the newest frame only
        await model.settle()
        #expect(list.rows.prefix(2).map(\.id) == [applied, skipped])
    }

    @Test func aFrameDuringASearchReadsOnceForTheWholeResultAndKeepsTheResults() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 12, unassigned: 3, mode: .projects)
        defer { rig.cleanup() }
        let model = rig.model
        model.setSearchText("alpha")
        await model.settle()
        let target = try #require(model.list(for: .project(rig.projects[1].id)).rows.first?.id)
        let before = rig.shape()
        let base = model.statistics
        try await rig.feed(.runStarted(UUID()), for: target)
        await model.settle()
        let counts = delta(model, since: base)
        #expect(counts.queries == 1, "queries for a frame during a search: \(counts.queries)")
        #expect(counts.reloads == 0)
        #expect(rig.shape() == before)
    }

    // MARK: Item 3

    /// The old per-list reads, for comparison: one `sessionPage` per visible list.
    private func perListResults(_ rig: ListRig, search: String) async throws -> [CatalogListKey: [UUID]] {
        var result: [CatalogListKey: [UUID]] = [:]
        for key in rig.model.visibleListKeys() {
            let query: CatalogQuery
            switch key {
            case .activity: query = CatalogQuery(scope: .all, order: .recentActivity, search: search)
            case let .project(id): query = CatalogQuery(scope: .project(id), order: .creation, search: search)
            case .unassigned: query = CatalogQuery(scope: .unassigned, order: .creation, search: search)
            }
            result[key] = try await rig.catalog.sessionPage(query).sessions.map(\.session.id)
        }
        return result
    }

    /// Before: one query per visible list (six projects, one of them collapsed, and the unassigned list: 7);
    /// now one for the settled search.
    @Test func aSettledSearchRunsOneQueryForEveryList() async throws {
        let rig = try await ListRig.make(projects: 6, perProject: 12, unassigned: 3, mode: .projects, collapsedProjects: 1)
        defer { rig.cleanup() }
        let model = rig.model
        let base = model.statistics
        for text in ["a", "al", "alp", "alph", "alpha"] { model.setSearchText(text) }
        await model.settle()
        let counts = delta(model, since: base)
        #expect(counts.queries == 1, "queries for one settled search over 7 lists: \(counts.queries)")
        #expect(counts.reloads == 0)
        #expect(counts.searches == 1)

        // The same lists, rows and order the per-list queries gave (the collapsed project is searched too).
        let expected = try await perListResults(rig, search: "alpha")
        #expect(Set(model.visibleListKeys()) == Set(expected.keys) && expected.count == 7)
        for (key, ids) in expected {
            #expect(model.list(for: key).rows.map(\.id) == ids, "\(key)")
        }
        #expect(expected.values.contains { !$0.isEmpty })
    }

    @Test func theActivityViewGroupsTheSearchInActivityOrderWithOneQuery() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 40, unassigned: 3, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let base = model.statistics
        model.setSearchText("beta")
        await model.settle()
        #expect(delta(model, since: base).queries == 1)
        let expected = try await perListResults(rig, search: "beta")
        let list = model.list(for: .activity)
        #expect(list.rows.map(\.id) == expected[.activity])
        #expect(list.rows.count == 100 && list.hasMore)
        // Paging continues from the search result.
        for _ in 0..<4 {
            model.loadMore(.activity)
            _ = await waitUntil(2) { !list.hasMore }
        }
        await model.settle()
        let all = try await rig.catalog.sessionPage(CatalogQuery(search: "beta", limit: 100))
        var order = all.sessions.map(\.session.id)
        var cursor = all.next
        while let next = cursor {
            let page = try await rig.catalog.sessionPage(CatalogQuery(search: "beta", limit: 100), after: next)
            order += page.sessions.map(\.session.id)
            cursor = page.next
        }
        #expect(list.rows.map(\.id) == order)
    }

    @Test func aProjectWithMoreThanOnePageOfMatchesKeepsItsPagingAndNoProjectIsCrowdedOut() async throws {
        let rig = try await ListRig.make(projects: 3, perProject: 130, unassigned: 3, mode: .projects)
        defer { rig.cleanup() }
        let model = rig.model
        model.setSearchText("p1")
        await model.settle()
        let busy = model.list(for: .project(rig.projects[1].id))
        #expect(busy.rows.count == 100 && busy.hasMore)
        #expect(model.list(for: .project(rig.projects[0].id)).rows.isEmpty)
        let expected = try await perListResults(rig, search: "p1")
        #expect(busy.rows.map(\.id) == expected[.project(rig.projects[1].id)])
        model.loadMore(.project(rig.projects[1].id))
        #expect(await waitUntil { busy.rows.count == 130 })
        #expect(busy.hasMore == false)
        #expect(Set(busy.rows.map(\.id)) == Set(rig.ids[rig.projects[1].id] ?? []))
    }

    @Test func searchMatchesTheSameFieldsFoldingAndEscapesAsBefore() async throws {
        let rig = try await ListRig.make(projects: 3, perProject: 6, unassigned: 2, mode: .projects)
        defer { rig.cleanup() }
        let model = rig.model
        let special = try #require(rig.ids[rig.projects[0].id]?.first)
        try await rig.catalog.renameSession(sessionID: special, to: "100%_done İstanbul")
        for term in ["100%", "%_d", "istanbul", "İSTANBUL", "claude", "CODEX", "project-1", "p2 n3", "no such thing", "alpha beta"] {
            model.setSearchText(term)
            await model.settle()
            let expected = try await perListResults(rig, search: term)
            for (key, ids) in expected {
                #expect(model.list(for: key).rows.map(\.id) == ids, "term \(term), \(key)")
            }
        }
    }

    @Test func clearingTheSearchRestoresTheNormalLists() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 12, unassigned: 3, mode: .projects)
        defer { rig.cleanup() }
        let model = rig.model
        let before = rig.shape()
        model.setSearchText("alpha")
        await model.settle()
        #expect(rig.shape() != before)
        model.setSearchText("")
        await model.settle()
        #expect(rig.shape() == before)
    }

    @Test func anOlderSearchResultNeverReplacesANewerOne() async throws {
        let rig = try await ListRig.make(projects: 4, perProject: 12, unassigned: 3, mode: .projects)
        defer { rig.cleanup() }
        let model = rig.model
        let gate = Gate()
        let calls = Counter()
        model.afterSearchRead = {
            // Only the first read (for "alpha") is held back until the newer search has landed.
            if calls.next() == 1 { await gate.wait() }
        }
        model.setSearchText("alpha")
        #expect(await waitUntil { calls.value == 1 })
        model.setSearchText("beta")
        #expect(await waitUntil { calls.value >= 2 })
        #expect(await waitUntil { model.list(for: .project(rig.projects[0].id)).rows.allSatisfy { $0.record.title?.hasPrefix("Beta") == true } })
        let newer = rig.shape()
        gate.open()
        try await Task.sleep(for: .milliseconds(200))
        await model.settle()
        #expect(rig.shape() == newer)
        #expect(newer.values.flatMap(\.records).allSatisfy { $0.title?.hasPrefix("Beta") == true })
    }

    // MARK: Item 4 (the model side; the redraw counts are in `SidebarRenderTests`)

    @Test func theSelectedFlagFollowsTheSelectionThroughReloadsAndRestarts() async throws {
        let rig = try await ListRig.make(projects: 2, perProject: 6, unassigned: 2, mode: .projects)
        defer { rig.cleanup() }
        let model = rig.model
        let first = try #require(rig.ids[rig.projects[0].id]?[1])
        let second = try #require(rig.ids[rig.projects[1].id]?[2])
        func selectedIDs() -> [UUID] {
            model.visibleListKeys().flatMap { model.list(for: $0).rows }.filter(\.isSelected).map(\.id)
        }
        #expect(selectedIDs().isEmpty)
        model.select(first)
        #expect(selectedIDs() == [first])
        model.select(second)
        #expect(selectedIDs() == [second])
        _ = await rig.fullReload()
        #expect(selectedIDs() == [second])
        model.select(nil)
        #expect(selectedIDs().isEmpty)

        // A row read after the selection was made (a restart, a tab) starts selected.
        model.select(first)
        model.flushPreferences()
        let reopened = CatalogModel(catalog: rig.catalog, events: SessionEventHub(),
                                    preferences: UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json")))
        reopened.branchReader = { _ in .unavailable }
        await reopened.start()
        defer { reopened.stop() }
        let rows = reopened.visibleListKeys().flatMap { reopened.list(for: $0).rows }
        #expect(rows.filter(\.isSelected).map(\.id) == [first])
        #expect(reopened.selectedRow?.isSelected == true)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// Holds a caller until opened; unlike a sleep it keeps waiting when the caller's task is cancelled.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if opened { return true }
                    waiting = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        func open() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                opened = true
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }
}

// MARK: The Active section moves with frames, not with list reads (FB4-2)

extension CatalogHotPathTests {
    private static let working = SessionEventChange.status(ProviderWorkState(activity: .working))

    /// Starts a run and a turn for `id`, the way the runtime's frames arrive.
    @discardableResult
    private func startTurn(_ rig: ListRig, _ id: UUID) async throws -> UUID {
        let run = UUID()
        try await rig.feed(.runStarted(run), for: id)
        try await rig.feed(Self.working, for: id)
        await rig.model.settle() // the run frame patched the card's catalog row
        return run
    }

    /// The turn finishes while nobody looks, and the user reads the end with "Mark as Read".
    private func readTheEnd(_ rig: ListRig, _ id: UUID) async throws {
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete)), for: id)
        try await markRead(rig, id)
    }

    /// "Mark as Read" the way the card menu does it: the hub publishes the change and the model applies its frame.
    private func markRead(_ rig: ListRig, _ id: UUID) async throws {
        rig.model.markRead(id)
        await rig.model.settle()
        try await rig.applyNextFrame()
    }

    private func request(from id: UUID, phase: OpenSessionRequest.Phase = .waiting) -> OpenSessionRequest {
        OpenSessionRequest(requesterID: id, projectID: UUID(), projectName: "p", title: "Open", message: "m", phase: phase)
    }

    @Test func framesMoveARowIntoAndOutOfActiveWithoutListReloadsOrRowPatches() async throws {
        let rig = try await ListRig.make(projects: 2, perProject: 6, unassigned: 2, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let list = model.list(for: .activity)
        let order = list.rows.map(\.id)
        let target = order[5]

        try await rig.feed(.runStarted(UUID()), for: target)
        await model.settle()
        #expect(model.activeIDs.isEmpty, "a started run is not active before a turn runs")
        #expect(model.activityLayout().active.isEmpty)
        #expect(model.activityLayout().days.flatMap(\.rows).map(\.id) == order)

        // The turn starts: one flip, no list read, no row patch.
        var base = model.statistics
        var revision = model.activeRevision
        try await rig.feed(Self.working, for: target)
        await model.settle()
        #expect(model.activeIDs == [target] && model.activeRevision == revision + 1)
        #expect(model.activityLayout().active.map(\.id) == [target])
        #expect(model.activityLayout().days.flatMap(\.rows).map(\.id) == order.filter { $0 != target })
        #expect(list.rows.map(\.id) == order, "the list itself does not move")
        var counts = delta(model, since: base)
        #expect(counts.reloads == 0 && counts.queries == 0 && counts.patches == 0,
                "reloads \(counts.reloads), queries \(counts.queries), patches \(counts.patches)")

        // Frames that flip nothing leave the set and its revision alone: more state, a question, the finish unseen.
        revision = model.activeRevision
        base = model.statistics
        try await rig.feed(.blockers([.ambiguousIdentity]), for: target)
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForInput)), for: target)
        try await rig.feed(Self.working, for: target)
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete, pendingProviderWorkCount: 1)), for: target)
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete)), for: target)
        await model.settle()
        #expect(model.activeIDs == [target] && model.activeRevision == revision, "the finish nobody saw stays in")
        counts = delta(model, since: base)
        #expect(counts.reloads == 0 && counts.queries == 0 && counts.patches == 0)

        // Read: it leaves, again without a read of the catalog.
        try await markRead(rig, target)
        #expect(model.activeIDs.isEmpty && model.activeRevision == revision + 1)
        #expect(model.activityLayout().active.isEmpty)
        #expect(model.activityLayout().days.flatMap(\.rows).map(\.id) == order)
        counts = delta(model, since: base)
        #expect(counts.reloads == 0 && counts.queries == 0 && counts.patches == 0)
    }

    @Test func aSelectedActiveSessionStaysUntilAnotherIsSelectedAndAnEndedRunDropsIt() async throws {
        let rig = try await ListRig.make(projects: 2, perProject: 6, unassigned: 2, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let order = model.list(for: .activity).rows.map(\.id)
        let (first, second, third) = (order[2], order[7], order[9])

        // Active when selected, then read: the card does not jump under the cursor.
        try await startTurn(rig, first)
        model.select(first, revealInList: false)
        try await readTheEnd(rig, first)
        #expect(model.activeIDs == [first], "read and selected: still displayed")
        #expect(model.activityLayout().active.map(\.id) == [first])

        // A session that becomes active while selected is held too.
        model.select(second, revealInList: false)
        #expect(model.activeIDs.isEmpty, "selecting another session drops the read one")
        try await startTurn(rig, second)
        try await readTheEnd(rig, second)
        #expect(model.activeIDs == [second])
        model.select(nil)
        #expect(model.activeIDs.isEmpty, "dropped when nothing is selected")

        // Selecting an active session holds it; selecting another one that is active releases only the first.
        try await startTurn(rig, first)
        try await startTurn(rig, third)
        model.select(first, revealInList: false)
        try await readTheEnd(rig, first)
        model.select(third, revealInList: false)
        #expect(model.activeIDs == [third])

        // A held session whose run ended is out: the section lists running sessions.
        let run = try await startTurn(rig, second)
        model.select(second, revealInList: false)
        try await readTheEnd(rig, second)
        #expect(model.activeIDs == [second, third], "third is still under way; second is held")
        try await rig.feed(.runEnded(run, .processExited), for: second)
        await model.settle()
        #expect(model.activeIDs == [third])
    }

    @Test func aSessionAwaitingAnOpenSessionAnswerIsActiveOnlyWhileItsRunLives() async throws {
        let rig = try await ListRig.make(projects: 2, perProject: 6, unassigned: 2, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let order = model.list(for: .activity).rows.map(\.id)
        let (asking, idle) = (order[3], order[8])
        try await rig.feed(.runStarted(UUID()), for: asking)
        await model.settle()
        #expect(model.activeIDs.isEmpty)

        let revision = model.activeRevision
        model.setOpenRequests([request(from: asking), request(from: idle)])
        #expect(model.activeIDs == [asking], "a request of a session with no run asks nothing of the user")
        #expect(model.activeRevision == revision + 1)
        #expect(model.activityLayout().active.map(\.id) == [asking])

        // The answer was given (starting): the card goes back.
        model.setOpenRequests([request(from: asking, phase: .starting)])
        #expect(model.activeIDs.isEmpty)
        model.setOpenRequests([request(from: asking)])
        #expect(model.activeIDs == [asking])
        model.setOpenRequests([])
        #expect(model.activeIDs.isEmpty)
    }

    @Test func searchHidesTheActiveSectionAndLeavesTheResultAsItIs() async throws {
        let rig = try await ListRig.make(projects: 2, perProject: 6, unassigned: 2, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let list = model.list(for: .activity)
        let target = list.rows[4].id
        try await startTurn(rig, target)
        #expect(model.activityLayout().active.map(\.id) == [target])

        model.setSearchText("Alpha")
        await model.settle()
        #expect(model.isSearching && !list.rows.isEmpty)
        let layout = model.activityLayout()
        #expect(layout.active.isEmpty, "no Active section while searching")
        #expect(layout.days.flatMap(\.rows).map(\.id) == list.rows.map(\.id), "the result as the day sections draw it")
        #expect(model.visibleSessionIDs() == list.rows.map(\.id))
        #expect(model.activeIDs == [target], "membership itself is kept")

        model.setSearchText("")
        await model.settle()
        #expect(model.activityLayout().active.map(\.id) == [target])
    }

    @Test func nextAndPreviousSessionWalkTheActiveRowsFirstAndThenTheDays() async throws {
        let rig = try await ListRig.make(projects: 2, perProject: 6, unassigned: 2, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let order = model.list(for: .activity).rows.map(\.id)
        // Two active sessions that sit in the middle of the list; the drawn order lists them first, newest first.
        let (late, early) = (order[6], order[3])
        try await startTurn(rig, late)
        try await startTurn(rig, early)
        let drawn = [early, late] + order.filter { $0 != early && $0 != late }
        #expect(model.visibleSessionIDs() == drawn)
        #expect(model.activityLayout().rowIDs == drawn)

        model.select(late, revealInList: false)
        #expect(model.adjacentSession(.previous) == early)
        #expect(model.adjacentSession(.next) == drawn[2], "after the Active rows comes the first day row")
        model.select(drawn[2], revealInList: false)
        #expect(model.adjacentSession(.previous) == late)
        #expect(model.selectAdjacentSession(.next))
        #expect(model.selectedSessionID == drawn[3])
    }

    @Test func pagingStartsFromTheLastDrawnRowEvenWhenTheListsLastRowIsActive() async throws {
        let rig = try await ListRig.make(projects: 3, perProject: 40, unassigned: 3, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let list = model.list(for: .activity)
        #expect(list.rows.count == 100 && list.hasMore)
        let tail = try #require(list.rows.last?.id)
        #expect(model.activityLayout().lastRowID == tail)

        try await startTurn(rig, tail)
        let layout = model.activityLayout()
        #expect(layout.active.map(\.id) == [tail])
        #expect(layout.lastRowID == list.rows[98].id, "the list's last row is drawn at the top, not at the bottom")
        #expect(layout.lastRowID != tail)

        // Everything loaded is active: the last Active row is the last drawn one.
        for row in list.rows.dropLast() {
            try await rig.feed(.runStarted(UUID()), for: row.id)
            try await rig.feed(Self.working, for: row.id)
        }
        await model.settle()
        let all = model.activityLayout()
        #expect(all.days.isEmpty && all.active.count == 100)
        #expect(all.lastRowID == all.active.last?.id)
    }
}
