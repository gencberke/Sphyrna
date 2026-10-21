import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomCore

/// I6b: the inspector's Agents tab in Ink (DESIGN §4 "The Agents tab"): the list's grouping, order and lines, the transcript's two
/// voices, its brief, "Result" and its tail, the review width while a transcript is open, and Esc back to the list.
@MainActor
@Suite struct InkAgentsTabTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func record(_ id: String, started: TimeInterval, ended: TimeInterval? = nil, interrupted: Bool = false,
                        type: String = "explorer", description: String? = "Map the module") -> SubagentRecord {
        var record = SubagentRecord(id: id, agentType: type, description: description, startedAt: t0.addingTimeInterval(started),
                                    endedAt: ended.map { t0.addingTimeInterval($0) })
        record.wasInterrupted = interrupted
        return record
    }

    // MARK: The list

    @Test func theListGroupsRunningThenFinishedEachOldestFirst() {
        let records = [record("f-late", started: 30, ended: 50), record("r-late", started: 20), record("f-early", started: 0, ended: 94),
                       record("r-early", started: 10)]
        let content = InspectorAgentsContent(records: records, now: t0.addingTimeInterval(200))
        #expect(content.running.map(\.id) == ["r-early", "r-late"])
        #expect(content.finished.map(\.id) == ["f-early", "f-late"])
        #expect(InspectorAgentsContent.runningTitle == "Running" && InspectorAgentsContent.finishedTitle == "Finished")
    }

    @Test func aRowCarriesTheTreesStatusColumnTheTypeTheTimeAndTheDescription() {
        let records = [record("run", started: 0), record("wait", started: 5), record("done", started: 0, ended: 94),
                       record("cut", started: 0, ended: 41, interrupted: true)]
        let content = InspectorAgentsContent(records: records, now: t0.addingTimeInterval(130), waiting: ["wait"])
        let rows = Dictionary(uniqueKeysWithValues: (content.running + content.finished).map { ($0.id, $0) })
        let running = rows["run"]
        #expect(running?.status == .working && running?.underLine == nil)
        #expect(running?.title == "explorer" && running?.detail == "Map the module" && running?.time == "2m")
        // A request that waits: the attention dot and "Waiting for you" under the description, in the attention text.
        #expect(rows["wait"]?.status == .waiting)
        #expect(rows["wait"]?.underLine == InspectorAgentsContent.Row.Note(text: "Waiting for you", isAttention: true))
        // Finished: nothing in the status column, and the time to the second.
        #expect(rows["done"]?.status == InspectorAgentsContent.Row.Status.none && rows["done"]?.underLine == nil)
        #expect(rows["done"]?.time == "1m 34s")
        // Interrupted: "Interrupted" under the description, in secondary.
        #expect(rows["cut"]?.status == InspectorAgentsContent.Row.Status.none)
        #expect(rows["cut"]?.underLine == InspectorAgentsContent.Row.Note(text: "Interrupted", isAttention: false))
    }

    @Test func theStatePillReadsToTheSecondOnceFinished() {
        #expect(SubagentPillContent(record: record("a", started: 0, ended: 94), now: t0).label == "Finished 1m 34s")
        #expect(SubagentPillContent(record: record("a", started: 0, ended: 420), now: t0).label == "Finished 7m")
        #expect(SubagentPillContent(record: record("a", started: 0, ended: 41), now: t0).label == "Finished 41s")
        #expect(SubagentPillContent(record: record("a", started: 0, ended: 3_720), now: t0).label == "Finished 1h 2m")
        #expect(SubagentPillContent(record: record("a", started: 0, ended: 41, interrupted: true), now: t0).label == "Interrupted")
        #expect(SubagentPillContent(record: record("a", started: 0), now: t0.addingTimeInterval(65)).label == "Running 1m")
        #expect(SubagentWaitingNotice.showTitle == "Show the Request")
    }

    // MARK: Width and keys

    @Test func anOpenTranscriptTakesTheReviewWidthAndTheListKeepsTheNarrowOne() {
        #expect(InspectorAgents.width(tab: .agents, showsTranscript: true) == 556)
        #expect(InspectorAgents.width(tab: .agents, showsTranscript: false) == 328)
        #expect(InspectorAgents.width(tab: .overview, showsTranscript: true) == 328)
        #expect(InspectorAgents.width(tab: .changes, showsTranscript: false) == 556)
        #expect(InspectorAgents.width(tab: .side, showsTranscript: true) == LoomTheme.Rhythm.inspectorWidthSide)
    }

    @Test func theModelsInspectorWidthFollowsTheClickThatOpensOrClosesATranscript() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        await rig.goLive(0, [inspectorRecord("a1")])
        rig.model.select(rig.ids[0])
        rig.model.selectInspectorTab(.agents)
        rig.model.setInspector(open: true, for: rig.ids[0])
        #expect(rig.model.shownInspectorWidth == 328)
        rig.model.openSubagent("a1", in: rig.ids[0])
        #expect(rig.model.shownInspectorWidth == 556)
        rig.model.closeSubagent()
        #expect(rig.model.shownInspectorWidth == 328)
    }

    @Test func theContainerLaysTheInspectorOutAtTheTranscriptsWidth() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        await rig.goLive(0, [inspectorRecord("a1")])
        rig.model.select(rig.ids[0])
        rig.model.selectInspectorTab(.agents)
        rig.model.setInspector(open: true, for: rig.ids[0])
        // The list: a 328 column beside the content.
        #expect(rig.model.inspectorLayout(detailWidth: 900)
                == InspectorLayout(open: true, detailWidth: 900, openWidth: 328))
        #expect(rig.model.inspectorLayout(detailWidth: 900).placement == .column)
        rig.model.openSubagent("a1", in: rig.ids[0])
        // A transcript: 556 wide; a pane that keeps 480 beside it stays a column, a narrower one is overlaid at 556.
        let wide = rig.model.inspectorLayout(detailWidth: 1_100)
        #expect(wide.placement == .column && wide.inspectorWidth == 556 && wide.contentWidth == 544)
        let narrow = rig.model.inspectorLayout(detailWidth: 900)
        #expect(narrow.placement == .overlay && narrow.inspectorWidth == 556 && narrow.contentWidth == 900)
        let tiny = rig.model.inspectorLayout(detailWidth: 500)
        #expect(tiny.placement == .overlay && tiny.inspectorWidth == 500, "never wider than the pane")
        rig.model.closeSubagent()
        #expect(rig.model.inspectorLayout(detailWidth: 900).inspectorWidth == 328)
    }

    @Test func escapeGoesBackToTheListAndNoOtherKeyIsTheTabs() {
        #expect(AgentsTranscriptKeys.reaction(to: .escape) == .back)
        #expect(AgentsTranscriptKeys.reaction(to: .return) == .ignore)
        #expect(AgentsTranscriptKeys.reaction(to: .space) == .ignore)
        #expect(AgentsTranscriptKeys.reaction(to: KeyEquivalent("w")) == .ignore)
    }

    // MARK: The transcript's two voices

    private func items(_ entries: [SubagentTranscriptEntry]) -> [SubagentTranscriptModel.Item] {
        entries.enumerated().map { SubagentTranscriptModel.Item(id: $0.offset, entry: $0.element) }
    }

    private let stream: [SubagentTranscriptEntry] = [
        .text("I'll read the tree first."),
        .toolCall(name: "Read", argument: "Sources/LoomCatalogUI/SubagentTree.swift"),
        .toolResult(firstLine: "import SwiftUI", lineCount: 88, isError: false),
        .toolCall(name: "Bash", argument: "swift build"),
        .toolResult(firstLine: "error: no such module", lineCount: 1, isError: true),
        .thought(milliseconds: 6_400),
        .text("The branch offsets are the reference's own."),
    ]

    @Test func eachEntryTakesItsVoice() {
        let lines = TranscriptLines.make(brief: nil, omitsEarlier: false, items: items(stream), isRunning: false, isWaiting: false,
                                         isFinished: false)
        #expect(lines.map(\.kind) == [.words, .call, .result, .call, .result, .thought, .words])
        // The agent's words: the chat's type (12.5), primary, after ⏺.
        #expect(lines[0].mark == .glyph("⏺") && lines[0].markTone == .primary)
        #expect(lines[0].style == LoomTheme.InkStyle(size: 12.5, lineHeight: 19.4) && lines[0].tone == .primary && lines[0].label == nil)
        // A tool call in mono 11.5: the name semibold primary, the argument secondary.
        #expect(lines[1].name == "Read" && lines[1].text == "(Sources/LoomCatalogUI/SubagentTree.swift)")
        #expect(lines[1].style.mono && lines[1].style.size == 11.5 && lines[1].tone == .secondary)
        #expect(LoomTheme.Agents.callName.weight == .semibold && LoomTheme.Agents.callName.mono)
        // Its result after ⎿: mono 11, tertiary, one line with how many more there were.
        #expect(lines[2].mark == .glyph("⎿") && lines[2].text == "import SwiftUI  (+87 lines)")
        #expect(lines[2].style.mono && lines[2].style.size == 11 && lines[2].tone == .tertiary && lines[2].lineLimit == 1)
        // An error is in the failure text.
        #expect(lines[4].tone == .failure && lines[4].markTone == .failure && lines[4].text == "error: no such module")
        #expect(lines[4].accessibilityLabel == "Error: error: no such module")
        // "✻ Thought for Ns" in tertiary.
        #expect(lines[5].mark == .glyph("✻") && lines[5].text == "Thought for 6s" && lines[5].tone == .tertiary)
        // A result sits right under its call; the other entries are a block apart.
        #expect(lines[0].top == 0 && lines[1].top == LoomTheme.Agents.blockGap && lines[2].top == LoomTheme.Agents.resultGap)
    }

    @Test func theBriefOpensTheTranscriptUnderItsLabelCutAtFourLines() {
        let lines = TranscriptLines.make(brief: "Find every tree offset", omitsEarlier: true, items: items(stream), isRunning: true,
                                         isWaiting: false, isFinished: false)
        #expect(lines.first?.kind == .brief && lines.first?.label == "Brief" && lines.first?.text == "Find every tree offset")
        #expect(lines.first?.tone == .secondary && lines.first?.lineLimit == 4 && lines.first?.mark == TranscriptLine.Mark.none)
        #expect(lines[1].kind == .omitted && lines[1].text == "Earlier entries are not shown")
        #expect(lines[1].top == LoomTheme.Agents.afterBriefGap && lines[2].top == LoomTheme.Agents.afterBriefGap)
    }

    @Test func aFinishedAgentsLastWordsCarryResult() {
        let finished = TranscriptLines.make(brief: nil, omitsEarlier: false, items: items(stream), isRunning: false, isWaiting: false,
                                            isFinished: true)
        let labelled = finished.filter { $0.label == "Result" }
        #expect(labelled.map(\.text) == ["The branch offsets are the reference's own."], "only the last words, once")
        #expect(finished.last?.kind == .words, "and no tail once it is done")
        // Running, or interrupted (it ended with no result): no label.
        let running = TranscriptLines.make(brief: nil, omitsEarlier: false, items: items(stream), isRunning: true, isWaiting: false,
                                           isFinished: false)
        #expect(running.allSatisfy { $0.label == nil })
        let interrupted = TranscriptLines.make(brief: nil, omitsEarlier: false, items: items(stream), isRunning: false,
                                               isWaiting: false, isFinished: false)
        #expect(interrupted.allSatisfy { $0.label == nil })
    }

    @Test func theTailSaysRunningOrWaitingForYou() {
        let running = TranscriptLines.make(brief: nil, omitsEarlier: false, items: items(stream), isRunning: true, isWaiting: false,
                                           isFinished: false)
        #expect(running.last?.kind == .tail && running.last?.mark == .spinner && running.last?.text == "Running…")
        #expect(running.last?.tone == .secondary)
        let waiting = TranscriptLines.make(brief: nil, omitsEarlier: false, items: items(stream), isRunning: true, isWaiting: true,
                                           isFinished: false)
        #expect(waiting.last?.kind == .tail && waiting.last?.mark == .attentionDot && waiting.last?.text == "Waiting for you")
        #expect(waiting.last?.tone == .attention)
        #expect(waiting.filter { $0.kind == .tail }.count == 1)
        let empty = TranscriptLines.make(brief: nil, omitsEarlier: false, items: [], isRunning: true, isWaiting: false,
                                         isFinished: false)
        #expect(empty.map(\.kind) == [.tail] && empty.first?.top == 0)
    }
}
