import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

@MainActor
struct ChatRowBuilderTests {
    private func tags(_ rows: [ChatRow]) -> [String] { rows.map(\.kind.tag) }

    // MARK: Folds

    @Test func settledTurnFoldsItsWorkBetweenPromptAndAnswer() {
        let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls"), ChatFixture.read("/tmp/a.txt")], answer: "All done.")
        let rows = ChatFixture.rows(lines)
        #expect(tags(rows) == ["start", "user", "fold", "answer"])
        guard case let .turnFold(fold) = rows[2].kind else { Issue.record("no fold"); return }
        #expect(fold.detail == "ran 1 command and read 1 file")
        #expect(rows[2].open == false)
    }

    @Test func verboseOpensFoldsAndGroups() {
        let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls"), ChatFixture.read("/tmp/a.txt")])
        let rows = ChatFixture.rows(lines, mode: .verbose)
        #expect(tags(rows) == ["start", "user", "fold", "group", "tool", "tool", "answer"])
        #expect(rows[3].open)
        #expect(rows[4].indent == 1 && rows[5].indent == 1)
    }

    @Test func foldOpensWithTheReadersToggleAndClosesAgain() {
        let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls")])
        let id = ChatRowBuilder.foldID("turn:u1")
        let open = ChatFixture.rows(lines, toggled: [id])
        #expect(tags(open) == ["start", "user", "fold", "tool", "answer"])
        #expect(open[2].open)
        #expect(tags(ChatFixture.rows(lines)) == ["start", "user", "fold", "answer"])
    }

    @Test func aLiveTurnNeverFoldsAndEndsInTheLiveRow() {
        var lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls")], answer: "Earlier.")
        lines.append(ChatFixture.user("next", uuid: "u2", at: 20))
        lines.append(ChatFixture.assistant("m2", uuid: "c2", blocks: [ChatFixture.tool("toolu_2", "Bash", ["command": "swift build"])], at: 21))
        let rows = ChatFixture.rows(lines, isWorking: true)
        #expect(tags(rows) == ["start", "user", "fold", "answer", "user", "live"])
        guard case let .live(live) = rows.last?.kind else { Issue.record("no live row"); return }
        #expect(live.label == "Running swift build")
        #expect(live.hiddenTools.count == 1)
    }

