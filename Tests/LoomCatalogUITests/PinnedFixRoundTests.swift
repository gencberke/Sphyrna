import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomChat
@testable import LoomCatalogUI
import LoomTestSupport

// The fix round after the strict review of V18 (pinned cards), view side: each test fails without the fix it names.

private func request(_ id: String, tool: String = "Bash", input: JSONValue = ["command": "make", "description": "Build"],
                     suggestions: [JSONValue] = []) -> ChatPendingRequest {
    var fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": .string(tool), "input": input,
                                       "tool_use_id": .string("toolu_" + id)]
    if !suggestions.isEmpty { fields["permission_suggestions"] = .array(suggestions) }
    return ChatPendingRequest(requestID: id, request: ToolPermissionRequest(json: .object(fields))!,
                              arrivedAt: Date(timeIntervalSince1970: 1), agent: nil)
}

private func state(_ requests: [ChatPendingRequest], phase: ChatDriverPhase = .needsYou) -> ChatLiveState {
    ChatLiveState(sessionID: UUID(), phase: phase, requests: requests)
}

private final class ComposerSpy: PinnedNoteLink {
    var focusCount = 0
    var notes: [String] = []
    func cardSetNote(_ text: String) { notes.append(text) }
    func focusComposer() { focusCount += 1 }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PinnedFixRoundTests {
    // MARK: Fix 4: bounded approval content

    @Test func aHugeCommandOrFileBuildsASmallCardWithAVisibleCut() {
        let started = ProcessInfo.processInfo.systemUptime
        let oneLine = String(repeating: "a", count: 3_000_000)
        let command = PinnedApprovalContent.make(request("c", input: ["command": .string(oneLine)]))
        #expect(command.lines.count <= PinnedApprovalContent.maximumLines + 1)
        #expect(command.lines.allSatisfy { $0.text.count <= PinnedApprovalContent.maximumLineCharacters + 1 })
        #expect(command.lines.first?.text.hasSuffix("\u{2026}") == true, "a cut line ends in the mark")

        let manyLines = (1...100_000).map { "line \($0)" }.joined(separator: "\n")
        let write = PinnedApprovalContent.make(request("w", tool: "Write", input: ["file_path": "/tmp/a.txt", "content": .string(manyLines)]))
        #expect(write.lines.count <= PinnedApprovalContent.maximumLines + 3)
        #expect(write.lines.last?.text == "\u{2026} the rest is not shown", "\(write.lines.last?.text ?? "")")
        #expect(write.lines.map(\.text.count).reduce(0, +) <= PinnedApprovalContent.maximumCharacters + 1_000)

        let edit = PinnedApprovalContent.make(request("e", tool: "Edit", input: [
            "file_path": "/tmp/a.swift", "old_string": .string(manyLines), "new_string": .string(manyLines + "\nmore")]))
        #expect(edit.lines.count <= PinnedApprovalContent.maximumLines + 3)
        #expect(ProcessInfo.processInfo.systemUptime - started < 5, "building the content of huge inputs stays cheap")

        // A small input is shown whole, without a mark.
        let small = PinnedApprovalContent.make(request("s", input: ["command": "make clean\nmake"]))
        #expect(small.lines.map(\.text) == ["make clean", "make"])
    }

    @Test func theContentIsBuiltOncePerRequestNotOnEveryBody() {
        let cards = PinnedCardsModel(source: CardSource())
        let one = request("a", tool: "Write", input: ["file_path": "/tmp/a.txt", "content": "x\ny"])
        let first = cards.content(for: one)
        let second = cards.content(for: one)
        #expect(first == second)
        cards.apply(state([one]))
        cards.apply(state([]))
        #expect(cards.content(for: one) == first)
    }

    // MARK: Fix 2: stopping

    @Test func theButtonsAreOffWhileTheSessionStopsAndTheDriversRefusalReadsAsStopping() async {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source)
        let one = request("a")
        cards.apply(state([one], phase: .stopping))
        #expect(cards.isStopping)
        cards.apply(state([one], phase: .needsYou))
        #expect(!cards.isStopping)
        await source.fail(with: ChatDriverError.stopping)
        await cards.allowOnce(one)
        #expect(cards.failures["a"] == "The session is stopping.")
        #expect(cards.current?.requestID == "a", "the card stays")
    }

    // MARK: Fix 14: the ring

