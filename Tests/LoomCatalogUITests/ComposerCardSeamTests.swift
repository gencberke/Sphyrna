import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The seam between the composer (V17) and the pinned cards (V18), on the real Chat driver and the fake provider: the composer's
// text is the card's text (a denial's note, a question's "Other", a plan's feedback), one key rule serves both (↵ never
// answers a card and never sends its text, Esc never denies, Tab goes to the card and back), and the typing guard follows the
// real composer. Nothing here talks to a real Claude.

final class SeamClock: Sendable {
    private let value = Mutex(Date())
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ComposerCardSeamTests {
    @MainActor struct Fixture {
        let rig: LiveRig
        let host: ChatSessionHost
        let driver: ChatSessionDriver
        let composer: ChatComposerModel
        let editor: FakeComposerEditor
        let cards: PinnedCardsModel
        let clock: SeamClock
        let follower: Task<Void, Never>
        let id: UUID

        func finish() async {
            follower.cancel()
            await rig.finish()
        }
    }

    private func make() async throws -> Fixture {
        let rig = try await LiveRig.make()
        let id = UUID()
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root)
        let driver = try await host.startNewSession(projectID: nil, sessionID: id)
        var environment = ComposerEnvironment()
        environment.draftDelay = .milliseconds(40)
        let composer = ChatComposerModel(driver: driver, card: id, drafts: host.draftStore, environment: environment)
        composer.start()
        await composer.refresh()
        let editor = FakeComposerEditor(model: composer)
        let clock = SeamClock()
        let cards = PinnedCardsModel(source: driver, clock: { clock.now }, typingClock: { clock.now.timeIntervalSinceReferenceDate }, typingHold: 1.5, foldedLinger: 600, questionAdvance: 0.02)
        composer.attach(cards: cards)
        let follower = Task { @MainActor in
            cards.apply(await driver.liveState())
            for await _ in await driver.updates() {
                guard !Task.isCancelled else { return }
                cards.apply(await driver.liveState())
            }
        }
        return Fixture(rig: rig, host: host, driver: driver, composer: composer, editor: editor, cards: cards, clock: clock,
                       follower: follower, id: id)
    }

