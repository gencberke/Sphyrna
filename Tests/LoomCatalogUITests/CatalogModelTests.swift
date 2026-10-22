import Foundation
import SQLite3
import Testing
import LoomCore
@testable import LoomCatalogUI

/// CP5 B2/B3/B5 at the presentation boundary: real catalog, real event hub,
/// real supervisor. Nothing here launches a provider or a PTY.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CatalogModelTests {
    struct Fixture {
        let root: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let preferences: UIPreferencesStore
        let model: CatalogModel
        var preferencesURL: URL { root.appendingPathComponent("ui-preferences.json") }
    }

    private func makeFixture(rows: Int = 0, hub: SessionEventHub = SessionEventHub()) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-ui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        for index in 0..<rows {
            try await catalog.insertSession(
                ManagedSession(provider: index % 2 == 0 ? .claude : .codex, workingDirectory: "/tmp"),
                title: "Row \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle
            )
        }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        let model = CatalogModel(catalog: catalog, events: hub, preferences: preferences)
        return Fixture(root: root, catalog: catalog, hub: hub, preferences: preferences, model: model)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.model.stop()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    // MARK: B2 start, selection and reopening start nothing

    @Test func startShowsFirstPageOnlyAndSelectionStartsNoProviderOrPTY() async throws {
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger()
        )
        let fixture = try await makeFixture(rows: 250, hub: supervisor.events)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let list = fixture.model.list(for: .activity)
        #expect(list.rows.count == 100)
        #expect(list.hasMore)
        // Newest use first.
        #expect(list.rows.first?.record.title == "Row 249")

        for row in list.rows.prefix(20) { fixture.model.select(row.id) }
        fixture.model.setViewMode(.projects)
        fixture.model.setViewMode(.activity)
        await fixture.model.settle()
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect(try await supervisor.ownedProcesses().isEmpty)
        #expect(fixture.model.showsDevTerminal == false)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func reopeningRestoresModeSelectionProjectsAndSidebarPreferences() async throws {
        let fixture = try await makeFixture(rows: 30)
        defer { cleanup(fixture) }
        let folder = fixture.root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await fixture.model.start()
        _ = await fixture.model.addProject(path: folder.path)
        let picked = try #require(fixture.model.list(for: .activity).rows.dropFirst(3).first)
        fixture.model.select(picked.id)
        fixture.model.setSidebarWidth(410)
        fixture.model.setSidebarCollapsed(true)
        try await fixture.catalog.renameSession(sessionID: picked.id, to: "Kept title")
        await fixture.model.settle()

        // A new model over the same files is the reopened app.
        let reopenedPreferences = UIPreferencesStore(url: fixture.preferencesURL)
        let reopened = CatalogModel(catalog: fixture.catalog, events: SessionEventHub(),
                                    preferences: reopenedPreferences)
        await reopened.start()
        defer { reopened.stop() }
        #expect(reopened.viewMode == .projects) // addProject switches to the project view
        #expect(reopened.selectedSessionID == picked.id)
        #expect(reopened.selectedRow.map { reopened.title(of: $0) } == "Kept title")
        #expect(reopened.projects.map(\.name) == ["proj"])
        #expect(reopenedPreferences.current.sidebarWidth == 410)
        #expect(reopenedPreferences.current.sidebarCollapsed)
        #expect(reopened.sidebarCollapsed)
    }

    @Test func selectionOfARemovedConversationIsClearedNotInvented() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        try fixture.preferences.update { $0.selectedSessionID = UUID() }
        let model = CatalogModel(catalog: fixture.catalog, events: fixture.hub, preferences: fixture.preferences)
        await model.start()
        defer { model.stop() }
        #expect(model.selectedSessionID == nil)
        #expect(model.selectedRow == nil)
        #expect(fixture.preferences.current.selectedSessionID == nil)
    }

    // MARK: Lists and search

    @Test func loadMoreAppendsEveryRowExactlyOnce() async throws {
        let fixture = try await makeFixture(rows: 230)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let list = fixture.model.list(for: .activity)
        for _ in 0..<5 {
            fixture.model.loadMore(.activity)
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(list.rows.count == 230)
        #expect(Set(list.rows.map(\.id)).count == 230)
        #expect(list.hasMore == false)
    }

    @Test func searchIsDebouncedAndTheLatestQueryWins() async throws {
        let fixture = try await makeFixture(rows: 60)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let before = fixture.model.statistics.pageQueries
        for text in ["r", "ro", "row", "row 1", "row 12"] { fixture.model.setSearchText(text) }
        await fixture.model.settle()
        let titles = fixture.model.list(for: .activity).rows.compactMap(\.record.title)
        #expect(titles == ["Row 12"])
        #expect(fixture.model.statistics.pageQueries - before == 1)
        fixture.model.setSearchText("")
        await fixture.model.settle()
        #expect(fixture.model.list(for: .activity).rows.count == 60)
    }

    // MARK: Titles and disk errors

    @Test func terminalTitleNeverReplacesACustomTitle() async throws {
        let fixture = try await makeFixture(rows: 2)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let row = try #require(fixture.model.list(for: .activity).rows.first)
        try await fixture.model.rename(sessionID: row.id, to: "Mine")
        await fixture.model.terminalTitleChanged(sessionID: row.id, title: "Terminal says otherwise")
        #expect(row.record.title == "Mine")
        #expect(row.record.titleIsCustom)
        try await fixture.model.rename(sessionID: row.id, to: "")
        await fixture.model.terminalTitleChanged(sessionID: row.id, title: "Automatic again")
        #expect(row.record.title == "Automatic again")
        #expect(row.record.titleIsCustom == false)
    }

    @Test func failedRenameShowsTheErrorAndKeepsTheOldTitle() async throws {
        let fixture = try await makeFixture(rows: 2)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let row = try #require(fixture.model.list(for: .activity).rows.first)
        let oldTitle = row.record.title

        // Another connection holds the write lock: a real disk-level failure.
        var connection: OpaquePointer?
        #expect(sqlite3_open(fixture.root.appendingPathComponent("catalog.sqlite3").path, &connection) == SQLITE_OK)
        let lock = try #require(connection)
        defer { sqlite3_close(lock) }
        #expect(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        do {
            try await fixture.model.rename(sessionID: row.id, to: "Never saved")
            Issue.record("A rename that could not be written reported success")
        } catch {}
        #expect(row.record.title == oldTitle)
        #expect(fixture.model.errorMessage?.contains("The title could not be saved") == true)
        #expect(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        try await fixture.model.rename(sessionID: row.id, to: "Saved now")
        #expect(row.record.title == "Saved now")
    }

    /// Titles the open search actually shows (all visible lists of the mode).
    private func shownTitles(_ model: CatalogModel) -> [String] {
        model.visibleListKeys().flatMap { model.list(for: $0).rows }.compactMap(\.record.title).sorted()
    }

    private func storedTitles(_ fixture: Fixture, _ search: String) async throws -> [String] {
        try await fixture.catalog.sessionPage(CatalogQuery(search: search)).sessions.compactMap(\.title).sorted()
    }

    @Test(arguments: [CatalogViewMode.activity, CatalogViewMode.projects])
    func renameAndTerminalTitleKeepTheOpenSearchResultsConsistent(mode: CatalogViewMode) async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let folder = fixture.root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await fixture.catalog.addProject(path: folder.path).project
        var ids: [String: UUID] = [:]
        for (name, projectID) in [("Needle", project.id), ("Other", nil), ("Third", project.id)] {
            let id = UUID()
            ids[name] = id
            try await fixture.catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: "/tmp"), title: name,
                createdAt: Date(timeIntervalSince1970: Double(ids.count)),
                lastUsedAt: Date(timeIntervalSince1970: Double(100 + ids.count)), lifecycle: .idle,
                projectID: projectID
            )
        }
        let model = fixture.model
        await model.start()
        model.setViewMode(mode)
        model.select(ids["Needle"])
        model.setSearchText("needle")
        await model.settle()
        #expect(shownTitles(model) == ["Needle"])

        // A record leaves the results when its title stops matching; the selected detail stays.
        try await model.rename(sessionID: ids["Needle"]!, to: "Unrelated")
        await model.settle()
        #expect(shownTitles(model) == [])
        #expect(try await storedTitles(fixture, "needle") == [])
        #expect(model.selectedRow.map { model.title(of: $0) } == "Unrelated")
        #expect(model.selectedRow?.record.titleIsCustom == true)

        // A record enters the results when its title starts matching.
        model.setSearchText("newmatch")
        await model.settle()
        #expect(shownTitles(model) == [])
        try await model.rename(sessionID: ids["Other"]!, to: "Newmatch")
        await model.settle()
        #expect(shownTitles(model) == ["Newmatch"])
        #expect(try await storedTitles(fixture, "newmatch") == ["Newmatch"])

        // Terminal titles take the same path, and never override a custom title.
        await model.terminalTitleChanged(sessionID: ids["Third"]!, title: "Newmatch from terminal")
        await model.settle()
        #expect(shownTitles(model) == ["Newmatch", "Newmatch from terminal"])
        await model.terminalTitleChanged(sessionID: ids["Other"]!, title: "Terminal wants this")
        await model.settle()
        #expect(shownTitles(model) == ["Newmatch", "Newmatch from terminal"])
        #expect(try await storedTitles(fixture, "newmatch") == shownTitles(model))

        // Clearing the search restores everything; a stale in-flight query cannot win.
        model.setSearchText("newm")
        model.setSearchText("")
        await model.settle()
        #expect(shownTitles(model).count == 3)
    }

    @Test func projectMessagesAreVisibleAndNothingIsDeletedFromDisk() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        await fixture.model.start()
        let folder = fixture.root.appendingPathComponent("code", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = try #require(await fixture.model.addProject(path: folder.path))
        #expect(first.alreadyPresent == false)
        let second = try #require(await fixture.model.addProject(path: folder.path + "/"))
        #expect(second.alreadyPresent)
        #expect(fixture.model.projects.count == 1)
        #expect(fixture.model.infoMessage?.contains("already") == true)

        try await fixture.catalog.insertSession(
            ManagedSession(provider: .claude, workingDirectory: folder.path), projectID: first.project.id
        )
        await fixture.model.removeProject(first.project.id)
        #expect(fixture.model.projects.count == 1)
        #expect(fixture.model.errorMessage?.contains("empty") == true)
        #expect(await fixture.model.addProject(path: fixture.root.appendingPathComponent("nope").path) == nil)
        #expect(fixture.model.errorMessage?.contains("could not be added") == true)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: B3 event recovery

    private func live(_ model: CatalogModel, _ id: UUID) -> SessionRowModel? {
        model.list(for: .activity).rows.first { $0.id == id }
    }

    @Test func slowConsumerRecoversLatestRunStatusStopFailureAndCompletionWithoutFalseFinish() async throws {
        let hub = SessionEventHub()
        let fixture = try await makeFixture(rows: 6, hub: hub)
        defer { cleanup(fixture) }
        await fixture.model.start()
        await fixture.model.stopAndWait() // the test feeds frames itself
        let rows = fixture.model.list(for: .activity).rows
        let finished = rows[0].id, failing = rows[1].id, replaced = rows[2].id, idle = rows[3].id

        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        fixture.model.apply(try #require(await iterator.next())) // initial snapshot
        // Burst while the consumer reads nothing: it can only see the last frame.
        let oldRun = UUID(), newRun = UUID(), failingRun = UUID(), finishedRun = UUID()
        await hub.publish(sessionID: finished, change: .runStarted(finishedRun))
        await hub.publish(sessionID: finished, change: .status(ProviderWorkState(activity: .working)))
        await hub.publish(sessionID: finished, change: .status(ProviderWorkState(activity: .turnComplete)))
        await hub.publish(sessionID: failing, change: .runStarted(failingRun))
        await hub.publish(sessionID: failing, change: .stopFailure("1 process(es) still running"))
        await hub.publish(sessionID: replaced, change: .runStarted(oldRun))
        await hub.publish(sessionID: replaced, change: .runEnded(oldRun, .processExited))
        await hub.publish(sessionID: replaced, change: .runStarted(newRun))
        await hub.publish(sessionID: replaced, change: .status(ProviderWorkState(activity: .working)))
        await hub.publish(sessionID: replaced, change: .runEnded(oldRun, .requested)) // late, old run
        for index in 0..<200 { await hub.publish(sessionID: idle, change: .blockers(index % 2 == 0 ? [.notDue] : [])) }
        let frame = try #require(await iterator.next())
        #expect(frame.sequence > 200)
        let reconciles = fixture.model.statistics.fullReconciles
        fixture.model.apply(frame)
        #expect(fixture.model.statistics.fullReconciles == reconciles + 1)

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[finished]?.live?.runID == finishedRun)
        #expect(byID[finished]?.indicator == .unviewedCompletion)
        #expect(byID[failing]?.indicator == .stopUnverified("Stop could not be verified: 1 process(es) still running")
                || byID[failing]?.indicator == .stopUnverified("1 process(es) still running"))
        #expect(byID[failing]?.live?.runID == failingRun)
        #expect(byID[replaced]?.live?.runID == newRun)
        #expect(byID[replaced]?.indicator == .working)
        // A conversation nothing happened to shows its catalog lifecycle, not an invented run.
        #expect(byID[idle]?.live?.runID == nil)
        #expect(byID[idle]?.indicator == .idle)
    }

    /// History §28.1: aging is a batched catalog change. A consumer that only
    /// sees a later frame (or the batch frame itself) still shows stale cards.
    @Test func agingBatchRefreshesVisibleCardsEvenWhenTheBatchFrameIsSkipped() async throws {
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger()
        )
        let hub = supervisor.events
        let fixture = try await makeFixture(hub: hub)
        defer { cleanup(fixture) }
        for index in 0..<30 {
            try await fixture.catalog.insertSession(
                ManagedSession(provider: .codex, workingDirectory: "/tmp"),
                title: "Old \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date().addingTimeInterval(-20 * 86_400 - Double(index)), lifecycle: .idle
            )
        }
        await fixture.model.start()
        await fixture.model.stopAndWait() // the test feeds frames itself
        let rows = fixture.model.list(for: .activity).rows
        #expect(rows.count == 30 && rows.allSatisfy { $0.indicator == .idle })

        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        fixture.model.apply(try #require(await iterator.next()))
        let controller = SessionLifecycleController(supervisor: supervisor, catalog: fixture.catalog)
        #expect(try await controller.classifyStale().count == 30)
        // Later events of one live conversation overwrite the batch frame.
        for index in 0..<50 {
            await hub.publish(sessionID: rows[0].id, change: .blockers(index % 2 == 0 ? [.notDue] : []))
        }
        let frame = try #require(await iterator.next())
        #expect(frame.change != .catalogLifecycle(.stale, count: 30))
        fixture.model.apply(frame)
        await fixture.model.settle()

        let refreshed = fixture.model.list(for: .activity).rows
        #expect(refreshed.count == 30)
        #expect(refreshed.allSatisfy { $0.indicator == .stale })
        #expect((await hub.snapshot().sessions.count) == 1)
        _ = await supervisor.shutdown()
    }

    @Test func contiguousFramesUpdateOneRowWithoutTouchingTheOthers() async throws {
        let hub = SessionEventHub()
        let fixture = try await makeFixture(rows: 5, hub: hub)
        defer { cleanup(fixture) }
        await fixture.model.start()
        await fixture.model.stopAndWait()
        let rows = fixture.model.list(for: .activity).rows
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        fixture.model.apply(try #require(await iterator.next()))
        let base = fixture.model.statistics
        await hub.publish(sessionID: rows[0].id, change: .runStarted(UUID()))
        fixture.model.apply(try #require(await iterator.next()))
        await hub.publish(sessionID: rows[0].id, change: .status(ProviderWorkState(activity: .waitingForApproval)))
        fixture.model.apply(try #require(await iterator.next()))
        #expect(fixture.model.statistics.fastPathFrames - base.fastPathFrames == 2)
        #expect(fixture.model.statistics.fullReconciles == base.fullReconciles)
        #expect(rows[0].indicator == .waitingForApproval)
        for other in rows.dropFirst() { #expect(other.live == nil) }
    }

    @Test func onlyVisibleActiveSelectionClearsAnUnviewedFinish() async throws {
        let hub = SessionEventHub()
        let fixture = try await makeFixture(rows: 4, hub: hub)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let target = try #require(fixture.model.list(for: .activity).rows.first)
        await hub.publish(sessionID: target.id, change: .status(ProviderWorkState(activity: .turnComplete)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.indicator == .unviewedCompletion)

        // List refreshes, searches, mode switches and an inactive window are not viewing.
        fixture.model.setSearchText("Row")
        fixture.model.setViewMode(.projects)
        fixture.model.setViewMode(.activity)
        await fixture.model.settle()
        fixture.model.select(target.id) // window not active
        await fixture.model.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.indicator == .unviewedCompletion)
        #expect(await hub.snapshot().sessions[target.id]?.unviewedCompletion == true)

        fixture.model.setWindowActive(true)
        await fixture.model.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.indicator == .idle) // marker cleared; no live run, catalog lifecycle shows
        #expect(await hub.snapshot().sessions[target.id]?.unviewedCompletion == false)
        // Losing the window again stops counting; a new completion is unviewed once more.
        fixture.model.setWindowActive(false)
        await hub.publish(sessionID: target.id, change: .status(ProviderWorkState(activity: .working)))
        await hub.publish(sessionID: target.id, change: .status(ProviderWorkState(activity: .turnComplete)))
        await fixture.model.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.indicator == .unviewedCompletion)
    }

    // MARK: B5 update path

    @Test func statusEventsNeverRequeryTheCatalogAndAConversationUnknownToTheListsRefreshesOnce() async throws {
        let hub = SessionEventHub()
        let fixture = try await makeFixture(rows: 200, hub: hub)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let rows = fixture.model.list(for: .activity).rows
        let before = fixture.model.statistics.pageQueries
        for index in 0..<1_000 {
            await hub.publish(sessionID: rows[index % rows.count].id,
                              change: .status(ProviderWorkState(activity: index % 2 == 0 ? .working : .turnComplete)))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.model.statistics.pageQueries == before)
        #expect(fixture.model.statistics.framesApplied >= 2)

        // A new conversation appears through the catalog and its first event.
        let newID = UUID()
        try await fixture.catalog.insertSession(
            ManagedSession(id: newID, provider: .codex, workingDirectory: "/tmp"), title: "Brand new"
        )
        await hub.publish(sessionID: newID, change: .conversationIdentity(nil))
        await hub.publish(sessionID: newID, change: .runStarted(UUID()))
        await hub.publish(sessionID: newID, change: .status(ProviderWorkState(activity: .working)))
        try await Task.sleep(for: .milliseconds(400))
        await fixture.model.settle()
        let appeared = live(fixture.model, newID)
        #expect(appeared?.record.title == "Brand new")
        #expect(appeared?.indicator == .working)
        #expect(fixture.model.statistics.pageQueries - before <= 3)
    }

    /// Feedback 1: a prompt, a finished turn or a Stop stamps the catalog and announces it; the
    /// card time and the activity order follow without any per-status query.
    @Test func anAnnouncedActivityMovesTheRowToTheTopAndItsCardTime() async throws {
        let hub = SessionEventHub()
        let fixture = try await makeFixture(rows: 5, hub: hub)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let oldest = try #require(fixture.model.list(for: .activity).rows.last)
        #expect(oldest.record.title == "Row 0")

        let stamp = Date(timeIntervalSince1970: 50_000)
        try await fixture.catalog.markActivity(sessionID: oldest.id, at: stamp)
        await hub.publishActivity(sessionID: oldest.id)
        try await Task.sleep(for: .milliseconds(400))
        await fixture.model.settle()
        #expect(fixture.model.list(for: .activity).rows.first?.id == oldest.id)
        #expect(live(fixture.model, oldest.id)?.record.lastActivityAt == stamp)
    }

    @Test func aChangeLandingDuringARefreshReadIsNotLost() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        await fixture.model.start()
        await fixture.model.stopAndWait()
        #expect(fixture.model.list(for: .activity).rows.count == 3)

        let newID = UUID()
        var reads = 0
        fixture.model.afterRefreshRead = { [model = fixture.model, catalog = fixture.catalog] in
            reads += 1
            guard reads == 1 else { return }
            // The first read is complete; this row arrives after it.
            try? await catalog.insertSession(
                ManagedSession(id: newID, provider: .codex, workingDirectory: "/tmp"), title: "Late"
            )
            model.scheduleRefresh()
        }
        fixture.model.scheduleRefresh()
        await fixture.model.settle()
        #expect(reads == 2)
        #expect(fixture.model.list(for: .activity).rows.contains { $0.id == newID })
    }

    @Test func startupWithAnUnreadableCatalogCreatesNothingAndSaysWhy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(
            catalog: nil, startupError: "Catalog schema version 9 is newer than this Sphyrna build supports",
            events: SessionEventHub(), preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json"))
        )
        await model.start()
        #expect(model.isReady)
        #expect(model.startupError?.contains("newer") == true)
        #expect(model.list(for: .activity).rows.isEmpty)
        #expect(await model.addProject(path: root.path) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