    @Test func theRingStartsNowhereAndMovesFromTheEdges() {
        #expect(PinnedKeyRegion.moved(from: nil, by: 1, count: 3) == 0, "→ from nowhere goes to the first")
        #expect(PinnedKeyRegion.moved(from: nil, by: -1, count: 3) == 2, "← from nowhere goes to the last")
        #expect(PinnedKeyRegion.moved(from: 2, by: 1, count: 3) == 0)
        #expect(PinnedKeyRegion.moved(from: 0, by: -1, count: 3) == 2)
        let cards = PinnedCardsModel(source: CardSource())
        cards.apply(state([request("a")]))
        cards.focus()
        #expect(cards.focusedIndex == nil, "Tab alone puts the ring on no button")
    }

    @Test func aFailureLineThatAppearsDoesNotMoveTheRing() async {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source)
        let one = request("a")
        cards.apply(state([one]))
        cards.focusedIndex = 1
        await source.fail(with: ChatDriverError.inputFull)
        await cards.allowOnce(one)
        #expect(cards.failures["a"] != nil)
        #expect(cards.focusedIndex == 1, "the ring lives in the model, so a card drawn again keeps it")
    }

    // MARK: Fix 15: the typing guard

    @Test func theGuardReadsTheMonotonicClockAndNotTheWallClock() {
        let wall = Mutex2<Date>(Date())
        let uptime = Mutex2<TimeInterval>(1_000)
        let cards = PinnedCardsModel(source: CardSource(), clock: { wall.value }, typingClock: { uptime.value }, typingHold: 1.5)
        cards.note.hasFocus = true
        cards.composerTextChanged("typing")
        // The wall clock jumps a day back (a clock change, sleep, a time zone): it holds or releases nothing.
        wall.value = wall.value.addingTimeInterval(-86_400)
        uptime.value += 0.5
        cards.apply(state([request("a")]))
        #expect(cards.isHeld)
        wall.value = wall.value.addingTimeInterval(7 * 86_400)
        cards.releaseHoldIfIdle()
        #expect(cards.isHeld, "half a second of the monotonic clock is not a pause")
        uptime.value += 1.1
        cards.releaseHoldIfIdle()
        #expect(!cards.isHeld)

        // The default clock is the system uptime: an edit stamped with it holds a card that arrives at once.
        let real = PinnedCardsModel(source: CardSource())
        real.note.hasFocus = true
        real.composerTextChanged("typing")
        real.apply(state([request("b")]))
        #expect(real.isHeld, "the default typing clock is the monotonic one")
    }

    @Test func aTextTheCardsOrTheComposerSetThemselvesIsNotTyping() {
        let uptime = Mutex2<TimeInterval>(10)
        let cards = PinnedCardsModel(source: CardSource(), typingClock: { uptime.value }, typingHold: 1.5)
        let spy = ComposerSpy()
        cards.attach(spy, text: "", hasFocus: false)
        cards.note.hasFocus = true
        cards.composerTextChanged("typed")
        uptime.value += 5
        // A clear (a send, a restore, a pick) is not an edit by the user, and does not make the composer busy.
        cards.composerTextSet("")
        cards.note.set("a pick's text")
        cards.apply(state([request("a")]))
        #expect(!cards.isHeld, "five seconds after the last keystroke, whatever was set since")
        #expect(spy.notes == ["a pick's text"])
    }
}

/// A box a test moves under a model's clock closures.
final class Mutex2<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: Fix: real key events

