import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// V09: the inspector's state per session, the words of its tabs and the way a subagent's click and the tabs
/// end a transcript. The window tests (the PTY resize count, the header toggle, what the tabs draw) are in
/// `InspectorWindowTests`. Files live in temporary folders that each test removes.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct InspectorTests {
    // MARK: State per session

    @Test func theInspectorIsClosedByDefaultAndOpensPerSession() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let (a, b) = (rig.ids[0], rig.ids[1])
        #expect(!rig.model.inspector.isOpen(for: a) && !rig.model.inspector.isOpen(for: b))
        #expect(rig.model.inspector.tab == .overview)

        rig.model.select(a)
        rig.model.toggleInspector()
        #expect(rig.model.inspector.isOpen(for: a) && !rig.model.inspector.isOpen(for: b))
        // Another session keeps its own state: selecting it does not open or close anything.
        rig.model.select(b)
        #expect(rig.model.inspector.openSessions == [a])
        rig.model.select(a)
        #expect(rig.model.inspector.openSessions == [a])
        rig.model.toggleInspector()
        #expect(rig.model.inspector.openSessions.isEmpty)

        // Remembered in the preferences file, read by the next window.
        rig.model.setInspector(open: true, for: b)
        let stored = try JSONDecoder().decode(
            UIPreferences.self, from: Data(contentsOf: rig.root.appendingPathComponent("prefs.json")))
        #expect(stored.inspectorOpen == [b])
    }

    @Test func aSubagentRowOpensTheInspectorOnItsAgentsTab() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let (a, b) = (rig.ids[0], rig.ids[1])
        await rig.goLive(1, [inspectorRecord()])
        rig.model.select(a)

        rig.model.openSubagent("a1", in: b)
        #expect(rig.model.selectedSessionID == b)
        #expect(rig.model.inspector.isOpen(for: b) && !rig.model.inspector.isOpen(for: a))
        #expect(rig.model.inspector.tab == .agents)
        #expect(rig.model.viewedSubagent == ViewedSubagent(sessionID: b, agentID: "a1"))
        #expect(rig.model.detailRoute == .terminal(sessionID: b), "the session's own view stays; nothing replaces it")

        // The same row again changes nothing: the panel goes on reading.
        let panel = try #require(rig.model.subagentPanel)
        rig.model.openSubagent("a1", in: b)
        #expect(rig.model.subagentPanel === panel)
    }

    @Test func closingTheInspectorOrLeavingAgentsEndsTheTranscript() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let b = rig.ids[1]
        await rig.goLive(1, [inspectorRecord()])

        rig.model.openSubagent("a1", in: b)
        rig.model.selectInspectorTab(.overview)
        #expect(rig.model.viewedSubagent == nil && rig.model.subagentPanel == nil)
        #expect(rig.model.inspector.isOpen(for: b), "the tab changed, the inspector did not close")

        rig.model.openSubagent("a1", in: b)
        #expect(rig.model.viewedSubagent != nil)
        rig.model.toggleInspector()
        #expect(!rig.model.inspector.isOpen(for: b) && rig.model.viewedSubagent == nil)

        // Back to the list is the same model call as before: the inspector stays open.
        rig.model.openSubagent("a1", in: b)
        rig.model.closeSubagent()
        #expect(rig.model.inspector.isOpen(for: b) && rig.model.inspector.tab == .agents)
    }

    // MARK: Words

    @Test func theReasonReadsAsAShortLine() {
        func line(_ kind: StatusReason.Kind, _ detail: String? = nil, work: BackgroundWork = BackgroundWork()) -> String? {
            InspectorReasonText.line(StatusReason(kind, detail: detail, work: work))
        }
        #expect(line(.approval(tool: "Bash"), "git push origin fix/webhook-sig") == "Allow: git push origin fix/webhook-sig")
        #expect(line(.approval(tool: "Edit"), "src/auth.py") == "Allow Edit: src/auth.py")
        #expect(line(.approval(tool: "WebFetch")) == "Allow WebFetch")
        #expect(line(.question, "Which database?") == "Question: Which database?")
        #expect(line(.planReady) == "Plan ready for review")
        #expect(line(.turnDone, "Done: 3 files changed") == "Done: 3 files changed")
        #expect(line(.turnDone, "Done", work: BackgroundWork(shells: 1, scheduled: 1)) == "Done · 2 running in the background")
        #expect(line(.turnDone) == nil)
        #expect(line(.failure(category: "rate_limit")) == "rate_limit")
        #expect(line(.failure(category: nil), "Overloaded") == "Overloaded")
    }

    @Test func theAgentsCountsAndTheTabsReadFromTheRecords() {
        #expect(InspectorOverviewContent.agents([]) == nil)
        #expect(InspectorOverviewContent.agents([inspectorRecord("a"), inspectorRecord("b", running: false), inspectorRecord("c")]) == "2 running · 1 finished")
        #expect(InspectorOverviewContent.agents([inspectorRecord("b", running: false)]) == "1 finished")
        #expect(InspectorTabBar.title(.overview) == "Overview" && InspectorTabBar.title(.agents) == "Agents")
    }

    @Test func theEmptyAgentsListSaysWhyForASessionWithoutARun() {
        #expect(InspectorAgents.emptyText(isRunning: false) == "Agents show while the session runs.")
        #expect(InspectorAgents.emptyText(isRunning: true).hasPrefix("No subagents."))
    }

    @Test func theAgentsListRunsFirstThenFinishedAndIndentsNestedOnes() {
        let now = inspectorT0.addingTimeInterval(4 * 60 + 5)
        let content = InspectorAgentsContent(records: [
            inspectorRecord("late", started: inspectorT0.addingTimeInterval(60)),
            inspectorRecord("done", running: false, type: "Explore", description: nil),
            inspectorRecord("early"),
            inspectorRecord("nested", type: "", description: "deeper", depth: 2, started: inspectorT0.addingTimeInterval(120)),
        ], now: now)
        #expect(content.running.map(\.id) == ["early", "late", "nested"])
        #expect(content.finished.map(\.id) == ["done"])
        #expect(content.count == 4 && !content.isEmpty)
        #expect(content.running[0].time == "4m" && content.finished[0].time == "41s")
        #expect(content.running[2].title == "Subagent" && content.running[2].depth == 2)
        #expect(content.running[0].accessibilityLabel == "implementer, map the module, Running 4m")
        #expect(content.finished[0].accessibilityLabel == "Explore, Finished 41s")
        #expect(InspectorAgentsContent(records: [], now: now).isEmpty)
    }
}