    @Test func aStoppedSessionShowsNoLiveRowAndMarksUnfinishedWorkStopped() {
        var lines = [ChatFixture.user("go", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("toolu_1", "Bash", ["command": "sleep 99"])], at: 1))
        let rows = ChatFixture.rows(lines, isWorking: false)
        #expect(!tags(rows).contains("live"))
        guard case let .tool(entry) = rows.last?.kind, case let .tool(call) = entry.body else { Issue.record("no tool row"); return }
        #expect(call.status == .interrupted)
    }

    @Test func aTurnWithoutWorkHasNothingToFold() {
        let rows = ChatFixture.rows(ChatFixture.turn(1))
        #expect(tags(rows) == ["start", "user", "answer"])
    }

    @Test func aFailedToolOpensItsBodyByDefault() {
        var lines = [ChatFixture.user("go", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("toolu_1", "Bash", ["command": "false"])], at: 1))
        lines.append(ChatFixture.result("toolu_1", "Exit code 1", isError: true, at: 2))
        let rows = ChatFixture.rows(lines, isWorking: false, toggled: [])
        let tool = rows.first { $0.kind.tag == "tool" }
        #expect(tool?.open == true)
    }

    // MARK: Groups

    @Test func twoToolsInARowFormAGroupWithASummary() {
        let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("a"), ChatFixture.bash("b"), ChatFixture.bash("c")])
        let rows = ChatFixture.rows(lines, toggled: [ChatRowBuilder.foldID("turn:u1")])
        #expect(tags(rows) == ["start", "user", "fold", "group", "answer"])
        guard case let .group(group) = rows[3].kind else { Issue.record("no group"); return }
        #expect(group.summary == "Ran 3 commands")
        #expect(group.members.count == 3)
        #expect(rows[3].open == false)
    }

    @Test func aGroupTakesTheStateOfItsLatestTool() {
        var lines = [ChatFixture.user("go", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "false"])], at: 1))
        lines.append(ChatFixture.result("t1", "Exit code 1", isError: true, at: 2))
        lines.append(ChatFixture.assistant("m2", uuid: "c2", blocks: [ChatFixture.tool("t2", "Bash", ["command": "true"])], at: 3))
        lines.append(ChatFixture.result("t2", "", at: 4))
        lines.append(ChatFixture.assistant("m3", uuid: "a1", blocks: [ChatFixture.text("ok")], at: 5))
        let rows = ChatFixture.rows(lines, mode: .verbose)
        guard case let .group(group)? = rows.first(where: { $0.kind.tag == "group" })?.kind else { Issue.record("no group"); return }
        #expect(group.status == .succeeded)
        #expect(group.failedCount == 1)
    }

    @Test func todoWriteIsNeverARow() {
        let todo: (name: String, input: JSONValue, output: String) = ("TodoWrite", ["todos": []], "ok")
        let rows = ChatFixture.rows(ChatFixture.turn(1, tools: [todo]))
        #expect(tags(rows) == ["start", "user", "answer"])
    }

    // MARK: Views

    @Test func thinkingBlocksShowOutsideNormalAndTheThoughtLineOnlyInNormal() {
        var lines = [ChatFixture.user("go", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "t1", blocks: [ChatFixture.thinking("**Plan the work**\nthen do it")], at: 1))
        let normal = ChatFixture.rows(lines, mode: .normal, isWorking: true)
        let thinking = ChatFixture.rows(lines, mode: .thinking, isWorking: true)
        #expect(!tags(normal).contains("thinking"))
        #expect(tags(normal).contains("thought"))
        #expect(tags(thinking).contains("thinking"))
        #expect(!tags(thinking).contains("thought"))
        #expect(tags(normal).last == "live" && tags(thinking).last == "live")
    }

    @Test func viewModesCycleNormalThinkingVerbose() {
        #expect(ChatViewMode.normal.next == .thinking)
        #expect(ChatViewMode.thinking.next == .verbose)
        #expect(ChatViewMode.verbose.next == .normal)
    }

    // MARK: Changed files

    @Test func theChangedFilesCardCountsLinesFromTheEditRecords() {
        var lines = [ChatFixture.user("write", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [
            ChatFixture.tool("w1", "Write", ["file_path": "/proj/src/a.txt", "content": "one\ntwo\nthree\n"]),
        ], at: 1))
        lines.append(ChatFixture.result("w1", "File created successfully at: /proj/src/a.txt", at: 2,
                                        structured: ["type": "create", "filePath": "/proj/src/a.txt", "content": "one\ntwo\nthree\n",
                                                     "structuredPatch": []]))
        lines.append(ChatFixture.assistant("m2", uuid: "a1", blocks: [ChatFixture.text("Done.")], at: 3))
        let rows = ChatFixture.rows(lines, workingDirectory: "/proj")
        guard case let .changedFiles(card)? = rows.last?.kind else { Issue.record("no card: \(tags(rows))"); return }
        #expect(card.files == [ChangedFile(path: "src/a.txt", added: 3, removed: 0)])
        #expect(card.added == 3 && card.removed == 0)
    }

    @Test func noCardWhileTheTurnIsLive() {
        var lines = [ChatFixture.user("write", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("w1", "Write", ["file_path": "/p/a", "content": "x"])], at: 1))
        lines.append(ChatFixture.result("w1", "File created successfully", at: 2,
                                        structured: ["type": "create", "filePath": "/p/a", "content": "x", "structuredPatch": []]))
        #expect(!tags(ChatFixture.rows(lines, isWorking: true)).contains("changes"))
    }

    // MARK: Interruption

    @Test func anInterruptedTurnShowsItsWorkAndAStopDivider() {
        var lines = [ChatFixture.user("go", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "sleep 5"])], at: 1))
        lines.append(ChatFixture.user("[Request interrupted by user]", uuid: "u2", at: 5))
        let rows = ChatFixture.rows(lines)
        #expect(!tags(rows).contains("fold"))
        #expect(tags(rows).contains("divider"))
        guard case let .divider(text)? = rows.first(where: { $0.kind.tag == "divider" })?.kind else { return }
        #expect(text.hasPrefix("You stopped"))
    }

    // MARK: Identity and diff

    @Test func rowIDsStayStableWhenTheFileGrows() {
        var lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls")])
        let before = ChatFixture.rows(lines)
        lines += ChatFixture.turn(2, answer: "Second.", start: 30)
        let after = ChatFixture.rows(lines)
        #expect(Array(after.map(\.id).prefix(before.count)) == before.map(\.id))
        let plan = ChatStreamController.plan(from: before, to: after)
        #expect(plan.removed.isEmpty && plan.updated.isEmpty && !plan.reloadAll)
        #expect(plan.inserted == IndexSet(before.count..<after.count))
    }

    @Test func aChangedRowIsUpdatedAndNothingElse() {
        let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("ls")])
        let closed = ChatFixture.rows(lines)
        let open = ChatFixture.rows(lines, toggled: [ChatRowBuilder.foldID("turn:u1")])
        let plan = ChatStreamController.plan(from: closed, to: open)
        #expect(plan.updated == IndexSet(integer: 2))
        #expect(plan.inserted == IndexSet(integer: 3))
        #expect(plan.removed.isEmpty)
    }

    @Test func olderTurnsPrependWithoutTouchingTheRest() {
        let newer = ChatFixture.turn(2, answer: "Newer.", start: 30)
        let older = ChatFixture.turn(1, answer: "Older.")
        let before = ChatFixture.rows(newer, hasOlder: true, firstOffset: ChatFixture.size(of: older))
        let after = ChatFixture.rows(older + newer, hasOlder: false)
        let plan = ChatStreamController.plan(from: before, to: after)
        #expect(plan.removed.isEmpty)
        #expect(plan.updated.isEmpty)
        #expect(plan.inserted.count == after.count - before.count)
    }

    @Test func anEmptyTranscriptHasOneEmptyRow() {
        #expect(tags(ChatFixture.rows([])) == ["empty"])
    }

    @Test func startLineIsOmittedWhenOlderTurnsExist() {
        let rows = ChatFixture.rows(ChatFixture.turn(2, answer: "x"), hasOlder: true)
        #expect(rows.first?.kind.tag == "user")
    }
}

