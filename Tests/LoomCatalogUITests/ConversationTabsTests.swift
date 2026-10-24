import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// U3: the model behind conversation tabs. Pure rules first, then the model
/// over a real catalog and preferences file. Nothing here starts a provider.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ConversationTabsTests {
    // MARK: Pure tab rules

    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    @Test func pinAppendsInOrderAndDeduplicates() {
        let all = ids(3)
        let tabs = ConversationTabs()
        for id in all { #expect(tabs.pin(id, canEvict: { _ in true }) == .pinned(evicted: nil)) }
        #expect(tabs.pin(all[0], canEvict: { _ in true }) == .alreadyPinned)
        #expect(tabs.pinned == all)
        #expect(ConversationTabs(pinned: all + all).pinned == all)
    }

    @Test func overTheCapEvictsTheOldestIdleTabAndKeepsRunningOnes() {
        let all = ids(ConversationTabs.capacity)
        let tabs = ConversationTabs(pinned: all)
        let extra = UUID()
        // The two oldest are protected (live or needing attention): the third goes.
        let protected = Set(all.prefix(2))
        #expect(tabs.pin(extra, canEvict: { !protected.contains($0) }) == .pinned(evicted: all[2]))
        #expect(tabs.pinned.count == ConversationTabs.capacity)
        #expect(tabs.pinned.first == all[0] && tabs.pinned.last == extra)
        #expect(!tabs.isPinned(all[2]))
    }

    @Test func overTheCapWithNothingEvictableRefusesWithAReason() {
        let all = ids(ConversationTabs.capacity)
        let tabs = ConversationTabs(pinned: all)
        guard case let .refused(reason) = tabs.pin(UUID(), canEvict: { _ in false }) else {
            Issue.record("expected a refusal"); return
        }
        #expect(!reason.isEmpty)
        #expect(tabs.pinned == all)
    }

    @Test func visibleTabsAddTheSelectionAsOneTransientTab() {
        let all = ids(2)
        let tabs = ConversationTabs(pinned: all)
        #expect(tabs.visible(selected: nil) == all)
        #expect(tabs.visible(selected: all[1]) == all)
        let other = UUID()
        #expect(tabs.visible(selected: other) == all + [other])
    }

    @Test func closingTheSelectedTabPicksTheRightNeighborThenTheLeft() {
        let all = ids(3)
        let tabs = ConversationTabs(pinned: all)
        #expect(tabs.neighbor(ofClosing: all[1], selected: all[1]) == all[2])
        #expect(tabs.neighbor(ofClosing: all[2], selected: all[2]) == all[1])
        #expect(tabs.neighbor(ofClosing: all[0], selected: all[0]) == all[1])
        // The transient tab is last: its left neighbor is the last pinned tab.
        let transient = UUID()
        #expect(tabs.neighbor(ofClosing: transient, selected: transient) == all[2])
        #expect(ConversationTabs().neighbor(ofClosing: transient, selected: transient) == nil)
    }

    @Test func replaceKeepsThePositionAndMergesWhenTheNewCardIsAlreadyPinned() {
        let all = ids(3)
        let new = UUID()
        let tabs = ConversationTabs(pinned: all)
        #expect(tabs.replace(all[1], with: new))
        #expect(tabs.pinned == [all[0], new, all[2]])
        #expect(!tabs.replace(UUID(), with: UUID())) // unpinned owner: nothing to do
        #expect(tabs.replace(all[0], with: all[2]))
        #expect(tabs.pinned == [new, all[2]])
    }

    // MARK: Drops and reordering (W3-b)

    @Test func pinAtPlacesANewTabAtTheStartTheMiddleAndTheEnd() {
        let all = ids(3)
        let (start, middle, end, far) = (UUID(), UUID(), UUID(), UUID())
        let tabs = ConversationTabs(pinned: all)
        #expect(tabs.pin(start, at: 0, canEvict: { _ in true }) == .pinned(evicted: nil))
        #expect(tabs.pinned == [start] + all)
        #expect(tabs.pin(middle, at: 2, canEvict: { _ in true }) == .pinned(evicted: nil))
        #expect(tabs.pinned == [start, all[0], middle, all[1], all[2]])
        #expect(tabs.pin(end, at: 5, canEvict: { _ in true }) == .pinned(evicted: nil))
        #expect(tabs.pinned.last == end)
        // Past the end, or before the start, clamps.
        #expect(tabs.pin(far, at: 99, canEvict: { _ in true }) == .pinned(evicted: nil))
        #expect(tabs.pinned.last == far && tabs.pinned.count == 7)
    }

    @Test func aPinnedSessionDroppedAgainMovesAndIsNeverDuplicated() {
        let all = ids(4)
        let tabs = ConversationTabs(pinned: all)
        #expect(tabs.pin(all[3], at: 0, canEvict: { _ in true }) == .alreadyPinned)
        #expect(tabs.pinned == [all[3], all[0], all[1], all[2]])
        #expect(tabs.pin(all[3], at: -4, canEvict: { _ in true }) == .alreadyPinned)
        #expect(tabs.pinned == [all[3], all[0], all[1], all[2]])
        #expect(Set(tabs.pinned).count == 4)
    }

    @Test func pinAtOnAFullStripEvictsLikePinOrRefusesWithTheSameReason() {
        let all = ids(ConversationTabs.capacity)
        let tabs = ConversationTabs(pinned: all)
        let extra = UUID()
        guard case let .refused(reason) = tabs.pin(extra, at: 1, canEvict: { _ in false }) else {
            Issue.record("expected a refusal"); return
        }
        #expect(tabs.pinned == all)
        #expect(ConversationTabs(pinned: all).pin(extra, canEvict: { _ in false }) == .refused(reason))
        // With room made by the oldest idle tab the new one lands where it was dropped.
        #expect(tabs.pin(extra, at: 1, canEvict: { $0 == all[0] }) == .pinned(evicted: all[0]))
        #expect(tabs.pinned == [all[1], extra] + all[2...])
    }

    @Test func moveReordersAndAGapMapsToTheTabsFinalPlace() {
        let all = ids(4)
        let tabs = ConversationTabs(pinned: all)
        #expect(tabs.move(all[0], to: 2))
        #expect(tabs.pinned == [all[1], all[2], all[0], all[3]])
        #expect(!tabs.move(all[0], to: 2), "already there")
        #expect(!tabs.move(UUID(), to: 0), "not pinned")
        #expect(tabs.move(all[0], to: 99))
        #expect(tabs.pinned.last == all[0])
        // A tab moving right leaves its own place: dropped in the gap before visible tab 3 it ends at 2.
        let order = ConversationTabs(pinned: all)
        #expect(order.position(forGap: 3, of: all[0]) == 2)
        #expect(order.position(forGap: 0, of: all[2]) == 0)
        #expect(order.position(forGap: 1, of: all[1]) == 1 && order.position(forGap: 2, of: all[1]) == 1, "either side of itself")
        // A new session, and any gap past the pinned tabs (the transient tab's), is the end.
        #expect(order.position(forGap: 2, of: UUID()) == 2)
        #expect(order.position(forGap: 9, of: UUID()) == 4)
    }

    // MARK: Model over a real catalog

    struct Fixture {
        let root: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let preferences: UIPreferencesStore
        let model: CatalogModel
        let sessionIDs: [UUID] // oldest use first
        var preferencesURL: URL { root.appendingPathComponent("ui-preferences.json") }
    }

    private func makeFixture(rows: Int, preselect: [UUID] = [],
                             hub: SessionEventHub = SessionEventHub()) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-tabs-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var sessionIDs: [UUID] = []
        for index in 0..<rows {
            let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
            sessionIDs.append(session.id)
            try await catalog.insertSession(
                session, title: "Row \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle
            )
        }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        if !preselect.isEmpty { try preferences.update { $0.openTabs = preselect } }
        let model = CatalogModel(catalog: catalog, events: hub, preferences: preferences)
        model.preferenceWriteDelay = .milliseconds(40)
        return Fixture(root: root, catalog: catalog, hub: hub, preferences: preferences, model: model,
                       sessionIDs: sessionIDs)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.model.stop()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func reopen(_ fixture: Fixture) async -> (CatalogModel, UIPreferencesStore) {
        fixture.model.flushPreferences()
        let store = UIPreferencesStore(url: fixture.preferencesURL)
        let model = CatalogModel(catalog: fixture.catalog, events: SessionEventHub(), preferences: store)
        await model.start()
        return (model, store)
    }

    @Test func pinnedTabsPersistAndComeBackAfterReopening() async throws {
        let fixture = try await makeFixture(rows: 5)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let (a, b) = (fixture.sessionIDs[0], fixture.sessionIDs[3])
        fixture.model.openTab(a)
        fixture.model.openTab(b)
        #expect(fixture.model.visibleTabIDs == [a, b])
        #expect(fixture.model.selectedSessionID == b)

        let (reopened, store) = await reopen(fixture)
        defer { reopened.stop() }
        #expect(store.current.openTabs == [a, b])
        #expect(reopened.tabs.pinned == [a, b])
        #expect(reopened.visibleTabIDs == [a, b])
        // Titles come from the rows, which start() read for the tabs.
        #expect(reopened.tabRow(a).map { reopened.title(of: $0) } == "Row 0")
    }

    @Test func aDropPinsAtThePositionShowsTheSessionAndPersistsAndAMoveSurvivesAReload() async throws {
        let fixture = try await makeFixture(rows: 5)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.sessionIDs
        fixture.model.openTab(ids[0])
        fixture.model.openTab(ids[1])
        // Dropped in the gap before the second tab.
        #expect(fixture.model.dropOnTabs(ids[2], gap: 1) == .pinned(evicted: nil))
        #expect(fixture.model.tabs.pinned == [ids[0], ids[2], ids[1]])
        #expect(fixture.model.selectedSessionID == ids[2])
        // A pinned tab dropped at the end moves; nothing is duplicated.
        #expect(fixture.model.dropOnTabs(ids[0], gap: 3) == .alreadyPinned)
        #expect(fixture.model.tabs.pinned == [ids[2], ids[1], ids[0]])
        fixture.model.moveTab(ids[0], to: 0)
        #expect(fixture.model.tabs.pinned == [ids[0], ids[2], ids[1]])
        #expect(fixture.preferences.current.openTabs == [ids[0], ids[2], ids[1]])

        let (reopened, store) = await reopen(fixture)
        defer { reopened.stop() }
        #expect(store.current.openTabs == [ids[0], ids[2], ids[1]])
        #expect(reopened.tabs.pinned == [ids[0], ids[2], ids[1]])
    }

    @Test func aDropOnAFullStripOfRunningTabsIsRefusedWithTheFeedbackOfOpenTab() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let fixture = try await makeFixture(rows: 10, hub: supervisor.events)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let firstEight = Array(fixture.sessionIDs.prefix(ConversationTabs.capacity))
        for id in firstEight { fixture.model.openTab(id) }
        for id in firstEight {
            try await publish(.runStarted(UUID()), for: id, on: fixture) { $0.live?.runID != nil }
        }
        let ninth = fixture.sessionIDs[8]
        guard case let .refused(reason) = fixture.model.dropOnTabs(ninth, gap: 2) else {
            Issue.record("expected a refusal"); return
        }
        #expect(fixture.model.infoMessage == reason)
        #expect(fixture.model.tabs.pinned == firstEight)
        #expect(fixture.model.selectedSessionID == ninth) // shown as the transient tab, as Open in Tab does
        #expect(fixture.preferences.current.openTabs == firstEight)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func selectingASidebarRowReplacesTheTransientTabWithoutPinning() async throws {
        let fixture = try await makeFixture(rows: 4)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.sessionIDs
        fixture.model.openTab(ids[0])
        fixture.model.select(ids[1])
        #expect(fixture.model.visibleTabIDs == [ids[0], ids[1]])
        fixture.model.select(ids[2])
        #expect(fixture.model.visibleTabIDs == [ids[0], ids[2]])
        #expect(fixture.model.tabs.pinned == [ids[0]])
        // Selecting a pinned tab adds nothing.
        fixture.model.select(ids[0])
        #expect(fixture.model.visibleTabIDs == [ids[0]])
    }

    @Test func fullStripEvictsTheOldestIdleTabAndOpenTabsAreCapped() async throws {
        let fixture = try await makeFixture(rows: 10)
        defer { cleanup(fixture) }
        await fixture.model.start()
        for id in fixture.sessionIDs { fixture.model.openTab(id) }
        #expect(fixture.model.tabs.pinned.count == ConversationTabs.capacity)
        #expect(fixture.model.tabs.pinned == Array(fixture.sessionIDs.suffix(ConversationTabs.capacity)))
        await fixture.model.settle()
        #expect(fixture.preferences.current.openTabs == fixture.model.tabs.pinned)
    }

    @Test func fullStripOfRunningTabsRefusesToPinButStillShowsTheConversation() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let fixture = try await makeFixture(rows: 10, hub: supervisor.events)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let firstEight = Array(fixture.sessionIDs.prefix(ConversationTabs.capacity))
        for id in firstEight { fixture.model.openTab(id) }
        // Every pinned conversation is live.
        for id in firstEight {
            try await publish(.runStarted(UUID()), for: id, on: fixture) { $0.live?.runID != nil }
        }
        let ninth = fixture.sessionIDs[8]
        guard case let .refused(reason) = fixture.model.openTab(ninth) else {
            Issue.record("expected a refusal"); return
        }
        #expect(fixture.model.infoMessage == reason)
        #expect(fixture.model.tabs.pinned == firstEight)
        #expect(fixture.model.selectedSessionID == ninth)
        #expect(fixture.model.visibleTabIDs == firstEight + [ninth])
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func attentionTabsAreNotEvicted() async throws {
        let fixture = try await makeFixture(rows: 10)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let firstEight = Array(fixture.sessionIDs.prefix(ConversationTabs.capacity))
        for id in firstEight { fixture.model.openTab(id) }
        // The oldest tab finished a turn nobody looked at: it needs the user.
        try await publish(.unviewedCompletion(true), for: firstEight[0], on: fixture) {
            $0.indicator == .unviewedCompletion
        }
        _ = fixture.model.openTab(fixture.sessionIDs[8])
        #expect(fixture.model.tabs.isPinned(firstEight[0]))
        #expect(!fixture.model.tabs.isPinned(firstEight[1]))
        #expect(fixture.model.tabs.pinned.last == fixture.sessionIDs[8])
    }

    @Test func closingTheSelectedTabShowsTheNeighborAndNeverStopsARun() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let fixture = try await makeFixture(rows: 4, hub: supervisor.events)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.sessionIDs
        for id in ids.prefix(3) { fixture.model.openTab(id) }
        fixture.model.select(ids[1])
        fixture.model.closeTab(ids[1])
        #expect(fixture.model.tabs.pinned == [ids[0], ids[2]])
        #expect(fixture.model.selectedSessionID == ids[2]) // right neighbor
        fixture.model.closeTab(ids[2])
        #expect(fixture.model.selectedSessionID == ids[0]) // no right: left
        // Closing an unselected tab leaves the selection alone.
        fixture.model.openTab(ids[3])
        fixture.model.closeTab(ids[0])
        #expect(fixture.model.selectedSessionID == ids[3])
        // Closing the transient tab goes to the last pinned tab; the last tab leaves nothing.
        fixture.model.select(ids[1])
        fixture.model.closeTab(ids[1])
        #expect(fixture.model.selectedSessionID == ids[3])
        fixture.model.closeTab(ids[3])
        #expect(fixture.model.selectedSessionID == nil)
        #expect(fixture.model.visibleTabIDs.isEmpty)
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func missingConversationsAreDroppedAtLoadAndPersisted() async throws {
        let ghost = UUID()
        let fixture = try await makeFixture(rows: 3)
        let live = fixture.sessionIDs[1]
        try fixture.preferences.update { $0.openTabs = [ghost, live] }
        let model = CatalogModel(catalog: fixture.catalog, events: fixture.hub, preferences: fixture.preferences)
        defer { model.stop(); cleanup(fixture) }
        await model.start()
        #expect(model.tabs.pinned == [live])
        #expect(fixture.preferences.current.openTabs == [live])
        #expect(UIPreferencesStore(url: fixture.preferencesURL).current.openTabs == [live])
    }

    @Test func forgetDropsADeletedConversationsTab() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.sessionIDs
        fixture.model.openTab(ids[0])
        fixture.model.openTab(ids[1])
        fixture.model.forget(sessionID: ids[1])
        #expect(fixture.model.tabs.pinned == [ids[0]])
        #expect(fixture.model.selectedSessionID == ids[0])
        #expect(UIPreferencesStore(url: fixture.preferencesURL).current.openTabs == [ids[0]])
    }

    @Test func tabRowsSurviveListChangesAndComeBackOnStartEvenBeyondTheFirstPage() async throws {
        let fixture = try await makeFixture(rows: 250)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let oldest = fixture.sessionIDs[0] // oldest use: far beyond the first 100 rows
        #expect(fixture.model.list(for: .activity).rows.contains { $0.id == oldest } == false)
        fixture.model.openTab(oldest)
        await fixture.model.settle()
        fixture.model.select(fixture.sessionIDs[249]) // the tab is no longer selected
        fixture.model.setViewMode(.projects)
        fixture.model.setViewMode(.activity)
        await fixture.model.settle()
        #expect(fixture.model.tabRow(oldest)?.record.title == "Row 0")

        let (reopened, _) = await reopen(fixture)
        defer { reopened.stop() }
        #expect(reopened.tabRow(oldest)?.record.title == "Row 0")
        #expect(reopened.statistics.rowModels <= 100 + ConversationTabs.capacity + 1)
    }

    @Test func rapidSelectionWritesOnceAndTheLastChoiceWins() async throws {
        let fixture = try await makeFixture(rows: 8)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let writesBefore = fixture.preferences.writeCount
        for id in fixture.sessionIDs { fixture.model.select(id) }
        #expect(fixture.preferences.writeCount == writesBefore) // nothing written synchronously
        #expect(fixture.preferences.current.selectedSessionID == fixture.sessionIDs.last)
        await fixture.model.settle()
        #expect(fixture.preferences.writeCount == writesBefore + 1)
        #expect(UIPreferencesStore(url: fixture.preferencesURL).current.selectedSessionID == fixture.sessionIDs.last)
    }

    @Test func flushWritesAPendingSelectionImmediately() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        fixture.model.preferenceWriteDelay = .seconds(60)
        await fixture.model.start()
        fixture.model.select(fixture.sessionIDs[2])
        fixture.model.flushPreferences()
        #expect(UIPreferencesStore(url: fixture.preferencesURL).current.selectedSessionID == fixture.sessionIDs[2])
    }

    @Test func selectingTabsStartsNoProviderOrPTY() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let fixture = try await makeFixture(rows: 6, hub: supervisor.events)
        defer { cleanup(fixture) }
        await fixture.model.start()
        for id in fixture.sessionIDs.prefix(4) { fixture.model.openTab(id) }
        for id in fixture.sessionIDs { fixture.model.select(id) }
        fixture.model.closeTab(fixture.sessionIDs[0])
        await fixture.model.settle()
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect(try await supervisor.ownedProcesses().isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    // MARK: Helpers

    /// Publishes a live change through the hub and waits until the model's own
    /// event consumer applied it to the tab's row.
    private func publish(_ change: SessionEventChange, for id: UUID, on fixture: Fixture,
                         until applied: @MainActor (SessionRowModel) -> Bool) async throws {
        await fixture.hub.publish(sessionID: id, change: change)
        for _ in 0..<200 {
            if let row = fixture.model.tabRow(id), applied(row) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the model did not apply \(change)")
    }
}
