import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// U4: the strip's layout rules and the keyboard commands the menu routes to the model.
/// Everything here is pure presentation state; nothing starts a provider.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ConversationTabStripTests {
    // MARK: Layout rules

    @Test func theStripIsHiddenWithFewerThanTwoTabs() {
        #expect(!TabStripLayout.isVisible(tabCount: 0))
        #expect(!TabStripLayout.isVisible(tabCount: 1))
        #expect(TabStripLayout.isVisible(tabCount: 2))
        #expect(TabStripLayout.isVisible(tabCount: 8))
    }

    @Test func tabsShareTheWidthBetweenMinimumAndMaximum() {
        // Detail panel at the default 1220 pt window with a 300 pt sidebar: 904 pt of strip.
        let two = TabStripLayout(count: 2, width: 904)
        #expect(two.tabWidth == LoomTheme.TabStrip.maxTabWidth)
        #expect(!two.overflows)
        let six = TabStripLayout(count: 6, width: 904)
        #expect(!six.overflows)
        #expect(abs(six.tabWidth - (904 - 16 - 5 * 4) / 6) < 0.001) // about 145 pt, as in the design
    }

    @Test func tabsStopAtTheMinimumThenTheStripScrollsWithAChevron() {
        let five = TabStripLayout(count: 5, width: 904)
        #expect(!five.overflows)
        let eightWide = TabStripLayout(count: 8, width: 904)
        #expect(eightWide.overflows) // 8 x 112 + 7 x 4 + padding = 940 pt
        #expect(eightWide.tabWidth == LoomTheme.TabStrip.minTabWidth)
        #expect(eightWide.listWidth == 904 - 16 - LoomTheme.TabStrip.gap - LoomTheme.TabStrip.overflowWidth)
        let eightNarrow = TabStripLayout(count: 8, width: 464) // 780 pt window, 300 pt sidebar
        #expect(eightNarrow.overflows && eightNarrow.tabWidth == LoomTheme.TabStrip.minTabWidth)
        let twoNarrow = TabStripLayout(count: 2, width: 464)
        #expect(!twoNarrow.overflows)
        // The boundary: exactly fitting is not an overflow, one point less is.
        let exact = 4 * 112 + 3 * 4 + 16
        #expect(!TabStripLayout(count: 4, width: CGFloat(exact)).overflows)
        #expect(TabStripLayout(count: 4, width: CGFloat(exact - 1)).overflows)
    }

    @Test func hiddenTabsAreTheOnesScrolledOutOfTheViewport() {
        let layout = TabStripLayout(count: 8, width: 464)
        let tab = layout.tabWidth, step = tab + LoomTheme.TabStrip.gap
        // Scrolled to the start: only the tabs that fit are visible.
        let atStart = layout.hiddenIndices(scrollOffset: 0)
        let fitting = Int((layout.listWidth + LoomTheme.TabStrip.gap) / step)
        #expect(atStart == Array(fitting..<8) || atStart == Array((fitting + 1)..<8))
        #expect(!atStart.contains(0))
        // Scrolled to the end: the first tabs are hidden, the last one is not.
        let atEnd = layout.hiddenIndices(scrollOffset: 8 * step - LoomTheme.TabStrip.gap - layout.listWidth)
        #expect(atEnd.contains(0) && !atEnd.contains(7))
        // No overflow, nothing hidden.
        #expect(TabStripLayout(count: 3, width: 904).hiddenIndices(scrollOffset: 0).isEmpty)
    }

    @Test func aSelectedTabIsRevealedByTheSmallestScroll() {
        let layout = TabStripLayout(count: 8, width: 464)
        let step = layout.tabWidth + LoomTheme.TabStrip.gap
        #expect(layout.revealEdge(of: 0, scrollOffset: 0) == nil)
        #expect(layout.revealEdge(of: 2, scrollOffset: 0) == nil) // the third tab fits at the start
        #expect(layout.revealEdge(of: 7, scrollOffset: 0) == .trailing)
        #expect(layout.revealEdge(of: 0, scrollOffset: 3 * step) == .leading)
        #expect(layout.revealEdge(of: 1, scrollOffset: step + 1) == .leading) // partly clipped on the left
        #expect(TabStripLayout(count: 3, width: 904).revealEdge(of: 2, scrollOffset: 0) == nil)
    }

    @Test func theChevronDotShowsTheStrongestHiddenStatus() {
        #expect(TabStripLayout.hiddenAttention([.idle, .working, .ready]) == nil)
        #expect(TabStripLayout.hiddenAttention([.unviewedCompletion, .idle]) == .unviewed)
        #expect(TabStripLayout.hiddenAttention([.unviewedCompletion, .waitingForInput, .idle]) == .attention)
        #expect(TabStripLayout.hiddenAttention([.waitingForApproval, .failed(nil), .unviewedCompletion]) == .failure)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.lock(); raised = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    // MARK: Vertical rhythm (FB-C): no gap between the title row and its tabs

    /// The real header-and-strip composition (`DetailTop`) laid out by AppKit, no window needed.
    private func topBlockHeight(_ model: CatalogModel) -> CGFloat {
        let hosting = NSHostingView(rootView: DetailTop(model: model).frame(width: 800))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    @Test func theStripSitsDirectlyUnderTheHeaderRowAndASingleTabKeepsTheOldBlock() async throws {
        let fixture = try await makeFixture(rows: 2)
        defer { cleanup(fixture) }
        await fixture.model.start()
        fixture.model.select(fixture.ids[0])
        #expect(!fixture.model.tabStripIsVisible)
        // One tab: the unchanged 52 pt block (36 pt row + 16 pt spacing above the terminal).
        #expect(topBlockHeight(fixture.model) == LoomTheme.Layout.headerHeight)
        fixture.model.openTab(fixture.ids[0])
        fixture.model.select(fixture.ids[1])
        #expect(fixture.model.tabStripIsVisible)
        // Two tabs: row and strip touch (36 + 32 pt), as in the approved preview.
        #expect(topBlockHeight(fixture.model) == LoomTheme.Layout.detailRowHeight + LoomTheme.TabStrip.height)
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let catalog: SessionCatalog
        let preferences: UIPreferencesStore
        let model: CatalogModel
        let ids: [UUID]
        var preferencesURL: URL { root.appendingPathComponent("ui-preferences.json") }
    }

    private func makeFixture(rows: Int, preselect: [UUID] = []) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-strip-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for index in 0..<rows {
            let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
            ids.append(session.id)
            try await catalog.insertSession(
                session, title: "Row \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle)
        }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        if !preselect.isEmpty { try preferences.update { $0.openTabs = preselect } }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(), preferences: preferences)
        model.preferenceWriteDelay = .milliseconds(40)
        return Fixture(root: root, catalog: catalog, preferences: preferences, model: model, ids: ids)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.model.stop()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    // MARK: Keyboard commands on the model

    @Test func nextAndPreviousWalkPinnedTabsThenTheTransientOneAndWrap() async throws {
        let fixture = try await makeFixture(rows: 5)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.ids
        fixture.model.openTab(ids[0])
        fixture.model.openTab(ids[1])
        fixture.model.select(ids[2]) // transient, last
        #expect(fixture.model.visibleTabIDs == [ids[0], ids[1], ids[2]])
        #expect(fixture.model.selectAdjacentTab(.next))
        #expect(fixture.model.selectedSessionID == ids[0]) // wraps; the transient tab goes away
        #expect(fixture.model.visibleTabIDs == [ids[0], ids[1]])
        #expect(fixture.model.selectAdjacentTab(.next))
        #expect(fixture.model.selectedSessionID == ids[1])
        #expect(fixture.model.selectAdjacentTab(.previous))
        #expect(fixture.model.selectedSessionID == ids[0])
        #expect(fixture.model.selectAdjacentTab(.previous))
        #expect(fixture.model.selectedSessionID == ids[1]) // wraps backwards
        #expect(fixture.model.tabs.pinned == [ids[0], ids[1]]) // walking pins nothing
    }

    @Test func withoutASelectionNextPicksTheFirstTabAndPreviousTheLast() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        await fixture.model.start()
        for id in fixture.ids { fixture.model.openTab(id) }
        fixture.model.select(nil)
        #expect(fixture.model.selectAdjacentTab(.next))
        #expect(fixture.model.selectedSessionID == fixture.ids[0])
        fixture.model.select(nil)
        #expect(fixture.model.selectAdjacentTab(.previous))
        #expect(fixture.model.selectedSessionID == fixture.ids[2])
    }

    @Test func commandsDoNothingWhileTheStripIsHidden() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        await fixture.model.start()
        fixture.model.select(fixture.ids[0])
        #expect(!fixture.model.tabStripIsVisible)
        #expect(!fixture.model.canSelectAdjacentTab)
        #expect(!fixture.model.canCloseSelectedTab)
        #expect(!fixture.model.selectAdjacentTab(.next))
        fixture.model.closeSelectedTab()
        #expect(fixture.model.selectedSessionID == fixture.ids[0])
        fixture.model.openTab(fixture.ids[0])
        #expect(!fixture.model.tabStripIsVisible) // one pinned tab is still one tab
        fixture.model.select(fixture.ids[1])
        #expect(fixture.model.tabStripIsVisible && fixture.model.canSelectAdjacentTab && fixture.model.canCloseSelectedTab)
    }

    @Test func closeTabClosesTheSelectedOneAndShowsItsNeighbor() async throws {
        let fixture = try await makeFixture(rows: 4)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.ids
        for id in ids.prefix(3) { fixture.model.openTab(id) }
        fixture.model.select(ids[1])
        fixture.model.closeSelectedTab()
        #expect(fixture.model.tabs.pinned == [ids[0], ids[2]])
        #expect(fixture.model.selectedSessionID == ids[2]) // right neighbor
        fixture.model.closeSelectedTab()
        #expect(fixture.model.selectedSessionID == ids[0])
        #expect(!fixture.model.tabStripIsVisible) // one tab left: strip hidden, nothing more to close
        fixture.model.closeSelectedTab()
        #expect(fixture.model.selectedSessionID == ids[0])
        // A transient last tab closes to its left neighbor and was never pinned.
        fixture.model.select(ids[3])
        #expect(fixture.model.isTransientTab(ids[3]))
        fixture.model.closeSelectedTab()
        #expect(fixture.model.selectedSessionID == ids[0])
        #expect(fixture.model.tabs.pinned == [ids[0]])
    }

    @Test func selectTabShowsTheTabWithoutPinningAndTransientIsTheUnpinnedSelection() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.ids
        fixture.model.openTab(ids[0])
        fixture.model.selectTab(ids[1])
        #expect(fixture.model.selectedSessionID == ids[1])
        #expect(fixture.model.isTransientTab(ids[1]))
        #expect(!fixture.model.isTransientTab(ids[0]))
        #expect(fixture.model.tabs.pinned == [ids[0]])
        fixture.model.selectTab(ids[0])
        #expect(!fixture.model.isTransientTab(ids[0]))
        #expect(fixture.model.visibleTabIDs == [ids[0]])
    }

    @Test func unpinningTheSelectedTabKeepsItShownAsTheTransientTabAndPersists() async throws {
        let fixture = try await makeFixture(rows: 3)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let ids = fixture.ids
        fixture.model.openTab(ids[0])
        fixture.model.openTab(ids[1])
        fixture.model.unpinTab(ids[1])
        #expect(fixture.model.selectedSessionID == ids[1])
        #expect(fixture.model.isTransientTab(ids[1]))
        #expect(fixture.model.visibleTabIDs == [ids[0], ids[1]])
        fixture.model.flushPreferences()
        #expect(UIPreferencesStore(url: fixture.preferencesURL).current.openTabs == [ids[0]])
    }

    @Test func aTabRowThatLoadsLaterInvalidatesWhatTheStripRead() async throws {
        let base = try await makeFixture(rows: 2)
        defer { cleanup(base) }
        let id = base.ids[0]
        try base.preferences.update { $0.openTabs = [id] }
        // A fresh model: the tab is pinned but its row is not read until start().
        let model = CatalogModel(catalog: base.catalog, events: SessionEventHub(), preferences: base.preferences)
        defer { model.stop() }
        #expect(model.tabRow(id) == nil)
        let invalidated = Flag()
        withObservationTracking({ _ = model.tabRow(id) }, onChange: { invalidated.set() })
        await model.start()
        #expect(model.tabRow(id) != nil)
        #expect(invalidated.value)
    }
}