    private func waitUntil(_ seconds: Double = 12, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// A scenario's card is on screen.
    private func shown(_ fixture: Fixture, _ scenario: String) async throws {
        try await fixture.driver.send("/scenario " + scenario)
        #expect(await waitUntil { await fixture.composer.refresh(); return fixture.cards.isShowingCard })
    }

    private func prompts(_ fixture: Fixture) async -> [String] {
        await fixture.driver.snapshot().model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
    }

    private func keys(_ fixture: Fixture, menuOpen: Bool = false) -> ComposerKeys.State {
        var state = fixture.composer.keyState(isRepeat: false, hasMarkedText: false, bridge: fixture.editor)
        if menuOpen { state.menuOpen = true }
        return state
    }

    private func resolve(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ state: ComposerKeys.State) -> ComposerKeys.Action {
        ComposerKeys.resolve(keyCode: code, modifiers: modifiers, state: state)
    }

    private func folded(_ fixture: Fixture) async -> String? {
        _ = await waitUntil { fixture.cards.folded != nil }
        return fixture.cards.folded?.summary
    }

    // MARK: Compact

    /// At 780 by 500 a card plus a full composer left no room for the card's buttons. With a card shown the composer is a
    /// line and a bar and the dock drops its hints line: the dock gets shorter by what the window cannot spare, and the
    /// pinned stack may take more of the window.
    @Test func theComposerIsCompactWhileACardWaits() async throws {
        let fixture = try await make()
        func dockHeight() -> CGFloat {
            let host = NSHostingView(rootView: ChatComposerDock(model: fixture.composer).frame(width: 700))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let normal = dockHeight()
        try await shown(fixture, "approval")
        let compact = dockHeight()
        print("dock height: normal \(normal), compact \(compact)")
        // The card's note line comes with a card; the hints line goes and the field is one line. Without the compact form the
        // same composer measured 157 with a card.
        #expect(compact < normal, "compact \(compact) against \(normal)")
        #expect(compact <= 125, "a line, the card's note and the bar: \(compact)")
        #expect(LoomTheme.Pinned.compactStackMaxHeightFraction > LoomTheme.Pinned.stackMaxHeightFraction)
        // The card is answered: the composer is full size again.
        let request = try #require(await fixture.driver.snapshot().requests.first)
        try await fixture.driver.answer(requestID: request.requestID, .allowOnce)
        #expect(await waitUntil { await fixture.composer.refresh(); return !fixture.cards.isShowingCard })
        #expect(abs(dockHeight() - normal) < 1, "back to \(normal)")
        await fixture.finish()
    }

    // MARK: Keys

    @Test func tabGoesFromTheComposerToTheCardAndBackAndAnswersNothing() async throws {
        let fixture = try await make()
        try await shown(fixture, "approval")
        let state = keys(fixture)
        #expect(state.cardShown && state.cardWaiting)
        // Tab with a card shown moves to the card; with ⇧ it is the field's own.
        #expect(resolve(ComposerKeys.tab, [], state) == .focusCard)
        #expect(resolve(ComposerKeys.tab, .shift, state) == .passThrough)
        let before = fixture.cards.focusRequest
        #expect(fixture.composer.perform(.focusCard, bridge: fixture.editor, in: nil))
        #expect(fixture.cards.focusRequest == before + 1)
        // On the card, Tab (with or without ⇧) hands the keyboard back to the composer.
        #expect(PinnedKeys.action(for: .tab, kind: .approval) == .returnToComposer)
        fixture.cards.returnToComposer()
        #expect(fixture.editor.focusCount == 1)
        // An open menu keeps Tab for itself; with no card, Tab is the field's own.
        #expect(resolve(ComposerKeys.tab, [], keys(fixture, menuOpen: true)) == .menuInsert)
        #expect(resolve(ComposerKeys.tab, [], ComposerKeys.State()) == .passThrough)
        #expect(await fixture.driver.snapshot().requests.count == 1, "moving the keyboard answered nothing")
        await fixture.finish()
    }

    @Test func returnWithACardShownSendsNothingAndAnswersNothing() async throws {
        let fixture = try await make()
        try await shown(fixture, "approval")
        fixture.editor.type("check the logs first")
        let state = keys(fixture)
        #expect(resolve(ComposerKeys.returnKey, [], state) == .ignore)
        #expect(resolve(ComposerKeys.keypadEnter, [], state) == .ignore)
        #expect(resolve(ComposerKeys.returnKey, .command, state) == .ignore)
        // A new line is still the field's own; an open menu still takes ↵.
        #expect(resolve(ComposerKeys.returnKey, .shift, state) == .newline)
        #expect(resolve(ComposerKeys.returnKey, [], keys(fixture, menuOpen: true)) == .menuInsert)
        // Neither the key nor the button nor a direct send moves the text anywhere.
        #expect(fixture.composer.perform(.ignore, bridge: fixture.editor, in: nil))
        fixture.composer.submit(secondary: false)
        fixture.composer.submit(secondary: true)
        fixture.composer.performSendButton(commandHeld: false)
        await fixture.composer.settled()
        #expect(fixture.composer.sendKind(commandHeld: false) == .sendDisabled)
        #expect(fixture.composer.text == "check the logs first" && fixture.editor.text == "check the logs first")
        #expect(await prompts(fixture) == ["/scenario approval"], "the text was not sent as a message")
        #expect(await fixture.driver.snapshot().requests.count == 1 && fixture.cards.folded == nil, "the card was not answered")
        await fixture.finish()
    }

    @Test func escapeWithACardWaitingLosesNothingAndStillClosesAMenu() async throws {
        let fixture = try await make()
        try await shown(fixture, "approval")
        fixture.editor.type("note for later")
        let state = keys(fixture)
        #expect(resolve(ComposerKeys.escape, [], state) == .ignore, "Esc neither interrupts nor denies")
        #expect(fixture.composer.perform(.ignore, bridge: fixture.editor, in: nil))
        // An open menu closes first, as it always does.
        #expect(resolve(ComposerKeys.escape, [], keys(fixture, menuOpen: true)) == .closeMenu)
        fixture.composer.flushDraft()
        #expect(fixture.composer.text == "note for later")
        #expect(try fixture.host.draftStore.load(sessionID: fixture.id)?.text == "note for later")
        #expect(await fixture.driver.snapshot().requests.count == 1 && fixture.cards.folded == nil)
        #expect(fixture.composer.state.turnRunning, "the turn goes on")
        await fixture.finish()
    }

    // MARK: The composer's text is the card's text

    @Test func theComposersTextArrivesAsTheDenialsNoteAndTheFoldedLineKeepsIt() async throws {
        let fixture = try await make()
        try await shown(fixture, "approval")
        fixture.editor.type("use make clean")
        #expect(fixture.cards.note.text == "use make clean")
        let request = try #require(fixture.cards.current)
        await fixture.cards.deny(request)
        let line = await folded(fixture)
        #expect(line?.hasPrefix("Denied: ") == true && line?.hasSuffix("use make clean") == true, "\(line ?? "nil")")
        #expect(fixture.composer.text.isEmpty && fixture.editor.text.isEmpty, "the note went with the answer")
        await fixture.finish()
    }

    @Test func aFailedDenialKeepsTheNoteInTheComposer() async throws {
        let fixture = try await make()
        try await shown(fixture, "approval")
        fixture.editor.type("not this one")
        let request = try #require(fixture.cards.current)
        // The request is gone from the driver (answered elsewhere): the answer fails and the text stays where it was.
        try await fixture.driver.respond(to: request.requestID, with: .allow(updatedInput: request.request.input),
                                         record: RequestRecord(kind: .approval, summary: "Allowed once"))
        await fixture.cards.deny(request)
        #expect(fixture.composer.text == "not this one")
        await fixture.finish()
    }

    @Test func aQuestionsOtherIsTheComposersTextTypingClearsThePicksAndPickingClearsTheText() async throws {
        let fixture = try await make()
        try await shown(fixture, "question")
        let question = try #require(fixture.cards.current)
        #expect(question.kind == .question)
        // Pick, then type: the pick goes.
        fixture.cards.pick(option: 0, in: question)
        #expect(fixture.cards.draft(for: question).picks[0].count == 1)
        fixture.editor.type("DuckDB")
        #expect(fixture.cards.draft(for: question).picks[0].isEmpty)
        // Type, then pick: the text goes, from the composer as well.
        fixture.cards.pick(option: 1, in: question)
        #expect(fixture.composer.text.isEmpty && fixture.editor.text.isEmpty)
        #expect(fixture.cards.draft(for: question).picks[0].count == 1)
        // Type again and go on: the text is that question's own answer; the composer is free for the next one.
        fixture.editor.type("DuckDB")
        #expect(fixture.cards.canSubmit(question) == false, "the second question is open")
        fixture.cards.next(in: question)
        #expect(fixture.cards.draft(for: question).other[0] == "DuckDB")
        #expect(fixture.composer.text.isEmpty)
        fixture.cards.pick(option: 0, in: question)
        await fixture.cards.submit(question)
        let line = await folded(fixture)
        #expect(line?.contains("DuckDB") == true, "\(line ?? "nil")")
        await fixture.finish()
    }

    @Test func thePlansFeedbackIsTheComposersTextAndKeepPlanningSendsIt() async throws {
        let fixture = try await make()
        try await shown(fixture, "plan")
        let plan = try #require(fixture.cards.current)
        #expect(plan.kind == .plan)
        fixture.editor.type("Add a rollback step.")
        await fixture.cards.keepPlanning(plan)
        let line = await folded(fixture)
        #expect(line == "Kept planning: Add a rollback step.", "\(line ?? "nil")")
        #expect(fixture.composer.text.isEmpty)
        await fixture.finish()
    }

    @Test func theComposerSaysItsTextGoesWithTheCard() async throws {
        let fixture = try await make()
        #expect(fixture.composer.cardNoteHint == nil && fixture.composer.cardPlaceholder == nil)
        try await shown(fixture, "approval")
        #expect(fixture.composer.cardNoteHint?.contains("deny") == true)
        #expect(fixture.composer.cardPlaceholder == "Note for Claude, sent if you deny")
        #expect(ComposerBarText.hints(fixture.composer.state, editing: false, cardShown: true).contains { $0.contains("tab") })
        await fixture.finish()
    }

    // MARK: The typing guard, with the real composer

    @Test func aCardThatArrivesWhileTypingWaitsAndNeverTakesTheTextOrTheFocus() async throws {
        let fixture = try await make()
        fixture.composer.editorFocusChanged(true)
        fixture.editor.type("half a thought")
        try await fixture.driver.send("/scenario approval")
        #expect(await waitUntil { fixture.cards.count == 1 })
        #expect(fixture.cards.isHeld && !fixture.cards.isShowingCard && !fixture.composer.cardShown)
        #expect(fixture.cards.heldText == "1 request waiting")
        // Held, the composer keeps its own keys: ↵ sends, Tab is the field's, Esc still never denies.
        let state = keys(fixture)
        #expect(!state.cardShown && state.cardWaiting)
        #expect(resolve(ComposerKeys.returnKey, [], state) == .send)
        #expect(resolve(ComposerKeys.tab, [], state) == .passThrough)
        #expect(resolve(ComposerKeys.escape, [], state) == .ignore)
        // The text and the focus are the user's: nothing was taken.
        #expect(fixture.composer.text == "half a thought" && fixture.editor.focusCount == 0)
        #expect(await fixture.driver.snapshot().requests.count == 1 && fixture.cards.folded == nil)
        await fixture.finish()
    }

    @Test func aPauseOfOneAndAHalfSecondsShowsTheHeldCardWithoutTouchingTheText() async throws {
        let fixture = try await make()
        fixture.composer.editorFocusChanged(true)
        fixture.editor.type("still typing")
        try await fixture.driver.send("/scenario approval")
        #expect(await waitUntil { fixture.cards.isHeld })
        fixture.clock.advance(1.0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(fixture.cards.isHeld, "one second of quiet is not a pause")
        fixture.clock.advance(0.6)
        #expect(await waitUntil { fixture.cards.isShowingCard })
        #expect(fixture.composer.cardShown && fixture.composer.text == "still typing" && fixture.editor.focusCount == 0)
        // Now the text is the card's: ↵ stops sending it.
        #expect(resolve(ComposerKeys.returnKey, [], keys(fixture)) == .ignore)
        await fixture.finish()
    }

    @Test func leavingTheComposerShowsTheHeldCard() async throws {
        let fixture = try await make()
        fixture.composer.editorFocusChanged(true)
        fixture.editor.type("typing")
        try await fixture.driver.send("/scenario approval")
        #expect(await waitUntil { fixture.cards.isHeld })
        fixture.composer.editorFocusChanged(false)
        #expect(fixture.cards.isShowingCard && fixture.composer.cardShown)
        await fixture.finish()
    }

    @Test func aSendWhileTheCardIsHeldGoesOutAsAMessageAndThenTheCardShows() async throws {
        let fixture = try await make()
        fixture.composer.editorFocusChanged(true)
        fixture.editor.type("please also check the tests")
        try await fixture.driver.send("/scenario approval")
        #expect(await waitUntil { fixture.cards.isHeld })
        fixture.composer.submit(secondary: false)
        await fixture.composer.settled()
        // A message, not a denial: it is in the stream as the user's, and the request still waits, unanswered.
        #expect(await waitUntil { await prompts(fixture).contains("please also check the tests") })
        #expect(fixture.composer.text.isEmpty && fixture.cards.note.text.isEmpty)
        #expect(!fixture.cards.isHeld && fixture.cards.isShowingCard, "the send ended the guard")
        #expect(await fixture.driver.snapshot().requests.count == 1 && fixture.cards.folded == nil)
        await fixture.finish()
    }

    /// Fix 15 (V18): a clear the composer makes itself (a send, a restore, a returned draft) is not typing.
    @Test func aTextTheComposerSetsItselfDoesNotHoldACard() async throws {
        let fixture = try await make()
        fixture.composer.editorFocusChanged(true)
        fixture.editor.type("a draft")
        fixture.clock.advance(5)
        fixture.composer.setText("")
        try await fixture.driver.send("/scenario approval")
        #expect(await waitUntil { fixture.cards.count == 1 })
        #expect(!fixture.cards.isHeld && fixture.cards.isShowingCard, "five seconds after the last keystroke")
        await fixture.finish()
    }

    /// Fix 15 (V18): the field going away (the view is torn down while it has the keyboard) is leaving the composer.
    @Test func theFieldGoingAwayShowsAHeldCard() async throws {
        let fixture = try await make()
        fixture.composer.editorFocusChanged(true)
        fixture.editor.type("typing")
        try await fixture.driver.send("/scenario approval")
        #expect(await waitUntil { fixture.cards.isHeld })
        fixture.composer.editorAttached(nil)
        #expect(fixture.cards.isShowingCard && fixture.composer.cardShown)
        await fixture.finish()
    }
}
