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

    @Test func aNestedSubagentIndentsOneStepPerLevel() {
        let rows = content([running("a"), running("b", depth: 2), running("c", depth: 3)]).rows
        #expect(rows.map(\.depth) == [1, 2, 3])
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
