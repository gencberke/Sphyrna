import AppKit
import LoomChat
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The chat stream in Ink (DESIGN §7): the values that changed from Night Fleece 2, pinned as numbers and as measured heights of
/// the real row views (a hosting controller that is never ordered front: nothing appears on screen), and the tree's geometry as a
/// plain value. The stream's cost is the budget suites'.
@MainActor
struct ChatInkStreamTests {
    typealias Chat = LoomTheme.Chat

    private func measured(_ row: ChatRow, width: CGFloat = 900, context: ChatRowContext = ChatRowContext()) -> CGFloat {
        ChatRowMeasurer(context: context).height(of: row, width: width)
    }

    private func hostedHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height)
    }

    // MARK: Your message

    /// The one bubble: white 7 % over Ink and ink 6 % over Paper, radius 12, no edge, padded 9 × 14, at most 80 % of the
    /// column and 560 wide. The off-grid values (9 and 14) are optical and not in `HighlightTests`' grid list.
    @Test func yourMessageIsTheOneBubbleOfInk() {
        #expect(Chat.bubbleTone.dark.rgb == LoomTheme.whiteRGB && Chat.bubbleTone.dark.opacity == 0.07)
        #expect(Chat.bubbleTone.light.rgb == LoomTheme.inkRGB && Chat.bubbleTone.light.opacity == 0.06)
        #expect(Chat.userRadius == 12)
        #expect(Chat.userPaddingH == 14 && Chat.userPaddingV == 9)
        #expect(Chat.userMaxWidthFraction == 0.8 && Chat.userMaxWidth == 560)
    }

    @Test func theBubbleTakesAtMostEightyPercentOfTheColumnAndFiveHundredSixty() {
        #expect(abs(ChatCappedWidth.cap(636, fraction: Chat.userMaxWidthFraction, maximum: Chat.userMaxWidth) - 508.8) < 0.01)
        #expect(ChatCappedWidth.cap(900, fraction: Chat.userMaxWidthFraction, maximum: Chat.userMaxWidth) == 560)
        #expect(ChatCappedWidth.cap(nil, fraction: Chat.userMaxWidthFraction, maximum: Chat.userMaxWidth) == 560)
        // The layout itself: a view that wants all the room gets the capped width.
        let wide = ChatCappedWidth(fraction: 0.8, maximum: 560) { Color.clear.frame(maxWidth: .infinity).frame(height: 10) }
        let host = NSHostingController(rootView: wide)
        host.sizingOptions = []
        #expect(host.sizeThatFits(in: CGSize(width: 900, height: 100)).width == 560)
        #expect(abs(host.sizeThatFits(in: CGSize(width: 400, height: 100)).width - 320) < 0.01)
    }

    /// A one-line message: 20 above, the bubble (one 22 pt line and 9 above and below) and the 26 pt line under it.
    @Test func aOneLineMessageRowIs86High() throws {
        let rows = ChatFixture.rows([ChatFixture.user("hi", uuid: "u1")])
        let user = try #require(rows.first { $0.kind.tag == "user" })
        let height = measured(user)
        #expect(abs(height - (Chat.userTopGap + 22 + 2 * Chat.userPaddingV + Chat.userFooterHeight)) <= 2, "\(height)")
    }

    // MARK: Work rows

    /// A work row is 26 pt whatever it says, and its pill hangs 8 pt outside the column.
    @Test func aWorkRowIs26HighAndItsPillHangsEightOutsideTheColumn() throws {
        #expect(Chat.workRowHeight == 26 && Chat.workRowPaddingH == 8 && Chat.workRowRadius == 8 && Chat.iconSlot == 16)
        let rows = ChatFixture.rows(ChatFixture.turn(1, tools: [ChatFixture.bash("swift build")]), mode: .verbose)
        let tool = try #require(rows.first { $0.kind.tag == "tool" })
        #expect(measured(tool) == 26)
        // A read has no body to open: no chevron, but the same line.
        let read = ChatFixture.rows(ChatFixture.turn(1, tools: [ChatFixture.read("/tmp/a.txt")]), mode: .verbose)
        #expect(measured(try #require(read.first { $0.kind.tag == "tool" })) == 26)
    }

    @Test func onlyARowWithSomethingToOpenDrawsAChevron() throws {
        let calls = ChatFixture.calls(ChatFixture.turn(1, tools: [
            ChatFixture.bash("ls"), ChatFixture.read("/tmp/a.txt"),
            ("Edit", ["file_path": "/tmp/a.txt", "old_string": "a", "new_string": "b"], "ok"),
        ]))
        let labels = calls.map { ChatWork.label(for: $0, workingDirectory: nil) }
        #expect(ChatToolBody.hasBody(calls[0], label: labels[0]), "a command has its output")
        #expect(!ChatToolBody.hasBody(calls[1], label: labels[1]), "a read's body is the path its line shows")
        #expect(ChatToolBody.hasBody(calls[2], label: labels[2]), "an edit has its diff")
        var failedRead = calls[1]
        failedRead.status = .failed
        #expect(ChatToolBody.hasBody(failedRead, label: labels[1]), "a failed read says why")
    }

    /// Failure is loud: the box is headed "Exit code 1 · last 12 lines" and edged in the failure colour at 36 %.
    @Test func aFailedCommandIsHeadedByItsExitCodeAndItsLastLines() {
        #expect(ChatToolBody.failureTitle(code: 1, lines: 40, tail: true, all: false) == "Exit code 1 \u{00B7} last 12 lines")
        #expect(ChatToolBody.failureTitle(code: 2, lines: 4, tail: false, all: false) == "Exit code 2 \u{00B7} last 4 lines")
        #expect(ChatToolBody.failureTitle(code: 2, lines: 1, tail: false, all: false) == "Exit code 2 \u{00B7} last line")
        #expect(ChatToolBody.failureTitle(code: 1, lines: 40, tail: false, all: true) == "Exit code 1")
        #expect(ChatToolBody.failureTitle(code: nil, lines: 3, tail: false, all: false) == "Failed \u{00B7} last 3 lines")
        #expect(Chat.failureEdgeOpacity == 0.36 && Chat.failedTailLines == 12)
        #expect(Chat.outputHeaderHeight == 28 && Chat.outputFooterHeight == 30 && Chat.outputLineHeight == 18)
        #expect(Chat.outputMaxHeight == 306, "16 lines of 18 and the padding")
    }

    @Test func aFailedCommandOpensByItselfAndItsBoxIsOutputHeaderAndLines() throws {
        let output = (1...30).map { "line \($0)" }.joined(separator: "\n")
        var lines = [ChatFixture.user("go", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "make"])], at: 1))
        lines.append(ChatFixture.result("t1", output + "\nExit code 1", isError: true, at: 2))
        lines.append(ChatFixture.assistant("m2", uuid: "a1", blocks: [ChatFixture.text("It failed.")], at: 3))
        var rows = ChatFixture.rows(lines, mode: .verbose)
        let index = try #require(rows.firstIndex { $0.kind.tag == "tool" })
        #expect(rows[index].open, "a failed command opens by itself")
        let open = measured(rows[index])
        rows[index].open = false
        let closed = measured(rows[index])
        // The line, 3 above the body, the 28 pt header + rule + 12 lines of 18 and 18 of padding, 10 below, and the box's edge.
        let box = Chat.outputHeaderHeight + 1 + 12 * Chat.outputLineHeight + Chat.outputPaddingTop + Chat.outputPaddingBottom
        let expected = closed + Chat.bodyTop + box + Chat.bodyBottom
        #expect(abs(open - expected) <= 8, "open \(open), expected \(expected)")
    }

    // MARK: The tree

    /// A group's steps branch from its icon as the sidebar's subagents do: the line at x 8 (the icon's centre), the turn of
    /// radius 6 into the row's middle, and the line on to the next step for every step but the last.
    @Test func theGroupsBranchesAreOneLinePerStepAndTheLastCurvesAndEnds() {
        typealias T = ChatTree
        #expect(T.segments(.step(.last), height: 26) == [.turn(x: 8, top: 0)])
        #expect(T.segments(.step(.middle), height: 26) == [.turn(x: 8, top: 0), .line(x: 8, from: 0, to: 26)])
        // An opened step runs its line down through its body.
        #expect(T.segments(.step(.middle), height: 140) == [.turn(x: 8, top: 0), .line(x: 8, from: 0, to: 140)])
        // The group's own row leaves its icon 7 above the first step and runs to its foot.
        #expect(T.segments(.head, height: 26) == [.line(x: 8, from: 19, to: 26)])
        #expect(LoomTheme.Chat.Tree.curveRadius == 6 && LoomTheme.Chat.Tree.arm == 7 && LoomTheme.Chat.Tree.overhang == 7)
        #expect(LoomTheme.Chat.Tree.lineWidth == 1)
    }

    @Test func theFoldsGuideStandsAtSevenAndTheLastRowEndsItTenAboveItsFoot() {
        typealias T = ChatTree
        #expect(T.segments(.fold(.middle), height: 60) == [.line(x: 7, from: 0, to: 60)])
        #expect(T.segments(.fold(.last), height: 60) == [.line(x: 7, from: 0, to: 50)])
        #expect(T.segments(.fold(.last), height: 6) == [.line(x: 7, from: 0, to: 0)])
        #expect(LoomTheme.Chat.Tree.foldGuide == 7 && LoomTheme.Chat.Tree.foldIndent == 22 && LoomTheme.Chat.Tree.foldGuideEnd == 10)
    }

    @Test func aStepsTurnEntersTheMiddleOfItsRowAndStopsBeforeTheNextIcon() {
        let segments = ChatTree.segments(.step(.last), height: 26)
        let path = ChatTree.path(segments, in: CGRect(x: 0, y: 0, width: 300, height: 26))
        let box = path.boundingRect
        // The line is 1 pt wide with its left edge on 8; the arm ends 7 pt on, at 15, in the row's middle (the 1 pt line's centre).
        #expect(abs(box.minX - 8.5) < 0.01 && abs(box.maxX - 15) < 0.01)
        #expect(abs(box.minY) < 0.01 && abs(box.maxY - 12.5) < 0.01)
    }

    @Test func anOpenGroupsStepsHangOnItsBranchAndTheLastEndsIt() throws {
        let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls"), ChatFixture.read("/tmp/a.txt"), ChatFixture.read("/tmp/b.txt")])
        let rows = ChatFixture.rows(lines, mode: .verbose)
        let steps = rows.filter { $0.kind.tag == "tool" }
        let branches: [ChatTreePosition?] = steps.map { $0.branch }
        #expect(branches == [.middle, .middle, .last])
        #expect(steps.allSatisfy { $0.indent == 1 })
        #expect(rows.first { $0.kind.tag == "group" }?.branch == nil)
        // A tool that is alone is not a step.
        let single = ChatFixture.rows(ChatFixture.turn(1, tools: [ChatFixture.bash("ls")]), mode: .verbose)
        #expect(single.filter { $0.kind.tag == "tool" }.allSatisfy { $0.branch == nil && $0.foldGuide != nil })
    }

    @Test func anOpenFoldsWorkHangsOnItsGuideAndYourMessageDoesNot() {
        let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls")], answer: "Done.", thought: "Looking.")
        let rows = ChatFixture.rows(lines, mode: .thinking, toggled: [ChatRowBuilder.foldID("turn:u1")])
        let guides: [ChatTreePosition?] = rows.map { $0.foldGuide }
        let tags: [String] = rows.map { $0.kind.tag }
        #expect(tags == ["start", "user", "fold", "thinking", "tool", "answer"])
        #expect(guides == [nil, nil, nil, .middle, .last, nil])
    }

    // MARK: Turn fold

    /// The fold is one 28 pt line (8 above, 4 below), tertiary, with a hairline running on; no box.
    @Test func theTurnFoldIsOneTwentyEightPointLine() throws {
        #expect(Chat.foldHeight == 28 && Chat.liveHeight == 28)
        let rows = ChatFixture.rows(ChatFixture.turn(1, tools: [ChatFixture.bash("ls")]))
        let fold = try #require(rows.first { $0.kind.tag == "fold" })
        #expect(measured(fold) == Chat.foldHeight + 12)
    }

    // MARK: Code block

    /// A code block's header is 30 pt, its text 12.5 on 20, padded 10 above, 14 aside and 12 below; a hairline under the header.
    @Test func aCodeBlockIsAThirtyPointHeaderAndLinesOfTwenty() {
        #expect(Chat.codeHeaderHeight == 30 && Chat.bodyLineHeight == 20 && Chat.codeRadius == 8)
        #expect(Chat.codePaddingTop == 10 && Chat.codePaddingH == 14 && Chat.codePaddingBottom == 12)
        let one = hostedHeight(ChatCodeBlockView(language: "swift", code: "let a = 1", isStreaming: false, wrapped: false,
                                                 context: ChatRowContext()) {}, width: 600)
        let two = hostedHeight(ChatCodeBlockView(language: "swift", code: "let a = 1\nlet b = 2", isStreaming: false, wrapped: false,
                                                 context: ChatRowContext()) {}, width: 600)
        #expect(abs(one - (30 + 1 + 10 + 20 + 12)) <= 2, "\(one)")
        #expect(abs((two - one) - 20) <= 1, "a line is 20 pt: \(two - one)")
    }

    // MARK: Markers, live row, cards

    @Test func aMarkerIsMonoElevenWithTwentyAboveAndBelow() throws {
        let rows = ChatFixture.rows([ChatFixture.user("go", uuid: "u1")])
        let start = try #require(rows.first)
        #expect(start.kind.tag == "start")
        #expect(Chat.markerGap == 12 && Chat.markerPaddingV == 20 && Chat.markerLineHeight == 16 && Chat.markerHeight == 56)
        #expect(abs(measured(start) - Chat.markerHeight) <= 2)
    }

    @Test func theLiveRowSplitsWhatClaudeDoesFromWhatItActsOn() throws {
        var lines = [ChatFixture.user("go", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Edit", ["file_path": "/tmp/migrations/0042.py"])], at: 1))
        let rows = ChatFixture.rows(lines, isWorking: true)
        guard case let .live(live) = rows.last?.kind else { Issue.record("no live row"); return }
        #expect(live.label == "Editing /tmp/migrations/0042.py" && live.subject == "/tmp/migrations/0042.py" && live.subjectIsMono)
        // A state with no object has no subject.
        let thinking = ChatFixture.rows([ChatFixture.user("go", uuid: "u1")], isWorking: true)
        guard case let .live(idle) = thinking.last?.kind else { Issue.record("no live row"); return }
        #expect(idle.label == "Working" && idle.subject.isEmpty)
    }

    @Test func theLiveRowIsQuietAfterFortySecondsAndSaysForHowLong() {
        let last = Date(timeIntervalSince1970: 1_000)
        var live = LiveRow(turnID: "t", label: "Running swift build", subject: "swift build", subjectIsMono: true,
                           startedAt: last.addingTimeInterval(-100), lastActivity: last, hiddenTools: [])
        #expect(ChatLiveStatusText.quietSeconds(live, now: last.addingTimeInterval(39)) == nil)
        #expect(ChatLiveStatusText.quietSeconds(live, now: last.addingTimeInterval(41)) == 41)
        #expect(ChatLiveStatusText.text(live, now: last.addingTimeInterval(41)) == "No activity for 41s")
        #expect(ChatLiveStatusText.text(live, now: last.addingTimeInterval(10)).hasPrefix("Running swift build \u{00B7} "))
        live.lastActivity = nil
        #expect(ChatLiveStatusText.quietSeconds(live, now: last.addingTimeInterval(500)) == nil)
    }

    @Test func theFirstSubagentCardOfARunSaysHowManyAgentsThereAre() {
        #expect(ChatRowBuilder.agentsHeader([.succeeded, .running]) == "2 agents \u{00B7} 1 working \u{00B7} 1 done")
        #expect(ChatRowBuilder.agentsHeader([.running]) == "1 agent \u{00B7} working")
        #expect(ChatRowBuilder.agentsHeader([.failed, .interrupted, .succeeded])
            == "3 agents \u{00B7} 1 done \u{00B7} 1 failed \u{00B7} 1 stopped")
    }

    // MARK: Copy

    @Test func commandsAreTitleCaseAndTheRestIsSentenceCase() {
        #expect(ChatRewindAction.title == "Rewind Files to Before This Message")
        #expect(ChatSubagentCardView.openLabel == "Open in Agents")
    }

    @Test func theViewChipIs24HighAndTheJumpPillIs28() {
        #expect(Chat.viewChipHeight == 24 && Chat.viewChipFillOpacity == 0.92)
        #expect(Chat.jumpPillHeight == 28 && Chat.fadeDuration == 0.15)
    }

    /// The optical values that stay off the 4 pt grid, and are not in `HighlightTests`' list: the bubble's 9 × 14, the code
    /// block's 10 / 14, the tree's offsets and the diff's gutter.
    @Test func theOffGridTokensKeepTheirReferenceValues() {
        let optical: [(String, CGFloat, CGFloat)] = [
            ("Chat.userPaddingV", Chat.userPaddingV, 9), ("Chat.userPaddingH", Chat.userPaddingH, 14),
            ("Chat.codePaddingTop", Chat.codePaddingTop, 10), ("Chat.codePaddingH", Chat.codePaddingH, 14),
            ("Chat.outputPaddingBottom", Chat.outputPaddingBottom, 10), ("Chat.bodyTop", Chat.bodyTop, 3),
            ("Chat.Tree.groupLine", Chat.Tree.groupLine, 8), ("Chat.Tree.curveRadius", Chat.Tree.curveRadius, 6),
            ("Chat.Tree.arm", Chat.Tree.arm, 7), ("Chat.Tree.overhang", Chat.Tree.overhang, 7),
            ("Chat.Tree.foldGuide", Chat.Tree.foldGuide, 7), ("Chat.Tree.foldIndent", Chat.Tree.foldIndent, 22),
            ("Chat.thoughtInset", Chat.thoughtInset, 21), ("Chat.diffGutter", Chat.diffGutter, 22),
            ("Chat.changesFileHeight", Chat.changesFileHeight, 29),
        ]
        for (name, value, expected) in optical { #expect(value == expected, "\(name) is \(value)") }
    }
}
