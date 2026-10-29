import AppKit
import Foundation
import Synchronization
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// The quick question (V22): the panel's holder (one question at a time, a closed panel drops a late answer, a session that can
/// no longer take a question closes it), the field's keys, the theme's contrast, and the menu and palette state on the real
/// model with a driver on the fake provider. Nothing is drawn.

/// An `ask` the test answers by hand, and that keeps waiting through a cancellation (a late answer, as the wire can deliver one).
private final class Asks: Sendable {
    private struct State {
        var asked: [String] = []
        var waiting: [CheckedContinuation<Result<String, any Error>, Never>] = []
    }

    private let state = Mutex(State())

    var asked: [String] { state.withLock { $0.asked } }

    var ask: QuickQuestionPanel.Ask {
        { [self] question in
            state.withLock { $0.asked.append(question) }
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, any Error>, Never>) in
                state.withLock { $0.waiting.append(continuation) }
            }
            return try result.get()
        }
    }

    func answer(_ text: String) { resolve(.success(text)) }
    func fail(_ error: any Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<String, any Error>) {
        let next = state.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }
        next?.resume(returning: result)
    }
}

@MainActor
struct QuickQuestionHolderTests {
    private func settle() async { for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) } }

    private func make(_ asks: Asks = Asks()) -> (QuickQuestionPanel, Asks) {
        let panel = QuickQuestionPanel(ask: asks.ask)
        panel.open()
        return (panel, asks)
    }

    @Test func aQuestionIsAskedAnsweredAndTheFieldClearsForTheNextOne() async {
        let (panel, asks) = make()
        panel.text = "  why is the build red?  "
        #expect(panel.canSend)
        panel.submit()
        #expect(panel.isWaiting && panel.question == "why is the build red?" && panel.text.isEmpty)
        await settle()
        #expect(asks.asked == ["why is the build red?"])
        asks.answer("Because of a missing import.")
        await settle()
        #expect(panel.answer == "Because of a missing import." && !panel.isWaiting && panel.failure == nil)
        #expect(panel.question == "why is the build red?", "the last question stays above its answer")

        panel.text = "and the second one?"
        panel.submit()
        #expect(panel.answer == nil, "a new question drops the old answer")
        await settle()
        asks.answer("Another answer.")
        await settle()
        #expect(panel.answer == "Another answer." && panel.question == "and the second one?")
    }

    @Test func aSecondReturnWhileOneWaitsSendsNothing() async {
        let (panel, asks) = make()
        panel.text = "first"
        panel.submit()
        await settle()
        panel.text = "second"
        #expect(!panel.canSend)
        panel.submit()
        panel.submit()
        await settle()
        #expect(asks.asked == ["first"], "one question at a time")
        #expect(panel.text == "second", "the field keeps what was typed meanwhile")
        asks.answer("done")
        await settle()
        #expect(panel.canSend)
        panel.submit()
        await settle()
        #expect(asks.asked == ["first", "second"])
    }

    @Test func anEmptyFieldSendsNothing() async {
        let (panel, asks) = make()
        panel.text = "  \n "
        #expect(!panel.canSend)
        panel.submit()
        await settle()
        #expect(asks.asked.isEmpty && !panel.isWaiting)
    }

    @Test func closingDropsTheQuestionTheAnswerAndALateAnswer() async {
        let (panel, asks) = make()
        panel.text = "slow one"
        panel.submit()
        await settle()
        #expect(panel.isWaiting)
        panel.close()
        #expect(!panel.isOpen && panel.question == nil && panel.answer == nil && panel.failure == nil && !panel.isWaiting)
        #expect(panel.text.isEmpty)

        // The answer arrives anyway (the wire can); nothing takes it.
        asks.answer("too late")
        await settle()
        #expect(panel.answer == nil && panel.question == nil && !panel.isOpen && !panel.isWaiting)

        // A panel opened again starts empty, and a late answer of the old question is not its answer either.
        panel.open()
        panel.text = "new one"
        panel.submit()
        await settle()
        asks.answer("for the new one")
        await settle()
        #expect(panel.answer == "for the new one")
    }

    @Test func anAnswerOfAnEarlierOpeningNeverLandsInALaterQuestion() async {
        let (panel, asks) = make()
        panel.text = "old"
        panel.submit()
        await settle()
        panel.close()
        panel.open()
        panel.text = "new"
        panel.submit()
        await settle()
        #expect(asks.asked == ["old", "new"])
        asks.answer("answer of old")
        await settle()
        #expect(panel.answer == nil, "the old question's answer is not the new question's")
        #expect(panel.isWaiting)
        asks.answer("answer of new")
        await settle()
        #expect(panel.answer == "answer of new")
    }

    @Test func aSessionThatCanNoLongerTakeAQuestionClosesThePanel() async {
        for availability in [SideQuestionAvailability.stopped, .stopping, .launching, .handover] {
            let (panel, asks) = make()
            panel.text = "waiting"
            panel.submit()
            await settle()
            panel.reconcile(.available)
            #expect(panel.isOpen && panel.isWaiting, "an available session keeps it")
            panel.reconcile(availability)
            #expect(!panel.isOpen && panel.question == nil && !panel.isWaiting, "\(availability)")
            asks.answer("late")
            await settle()
            #expect(panel.answer == nil)
        }
    }

    @Test func eachFailureIsOneQuietLineAndTheQuestionComesBackToTheField() async {
        let cases: [(SideQuestionError, String)] = [
            (.noAnswer, "No answer came back. Try again."),
            (.unsupported, "This Claude version has no quick questions"),
            (.failed("The CLI says no"), "The CLI says no"),
        ]
        for (error, line) in cases {
            let (panel, asks) = make()
            panel.text = "try this"
            panel.submit()
            await settle()
            asks.fail(error)
            await settle()
            #expect(panel.failure == line && panel.answer == nil && !panel.isWaiting)
            #expect(panel.text == "try this" && panel.isOpen, "the field is kept")
            #expect(panel.canSend)
        }
        // What the user typed meanwhile is not overwritten.
        let (panel, asks) = make()
        panel.text = "first"
        panel.submit()
        await settle()
        panel.text = "typed meanwhile"
        asks.fail(SideQuestionError.noAnswer)
        await settle()
        #expect(panel.text == "typed meanwhile")
    }

    @Test func aCancelledQuestionLeavesNoFailureLine() async {
        let (panel, asks) = make()
        panel.text = "stop me"
        panel.submit()
        await settle()
        asks.fail(CancellationError())
        await settle()
        #expect(panel.failure == nil && !panel.isWaiting)
    }

    @Test func openingAnOpenPanelAsksForTheKeyboardInsteadOfClosingIt() {
        let (panel, _) = make()
        let before = panel.focusRequests
        panel.open()
        #expect(panel.isOpen && panel.focusRequests == before + 1)
    }

    /// ⌘; often comes while the user types in the main composer: the panel's field must take the keyboard from it, or the
    /// question would go to the session with Return (a window that is never shown).
    @Test func thePanelsFieldTakesTheKeyboardFromTheMainComposer() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
                              defer: true)
        let composer = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView?.addSubview(composer)
        #expect(window.makeFirstResponder(composer), "the main composer has the keyboard")
        let field = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 150, width: 300, height: 100))
        window.contentView?.addSubview(field)
        let (panel, _) = make()
        let host = QuickQuestionEditorHost(panel: panel)
        host.editorAttached(field)
        #expect(window.firstResponder === field, "the panel's field took the keyboard")
    }

    @Test func theWaitingLineReadsLikeTheDesign() {
        #expect(QuickQuestionText.waiting(seconds: 3) == "Thinking \u{00B7} 3 s")
        #expect(QuickQuestionText.waiting(seconds: -1) == "Thinking \u{00B7} 0 s")
        #expect(QuickQuestionText.hint == "Claude answers from this session's context. The session never sees the question.")
        #expect(QuickQuestionText.placeholder == "Ask a quick question")
    }
}