extension ChatRowBuilderTests {
    @Test func aMessageSentWhileClaudeWorkedStaysVisibleInAFoldedTurn() {
        let model = ChatFixture.settledTurnWithAMidTurnMessage()
        #expect(model.turns.count == 1, "the second message joined the first turn")
        let closed = ChatRowBuilder.rows(ChatBuildInput(model: model))
        let ids = closed.compactMap { row -> String? in if case .user = row.kind { row.id } else { nil } }
        #expect(ids == ["u1", "u2"], "tags: \(closed.map(\.kind.tag))")
        #expect(closed.map(\.kind.tag).contains("fold"))
        let open = ChatRowBuilder.rows(ChatBuildInput(model: model, toggled: [ChatRowBuilder.foldID(model.turns[0].id)]))
        #expect(open.compactMap { row -> String? in if case .user = row.kind { row.id } else { nil } } == ["u1", "u2"])
        let verbose = ChatRowBuilder.rows(ChatBuildInput(model: model, mode: .verbose))
        #expect(verbose.compactMap { row -> String? in if case .user = row.kind { row.id } else { nil } } == ["u1", "u2"])
    }

    @Test func theChangedFilesCardAlsoShowsForAnInterruptedTurnThatEditedFiles() {
        var lines = [ChatFixture.user("write", uuid: "u1")]
        lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("w1", "Write", ["file_path": "/p/a.txt", "content": "x\ny\n"])], at: 1))
        lines.append(ChatFixture.result("w1", "File created successfully at: /p/a.txt", at: 2,
                                        structured: ["type": "create", "filePath": "/p/a.txt", "content": "x\ny\n", "structuredPatch": []]))
        lines.append(ChatFixture.user("[Request interrupted by user]", uuid: "u2", at: 5))
        let rows = ChatFixture.rows(lines, workingDirectory: "/p")
        #expect(rows.map(\.kind.tag).contains("divider"))
        guard case let .changedFiles(card)? = rows.last?.kind else { Issue.record("no card: \(rows.map(\.kind.tag))"); return }
        #expect(card.files == [ChangedFile(path: "a.txt", added: 2, removed: 0)])
    }
}
