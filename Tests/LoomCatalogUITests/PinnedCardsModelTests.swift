import AppKit
import Foundation
import LoomCore
import SwiftUI
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCatalogUI

// Pinned cards, view side (V18): the counter, the typing guard, the folded line, the question and plan flows, the safety
// rules (nothing answers by itself, Return never approves, Esc never denies), the cut-off card, and the cards drawn.
// The driver's side is in `ChatRequestCardsTests`.

/// A live source that records the answers the cards send, and can be made to fail or to take its time.
actor CardSource: ChatLiveSource {
    private(set) var answers: [(requestID: String, answer: ChatRequestAnswer)] = []
    private(set) var resumes = 0
    private var failure: Error?
    private var delay: Duration?

    func modelChanges() -> ChatModelChanges { ChatModelChanges(changes: AsyncStream { $0.finish() }) }
    func snapshotChange() -> ModelChange { TurnModel(source: .live).snapshot(sequence: 0, hasOlder: false) }
    func liveState() -> ChatLiveState { ChatLiveState(sessionID: UUID()) }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    func answer(requestID: String, _ answer: ChatRequestAnswer) async throws {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        answers.append((requestID, answer))
    }

    func resume() async throws { resumes += 1 }

    func fail(with error: Error?) { failure = error }
    func slow(_ value: Duration?) { delay = value }
}

private final class CardClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private func request(_ id: String, tool: String = "Bash", input: JSONValue = ["command": "rm -rf build", "description": "Remove it"],
                      suggestions: [JSONValue] = [], agent: ChatRequestAgent? = nil) -> ChatPendingRequest {
    var fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": .string(tool), "input": input,
                                       "tool_use_id": .string("toolu_" + id), "description": "Remove it",
                                       "decision_reason": "This command requires approval"]
    if !suggestions.isEmpty { fields["permission_suggestions"] = .array(suggestions) }
    return ChatPendingRequest(requestID: id, request: ToolPermissionRequest(json: .object(fields))!,
                              arrivedAt: Date(timeIntervalSince1970: 1), agent: agent)
}

private let questionInput: JSONValue = ["questions": [
    ["question": "Which database?", "header": "Database", "multiSelect": false,
     "options": [["label": "SQLite", "description": "One file"], ["label": "Postgres", "description": "A server"]]],
    ["question": "Which extras?", "header": "Extras", "multiSelect": true,
     "options": [["label": "Logging", "description": "Logs"], ["label": "Metrics", "description": "Counters"]]],
]]