extension WindowEventTests {
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PinnedKeyEventTests {
    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        NSApp.sendEvent(event)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(250)) }

    /// Return, Esc and Space answer nothing; ← and → move the ring; Space presses the button the ring is on; Tab goes back
    /// to the composer. These go through the card's real key handling, as the window delivers them.
    @Test func realKeysMoveTheRingPressTheFocusedButtonAndNeverApproveOrDeny() async throws {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source)
        let spy = ComposerSpy()
        cards.attach(spy, text: "", hasFocus: false)
        cards.apply(state([request("a")]))
        let (window, _) = host(PinnedCardsView(cards: cards).frame(width: 700), size: NSSize(width: 700, height: 400), key: true)
        defer { window.orderOut(nil) }
        await settle()
        cards.focus()
        await settle()

        // Nothing is chosen right after Tab: Return, Esc and Space press nothing.
        try press("\r", keyCode: 36, in: window)
        try press("\u{1b}", keyCode: 53, in: window)
        try press(" ", keyCode: 49, in: window)
        try press("1", keyCode: 18, in: window)
        await settle()
        #expect(await source.answers.isEmpty, "Return, Esc, Space and a digit answer nothing")
        #expect(cards.focusedIndex == nil && cards.current?.requestID == "a")

        // → chooses Deny (first), → again Allow once; Space presses it.
        try press("\u{F703}", keyCode: 124, in: window)
        await settle()
        #expect(cards.focusedIndex == 0)
        try press("\u{F703}", keyCode: 124, in: window)
        await settle()
        #expect(cards.focusedIndex == 1)
        try press("\u{F702}", keyCode: 123, in: window)
        await settle()
        #expect(cards.focusedIndex == 0)
        try press("\u{F703}", keyCode: 124, in: window)
        // Esc and Return with the ring on a button still press nothing.
        try press("\u{1b}", keyCode: 53, in: window)
        try press("\r", keyCode: 36, in: window)
        await settle()
        #expect(await source.answers.isEmpty)
        try press(" ", keyCode: 49, in: window)
        await settle()
        let answers = await source.answers
        #expect(answers.count == 1 && answers.first?.requestID == "a")
        #expect(answers.first?.answer == .allowOnce)

        // Tab hands the keyboard back to the composer, and so does Shift-Tab (a back-tab character).
        try press("\t", keyCode: 48, in: window)
        await settle()
        #expect(spy.focusCount == 1)
        cards.focus()
        await settle()
        try press("\u{19}", keyCode: 48, in: window, modifiers: [.shift])
        await settle()
        #expect(spy.focusCount == 2, "Shift-Tab goes back to the composer, not on to another key view")
    }

    /// Digits pick a question's options when the card has the keyboard, and nowhere else.
    @Test func digitsPickAQuestionsOptionsAndSpaceOnlyPressesWhatTheRingIsOn() async throws {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source, questionAdvance: 5)
        let question = request("q", tool: "AskUserQuestion", input: ["questions": [
            ["question": "Which database?", "header": "Database", "multiSelect": false,
             "options": [["label": "SQLite", "description": "One file"], ["label": "Postgres", "description": "A server"]]],
        ]])
        cards.apply(state([question]))
        let (window, _) = host(PinnedCardsView(cards: cards).frame(width: 700), size: NSSize(width: 700, height: 500), key: true)
        defer { window.orderOut(nil) }
        await settle()
        cards.focus()
        await settle()
        try press("2", keyCode: 19, in: window)
        await settle()
        #expect(cards.draft(for: question).picks.first == ["Postgres"])
        try press("9", keyCode: 25, in: window)
        await settle()
        #expect(cards.draft(for: question).picks.first == ["Postgres"], "an option that does not exist picks nothing")
        try press("\r", keyCode: 36, in: window)
        try press(" ", keyCode: 49, in: window)
        await settle()
        #expect(await source.answers.isEmpty, "Return and Space with no ring submit nothing")
    }
}
}

/// A source whose history never arrives: the feed stays `opening`.
private actor StalledSource: ChatLiveSource {
    func modelChanges() -> ChatModelChanges { ChatModelChanges(changes: AsyncStream { _ in }) }
    func snapshotChange() async -> ModelChange {
        try? await Task.sleep(for: .seconds(600))
        return TurnModel(source: .live).snapshot(sequence: 0, hasOlder: false)
    }
    func liveState() -> ChatLiveState { ChatLiveState(sessionID: UUID()) }
    func updates() -> AsyncStream<Void> { AsyncStream { _ in } }
}

extension WindowEventTests {
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PinnedSlotTests {
    /// Fix 6: a card shows while the history is still loading (a notification click opens the session at once).
    @Test func theCardSlotIsThereWhileTheHistoryLoads() async throws {
        let slot = Mutex2<Int>(0)
        let feed = LiveChatFeed(source: StalledSource(), card: UUID(), conversationID: nil, configDirectory: nil, workingDirectory: nil)
        #expect(feed.phase == .opening)
        let view = LiveChatView(feed: feed, composer: nil, onOpenSubagent: nil, pinned: { _ in
            slot.value += 1
            return Color.clear.frame(height: 40)
        }).frame(width: 700, height: 500)
        let (window, _) = host(view, size: NSSize(width: 700, height: 500), key: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(feed.phase == .opening, "the history has not arrived")
        #expect(slot.value > 0, "the slot between the stream and the composer is built while the feed is still opening")
    }
}
}
