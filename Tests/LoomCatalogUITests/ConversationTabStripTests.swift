import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

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

    // MARK: Drops (W3-b)

    @Test func aDropLandsInTheGapNearestThePointerAndTheMarkStandsInThatGap() {
        let layout = TabStripLayout(count: 3, width: 904) // three 230 pt tabs, 4 pt apart, from x = 8
        let inset = LoomTheme.TabStrip.inset, step = layout.tabWidth + LoomTheme.TabStrip.gap
        #expect(layout.dropGap(atX: 0, scrollOffset: 0) == 0)
        #expect(layout.dropGap(atX: inset + 100, scrollOffset: 0) == 0, "the first tab's left half")
        #expect(layout.dropGap(atX: inset + 130, scrollOffset: 0) == 1, "its right half")
        #expect(layout.dropGap(atX: inset + step + 200, scrollOffset: 0) == 2)
        #expect(layout.dropGap(atX: inset + 2 * step + 200, scrollOffset: 0) == 3)
        #expect(layout.dropGap(atX: 880, scrollOffset: 0) == 3, "past the tabs, over the + button: the end")
        #expect(layout.insertionX(forGap: 0, scrollOffset: 0) == inset)
        #expect(layout.insertionX(forGap: 1, scrollOffset: 0) == inset + step - LoomTheme.TabStrip.gap / 2)
        #expect(layout.insertionX(forGap: 3, scrollOffset: 0) == inset + layout.listWidth)
        // An empty strip shown as a drop zone takes the drop as its first tab.
        #expect(TabStripLayout(count: 0, width: 904).dropGap(atX: 300, scrollOffset: 0) == 0)
        // A scrolled strip counts the tabs scrolled out at the leading edge.
        let scrolled = TabStripLayout(count: 8, width: 464)
        let tab = scrolled.tabWidth + LoomTheme.TabStrip.gap
        #expect(scrolled.dropGap(atX: inset + 10, scrollOffset: 2 * tab) == 2)
    }

    @Test func theStripTakesASessionAndRefusesAnythingElse() async throws {
        let id = UUID()
        let session = SessionDrag.itemProvider(for: id, title: "Fix the build")
        #expect(SessionDrag.accepts([session]))
        #expect(await SessionDrag.sessionID(from: [session]) == id)
        // Text, even text that is a session's id, and a file are not sessions.
        let text = NSItemProvider(object: id.uuidString as NSString)
        let file = NSItemProvider(contentsOf: URL(fileURLWithPath: "/tmp"))!
        for other in [text, file] {
            #expect(!SessionDrag.accepts([other]))
            #expect(await SessionDrag.sessionID(from: [other]) == nil)
        }
        #expect(!SessionDrag.accepts([]))
        #expect(SessionDrag.accepts([text, session]))
        #expect(await SessionDrag.sessionID(from: [text, session]) == id, "the session among other items")
    }

    /// The room for tabs is the row without its "+" button and its gap.
    private let plus = TabStripLayout.plusReserve

    @Test func tabsShareTheWidthBetweenMinimumAndMaximum() {
        // Detail pane at the default 1220 pt window with a 300 pt sidebar: 904 pt of row.
        let two = TabStripLayout(count: 2, width: 904)
        #expect(two.tabWidth == LoomTheme.TabStrip.maxTabWidth && LoomTheme.TabStrip.maxTabWidth == 230)
        #expect(!two.overflows)
        let six = TabStripLayout(count: 6, width: 904)
        #expect(!six.overflows)
        #expect(abs(six.tabWidth - (904 - 16 - plus - 5 * 4) / 6) < 0.001) // about 137 pt: the "+" button takes its place
        // The list is the tabs themselves, so the "+" button follows the last one.
        #expect(abs(two.listWidth - (2 * 230 + 4)) < 0.001)
        #expect(abs(six.listWidth - (904 - 16 - plus)) < 0.001)
    }

    @Test func tabsStopAtTheMinimumThenTheStripScrollsWithAChevron() {
        let five = TabStripLayout(count: 5, width: 904)
        #expect(!five.overflows)
        let eightWide = TabStripLayout(count: 8, width: 904)
        #expect(eightWide.overflows) // 8 x 112 + 7 x 4 = 924 pt, over the 860 pt the row leaves
        #expect(eightWide.tabWidth == LoomTheme.TabStrip.minTabWidth)
        #expect(eightWide.listWidth == 904 - 16 - plus - LoomTheme.TabStrip.gap - LoomTheme.TabStrip.overflowWidth)
        let eightNarrow = TabStripLayout(count: 8, width: 464) // 780 pt window, 300 pt sidebar
        #expect(eightNarrow.overflows && eightNarrow.tabWidth == LoomTheme.TabStrip.minTabWidth)
        let twoNarrow = TabStripLayout(count: 2, width: 464)
        #expect(!twoNarrow.overflows)
        // The boundary: exactly fitting is not an overflow, one point less is.
        let exact = 4 * 112 + 3 * 4 + 16 + plus
        #expect(!TabStripLayout(count: 4, width: exact).overflows)
        #expect(TabStripLayout(count: 4, width: exact - 1).overflows)
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

    @Test func aLeadingFadeShowsOnlyWhenAnOverflowingListIsScrolled() {
        let layout = TabStripLayout(count: 8, width: 464)
        #expect(!layout.showsLeadingFade(scrollOffset: 0), "at the start nothing is cut on the left")
        #expect(layout.showsLeadingFade(scrollOffset: layout.tabWidth / 2), "a half-hidden first tab")
        #expect(!TabStripLayout(count: 3, width: 904).showsLeadingFade(scrollOffset: 40), "no overflow, no fade")
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

    // MARK: The header and the tab row (DESIGN §6 Tabs)

    private func fittingHeight<Content: View>(_ content: Content) -> CGFloat {
        let hosting = NSHostingView(rootView: content.frame(width: 800))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// The header is 52 pt and the tab row 36 pt under it, in the content column; a single tab draws no row.
    @Test func theHeaderIs52AndTheTabRowIs36AndAppearsWithTwoTabs() async throws {
        let fixture = try await makeFixture(rows: 2)
        defer { cleanup(fixture) }
        await fixture.model.start()
        fixture.model.select(fixture.ids[0])
        #expect(!fixture.model.tabStripIsVisible)
        #expect(!DetailHeader.drawsStrip(model: fixture.model, showsSessionHeader: true), "one tab: no row")
        #expect(fittingHeight(DetailHeader(model: fixture.model)) == 52 && LoomTheme.Layout.headerHeight == 52)
        fixture.model.openTab(fixture.ids[0])
        fixture.model.select(fixture.ids[1])
        #expect(fixture.model.tabStripIsVisible)
        #expect(DetailHeader.drawsStrip(model: fixture.model, showsSessionHeader: true), "two tabs: the row")
        #expect(fittingHeight(DetailHeader(model: fixture.model)) == 52, "the row does not change the header")
        #expect(fittingHeight(ConversationTabStrip(model: fixture.model)) == 36 && LoomTheme.TabStrip.height == 36)
    }

    /// A session dragged over the header (or the row it reveals) draws the row as a drop zone with 0 or 1 tabs; it goes when the
    /// drag leaves both. Pages without a session header get no zone.
    @Test func aSessionDraggedOverTheHeaderRevealsTheRowUntilItLeaves() async throws {
        let fixture = try await makeFixture(rows: 2)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let model = fixture.model
        #expect(model.visibleTabIDs.isEmpty)
        #expect(!DetailHeader.drawsStrip(model: model, showsSessionHeader: true))
        model.setTabDropHover(.header, true)
        #expect(DetailHeader.drawsStrip(model: model, showsSessionHeader: true), "0 tabs: the zone")
        #expect(!DetailHeader.drawsStrip(model: model, showsSessionHeader: false), "no session header: no zone")
        #expect(!model.tabStripIsVisible, "the menu commands still see no strip")
        model.select(fixture.ids[0])
        #expect(DetailHeader.drawsStrip(model: model, showsSessionHeader: true), "1 tab: the zone")
        // From the header into the row it revealed, in either order: the zone stays while one of them holds the drag.
        model.setTabDropHover(.strip, true)
        model.setTabDropHover(.header, false)
        #expect(DetailHeader.drawsStrip(model: model, showsSessionHeader: true))
        model.setTabDropHover(.strip, false)
        #expect(!DetailHeader.drawsStrip(model: model, showsSessionHeader: true), "the drag left: no zone")
        #expect(!model.showsTabDropZone)
    }

    @Test func thePagesThatShowNoSessionDrawNoRowEvenWithTwoTabsOpen() async throws {
        let fixture = try await makeFixture(rows: 2)
        defer { cleanup(fixture) }
        await fixture.model.start()
        fixture.model.openTab(fixture.ids[0])
        fixture.model.openTab(fixture.ids[1])
        #expect(fixture.model.tabStripIsVisible && fixture.model.detailRoute.showsSessionHeader)
        #expect(DetailHeader.drawsStrip(model: fixture.model, showsSessionHeader: fixture.model.detailRoute.showsSessionHeader))
        // Home, a draft and a project page: the tabs stay open behind them and the row is not drawn. The row itself (an empty pane,
        // a startup error, a draft's line) is 52 and has no hairline; Home and the project page draw none (`DetailShellTests`).
        fixture.model.showHome()
        #expect(fixture.model.tabStripIsVisible, "the tabs stay open behind Home")
        #expect(!fixture.model.detailRoute.showsSessionHeader)
        #expect(!DetailHeader.drawsStrip(model: fixture.model, showsSessionHeader: false))
        #expect(!DetailHeader.drawsHairline(showsSessionHeader: false, showsDevTerminal: false), "a page's header is bare")
        #expect(DetailHeader.drawsHairline(showsSessionHeader: true, showsDevTerminal: false))
        #expect(fittingHeight(DetailHeader(model: fixture.model, showsSessionHeader: false)) == 52)
        fixture.model.showDraft(projectID: nil)
        #expect(!DetailHeader.drawsStrip(model: fixture.model, showsSessionHeader: fixture.model.detailRoute.showsSessionHeader))
        fixture.model.select(fixture.ids[0])
        #expect(DetailHeader.drawsStrip(model: fixture.model, showsSessionHeader: fixture.model.detailRoute.showsSessionHeader),
                "the row is back with the session")
    }

    /// The v4 tab's size and the existing project tone's hover and selected strengths.
    @Test func aTabHasTheSizesAndTheTintOfInk() {
        typealias T = LoomTheme.TabStrip
        #expect(T.sessionTabHeight == 28 && T.sessionTabRadius == 8 && T.gap == 4 && T.inset == 8 && T.maxTabWidth == 230 && T.minTabWidth == 112)
        #expect(T.close == 16 && T.plus == 24 && LoomTheme.Layout.harnessMarkRow == 12)
        for tone in ProjectTone.allCases {
            let rest = ProjectTabStyle(tone: tone, selected: false, hovering: false)
            let hover = ProjectTabStyle(tone: tone, selected: false, hovering: true)
            let open = ProjectTabStyle(tone: tone, selected: true, hovering: true)
            #expect(rest.wash?.opacity == 0.06 && hover.wash?.opacity == 0.11 && open.wash?.opacity == 0.16, "\(tone)")
            #expect(rest.stroke == nil && hover.stroke == nil)
            #expect(open.stroke?.standard.opacity == 0.42 && open.stroke?.standard.rgb == LoomTheme.ProjectColor.baseRGB(tone))
            #expect(open.stroke?.lightStandard.rgb == LoomTheme.ProjectColor.lightBaseRGB(tone))
        }
        let none = ProjectTabStyle(tone: nil, selected: true, hovering: true)
        #expect(none.wash == nil && none.washColor == nil && none.stroke == nil, "no tone: the neutral fills stand in")
    }

    /// The "+" ends the row and does what ⌘N does there: it opens the new-session page of the project on screen.
    @Test func thePlusButtonOpensTheNewSessionPageLikeCommandN() async throws {
        let fixture = try await makeFixture(rows: 2)
        defer { cleanup(fixture) }
        await fixture.model.start()
        let intents = HeaderIntents()   // `CatalogModel.intents` is weak: the test holds the object
        fixture.model.intents = intents
        defer { withExtendedLifetime(intents) {} }
        fixture.model.openTab(fixture.ids[0])
        fixture.model.select(fixture.ids[1])
        #expect(ShellCommand.newSession.keyEquivalent == "n" && ShellCommand.newSession.modifiers == [.command])
        #expect(ShellCommand.newSession.isEnabled(on: fixture.model))

        enableAccessibilityTree()
        let size = NSSize(width: 800, height: LoomTheme.TabStrip.height)
        let hosting = NSHostingController(rootView: ConversationTabStrip(model: fixture.model).frame(width: 800, height: size.height))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let elements = accessibilityElements(in: hosting.view)
        let plus = try #require(elements.first { ($0.accessibilityLabel?() ?? "") == "New session" }, "the + button")
        let frame = try #require(plus.accessibilityFrame?())
        #expect(frame.width >= 24 && frame.height >= 24, "a hit area of at least 24 x 24")
        let tabs = elements.filter { ($0.accessibilityLabel?() ?? "").hasPrefix("Row ") }
        let lastTab = try #require(tabs.compactMap { $0.accessibilityFrame?() }.max { $0.maxX < $1.maxX })
        #expect(abs(frame.minX - lastTab.maxX - LoomTheme.TabStrip.gap) < 1.5, "the + follows the last tab: \(frame) \(lastTab)")

        let context = fixture.model.contextProjectID
        fixture.model.beginNewSession(projectID: context)
        let expected = fixture.model.destination
        fixture.model.select(fixture.ids[1])
        #expect(plus.accessibilityPerformPress?() == true)
        #expect(fixture.model.destination == expected, "the + opens the page ⌘N opens")
        if case .draft = fixture.model.destination {} else { Issue.record("not a draft: \(String(describing: fixture.model.destination))") }
    }

    /// The chevron is a native menu whose label is only a hidden icon: it stays in the accessibility tree, a menu button named
    /// "All tabs" (ARCHITECTURE §12.1).
    @Test func theChevronIsAMenuButtonNamedAllTabs() async throws {
        let fixture = try await makeFixture(rows: 10)
        defer { cleanup(fixture) }
        await fixture.model.start()
        for id in fixture.ids { fixture.model.openTab(id) }
        #expect(TabStripLayout(count: 10, width: 800).overflows)

        enableAccessibilityTree()
        let size = NSSize(width: 800, height: LoomTheme.TabStrip.height)
        let hosting = NSHostingController(rootView: ConversationTabStrip(model: fixture.model).frame(width: 800, height: size.height))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        #expect(InkAX.menuButtonLabels(in: hosting.view) == ["All tabs"])
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
