import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// The project page in Ink (I4c; DESIGN §10): the head on the first 52 pt line and its clearance, the stats line's words, the view
/// tabs, the session row's structured last line and layout, the project menu's items and order, the empty project and the narrow
/// layout. The reads, the lazy rows and the presets are `ProjectPageTests`.
@MainActor
struct ProjectPageInkPureTests {
    // MARK: The head keeps clear of what floats over it

    @Test func theHeadStartsAtTheLargerOfTheColumnsInsetAndTheClearance() {
        let collapsed = DetailPageChrome.leadingClearance(sidebarCollapsed: true, isFullScreen: false)
        let fullScreen = DetailPageChrome.leadingClearance(sidebarCollapsed: true, isFullScreen: true)
        #expect(collapsed == 130 && fullScreen == 56)
        // A 1,000 wide pane: the column's edge is its 32 inset.
        #expect(ProjectPageLayout.columnEdge(paneWidth: 1_000) == 32)
        #expect(ProjectPageLayout.headLeadingExtra(paneWidth: 1_000, clearance: 0) == 0, "sidebar open")
        #expect(ProjectPageLayout.headLeadingExtra(paneWidth: 1_000, clearance: collapsed) == 98)
        #expect(ProjectPageLayout.headLeadingExtra(paneWidth: 1_000, clearance: fullScreen) == 24)
        // A wide pane centres the column: its edge is past the clearance already.
        #expect(ProjectPageLayout.columnEdge(paneWidth: 1_400) == 232)
        #expect(ProjectPageLayout.headLeadingExtra(paneWidth: 1_400, clearance: collapsed) == 0)
        // Under 760 the inset is 20.
        #expect(ProjectPageLayout.columnEdge(paneWidth: 700) == 20)
        #expect(ProjectPageLayout.headLeadingExtra(paneWidth: 700, clearance: collapsed) == 110)
    }

    @Test func theProjectPageDrawsNoPreparingNoticeOverItsHead() {
        // The head holds the line (DESIGN §10 Head): the floating notice is left out there, and kept on Home's free line.
        #expect(!DetailPageChrome.showsNotice(on: .projectPage(projectID: UUID())))
        #expect(DetailPageChrome.showsNotice(on: .home))
    }

    @Test func theColumnIsWideFrom760AndInsetsTwentyBelow() {
        #expect(ProjectPageLayout.isWide(paneWidth: 760) && !ProjectPageLayout.isWide(paneWidth: 759))
        #expect(ProjectPageLayout.inset(paneWidth: 760) == 32 && ProjectPageLayout.inset(paneWidth: 759) == 20)
        #expect(LoomTheme.ProjectPage.headHeight == 52 && LoomTheme.ProjectPage.maxWidth == 1_000)
    }

    // MARK: The stats line

