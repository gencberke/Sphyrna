import Foundation
@testable import LoomCore
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// D-45 at the model: the attention set over live state, the Dock badge count, next/previous in the list as
/// drawn, the sidebar following the selection, and the two bug fixes (a tab unpinned by a failed read, a
/// bottom spinner that never loads its page). Real catalog and event hub; no process, no window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionNavigationModelTests {
    struct Rig {
        let root: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let model: CatalogModel
        /// Session ids in creation order (the first is the oldest).
        let ids: [UUID]
        let projects: [CatalogProject]

        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// `layout[i]` = the project index of session `i` (nil: no project). Sessions are titled "s<i>", created and
    /// used in index order, so the activity list shows the highest index first.
    private func makeRig(layout: [Int?], projectCount: Int = 0, collapsed: Set<Int> = [], projectView: Bool = false,
                         openTabs: [Int] = [], preStart: ((CatalogModel) -> Void)? = nil,
                         start: Bool = true) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nav-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var projects: [CatalogProject] = []
        for index in 0..<projectCount {
            let folder = root.appendingPathComponent("p\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(try await catalog.addProject(path: folder.path).project)
        }
        for index in collapsed { try await catalog.setProjectCollapsed(id: projects[index].id, collapsed: true) }
        var ids: [UUID] = []
        for (index, project) in layout.enumerated() {
            let session = ManagedSession(provider: .claude, providerConversationID: "conv-\(index)",
                                         workingDirectory: root.path)
            try await catalog.insertSession(
                session, title: "s\(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle,
                projectID: project.map { projects[$0].id })
            ids.append(session.id)
        }
        let hub = SessionEventHub()
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        if !openTabs.isEmpty { try preferences.update { $0.openTabs = openTabs.map { ids[$0] } } }
        let model = CatalogModel(catalog: catalog, events: hub, preferences: preferences)
        if projectView { model.setViewMode(.projects) }
        preStart?(model)
        if start { await model.start() }
        return Rig(root: root, catalog: catalog, hub: hub, model: model, ids: ids, projects: projects)
    }

    private func waitUntil(_ seconds: TimeInterval = 6, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func live(_ rig: Rig, _ index: Int, _ activity: AgentActivity) async {
        await rig.hub.publish(sessionID: rig.ids[index], change: .runStarted(UUID()))
        await rig.hub.publish(sessionID: rig.ids[index], change: .status(ProviderWorkState(activity: activity)))
    }

    private func openRequest(requester: UUID, phase: OpenSessionRequest.Phase = .waiting) -> OpenSessionRequest {
        OpenSessionRequest(
            requesterID: requester, requesterTitle: "Planner", projectID: UUID(), projectName: "p",
            title: "Fix", message: "Do it.", phase: phase)
    }

    // MARK: Attention order, jumps and the Dock badge

    @Test func jumpsWalkTheAttentionOrderAndTheBadgeCountFollowsLiveState() async throws {
        let rig = try await makeRig(layout: [nil, nil, nil, nil, nil])
        defer { rig.cleanup() }
        var counts: [Int] = []
        rig.model.onAttentionCountChange = { counts.append($0) }
        #expect(!rig.model.canJumpToAttention)
        #expect(rig.model.attentionCount == 0)

        await live(rig, 0, .working)
        await live(rig, 1, .waitingForInput)
        await live(rig, 2, .failed("boom"))
        await live(rig, 3, .waitingForApproval)
        await live(rig, 4, .turnComplete)
        #expect(await waitUntil { rig.model.attentionCount == 4 })
        #expect(counts.last == 4)
        #expect(counts == counts.sorted(), "the badge only counted up while sessions were added")
        #expect(DockBadge.label(count: rig.model.attentionCount) == "4")
        // Failure, then Needs approval, then Waiting for you, then Finished.
        let order = [2, 3, 1, 4].map { rig.ids[$0] }
        #expect(rig.model.sessionsNeedingAttention() == order)
        #expect(rig.model.busySessionCount() == 2, "Working and Needs approval count for the quit question")
        #expect(rig.model.canJumpToAttention)

        var visited: [UUID] = []
        for _ in 0..<5 {
            #expect(rig.model.jumpToAttention(.next))
            visited.append(try #require(rig.model.selectedSessionID))
        }
        #expect(visited == order + [order[0]], "repeated jumps walk and wrap")
        #expect(rig.model.jumpToAttention(.previous))
        #expect(rig.model.selectedSessionID == order[3])

        // Read, answered or ended sessions leave the set and the badge follows.
        rig.model.markRead(rig.ids[1])
        #expect(await waitUntil { rig.model.attentionCount == 3 })
        #expect(counts.last == 3)
        #expect(!rig.model.sessionsNeedingAttention().contains(rig.ids[1]))
    }

    @Test func aSessionWhoseAgentWaitsOnAnOpenRequestIsInTheSetLikeAnApproval() async throws {
        let rig = try await makeRig(layout: [nil, nil])
        defer { rig.cleanup() }
        await live(rig, 0, .working)
        #expect(await waitUntil { rig.model.list(for: .activity).rows.first { $0.id == rig.ids[0] }?.indicator == .working })
        #expect(rig.model.attentionCount == 0)
        #expect(rig.model.busySessionCount() == 1)

        var asked = openRequest(requester: rig.ids[0])
        rig.model.setOpenRequests([asked])
        #expect(rig.model.attentionCount == 1)
        #expect(rig.model.sessionsNeedingAttention() == [rig.ids[0]])
        #expect(rig.model.busySessionCount() == 1, "an agent's wait counts as Needs approval")

        asked.phase = .starting // the user answered
        rig.model.setOpenRequests([asked])
        #expect(rig.model.attentionCount == 0)
        asked.phase = .failed("x")
        rig.model.setOpenRequests([asked])
        #expect(rig.model.attentionCount == 1)
        rig.model.setOpenRequests([])
        #expect(rig.model.attentionCount == 0)
    }

    @Test func aLiveSessionThatIsNotLoadedStillCountsOnceItsRecordIsKnown() async throws {
        // 120 rows: the oldest is beyond the first page of the activity list.
        let rig = try await makeRig(layout: Array(repeating: nil, count: 120))
        defer { rig.cleanup() }
        #expect(rig.model.list(for: .activity).rows.count == 100)
        await live(rig, 0, .waitingForInput)
        #expect(await waitUntil { rig.model.attentionCount == 1 })
        #expect(rig.model.sessionsNeedingAttention() == [rig.ids[0]])
        // Jumping selects a session no list holds (select loads its row).
        #expect(rig.model.jumpToAttention(.next))
        #expect(rig.model.selectedSessionID == rig.ids[0])
        #expect(await waitUntil { rig.model.selectedRow?.id == rig.ids[0] })
    }

    // MARK: Next and previous in the list as drawn

    @Test func nextAndPreviousFollowTheActivityListWithoutWrapping() async throws {
        let rig = try await makeRig(layout: [nil, nil, nil])
        defer { rig.cleanup() }
        // Newest activity first: s2, s1, s0.
        #expect(rig.model.visibleSessionIDs() == [rig.ids[2], rig.ids[1], rig.ids[0]])
        #expect(rig.model.selectAdjacentSession(.next))
        #expect(rig.model.selectedSessionID == rig.ids[2], "with nothing selected, next is the first card")
        #expect(rig.model.selectAdjacentSession(.next))
        #expect(rig.model.selectAdjacentSession(.next))
        #expect(rig.model.selectedSessionID == rig.ids[0])
        #expect(!rig.model.canSelectAdjacentSession(.next))
        #expect(!rig.model.selectAdjacentSession(.next), "no wrap")
        #expect(rig.model.selectedSessionID == rig.ids[0])
        #expect(rig.model.selectAdjacentSession(.previous))
        #expect(rig.model.selectedSessionID == rig.ids[1])
    }

    @Test func theProjectViewWalksProjectsInOrderSkipsCollapsedOnesAndEndsWithTheSessionsGroup() async throws {
        // p0: s0 s1 · p1 (collapsed): s2 s3 · no project: s4. Inside a project the newest-created is first.
        let rig = try await makeRig(layout: [0, 0, 1, 1, nil], projectCount: 2, collapsed: [1], projectView: true)
        defer { rig.cleanup() }
        await rig.model.settle()
        #expect(rig.model.visibleSessionIDs() == [rig.ids[1], rig.ids[0], rig.ids[4]])
        rig.model.select(rig.ids[0], revealInList: false)
        #expect(rig.model.adjacentSession(.next) == rig.ids[4])
        #expect(rig.model.adjacentSession(.previous) == rig.ids[1])

        await rig.model.toggleCollapsed(rig.projects[1].id)
        #expect(rig.model.visibleSessionIDs() == [rig.ids[1], rig.ids[0], rig.ids[3], rig.ids[2], rig.ids[4]])
        #expect(rig.model.adjacentSession(.next) == rig.ids[3])

        // A search shows matching projects open, whatever their collapsed flag says.
        await rig.model.toggleCollapsed(rig.projects[1].id)
        rig.model.setSearchText("s3")
        await rig.model.settle()
        #expect(rig.model.visibleSessionIDs() == [rig.ids[3]])
    }

    // MARK: The sidebar follows the selection

    @Test func aSelectionNotMadeInTheListExpandsItsProjectAndAsksForAScroll() async throws {
        let rig = try await makeRig(layout: [0, 0], projectCount: 1, collapsed: [0], projectView: true)
        defer { rig.cleanup() }
        await rig.model.settle()
        #expect(rig.model.projects[0].collapsed)
        #expect(rig.model.revealRequest == nil)

        rig.model.select(rig.ids[0]) // a tab, a shortcut, "Show Session" ...
        await rig.model.settle()
        #expect(rig.model.projects[0].collapsed == false)
        let request = try #require(rig.model.revealRequest)
        #expect(request.id == rig.ids[0])

        // The same session again is not a change of the selection: no second request.
        rig.model.select(rig.ids[0])
        await rig.model.settle()
        #expect(rig.model.revealRequest == request)

        let other = rig.model.visibleSessionIDs().first { $0 != rig.ids[0] }!
        rig.model.selectTab(other)
        await rig.model.settle()
        let second = try #require(rig.model.revealRequest)
        #expect(second.id == other && second.serial != request.serial)
    }

    @Test func aClickInTheListDoesNotScrollIt() async throws {
        let rig = try await makeRig(layout: [nil, nil, nil])
        defer { rig.cleanup() }
        rig.model.selectFromList(rig.ids[1])
        await rig.model.settle()
        #expect(rig.model.selectedSessionID == rig.ids[1])
        #expect(rig.model.revealRequest == nil)
        // The list's own double click and menu entry (Open in Tab) neither.
        rig.model.openTab(rig.ids[2], revealInList: false)
        await rig.model.settle()
        #expect(rig.model.revealRequest == nil)
        rig.model.selectTab(rig.ids[0])
        await rig.model.settle()
        #expect(rig.model.revealRequest?.id == rig.ids[0])
    }

    @Test func aCardThatIsNotLoadedIsSkippedAndNothingIsPaged() async throws {
        let rig = try await makeRig(layout: Array(repeating: nil, count: 120))
        defer { rig.cleanup() }
        let queries = rig.model.statistics.pageQueries
        rig.model.select(rig.ids[0]) // the oldest: beyond the first page
        await rig.model.settle()
        #expect(rig.model.revealRequest == nil)
        #expect(rig.model.list(for: .activity).rows.count == 100)
        // One point lookup for the selected row, no page.
        #expect(rig.model.statistics.pageQueries - queries <= 2)
    }

    // MARK: Bug: a failed read unpinned a tab

    @Test func aFailedReadKeepsTheTabAndOnlyAMissingSessionUnpinsIt() async throws {
        struct Unreadable: Error {}
        // 120 rows: the pinned tab's session (the oldest) is not in a list, so its row is read on its own.
        let rig = try await makeRig(
            layout: Array(repeating: nil, count: 120), openTabs: [0],
            preStart: { $0.sessionReader = { _ in throw Unreadable() } })
        defer { rig.cleanup() }
        let pinned = rig.ids[0]
        #expect(rig.model.tabs.pinned == [pinned], "a read that failed does not unpin the tab")
        #expect(rig.model.errorMessage?.contains("A tab's session could not be read") == true)
        #expect(rig.model.tabRow(pinned) == nil)
        #expect(rig.model.preferencesSnapshot.openTabs == [pinned])

        // A later pass reads it.
        rig.model.sessionReader = nil
        await rig.model.ensureTabRows()
        #expect(rig.model.tabs.pinned == [pinned])
        #expect(rig.model.tabRow(pinned)?.record.session.id == pinned)

        // Only a definite "no such session" unpins.
        let ghost = UUID()
        _ = rig.model.tabs.pin(ghost, canEvict: { _ in true })
        rig.model.sessionReader = { id in id == ghost ? nil : try await rig.catalog.session(id: id) }
        await rig.model.ensureTabRows()
        #expect(!rig.model.tabs.isPinned(ghost))
        #expect(rig.model.tabs.isPinned(pinned))
    }

    // MARK: Bug: the bottom spinner stayed

    @Test func aPageOutdatedByAReloadIsReadAgainSoTheSpinnerCannotStayForever() async throws {
        let rig = try await makeRig(layout: Array(repeating: nil, count: 230))
        defer { rig.cleanup() }
        let list = rig.model.list(for: .activity)
        #expect(list.rows.count == 100 && list.hasMore)
        var reloaded = false
        rig.model.afterMoreRead = { [model = rig.model] in
            guard !reloaded else { return }
            reloaded = true
            // A reload lands while the page is being read (a turn finished, a title changed ...).
            model.scheduleRefresh()
            await model.settle()
        }
        // The user scrolled to the bottom: the last row appeared and asked for more, once.
        rig.model.loadMore(.activity)
        #expect(await waitUntil { reloaded })
        // Nothing asks again (the last row does not reappear after the reload): the model must.
        #expect(await waitUntil { list.rows.count == 200 }, "rows: \(list.rows.count)")
        #expect(list.hasMore)
        rig.model.loadMore(.activity)
        #expect(await waitUntil { list.rows.count == 230 && !list.hasMore })
        #expect(Set(list.rows.map(\.id)).count == 230)
    }
}