struct QuickQuestionThemeTests {
    typealias Appearance = LoomTheme.Appearance

    @Test func primaryAndSecondaryTextHoldTheirTiersOnThePanelsSurfaceInBothAppearancesAndEveryTone() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let surface = LoomTheme.QuickQuestion.fillRGB(appearance, tone: tone)
                let id = "\(appearance) \(tone)"
                #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: surface) >= 7, "primary on \(id)")
                #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: surface) >= 4.5, "secondary on \(id)")
                // The field's placeholder is the popover's, which holds the secondary tier.
                #expect(LoomTheme.OnPopover.placeholderPair[appearance].contrast(with: surface) >= 4.5, "placeholder on \(id)")
            }
        }
    }
}

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct QuickQuestionModelFlowTests {
    private struct Fixture {
        let rig: LiveRig
        let model: CatalogModel
        let controller: ConversationController

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            await rig.finish()
        }
    }

    private func make(environment: [String: String] = [:]) async throws -> Fixture {
        let rig = try await LiveRig.make(environment: environment)
        let model = CatalogModel(
            catalog: await rig.runtime.catalog, events: await rig.runtime.supervisor.events,
            preferences: UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: rig.runtime, model: model)
        await controller.begin()
        await model.start()
        model.installChatSessions(runtime: rig.runtime, dataRoot: rig.root)
        model.useFrozenChatFace()
        model.setClaudeConfigDirectory(rig.profile)
        return Fixture(rig: rig, model: model, controller: controller)
    }

    private func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    @Test func theMenuAndPaletteAreOnForARunningChatSessionOnlyAndThePanelAsksThroughTheDriver() async throws {
        let fixture = try await make()
        let model = fixture.model

        // Nothing selected: off, with the reason.
        #expect(!model.canAskQuickQuestion)
        #expect(model.quickQuestionUnavailableReason == "Quick questions need a running Chat session")
        #expect(!PaletteAction.askQuickQuestion.isEnabled(on: model))
        model.askQuickQuestion()
        #expect(model.quick.panel(for: UUID()) == nil)

        // A running Chat session.
        model.showDraft(projectID: nil)
        model.setDraftText("hello", projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.destination?.sessionID != nil })
        let id = try #require(model.destination?.sessionID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { await driver.snapshot().model.entries.contains {
            if case let .assistantText(text) = $0.body { text.text == "Fake answer to: hello" } else { false }
        } })
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await waitUntil { model.selectedRow != nil })
        let row = try #require(model.selectedRow)
        let feed = try #require(model.liveChatFeed(for: driver, card: id, conversationID: nil,
                                                   workingDirectory: row.record.session.workingDirectory))
        let composer = try #require(model.liveChatComposer(for: driver, row: row, feed: feed))
        composer.start()
        await composer.refresh()
        #expect(model.quickQuestionAvailability(for: id) == .available)
        #expect(model.canAskQuickQuestion && model.quickQuestionUnavailableReason == nil)
        #expect(PaletteAction.askQuickQuestion.isEnabled(on: model))
        #expect(PaletteAction.askQuickQuestion.title == "Ask a quick question")
        #expect(PaletteAction.askQuickQuestion.keyHint == "\u{2318};")

        // The palette's action opens the panel, which asks through the driver and shows the answer.
        let before = await driver.snapshot().model.entries.map(\.id)
        PaletteAction.askQuickQuestion.run(on: model)
        let panel = try #require(model.quick.panel(for: id))
        #expect(panel.isOpen)
        panel.text = "what did I just say?"
        panel.submit()
        #expect(await waitUntil { panel.answer != nil })
        #expect(panel.answer == "Fake side answer to: what did I just say?" && panel.failure == nil)
        #expect(await driver.snapshot().model.entries.map(\.id) == before, "the session never saw the question")

        // A handover or a stop closes it; a stopped session turns the action off, with the reason.
        _ = try await driver.stop()
        await composer.refresh()
        #expect(model.quickQuestionAvailability(for: id) == .stopped)
        #expect(!model.canAskQuickQuestion && model.quickQuestionUnavailableReason == "Quick questions need a running Chat session")
        #expect(!PaletteAction.askQuickQuestion.isEnabled(on: model))
        panel.reconcile(model.quickQuestionAvailability(for: id))
        #expect(!panel.isOpen && panel.answer == nil)
        model.askQuickQuestion()
        #expect(!panel.isOpen, "a stopped session is never asked, nor resumed")
        #expect(await driver.currentPhase == .stopped)
        await fixture.cleanup()
    }
}