    @Test func theStatsLineCountsOnlyWhatThereIsToCount() {
        typealias Item = ProjectStatsText.Item
        // Nothing running, no usage, outside Git: only the sessions, and an empty project says "0 sessions".
        #expect(ProjectStatsText.items(running: 0, total: 0, tokens: nil, branch: nil) == [.figure(count: 0, noun: "sessions")])
        #expect(ProjectStatsText.items(running: 0, total: 1, tokens: 0, branch: .unavailable) == [.figure(count: 1, noun: "session")])
        let all = ProjectStatsText.items(running: 3, total: 9, tokens: 3_100_000, branch: .named("swarm/1"))
        #expect(all == [.figure(count: 3, noun: "running"), .figure(count: 9, noun: "sessions"),
                        .tokens(figure: UsageFormat.tokens(3_100_000), spoken: UsageFormat.spokenTokens(3_100_000)),
                        .branch("swarm/1")])
        #expect(all.map(\.accessibilityLabel).prefix(2) == ["3 running", "9 sessions"])
        #expect(all.last?.accessibilityLabel == "Branch swarm/1")
        #expect(ProjectStatsText.items(running: 0, total: 4, tokens: nil, branch: .detached).last == .branch("Detached HEAD"))
        let tokens = ProjectStatsText.items(running: 0, total: 4, tokens: 820_000, branch: nil)
        #expect(tokens.count == 2 && tokens[1].accessibilityLabel.hasSuffix("tokens in the past 7 days"))
    }

    // MARK: The view tabs

    @Test func theTabsAreSessionsBranchesAndInstructionsWithTheirCounts() {
        let tabs = ProjectTabsText.items(sessions: 9, branches: 7)
        #expect(tabs.map(\.title) == ["Sessions", "Branches", "Instructions"])
        #expect(tabs.map(\.count) == [9, 7, nil])
        #expect(tabs.map(\.accessibilityLabel) == ["Sessions, 9", "Branches, 7", "Instructions"])
        #expect(tabs.map(\.identifier) == ["project-tab-sessions", "project-tab-branches", "project-tab-instructions"])
        #expect(tabs.map(\.hoverKey) == ["project-tab:Sessions", "project-tab:Branches", "project-tab:Instructions"])
        // Nothing to count, nothing said: no sessions, and branches not read (or none).
        #expect(ProjectTabsText.items(sessions: 0, branches: nil).map(\.count) == [nil, nil, nil])
        #expect(ProjectTabsText.items(sessions: 1, branches: 0).map(\.count) == [1, nil, nil])
        #expect(LoomTheme.ViewTabs.barHeight == 36 && LoomTheme.ViewTabs.gap == 18 && LoomTheme.ViewTabs.underline == 1.5)
    }

    // MARK: The session row

    @Test func aRowsLastLineIsALeadAndAMonoEnd() {
        let approval = StatusReason(.approval(tool: "Bash"), detail: "git push origin main")
        let line = ProjectSessionLine.line(reason: approval, transcript: "old words")
        #expect(line?.lead == "Asks to run: " && line?.mono == "git push origin main")
        #expect(line?.text == "Asks to run: git push origin main")
        // The words are the same as before: `text` is the line's text.
        #expect(ProjectSessionLine.text(reason: approval, transcript: nil) == line?.text)
        // A transcript's words are all lead; a bare "Turn done" gives way to them; nothing gives nothing.
        let transcript = ProjectSessionLine.line(reason: StatusReason(.turnDone), transcript: "Added 12 tests")
        #expect(transcript?.lead == "Added 12 tests" && transcript?.mono == nil)
        #expect(ProjectSessionLine.line(reason: nil, transcript: "") == nil)
        let question = ProjectSessionLine.line(reason: StatusReason(.question, detail: "Which branch?"), transcript: nil)
        #expect(question?.text == "Asks: Which branch?" && question?.mono == nil)
    }

    @Test func aRowLaysOutAsTheReferenceDoes() {
        let page = LoomTheme.ProjectPage.self
        #expect(page.rowColumnGap == 10 && page.rowPaddingH == 12 && page.rowPaddingTop == 8 && page.rowPaddingBottom == 9)
        #expect(page.rowRadius == 8 && page.rowPillGap == 2)
        #expect(page.rowTitleHeight == 18 && page.rowLineHeight == 17 && page.rowLineTop == 1)
        #expect(page.rowBranchWidth == 170 && page.rowTimeWidth == 44 && page.rowBranchGap == 5 && page.rowBranchBreakpoint == 460)
        #expect(page.rowTitle.size == 13 && page.rowTitle.weight == .medium)
        #expect(page.rowLine.size == 12 && page.rowLineMono.size == 11.5 && page.rowLineMono.mono)
        #expect(page.rowBranch.size == 11.5 && page.rowBranch.mono && page.rowTime.size == 11.5 && page.rowTime.mono)
        // The branch drops under 460 and outside Git; the time keeps its column.
        #expect(ProjectRowLayout.showsBranch(rowWidth: 460, branch: .named("main")))
        #expect(!ProjectRowLayout.showsBranch(rowWidth: 459, branch: .named("main")))
        #expect(!ProjectRowLayout.showsBranch(rowWidth: 900, branch: nil))
        #expect(!ProjectRowLayout.showsBranch(rowWidth: 900, branch: .unavailable))
        #expect(ProjectRowLayout.showsBranch(rowWidth: 900, branch: .detached))
    }

    // MARK: The side cards

    @Test func theSideCardsAndTheirLinesCarryDesignsValues() {
        let page = LoomTheme.ProjectPage.self
        #expect(page.cardRadius == 12 && page.cardPadding == 16 && page.sideColumn == 300 && page.columnGap == 20)
        #expect(page.blockGap == 14 && page.statGap == 8 && page.presetHeight == 28 && page.presetBleed == 8)
        #expect(page.cardTitle.size == 13 && page.cardTitle.weight == .semibold && page.cardNote.size == 11 && page.cardNote.mono)
        #expect(page.statFigure.size == 18 && page.statFigure.weight == .semibold && page.statLabel.size == 11.5)
        #expect(ProjectUsageText.line(loading: true, failed: false) == "Reading usage\u{2026}")
        #expect(ProjectUsageText.line(loading: false, failed: true) == "Could not read this project's usage.")
        #expect(ProjectUsageText.line(loading: false, failed: false) == "No usage in the past 7 days.")
        #expect(ProjectPresetText.empty == "Save a first message as a preset from a new session, and it shows up here.")
    }

    @Test func aPresetsTooltipSaysItsModeAndModelThenItsMessage() {
        let own = NewSessionPreset(name: "Run tests", message: "Run the tests", permissionMode: "acceptEdits", model: "sonnet",
                                   projectID: UUID())
        #expect(ProjectPresetText.tooltip(own, catalog: ModelCatalog()) == "Accept edits \u{00B7} Sonnet\nRun the tests")
        let shared = NewSessionPreset(name: "Explain", message: "Explain this folder", permissionMode: "ask", model: "haiku")
        #expect(ProjectPresetText.summary(shared, catalog: ModelCatalog()) == "All projects \u{00B7} Ask \u{00B7} Haiku")
        #expect(ProjectPresetText.tooltip(NewSessionPreset(name: "x", message: "m", projectID: UUID()), catalog: ModelCatalog()) == "m")
    }

    // MARK: The narrow layout and the empty project

    @Test func theNarrowLayoutPutsPresetsAboveTheListAndThePastWeekBelow() {
        #expect(ProjectSessionsLayout.arrangement(wide: false) == .init(main: [.presets, .list, .usage], side: []))
        #expect(ProjectSessionsLayout.arrangement(wide: true) == .init(main: [.list], side: [.presets, .usage]))
        #expect(ProjectEmptyList.line == "No sessions in this project yet. New session starts one.")
    }

    // MARK: The project menu

    private func starts(codex: Bool) -> [ProjectMenuPlan.Start] {
        [ProjectMenuPlan.Start(provider: .claude, title: "New Claude Session", enabled: true, reason: nil),
         ProjectMenuPlan.Start(provider: .codex, title: "New Codex Session", enabled: codex,
                               reason: codex ? nil : CatalogModel.codexLaterReason)]
    }

    @Test func theMenuListsNewSessionsColorMoveAndRemoveInDesignsOrder() {
        let plan = ProjectMenuPlan.make(starts: starts(codex: true), colorsEnabled: true, index: 1, count: 3, sessions: 0)
        #expect(plan.entries == [
            .start(provider: .claude, title: "New Claude Session", enabled: true),
            .start(provider: .codex, title: "New Codex Session", enabled: true),
            .divider, .color,
            .divider, .moveUp(enabled: true), .moveDown(enabled: true),
            .divider, .removeEmpty(enabled: true),
        ])
    }

    @Test func theMenusItemsAreOffWhereTheyDoNotApplyAndSayWhy() {
        // The first project cannot move up and the last cannot move down.
        let first = ProjectMenuPlan.make(starts: starts(codex: true), colorsEnabled: true, index: 0, count: 3, sessions: 0)
        #expect(first.entries.contains(.moveUp(enabled: false)) && first.entries.contains(.moveDown(enabled: true)))
        let last = ProjectMenuPlan.make(starts: starts(codex: true), colorsEnabled: true, index: 2, count: 3, sessions: 0)
        #expect(last.entries.contains(.moveUp(enabled: true)) && last.entries.contains(.moveDown(enabled: false)))
        let only = ProjectMenuPlan.make(starts: starts(codex: true), colorsEnabled: true, index: 0, count: 1, sessions: 0)
        #expect(only.entries.contains(.moveUp(enabled: false)) && only.entries.contains(.moveDown(enabled: false)))
        // Remove only for an empty project; otherwise it says why.
        let busy = ProjectMenuPlan.make(starts: starts(codex: true), colorsEnabled: true, index: 1, count: 3, sessions: 4)
        #expect(Array(busy.entries.suffix(3)) == [.divider, .removeEmpty(enabled: false), .note(ProjectMenuPlan.removeNote)])
        // Codex stays listed, off, with the reason after it, in a build that cannot start it.
        let noCodex = ProjectMenuPlan.make(starts: starts(codex: false), colorsEnabled: true, index: 1, count: 3, sessions: 0)
        #expect(Array(noCodex.entries.prefix(3)) == [
            .start(provider: .claude, title: "New Claude Session", enabled: true),
            .start(provider: .codex, title: "New Codex Session", enabled: false),
            .note("Codex comes in a later version"),
        ])
        // With Project colors off Color goes, and no divider is left doubled.
        let plain = ProjectMenuPlan.make(starts: starts(codex: true), colorsEnabled: false, index: 1, count: 3, sessions: 0)
        #expect(!plain.entries.contains(.color))
        #expect(plain.entries.firstIndex(of: .divider) != nil)
        for (before, after) in zip(plain.entries, plain.entries.dropFirst()) { #expect(!(before == .divider && after == .divider)) }
        #expect(plain.entries.first != .divider && plain.entries.last != .divider)
    }
}