private func state(_ requests: [ChatPendingRequest] = [], settled: [ChatSettledRequest] = [],
                   phase: ChatDriverPhase = .needsYou) -> ChatLiveState {
    ChatLiveState(sessionID: UUID(), phase: phase, requests: requests, settled: settled)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PinnedCardsModelTests {
    private func make(clock: CardClock = CardClock(), advance: TimeInterval = 0.02, linger: TimeInterval = 60)
        -> (cards: PinnedCardsModel, source: CardSource, clock: CardClock) {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source, clock: { clock.now }, typingClock: { clock.now.timeIntervalSinceReferenceDate }, typingHold: 1.5, foldedLinger: linger, questionAdvance: advance)
        return (cards, source, clock)
    }

    private func wait(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: Counter and order

    @Test func cardsComeInOrderOfArrivalWithACounterAndTheNextTakesTheirPlace() {
        let (cards, _, _) = make()
        let a = request("a"), b = request("b"), c = request("c")
        cards.apply(state([a]))
        #expect(cards.counter == nil && cards.current?.requestID == "a")
        cards.apply(state([a, b, c]))
        #expect(cards.counter == "1 of 3")
        cards.step(1)
        #expect(cards.counter == "2 of 3" && cards.current?.requestID == "b")
        cards.step(1); cards.step(1)
        #expect(cards.counter == "1 of 3", "the counter wraps")
        cards.step(-1)
        #expect(cards.current?.requestID == "c")
        // The one shown leaves (answered elsewhere, withdrawn): the next in line shows, not the first.
        cards.apply(state([a, b]))
        #expect(cards.current?.requestID == "a" && cards.counter == "1 of 2")
        cards.step(1)
        cards.apply(state([a]))
        #expect(cards.current?.requestID == "a" && cards.counter == nil)
        cards.apply(state([]))
        #expect(cards.current == nil && cards.isEmpty)
    }

    // MARK: Nothing answers by itself

    @Test func applyingStatesAndPressingKeysNeverAnswersARequest() async {
        let (cards, source, _) = make()
        for kind in [("Bash", JSONValue.object(["command": "ls"])), ("AskUserQuestion", questionInput),
                     ("ExitPlanMode", ["plan": "# Plan\n\n1. Do it."])] {
            cards.apply(state([request("r-" + kind.0, tool: kind.0, input: kind.1)]))
            cards.apply(state([request("r-" + kind.0, tool: kind.0, input: kind.1)], phase: .working))
        }
        for key: PinnedKey in [.returnKey, .escape, .other] {
            for kind in [ChatPendingRequest.Kind.approval, .question, .plan] {
                #expect(PinnedKeys.action(for: key, kind: kind) == nil, "\(key) \(kind)")
            }
        }
        // Digits pick a question's options, nothing else; Space only presses what the user moved to.
        #expect(PinnedKeys.action(for: .digit(2), kind: .question) == .pickOption(2))
        #expect(PinnedKeys.action(for: .digit(2), kind: .approval) == nil)
        #expect(PinnedKeys.action(for: .digit(0), kind: .question) == nil)
        #expect(PinnedKeys.action(for: .left, kind: .approval) == .moveFocus(-1))
        #expect(PinnedKeys.action(for: .right, kind: .plan) == .moveFocus(1))
        #expect(PinnedKeys.action(for: .space, kind: .approval) == .pressFocused)
        #expect(await source.answers.isEmpty)
    }

    @Test func noCardFileBindsADefaultOrCancelKey() throws {
        // Return never approves and Esc never denies: no card button is a default or a cancel action, and nothing in the
        // card files listens for the exit command (Esc).
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LoomCatalogUI/Chat", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Pinned") && $0.pathExtension == "swift" }
        #expect(files.count >= 5)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in [".keyboardShortcut", "defaultAction", "cancelAction", "onExitCommand", "onSubmit"] {
                let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                #expect(!code.contains { $0.contains(banned) }, "\(file.lastPathComponent) uses \(banned)")
            }
        }
    }

    // MARK: The typing guard

    @Test func aCardThatArrivesWhileYouTypeWaitsAsOneLineAndNeverTakesYourText() async {
        let (cards, source, clock) = make()
        cards.note.set("text written for Claude, not a denial")
        cards.note.hasFocus = true
        cards.note.edited(at: clock.now.timeIntervalSinceReferenceDate)
        let before = cards.note.text
        clock.advance(0.5)
        cards.apply(state([request("a")]))
        #expect(cards.isHeld && cards.heldText == "1 request waiting")
        // Still typing 1 s later; a pause of 1.5 s after the last edit releases it.
        clock.advance(0.9)
        cards.releaseHoldIfIdle()
        #expect(cards.isHeld)
        cards.note.edited(at: clock.now.timeIntervalSinceReferenceDate)
        clock.advance(1.4)
        cards.releaseHoldIfIdle()
        #expect(cards.isHeld)
        clock.advance(0.2)
        cards.releaseHoldIfIdle()
        #expect(!cards.isHeld)
        // Nothing was taken, sent or cleared meanwhile.
        #expect(cards.note.text == before)
        #expect(await source.answers.isEmpty)
    }

    @Test func theHeldLineEndsWhenTheComposerIsLeftOrOpenedAndNeverHoldsWhenYouWereNotTyping() {
        let (cards, _, clock) = make()
        cards.note.hasFocus = true
        cards.note.edited(at: clock.now.timeIntervalSinceReferenceDate)
        cards.apply(state([request("a"), request("b")]))
        #expect(cards.isHeld && cards.heldText == "2 requests waiting")
        // Leaving the composer releases it at once, whatever the clock says.
        cards.note.hasFocus = false
        cards.releaseHoldIfIdle()
        #expect(!cards.isHeld)

        // Opening the line is the user's own click.
        let (other, _, clock2) = make()
        other.note.hasFocus = true
        other.note.edited(at: clock2.now.timeIntervalSinceReferenceDate)
        other.apply(state([request("a")]))
        #expect(other.isHeld)
        other.openHeld()
        #expect(!other.isHeld)

        // Typed long ago, or not in the composer at all: the card shows at once.
        let (late, _, clock3) = make()
        late.note.hasFocus = true
        late.note.edited(at: clock3.now.timeIntervalSinceReferenceDate)
        clock3.advance(1.6)
        late.apply(state([request("a")]))
        #expect(!late.isHeld)
        let (idle, _, _) = make()
        idle.apply(state([request("a")]))
        #expect(!idle.isHeld)

        // A card that joins a stack already showing is never held: only the first card of an empty stack is.
        let (shown, _, clock4) = make()
        shown.apply(state([request("a")]))
        shown.note.hasFocus = true
        shown.note.edited(at: clock4.now.timeIntervalSinceReferenceDate)
        shown.apply(state([request("a"), request("b")]))
        #expect(!shown.isHeld && shown.counter == "1 of 2")
    }

    // MARK: Folded and cut off

    @Test func anAnsweredCardFoldsToOneLineThatExpiresAndDoesNotComeBack() {
        let (cards, _, clock) = make()
        let a = request("a")
        cards.apply(state([a]))
        let settled = ChatSettledRequest(request: a, outcome: .answered, summary: "Allowed once: rm -rf build", settledAt: clock.now)
        cards.apply(state([], settled: [settled]))
        #expect(cards.folded?.summary == "Allowed once: rm -rf build")
        #expect(cards.folded?.outcome == .answered)
        #expect(cards.current == nil && !cards.isEmpty)
        cards.expireFolded(id: "a")
        #expect(cards.folded == nil && cards.isEmpty)
        // The same settled request in the next update does not fold again.
        cards.apply(state([], settled: [settled]))
        #expect(cards.folded == nil)

        // A request settled long before this view looked is not shown.
        let (late, _, lateClock) = make(linger: 4)
        let old = ChatSettledRequest(request: a, outcome: .answered, summary: "Allowed once: x", settledAt: lateClock.now.addingTimeInterval(-10))
        late.apply(state([], settled: [old]))
        #expect(late.folded == nil)
        // Cancelled folds too, with its outcome.
        let cancelled = ChatSettledRequest(request: a, outcome: .cancelled, summary: "Cancelled: rm -rf build", settledAt: lateClock.now)
        late.apply(state([], settled: [cancelled]))
        #expect(late.folded?.outcome == .cancelled)
    }

    @Test func aFoldedLineExpiresByItself() async {
        let (cards, _, clock) = make(linger: 0.05)
        let a = request("a")
        cards.apply(state([], settled: [ChatSettledRequest(request: a, outcome: .answered, summary: "Allowed once: x", settledAt: clock.now)]))
        #expect(cards.folded != nil)
        #expect(await wait { cards.folded == nil })
    }

    @Test func aCardTheProcessLeftUnansweredIsCutOffWithResume() async {
        let (cards, source, clock) = make()
        let a = request("a")
        let cut = ChatSettledRequest(request: a, outcome: .processEnded, summary: "Not answered, Claude stopped: rm -rf build", settledAt: clock.now)
        cards.apply(state([], settled: [cut], phase: .failed(.ended)))
        #expect(cards.cutOff.map(\.id) == ["a"])
        #expect(cards.folded == nil && cards.current == nil && !cards.isEmpty)
        await cards.resume()
        #expect(await source.resumes == 1)
        // The next run clears it (the driver drops the settled entry).
        cards.apply(state([], settled: [], phase: .ready))
        #expect(cards.cutOff.isEmpty && cards.isEmpty)
    }

    // MARK: Answering

    @Test func approvalAnswersGoToTheSourceOnceAndTheNoteIsUsedOnlyByTheButtonsThatTakeIt() async {
        let (cards, source, _) = make()
        let a = request("a")
        cards.apply(state([a]))
        cards.note.set("use make clean")
        await cards.deny(a)
        #expect(await source.answers.map(\.answer) == [.deny(note: "use make clean")])
        #expect(cards.note.text.isEmpty, "the note went out with the denial")
        cards.note.set("keep this")
        await cards.allowOnce(a)
        await cards.allowForSession(a)
        await cards.denyAndStop(a)
        let sent = await source.answers.map(\.answer)
        #expect(sent == [.deny(note: "use make clean"), .allowOnce, .allowForSession, .denyAndStop(note: "keep this")])
    }

    @Test func aSecondClickWhileTheFirstAnswerIsOnItsWayIsIgnored() async {
        let (cards, source, _) = make()
        let a = request("a")
        cards.apply(state([a]))
        await source.slow(.milliseconds(150))
        async let first: Void = cards.allowOnce(a)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(cards.answering.contains("a"))
        await cards.allowOnce(a)
        await cards.deny(a)
        await first
        #expect(await source.answers.count == 1)
        #expect(cards.answering.isEmpty)
    }

    @Test func aFailedAnswerKeepsTheCardAnswerableWithTheReason() async {
        let (cards, source, _) = make()
        let a = request("a")
        cards.apply(state([a]))
        cards.note.set("no thanks")
        await source.fail(with: ChatDriverError.inputFull)
        await cards.deny(a)
        #expect(cards.failures["a"] == "Claude is not reading input right now. Try again in a moment.")
        #expect(cards.current?.requestID == "a")
        #expect(cards.note.text == "no thanks", "a denial that did not go out keeps the note")
        await source.fail(with: nil)
        await cards.deny(a)
        #expect(cards.failures["a"] == nil)
        #expect(await source.answers.count == 1)
        #expect(PinnedCardsModel.failureText(ChatDriverError.noSuchRequest("a")) == "This request is no longer waiting.")
    }

    // MARK: Questions

    @Test func aSingleSelectPickMovesOnAfterAMomentUnlessAnotherPickOrAChangeComesFirst() async {
        let (cards, source, _) = make(advance: 0.05)
        let q = request("q", tool: "AskUserQuestion", input: questionInput)
        cards.apply(state([q]))
        #expect(cards.draft(for: q).step == 0)
        cards.pick(option: 1, in: q)
        #expect(cards.draft(for: q).picks[0] == ["Postgres"] && cards.draft(for: q).step == 0)
        // Another pick restarts the wait: one move, to the second question.
        cards.pick(option: 0, in: q)
        #expect(await wait { cards.draft(for: q).step == 1 })
        #expect(cards.draft(for: q).picks[0] == ["SQLite"])
        // A change of question cancels a move that is on its way.
        cards.back(in: q)
        #expect(cards.draft(for: q).step == 0)
        cards.pick(option: 0, in: q)
        cards.next(in: q)
        cards.back(in: q)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(cards.draft(for: q).step == 0)
        // The last question never moves on by itself and never sends.
        cards.pick(option: 0, in: q)
        #expect(await wait { cards.draft(for: q).step == 1 })
        cards.pick(option: 1, in: q)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(cards.draft(for: q).step == 1 && cards.draft(for: q).picks[1] == ["Metrics"])
        #expect(await source.answers.isEmpty)
    }

    @Test func multiSelectTogglesTypingClearsThePicksAndPickingClearsTheText() async {
        let (cards, source, _) = make()
        let q = request("q", tool: "AskUserQuestion", input: questionInput)
        cards.apply(state([q]))
        cards.pick(option: 0, in: q)
        cards.next(in: q)
        #expect(cards.draft(for: q).step == 1)
        cards.pick(option: 0, in: q)
        cards.pick(option: 1, in: q)
        #expect(cards.draft(for: q).picks[1] == ["Logging", "Metrics"])
        cards.pick(option: 0, in: q)
        #expect(cards.draft(for: q).picks[1] == ["Metrics"], "a second pick on a multi-select toggles it off")
        // Typing clears this question's picks; picking clears the text.
        cards.note.set("Neither")
        cards.noteEdited()
        #expect(cards.draft(for: q).picks[1].isEmpty)
        cards.pick(option: 1, in: q)
        #expect(cards.note.text.isEmpty && cards.draft(for: q).picks[1] == ["Metrics"])
        // Submit needs every question answered, and goes out only when asked.
        let first = request("q2", tool: "AskUserQuestion", input: questionInput)
        cards.apply(state([q, first]))
        #expect(!cards.canSubmit(first))
        await cards.submit(first)
        #expect(await source.answers.isEmpty)
        #expect(cards.canSubmit(q))
        await cards.submit(q)
        let sent = await source.answers.last
        #expect(sent?.requestID == "q")
        #expect(sent?.answer == .answers([
            ChatQuestionAnswer(question: "Which database?", picks: ["SQLite"], other: nil),
            ChatQuestionAnswer(question: "Which extras?", picks: ["Metrics"], other: nil),
        ]))
    }

    @Test func theNoteIsTheAnswerOfTheQuestionShown() async {
        let (cards, source, _) = make()
        let q = request("q", tool: "AskUserQuestion", input: questionInput)
        cards.apply(state([q]))
        cards.note.set("DuckDB")
        cards.noteEdited()
        cards.next(in: q)
        #expect(cards.draft(for: q).step == 1 && cards.draft(for: q).other[0] == "DuckDB")
        #expect(cards.note.text.isEmpty)
        cards.pick(option: 0, in: q)
        await cards.submit(q)
        let sent = await source.answers.last?.answer
        #expect(sent == .answers([
            ChatQuestionAnswer(question: "Which database?", picks: [], other: "DuckDB"),
            ChatQuestionAnswer(question: "Which extras?", picks: ["Logging"], other: nil),
        ]))
    }

    // MARK: Plans

    @Test func aPlanSendsTheChosenModeEveryTimeAndKeepPlanningTakesTheNote() async {
        let (cards, source, _) = make()
        let p = request("p", tool: "ExitPlanMode", input: ["plan": "# Fake plan\n\n1. Do it.", "planFilePath": "/tmp/p.md"])
        cards.apply(state([p]))
        // Nothing chosen: Ask before edits, sent as `default` all the same.
        #expect(cards.planMode(for: p) == "default")
        await cards.approvePlan(p)
        cards.setPlanMode("acceptEdits", for: p)
        await cards.approvePlan(p)
        cards.setPlanMode("auto", for: p)
        cards.setPlanMode("bogus", for: p)
        #expect(cards.planMode(for: p) == "auto")
        await cards.approvePlan(p)
        cards.note.set("Add a rollback step.")
        await cards.keepPlanning(p)
        #expect(await source.answers.map(\.answer) == [
            .approvePlan(mode: "default"), .approvePlan(mode: "acceptEdits"), .approvePlan(mode: "auto"),
            .keepPlanning(feedback: "Add a rollback step."),
        ])
        #expect(cards.note.text.isEmpty)
    }

    // MARK: The feed follows the driver's state

    @Test func theFeedGivesTheCardsTheLiveStateOfItsSource() async throws {
        let card = UUID()
        let source = ScriptedLiveSource(card: card, conversationID: nil)
        let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
        feed.start()
        await source.setState { $0.requests = [request("a"), request("b")] }
        #expect(await wait { feed.cards.count == 2 })
        #expect(feed.cards.counter == "1 of 2")
        await source.setState { $0.requests = [request("b")] }
        #expect(await wait { feed.cards.count == 1 })
        #expect(feed.cards.current?.requestID == "b")
    }

    // MARK: Drawn

    private func fitting(_ cards: PinnedCardsModel, width: CGFloat = 700, maxHeight: CGFloat? = nil) -> CGSize {
        let host = NSHostingView(rootView: PinnedCardsView(cards: cards, maxHeight: maxHeight).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func eachKindOfCardIsDrawnAndAnEmptyStackTakesNoRoom() {
        let (cards, _, _) = make()
        #expect(fitting(cards).height == 0)
        let approval = request("a", suggestions: [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf build"]],
                                                    "behavior": "allow", "destination": "localSettings"]])
        cards.apply(state([approval]))
        let approvalSize = fitting(cards)
        #expect(approvalSize.height > 100)
        let question = request("q", tool: "AskUserQuestion", input: questionInput)
        cards.apply(state([question]))
        #expect(fitting(cards).height > 100)
        let plan = request("p", tool: "ExitPlanMode", input: .object(["plan": .string("# Plan\n\n" + (1...30).map { "\($0). Step \($0)" }.joined(separator: "\n"))]))
        cards.apply(state([plan]))
        #expect(fitting(cards).height > 100)
        // A stack taller than the room it is given scrolls in it.
        #expect(fitting(cards, maxHeight: 120).height <= 120 + LoomTheme.Pinned.stackPaddingBottom)
        // Held, it is one line.
        let (held, _, clock) = make()
        held.note.hasFocus = true
        held.note.edited(at: clock.now.timeIntervalSinceReferenceDate)
        held.apply(state([approval]))
        #expect(held.isHeld && fitting(held).height < approvalSize.height / 2)
    }

    @Test func anApprovalReadsDescriptionFirstThenReasonAndNamesASubagent() {
        let agent = ChatRequestAgent(id: "a1", type: "explorer", description: "Map the fake module")
        let content = PinnedApprovalContent.make(request("a", agent: agent))
        #expect(content.kind == .command && content.title == "Allow this command?" && content.kindLabel == "Command")
        #expect(content.claudeSays == "Remove it")
        #expect(content.reason == "This command requires approval")
        #expect(content.agentLine == "From explorer · Map the fake module")
        #expect(content.lines.map(\.text) == ["rm -rf build"])
        // An edit shows a diff; a long command keeps all its lines for the card to scroll.
        let edit = PinnedApprovalContent.make(request("e", tool: "Edit", input: ["file_path": "/a.swift", "old_string": "a\nb", "new_string": "c"]))
        #expect(edit.kind == .fileEdit)
        #expect(edit.lines.map(\.text) == ["/a.swift", "- a", "- b", "+ c"])
        #expect(edit.lines.map(\.tone) == [.meta, .removed, .removed, .added])
        let long = PinnedApprovalContent.make(request("l", input: .object(["command": .string((1...12).map { "step \($0)" }.joined(separator: "\n"))])))
        #expect(long.lines.count == 12)
        let mcp = PinnedApprovalContent.make(request("m", tool: "mcp__docs__search", input: ["query": "limits"]))
        #expect(mcp.kind == .mcp(server: "docs", tool: "search") && mcp.kindLabel == "docs · search")
        let web = PinnedApprovalContent.make(request("w", tool: "WebFetch", input: ["url": "https://example.com/x", "prompt": "Find limits"]))
        #expect(web.kind == .web && web.lines.map(\.text) == ["https://example.com/x", "Find limits"])
    }
}
