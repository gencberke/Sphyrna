import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// The subagent tree under a session card (D-39): the content rules as a plain value, and the real
/// sidebar in a window that is never ordered front.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SubagentTreeTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func running(_ id: String, _ type: String = "Explore", _ description: String? = "Find login flow handlers",
                         depth: Int = 1, started: TimeInterval = 0) -> SubagentRecord {
        SubagentRecord(id: id, agentType: type, description: description, depth: depth,
                       startedAt: t0.addingTimeInterval(started))
    }

    private func finished(_ id: String, took: TimeInterval = 18, _ description: String? = "List migration files") -> SubagentRecord {
        var record = running(id, "Explore", description)
        record.endedAt = t0.addingTimeInterval(took)
        return record
    }

    private func content(_ records: [SubagentRecord], now: TimeInterval = 0, finished: Bool = false, more: Bool = false)
        -> SubagentTreeContent {
        SubagentTreeContent(records: records, now: t0.addingTimeInterval(now), finishedExpanded: finished, runningExpanded: more)
    }

    // MARK: Content

    @Test func aSessionWithoutSubagentsHasNoTree() {
        #expect(content([]).isEmpty)
    }

    @Test func runningRowsShowTypeDescriptionAndElapsedTimeOnTheMinuteTick() {
        let rows = content([running("a"), running("b", "implementer", "Fix token refresh race", started: -130)]).rows
        #expect(rows.map(\.title) == ["Explore", "implementer"])
        #expect(rows.map(\.detail) == ["Find login flow handlers", "Fix token refresh race"])
        #expect(rows.map(\.trailing) == ["now", "2m"])
        #expect(rows.allSatisfy { $0.kind == .running && $0.opensSubagent })
        // Elapsed time follows `now`, nothing else.
        #expect(content([running("a")], now: 3 * 60).rows.map(\.trailing) == ["3m"])
        #expect(content([running("a")], now: 2 * 3600).rows.map(\.trailing) == ["2h"])
    }

    @Test func aRunningRowWithoutADescriptionYetShowsOnlyTheType() {
        let row = content([running("a", "Explore", nil)]).rows[0]
        #expect(row.detail == nil && row.accessibilityLabel == "Subagent Explore, running")
    }

    @Test func accessibilityReadsTypeDescriptionAndState() {
        #expect(content([running("a")]).rows[0].accessibilityLabel == "Subagent Explore, Find login flow handlers, running")
        let done = content([finished("f")], finished: true).rows
        #expect(done[1].accessibilityLabel == "Subagent Explore, List migration files, finished")
    }

    @Test func atMostThreeRunningRowsThenAMoreRowThatExpandsAndCollapses() {
        let records = (0..<5).map { running("r\($0)", "Explore", "task \($0)") }
        let folded = content(records).rows
        #expect(folded.map(\.id) == ["r0", "r1", "r2", "more"])
        #expect(folded[3].title == "+2 more" && folded[3].kind == .more(expanded: false) && !folded[3].opensSubagent)
        let open = content(records, more: true).rows
        #expect(open.map(\.id) == ["r0", "r1", "r2", "r3", "r4", "more"])
        #expect(open[5].title == "Show fewer" && open[5].kind == .more(expanded: true))
        // Exactly three: no more row.
        #expect(content(Array(records.prefix(3))).rows.map(\.id) == ["r0", "r1", "r2"])
    }

    @Test func finishedOnesFoldIntoOneRowThatExpandsToTheirRows() {
        let records = [running("busy"), finished("f1", took: 18), finished("f2", took: 125)]
        let folded = content(records).rows
        #expect(folded.map(\.id) == ["busy", "finished"])
        #expect(folded[1].title == "2 finished" && folded[1].kind == .finishedFold(expanded: false) && !folded[1].opensSubagent)
        let open = content(records, finished: true).rows
        #expect(open.map(\.id) == ["busy", "finished", "f1", "f2"])
        #expect(open[1].kind == .finishedFold(expanded: true))
        // A finished row shows its static duration, seconds included.
        #expect(open[2].trailing == "18s" && open[3].trailing == "2m")
        #expect(open[2].kind == .finished && open[2].opensSubagent)
    }

    @Test func withOnlyFinishedSubagentsOnlyTheFoldRowShows() {
        #expect(content([finished("f1")]).rows.map(\.title) == ["1 finished"])
        #expect(content([finished("f1")]).rows[0].accessibilityLabel == "1 subagent finished")
        #expect(content([finished("f1"), finished("f2")]).rows[0].accessibilityLabel == "2 subagents finished")
        #expect(content([finished("f1")]).rows[0].accessibilityValue == "collapsed")
    }

    @Test func aClickOpensTheSubagentsPanelOrTogglesAFold() {
        let rows = content((0..<4).map { running("r\($0)") } + [finished("f1")], finished: true).rows
        #expect(rows.map(\.tap) == [.openSubagent, .openSubagent, .openSubagent, .toggleRunning, .toggleFinished, .openSubagent])
    }

    @Test func aNestedSubagentBranchesOneStepFurtherPerLevel() {
        let rows = content([running("a"), running("b", depth: 2), running("c", depth: 3)]).rows
        #expect(rows.map(\.depth) == [1, 2, 3])
    }

    // MARK: Branches (A8)

    private typealias Segment = SubagentBranches.Segment

    @Test func theBranchGeometryIsInksOwn() {
        typealias M = LoomTheme.Branches
        // The status column at 22, one step of 19, 24 pt rows, a 7 pt curve into a 9 pt arm, a 1 pt line.
        #expect(M.column == 22 && M.step == 19 && M.rowHeight == 24)
        #expect(M.curveRadius == 7 && M.arm == 9 && M.overhang == 7 && M.lineWidth == 1)
        #expect(SubagentBranches.x(depth: 1) == 22 && SubagentBranches.x(depth: 2) == 41 && SubagentBranches.x(depth: 3) == 60)
        // The row's mark starts 13 right of its line.
        #expect(SubagentBranches.contentLeading(depth: 1) == 35 && SubagentBranches.contentLeading(depth: 2) == 54)
        #expect(SubagentBranches(depths: [1, 1, 1]).height == 72)
    }

    @Test func theBranchesLeaveTheStatusColumnTheRowsAndHeadsDraw() {
        // The tree has no inset of its own, so the session rows (and the project head's mark above them) must centre
        // their status column on the first branch's line; an activity card's line starts 7 pt under its mark.
        let column = LoomTheme.Branches.column
        #expect(LoomTheme.Sidebar.rowLeading + LoomTheme.Layout.indicatorSlot.width / 2 == column)
        #expect(LoomTheme.Sidebar.headLeading + LoomTheme.ProjectMarkStyle.Size.head.side / 2 == column)
        let trunk = SubagentTrunkShape().path(in: CGRect(x: 0, y: 0, width: 260, height: 60)).boundingRect
        #expect(trunk.minX == column + 0.5 && trunk.minY == LoomTheme.Sidebar.cardTop + 8 + 7 && trunk.maxY == 60)
    }

    @Test func eachRowHangsOnABranchAndTheLastOneEnds() {
        let tree = SubagentBranches(depths: [1, 1, 1])
        #expect(tree.branches.map(\.isLast) == [false, false, true])
        #expect(tree.segments == [
            .turn(x: 22, rowTop: 0), .line(x: 22, from: -7, to: 24),
            .turn(x: 22, rowTop: 24), .line(x: 22, from: 17, to: 48),
            .turn(x: 22, rowTop: 48),
        ])
        // Nothing runs below the last row's curve, and a lone row only curves.
        #expect(SubagentBranches(depths: [1]).segments == [.turn(x: 22, rowTop: 0)])
    }

    @Test func aNestedBranchStepsFurtherAndItsAncestorsLineRunsOnWhileASiblingIsBelow() {
        // a (1) / b (2) / c (2) / d (1): a's line runs beside b and c, because d is a sibling of a below them.
        let tree = SubagentBranches(depths: [1, 2, 2, 1])
        #expect(tree.branches.map(\.isLast) == [false, false, true, true])
        #expect(tree.branches.map(\.passing) == [[], [1], [1], []])
        #expect(tree.segments == [
            .turn(x: 22, rowTop: 0), .line(x: 22, from: -7, to: 24),
            .turn(x: 41, rowTop: 24), .line(x: 41, from: 17, to: 48), .line(x: 22, from: 24, to: 48),
            .turn(x: 41, rowTop: 48), .line(x: 22, from: 48, to: 72),
            .turn(x: 22, rowTop: 72),
        ])
        // With no sibling of a below, its line ends at its own curve and does not run beside the children.
        let ended = SubagentBranches(depths: [1, 2, 2])
        #expect(ended.branches.map(\.isLast) == [true, false, true] && ended.branches.map(\.passing) == [[], [], []])
        // Three levels: the grandchild's two ancestors each run on only while they have a sibling below.
        let deep = SubagentBranches(depths: [1, 2, 3, 2, 1])
        #expect(deep.branches.map(\.passing) == [[], [1], [1, 2], [1], []])
        #expect(deep.branches.map(\.isLast) == [false, false, true, true, true])
    }

    @Test func theTreesRowsGiveTheBranchesTheirDepths() {
        let rows = content([running("a"), running("b", depth: 2), finished("f")], finished: true).rows
        #expect(rows.map(\.id) == ["a", "b", "finished", "f"])
        let tree = SubagentBranches(depths: rows.map(\.depth))
        // The fold row and the finished rows hang on branches like any other row.
        #expect(tree.branches.count == rows.count && tree.branches.last?.isLast == true)
        #expect(tree.height == CGFloat(rows.count) * 24)
    }

    /// The path, drawn without a window: the line's pixels sit on the column, the arm reaches 9 pt, and the last branch
    /// leaves nothing below its curve.
    @Test func thePathDrawsOneLineAtTheColumnAndEndsAtTheLastRow() throws {
        let renderer = ImageRenderer(content: SubagentBranchesShape(branches: SubagentBranches(depths: [1, 1]))
            .stroke(Color.black, style: StrokeStyle(lineWidth: 1))
            .padding(.top, 10).frame(width: 60, height: 80, alignment: .topLeading).background(Color.white))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        func dark(_ x: Int, _ y: Int) -> Bool { (bitmap.colorAt(x: x, y: y)?.redComponent ?? 1) < 0.5 }
        // The tree starts at y = 10. The first branch starts 7 above it, and carries on through the first row to the second.
        #expect(dark(22, 3) && dark(22, 12) && dark(22, 30) && dark(22, 36))
        #expect(!dark(21, 30) && !dark(23, 30) && !dark(22, 1))
        // The first arm runs along y = 21 to x = 31; the second row's along y = 45.
        #expect(dark(30, 21) && !dark(32, 21))
        #expect(dark(30, 45) && !dark(32, 45))
        // The last branch ends at its curve: nothing runs on below it.
        #expect(!dark(22, 50) && !dark(22, 60))
    }

    // MARK: Hosted in the sidebar

    private func fixture() async throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        let folder = root.appendingPathComponent("edd-backend", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        for _ in 0..<2 {
            try await catalog.insertSession(ManagedSession(provider: .claude, workingDirectory: folder.path),
                                            title: nil, lifecycle: .idle, projectID: project.id)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        await model.settle()
        return (model, root)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func element(_ label: String, in view: NSView) -> AnyObject? {
        accessibilityElements(in: view).first { $0.accessibilityLabel?() == label }
    }

    @Test func theRealSidebarDrawsTheTreeUnderOnlyTheSessionThatHasSubagents() async throws {
        enableAccessibilityTree()
        let (model, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.activity)
        await model.settle()
        let rows = model.list(for: .activity).rows
        #expect(rows.count == 2)
        let withAgents = rows[0]
        let start = Date().addingTimeInterval(-30)
        var done = SubagentRecord(id: "f1", agentType: "Explore", description: "List migration files", startedAt: start)
        done.endedAt = start.addingTimeInterval(18)
        withAgents.apply(live: SessionViewState(runID: UUID(), subagents: [
            SubagentRecord(id: "a1", agentType: "Explore", description: "Find login flow handlers", startedAt: start),
            done,
        ]))

        let hosting = NSHostingController(rootView: SidebarView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 300, height: 600))
        // Never ordered front: the layout runs against a window nobody sees. ARC owns it.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try await settle(window)

        let labels = accessibilityElements(in: hosting.view).compactMap { $0.accessibilityLabel?() }
        #expect(labels.filter { $0.hasPrefix("Subagent") } == ["Subagent Explore, Find login flow handlers, running"])
        #expect(labels.contains("1 subagent finished"))
        #expect(!labels.contains("Subagent Explore, List migration files, finished"), "finished ones start folded")
        // Both cards are there, and the one without subagents has no tree.
        #expect(labels.filter { $0.hasPrefix("Claude") }.count == 2)

        // The run ends: the tree is gone and the cards are what they were.
        withAgents.apply(live: SessionViewState())
        try await settle(window)
        let after = accessibilityElements(in: hosting.view).compactMap { $0.accessibilityLabel?() }
        #expect(after.filter { $0.hasPrefix("Subagent") || $0.hasSuffix("finished") }.isEmpty)
        #expect(after.filter { $0.hasPrefix("Claude") }.count == 2)
    }
}