/// The page hosted in a window that is never ordered front: where its parts land.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProjectPageInkViewTests {
    private struct Rig {
        let root: URL
        let model: CatalogModel
        let project: CatalogProject
    }

    private func rig(sessions: Int, startable: Set<ManagedSession.Provider> = [.claude, .codex]) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-project-ink-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        for index in 0..<sessions {
            let session = ManagedSession(provider: .claude, providerConversationID: "conv-\(index)", workingDirectory: folder.path)
            let used = Date().addingTimeInterval(-TimeInterval(3_600 * (index + 1)))
            try await catalog.insertSession(session, title: "Session \(index)", createdAt: used, lastUsedAt: used, lifecycle: .idle,
                                            projectID: project.id)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")),
                                 startableProviders: startable)
        model.claudeConfigDirectory = root.appendingPathComponent("claude-config", isDirectory: true)
        await model.start()
        return Rig(root: root, model: model, project: project)
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat = 800) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, rounds: Int = 15) async {
        for _ in 0..<rounds {
            try? await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// An element's frame in the window's top-left coordinates.
    private func frame(_ identifier: String, in hosting: NSView, window: NSWindow) -> CGRect? {
        let element = accessibilityElements(in: hosting).first { $0.accessibilityIdentifier?() == identifier }
        guard let screen = element?.accessibilityFrame?() else { return nil }
        let origin = window.frame.origin
        return CGRect(x: screen.minX - origin.x, y: window.frame.height - (screen.maxY - origin.y), width: screen.width, height: screen.height)
    }

    @Test func theHeadIsOnTheFirst52PointsAndKeepsClearOfTheFloatingButtons() async throws {
        enableAccessibilityTree()
        let rig = try await rig(sessions: 2)
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        func head(clearance: CGFloat) async -> (name: CGRect, new: CGRect, actions: CGRect) {
            let view = ProjectPageView(model: rig.model, projectID: rig.project.id).environment(\.detailLeadingClearance, clearance)
            let (window, hosting) = host(view, width: 940)
            defer { window.contentView = nil; window.close() }
            await settle(window)
            return (frame("project-name", in: hosting, window: window) ?? .zero, frame("project-new-session", in: hosting, window: window) ?? .zero,
                    frame("project-actions", in: hosting, window: window) ?? .zero)
        }
        let open = await head(clearance: 0)
        let collapsed = await head(clearance: DetailPageChrome.leadingClearance(sidebarCollapsed: true, isFullScreen: false))
        // The name is the page's first line: centred 26 from the top, in the header's 52.
        #expect(open.name.height > 0 && open.name.midY > 0 && open.name.midY < 52, "\(open.name)")
        #expect(abs(open.new.midY - 26) < 2 && abs(open.actions.midY - 26) < 2, "\(open.new) \(open.actions)")
        // The mark (26) and a gap (10) start at the column's 32 inset: the name begins 36 later; clear of the buttons it moves right.
        #expect(abs(open.name.minX - (32 + 26 + 10)) < 2, "\(open.name)")
        #expect(abs(collapsed.name.minX - open.name.minX - 98) < 2, "open \(open.name) collapsed \(collapsed.name)")
        // A start that prepares does not move the head: the notice is not drawn on this page.
        rig.model.beginStart(StartKey(provider: .claude, projectID: rig.project.id))
        #expect(rig.model.preparingNotice != nil)
        let preparing = await head(clearance: 0)
        #expect(abs(preparing.name.minX - open.name.minX) < 1, "open \(open.name) preparing \(preparing.name)")
        // At the trailing edge, ⋯ then New session, 8 apart, 32 from the edge.
        #expect(abs(open.new.maxX - (940 - 32)) < 2 && abs(open.actions.maxX + 8 - open.new.minX) < 2, "\(open.actions) \(open.new)")
    }

    /// The brightest red value of the pixels in `columns` of a rendering of `view` on black, in the dark appearance.
    private func peak<V: View>(_ view: V, size: CGSize, columns: [ClosedRange<Int>]) async -> [CGFloat] {
        let (window, hosting) = host(view.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height, alignment: .leading)
            .background(Color.black), width: size.width, height: size.height)
        defer { window.contentView = nil; window.close() }
        await settle(window, rounds: 4)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return [] }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
        return columns.map { range in
            var best: CGFloat = 0
            for x in Int(CGFloat(range.lowerBound) * scale)...Int(CGFloat(range.upperBound) * scale) {
                for y in 0..<rep.pixelsHigh {
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { best = max(best, color.redComponent) }
                }
            }
            return best
        }
    }

    @Test func aLastLinesMonoEndIsPrimaryAndItsWordsAreSecondary() async throws {
        let line = SessionReasonLine(text: "Asks to run: git push origin main", mono: "git push origin main")
        let peaks = await peak(ProjectLastLineText(line: line), size: CGSize(width: 300, height: 24), columns: [2...60, 100...200])
        // Primary is #ECECEF and secondary #9E9EA8 in Ink: the words stay near the second, the command reaches the first.
        #expect(peaks.count == 2 && peaks[0] < 0.70 && peaks[0] > 0.4 && peaks[1] > 0.85, "\(peaks)")
    }

    @Test func theNarrowPageStacksPresetsTheListAndThePastWeek() async throws {
        enableAccessibilityTree()
        let rig = try await rig(sessions: 3)
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        func blocks(width: CGFloat) async -> (presets: CGRect, row: CGRect, usage: CGRect)? {
            let (window, hosting) = host(ProjectPageView(model: rig.model, projectID: rig.project.id), width: width)
            defer { window.contentView = nil; window.close() }
            await settle(window)
            guard let presets = frame("project-presets", in: hosting, window: window),
                  let row = frame("project-session-row", in: hosting, window: window),
                  let usage = frame("project-usage", in: hosting, window: window) else { return nil }
            return (presets, row, usage)
        }
        let narrow = try #require(await blocks(width: 700))
        #expect(narrow.presets.maxY <= narrow.row.minY + 1 && narrow.row.maxY <= narrow.usage.minY + 1, "\(narrow)")
        #expect(abs(narrow.presets.minX - 20) < 2, "narrow inset is 20: \(narrow.presets)")
        let wide = try #require(await blocks(width: 1_000))
        #expect(wide.presets.minX > wide.row.maxX - 1 && wide.usage.minX > wide.row.maxX - 1, "\(wide)")
        #expect(wide.presets.maxY <= wide.usage.minY + 1 && abs(wide.presets.width - 300) < 2, "\(wide)")
        #expect(abs(wide.usage.minY - wide.presets.maxY - 14) < 2, "the cards are 14 apart: \(wide)")
    }

    @Test func anEmptyProjectSaysOneLineInTheListsPlaceAndKeepsItsCards() async throws {
        enableAccessibilityTree()
        let rig = try await rig(sessions: 0)
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let (window, hosting) = host(ProjectPageView(model: rig.model, projectID: rig.project.id), width: 940)
        defer { window.contentView = nil; window.close() }
        await settle(window, rounds: 25)
        let elements = accessibilityElements(in: hosting)
        let ids = elements.compactMap { $0.accessibilityIdentifier?() }
        #expect(ids.contains("project-no-sessions") && !ids.contains("project-session-row"))
        #expect(ids.contains("project-presets") && ids.contains("project-usage"))
        let labels = elements.compactMap { $0.accessibilityLabel?() }
        #expect(labels.contains("0 sessions"), "\(labels)")
        #expect(frame("project-no-sessions", in: hosting, window: window) != nil)
    }

    @Test func theTabsShowTheirCountsAndTheMenuHoldsTheModelsAnswers() async throws {
        enableAccessibilityTree()
        let rig = try await rig(sessions: 4, startable: [.claude])
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let (window, hosting) = host(ProjectPageView(model: rig.model, projectID: rig.project.id), width: 940)
        defer { window.contentView = nil; window.close() }
        await settle(window, rounds: 25)
        let labels = accessibilityElements(in: hosting).compactMap { $0.accessibilityLabel?() }
        #expect(labels.contains("Sessions, 4") && labels.contains("Instructions"), "\(labels)")
        // The model's own answers feed the plan: Codex off with its reason, Remove off for a project with sessions.
        let plan = ProjectMenuPlan.make(model: rig.model, project: rig.project)
        #expect(plan.entries.contains(.start(provider: .codex, title: "New Codex Session", enabled: false)))
        #expect(plan.entries.contains(.note("Codex comes in a later version")))
        #expect(plan.entries.contains(.removeEmpty(enabled: false)))
    }
}
