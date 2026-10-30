import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomChat
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

private typealias ComposerSpy = PinnedFixRoundShared.ComposerSpy

// The fix round after the strict review of V18 (pinned cards), view side: each test fails without the fix it names.

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

    /// The pause before keys after a host or a `focus()`. The card's keyboard is focus state private to `PinnedKeyRegion`, so
    /// nothing outside it says the region was built or took the focus. Every effect of a key is waited for.
    private func handOver() async {
        try? await Task.sleep(for: .milliseconds(250)) // sleep: the card's focus state is private to its view; nothing to observe
    }

    /// Waits for a key's effect on the model and for the window to draw it. A key sent before the card has drawn the last
    /// one's change is lost (the T3 gate on 4122193: the second → straight after the first never moved the ring), so the
    /// next key goes in only once the change is on screen.
    private func drawn(_ what: @autoclosure () -> String, in window: NSWindow, _ condition: () -> Bool) async {
        await waitFor(what()) {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return condition()
        }
    }

    /// Return, Esc and Space answer nothing; ← and → move the ring; Space presses the button the ring is on; Tab goes back
    /// to the composer. These go through the card's real key handling, as the window delivers them.
    @Test func realKeysMoveTheRingPressTheFocusedButtonAndNeverApproveOrDeny() async throws {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source)
        let spy = ComposerSpy()
        cards.attach(spy, text: "", hasFocus: false)
        cards.apply(PinnedFixRoundShared.state([PinnedFixRoundShared.request("a")]))
        let (window, _) = host(PinnedCardsView(cards: cards).frame(width: 700), size: NSSize(width: 700, height: 400), key: true)
        defer { window.orderOut(nil) }
        await handOver()
        cards.focus()
        await handOver()

        // Nothing is chosen right after Tab: Return, Esc and Space press nothing.
        try press("\r", keyCode: 36, in: window)
        try press("\u{1b}", keyCode: 53, in: window)
        try press(" ", keyCode: 49, in: window)
        try press("1", keyCode: 18, in: window)
        // The negative window: for 250 ms after the keys, no answer goes out and no ring is chosen.
        await holds("Return, Esc, Space and a digit answer nothing", for: .milliseconds(250)) {
            await source.answers.isEmpty && cards.focusedIndex == nil
        }
        #expect(await source.answers.isEmpty, "Return, Esc, Space and a digit answer nothing")
        #expect(cards.focusedIndex == nil && cards.current?.requestID == "a")

        // → chooses Deny (first), → again Allow once; Space presses it.
        try press("\u{F703}", keyCode: 124, in: window)
        await drawn("→ to put the ring on Deny", in: window) { cards.focusedIndex == 0 }
        #expect(cards.focusedIndex == 0)
        try press("\u{F703}", keyCode: 124, in: window)
        await drawn("→ to move the ring to Allow Once", in: window) { cards.focusedIndex == 1 }
        #expect(cards.focusedIndex == 1)
        try press("\u{F702}", keyCode: 123, in: window)
        await drawn("← to move the ring back to Deny", in: window) { cards.focusedIndex == 0 }
        #expect(cards.focusedIndex == 0)
        try press("\u{F703}", keyCode: 124, in: window)
        await drawn("→ to move the ring to Allow Once again", in: window) { cards.focusedIndex == 1 }
        // Esc and Return with the ring on a button still press nothing.
        try press("\u{1b}", keyCode: 53, in: window)
        try press("\r", keyCode: 36, in: window)
        await holds("Esc and Return with the ring on a button answer nothing", for: .milliseconds(250)) {
            await source.answers.isEmpty
        }
        #expect(await source.answers.isEmpty)
        try press(" ", keyCode: 49, in: window)
        let answers = await waitFor("Space to press the button the ring is on",
                                    observe: { await source.answers }, until: { !$0.isEmpty })
        #expect(answers.count == 1 && answers.first?.requestID == "a")
        #expect(answers.first?.answer == .allowOnce)

        // Tab hands the keyboard back to the composer, and so does Shift-Tab (a back-tab character).
        try press("\t", keyCode: 48, in: window)
        await waitFor("Tab to hand the keyboard back to the composer") { spy.focusCount >= 1 }
        #expect(spy.focusCount == 1)
        cards.focus()
        await handOver()
        try press("\u{19}", keyCode: 48, in: window, modifiers: [.shift])
        await waitFor("Shift-Tab to hand the keyboard back to the composer") { spy.focusCount >= 2 }
        #expect(spy.focusCount == 2, "Shift-Tab goes back to the composer, not on to another key view")
    }

    /// Digits pick a question's options when the card has the keyboard, and nowhere else.
    @Test func digitsPickAQuestionsOptionsAndSpaceOnlyPressesWhatTheRingIsOn() async throws {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source, questionAdvance: 5)
        let question = PinnedFixRoundShared.request("q", tool: "AskUserQuestion", input: ["questions": [
            ["question": "Which database?", "header": "Database", "multiSelect": false,
             "options": [["label": "SQLite", "description": "One file"], ["label": "Postgres", "description": "A server"]]],
        ]])
        cards.apply(PinnedFixRoundShared.state([question]))
        let (window, _) = host(PinnedCardsView(cards: cards).frame(width: 700), size: NSSize(width: 700, height: 500), key: true)
        defer { window.orderOut(nil) }
        await handOver()
        cards.focus()
        await handOver()
        try press("2", keyCode: 19, in: window)
        await waitFor("2 to pick Postgres") { cards.draft(for: question).picks.first == ["Postgres"] }
        #expect(cards.draft(for: question).picks.first == ["Postgres"])
        try press("9", keyCode: 25, in: window)
        // The negative window: for 250 ms after the 9, the pick stays Postgres.
        await holds("a 9 for an option that does not exist picks nothing", for: .milliseconds(250)) {
            cards.draft(for: question).picks.first == ["Postgres"]
        }
        #expect(cards.draft(for: question).picks.first == ["Postgres"], "an option that does not exist picks nothing")
        try press("\r", keyCode: 36, in: window)
        try press(" ", keyCode: 49, in: window)
        await holds("Return and Space with no ring submit nothing", for: .milliseconds(250)) { await source.answers.isEmpty }
        #expect(await source.answers.isEmpty, "Return and Space with no ring submit nothing")
    }
}
}

/// A source whose history never arrives: the feed stays `opening`.
private actor StalledSource: ChatLiveSource {
    func modelChanges() -> ChatModelChanges { ChatModelChanges(changes: AsyncStream { _ in }) }
    func snapshotChange() async -> ModelChange {
        try? await Task.sleep(for: .seconds(600)) // sleep: the history that never arrives, so the feed stays opening
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
        await waitFor("the card slot to be built") { slot.value > 0 }
        #expect(feed.phase == .opening, "the history has not arrived")
        #expect(slot.value > 0, "the slot between the stream and the composer is built while the feed is still opening")
    }
}
}
