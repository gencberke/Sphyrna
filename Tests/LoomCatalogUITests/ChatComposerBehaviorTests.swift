import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The Chat composer on the real Chat driver and the fake provider (V17): the keys' meanings through the model, delivery
// states, Read now, the queue, drafts, attachments, the chips and the menus. Nothing here sends a message to a real Claude.

/// A text view stand-in for the model's bridge: the text, a caret, and the same call back a real field makes.
@MainActor
final class FakeComposerEditor: ComposerEditorBridge {
    var text = ""
    var caret = 0
    weak var model: ChatComposerModel?

    init(model: ChatComposerModel) {
        self.model = model
        model.editor = self
    }

    func hasMarkedText() -> Bool { false }
    var caretLocation: Int { caret }
    var hasSelection: Bool { false }
    var utf16Length: Int { text.utf16.count }
    func currentText() -> String { text }
    func replaceAll(with value: String) { text = value; caret = value.utf16.count }
    func substring(_ range: NSRange) -> String { (text as NSString).substring(with: range) }
    func replace(_ range: NSRange, with value: String) {
        text = (text as NSString).replacingCharacters(in: range, with: value)
        caret = range.location + (value as NSString).length
        model?.textChanged(text)
    }
    func insertAtCaret(_ value: String) { replace(NSRange(location: caret, length: 0), with: value) }
    func caretLines() -> (first: Bool, last: Bool) { (true, true) }
    var focusCount = 0
    func focus() { focusCount += 1 }

    /// The user types: one character after another, each reported as a keystroke is.
    func type(_ value: String) { for character in value { insertAtCaret(String(character)) } }
}

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ChatComposerBehaviorTests {
    @MainActor struct Fixture {
        let rig: LiveRig
        let host: ChatSessionHost
        let driver: ChatSessionDriver
        let composer: ChatComposerModel
        let id: UUID
        var store: ChatDraftStore { host.draftStore }
    }

    private func make(files: String? = nil, started: Bool = true) async throws -> Fixture {
        let rig = try await LiveRig.make()
        let id = UUID()
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root)
        let driver = started ? try await host.startNewSession(projectID: nil, sessionID: id) : host.driver(for: id)
        var environment = ComposerEnvironment()
        environment.draftDelay = .milliseconds(40)
        environment.mentionDebounce = .milliseconds(10)
        environment.workingDirectory = { files }
        let composer = ChatComposerModel(driver: driver, card: id, drafts: host.draftStore, environment: environment)
        composer.start()
        await composer.refresh()
        return Fixture(rig: rig, host: host, driver: driver, composer: composer, id: id)
    }

    private func waitUntil(_ seconds: Double = 12, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func idle(_ fixture: Fixture) async -> Bool {
        await waitUntil { await fixture.composer.refresh(); return fixture.composer.state.phase == .ready && !fixture.composer.state.turnRunning }
    }

    private func working(_ fixture: Fixture) async -> Bool {
        await waitUntil { await fixture.composer.refresh(); return fixture.composer.state.turnRunning }
    }

    private func prompts(_ fixture: Fixture) async -> [String] {
        await fixture.driver.snapshot().model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
    }

    /// The row of a message: its text equals `text`, or starts with it (a message with a pasted text reads on after it).
    private func prompt(_ text: String, _ fixture: Fixture, prefix: Bool = false) async -> (id: String, delivery: UserPrompt.Delivery)? {
        for entry in await fixture.driver.snapshot().model.entries {
            if case let .user(prompt) = entry.body, prefix ? prompt.text.hasPrefix(text) : prompt.text == text {
                return (entry.id, prompt.delivery)
            }
        }
        return nil
    }

    private func type(_ text: String, into fixture: Fixture) {
        fixture.composer.textChanged(text)
        fixture.composer.setText(text)
    }

    // MARK: Sending

    @Test func returnSendsTheMessageEmptiesTheFieldAndRemembersIt() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        type("hello there", into: fixture)
        #expect(composer.sendKind(commandHeld: false) == .send)
        composer.submit(secondary: false)
        #expect(composer.text.isEmpty)
        #expect(!composer.hasContent)
        await composer.settled()
        #expect(await idle(fixture))
        #expect(await prompts(fixture) == ["hello there"])
        #expect(await prompt("hello there", fixture)?.delivery == .read)
        #expect(composer.history.messages.last == "hello there")
        // The draft file went with the send.
        #expect(try fixture.store.load(sessionID: fixture.id) == nil)
        await fixture.rig.finish()
    }

    @Test func returnWhileClaudeWorksAlwaysSendsNextEvenWhenOnlyABashCallRuns() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        // Only a Bash call runs. ↵ is `next` all the same: it cancels nothing and never moves the command to the background,
        // so the CLI holds the message until the step ends, and Claude reads it after the Bash call.
        try await fixture.driver.send("/scenario work 4000")
        #expect(await working(fixture))
        type("wait for the step", into: fixture)
        composer.submit(secondary: false)
        await composer.settled()
        #expect(await waitUntil { await prompt("wait for the step", fixture)?.delivery == .queued })
        try await Task.sleep(for: .milliseconds(600))
        #expect(await prompt("wait for the step", fixture)?.delivery == .queued, "not read while the Bash call runs")
        #expect(await waitUntil(20) { await prompt("wait for the step", fixture)?.delivery == .read })
        #expect(await idle(fixture))
        // A subagent runs: ↵ is `next`, the CLI holds the message until the step ends, and its row offers Read now.
        try await fixture.driver.send("/scenario subagent 7000")
        #expect(await working(fixture))
        type("hold this", into: fixture)
        composer.submit(secondary: false)
        await composer.settled()
        #expect(await waitUntil { await prompt("hold this", fixture)?.delivery == .queued })
        #expect(await waitUntil { await composer.refresh(); return composer.state.unreadMessageIDs.count == 1 })
        let held = try #require(await prompt("hold this", fixture))
        composer.readNow(rowID: held.id)
        #expect(await waitUntil { await prompt("hold this", fixture)?.delivery == .read })
        #expect(await waitUntil { await composer.refresh(); return composer.state.unreadMessageIDs.isEmpty })
        #expect(await idle(fixture))
        await fixture.rig.finish()
    }

    @Test func commandReturnQueuesInLoomsQueueAndTheTurnsEndSendsThemInOrder() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario work 3000")
        #expect(await working(fixture))
        #expect(composer.sendKind(commandHeld: false) == .interrupt)
        type("first", into: fixture)
        #expect(composer.sendKind(commandHeld: false) == .sendNow)
        #expect(composer.sendKind(commandHeld: true) == .afterTurn)
        composer.submit(secondary: true)
        await composer.settled()
        type("second", into: fixture)
        composer.submit(secondary: true)
        await composer.settled()
        #expect(await waitUntil { await composer.refresh(); return composer.state.queue.items.map(\.text) == ["first", "second"] })
        #expect(composer.text.isEmpty)
        #expect(await waitUntil(25) { await composer.refresh(); return composer.state.queue.isEmpty && composer.state.phase == .ready && !composer.state.turnRunning })
        #expect(await prompts(fixture) == ["/scenario work 3000", "first", "second"])
        await fixture.rig.finish()
    }

    @Test func aQueuedMessageCarriesTextOnlyAndTheAttachmentsStay() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario work 4000")
        #expect(await working(fixture))
        type("with a paste", into: fixture)
        composer.addPastedText(String(repeating: "pasted line\n", count: 4_000))
        #expect(composer.attachments.count == 1)
        composer.submit(secondary: true)
        await composer.settled()
        #expect(composer.notice?.text.contains("text only") == true)
        #expect(composer.attachments.count == 1)
        #expect(composer.text == "with a paste")
        #expect(composer.state.queue.isEmpty)
        #expect(await idle(fixture))
        await fixture.rig.finish()
    }

    @Test func aMessageThatCannotBeSentComesBackAndStaysInTheDraft() async throws {
        let fixture = try await make(started: false)
        let composer = fixture.composer
        type("do not lose me", into: fixture)
        composer.submit(secondary: false)
        await composer.settled()
        // Whether the driver refuses or the child cannot start, the words are back in the field and in the draft file.
        #expect(await waitUntil { composer.notice != nil || composer.text == "do not lose me" })
        #expect(composer.text == "do not lose me")
        #expect(try fixture.store.load(sessionID: fixture.id)?.text == "do not lose me")
        await fixture.rig.finish()
    }

    // MARK: Interrupt, pause, resume, edit

    @Test func anInterruptKeepsTypedTextPausesTheQueueAndResumeSendsIt() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario work 9000")
        #expect(await working(fixture))
        type("queued one", into: fixture)
        composer.submit(secondary: true)
        await composer.settled()
        type("still typing", into: fixture)
        composer.interrupt()
        #expect(await idle(fixture))
        // Esc loses nothing: the typed text is where it was, the queue waits and says why.
        #expect(composer.text == "still typing")
        #expect(composer.state.queue.items.map(\.text) == ["queued one"])
        #expect(composer.state.queue.paused == .interrupted)
        #expect(composer.sendKind(commandHeld: false) == .send)
        type("", into: fixture)
        #expect(composer.sendKind(commandHeld: false) == .resume)
        composer.resumeQueue()
        #expect(await waitUntil { await prompt("queued one", fixture) != nil })
        #expect(await waitUntil(20) { await composer.refresh(); return composer.state.queue.isEmpty })
        #expect(composer.state.queue.paused == nil)
        await fixture.rig.finish()
    }

    @Test func aQueuedMessageCanBeEditedUpdatedCancelledAndSentWhileEdited() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario work 9000")
        #expect(await working(fixture))
        for text in ["q1", "q2"] {
            type(text, into: fixture)
            composer.submit(secondary: true)
            await composer.settled()
        }
        composer.interrupt()
        #expect(await idle(fixture))
        let ids = composer.state.queue.items.map(\.id)
        #expect(ids.count == 2)
        // Edit: the item moves into the composer, what was typed waits; Update puts the new text in place.
        type("my own draft", into: fixture)
        composer.beginEdit(ids[0])
        #expect(composer.text == "q1")
        #expect(composer.editing?.itemID == ids[0])
        #expect(composer.sendKind(commandHeld: false) == .update)
        type("q1 changed", into: fixture)
        composer.updateQueuedMessage()
        #expect(await waitUntil { composer.editing == nil })
        #expect(composer.state.queue.items.map(\.text) == ["q1 changed", "q2"])
        #expect(composer.text == "my own draft")
        // Cancel: the draft comes back and the item is as it was.
        composer.beginEdit(ids[1])
        type("never saved", into: fixture)
        composer.cancelEdit()
        #expect(composer.text == "my own draft")
        #expect(composer.state.queue.items.map(\.text) == ["q1 changed", "q2"])
        // Reorder.
        composer.moveQueued(ids[1], by: -1)
        #expect(await waitUntil { await composer.refresh(); return composer.state.queue.items.map(\.text) == ["q2", "q1 changed"] })
        // The queue sends the item that is being edited: the edit ends, the text stays, and a notice says so.
        composer.beginEdit(ids[0])
        type("edited while it left", into: fixture)
        composer.resumeQueue()
        #expect(await waitUntil { composer.editing == nil })
        #expect(composer.text.contains("edited while it left"))
        #expect(composer.text.contains("my own draft"))
        #expect(composer.notice?.text.contains("sent while you edited") == true)
        #expect(await idle(fixture))
        await fixture.rig.finish()
    }

    @Test func removeAndSendNowActOnTheirOwnRowAndClearEmptiesAPausedQueue() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario work 9000")
        #expect(await working(fixture))
        for text in ["a", "b", "c"] {
            type(text, into: fixture)
            composer.submit(secondary: true)
            await composer.settled()
        }
        composer.interrupt()
        #expect(await idle(fixture))
        let ids = composer.state.queue.items.map(\.id)
        composer.removeQueued(ids[0])
        #expect(await waitUntil { await composer.refresh(); return composer.state.queue.items.map(\.text) == ["b", "c"] })
        composer.sendQueuedNow(ids[2])
        #expect(await waitUntil { await prompt("c", fixture) != nil })
        #expect(await idle(fixture))
        #expect(composer.state.queue.items.map(\.text) == ["b"])
        composer.clearQueue()
        #expect(await waitUntil { await composer.refresh(); return composer.state.queue.isEmpty })
        await fixture.rig.finish()
    }

    @Test func messagesClaudeHadNotReadComeBackIntoTheComposerWithTheirAttachments() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario subagent 9000")
        #expect(await working(fixture))
        type("held with a paste", into: fixture)
        composer.addPastedText(String(repeating: "pasted line\n", count: 4_000))
        composer.submit(secondary: false)
        await composer.settled()
        #expect(await waitUntil { await prompt("held with a paste", fixture, prefix: true)?.delivery == .queued })
        type("typed after", into: fixture)
        composer.interrupt()
        #expect(await idle(fixture))
        #expect(await waitUntil { composer.text.contains("held with a paste") })
        // The unread message comes back in front of what was typed since, with its attachment.
        #expect(composer.text == "held with a paste\n\ntyped after")
        #expect(composer.attachments.count == 1)
        #expect(await prompt("held with a paste", fixture, prefix: true)?.delivery == .cancelled)
        // And the draft file holds it, so a crash right now loses nothing.
        composer.flushDraft()
        #expect(try fixture.store.load(sessionID: fixture.id)?.text == "held with a paste\n\ntyped after")
        await fixture.rig.finish()
    }

    // MARK: Cards

    @Test func returnAndEscapeNeverAnswerACardWaiting() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario approval")
        #expect(await waitUntil { await composer.refresh(); return composer.state.requestCount == 1 })
        // An empty field sends nothing, and the key rules ignore Esc while a card waits.
        composer.submit(secondary: false)
        let editor = FakeComposerEditor(model: composer)
        let keyState = composer.keyState(isRepeat: false, hasMarkedText: false, bridge: editor)
        #expect(keyState.cardWaiting)
        #expect(ComposerKeys.resolve(keyCode: ComposerKeys.escape, modifiers: [], state: keyState) == .ignore)
        #expect(await fixture.driver.snapshot().requests.count == 1)
        #expect(composer.state.phase == .needsYou)
        // The card is answered on the card; the composer follows.
        let request = try #require(await fixture.driver.snapshot().requests.first)
        try await fixture.driver.respond(to: request.requestID, with: .allow(updatedInput: request.request.input),
                                         record: RequestRecord(kind: .approval, summary: "Allowed once"))
        #expect(await idle(fixture))
        await fixture.rig.finish()
    }

    // MARK: Drafts

    @Test func aDraftIsSavedAfterAPauseAndSurvivesARelaunchAndQuit() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        composer.textChanged("half a thought")
        // Written 300 ms after the last change (40 ms in this test), not on every keystroke.
        #expect(await waitUntil { (try? fixture.store.load(sessionID: fixture.id))?.text == "half a thought" })
        composer.addPastedText(String(repeating: "x", count: 40_000))
        composer.textChanged("half a thought, more")
        // Quit: the draft is flushed at once.
        composer.flushDraft()
        let saved = try #require(try fixture.store.load(sessionID: fixture.id))
        #expect(saved.text == "half a thought, more")
        #expect(saved.attachments.count == 1)
        // A new composer (the app started again) finds text and attachment where they were left.
        var environment = ComposerEnvironment()
        environment.draftDelay = .milliseconds(40)
        let again = ChatComposerModel(driver: fixture.driver, card: fixture.id, drafts: fixture.store, environment: environment)
        await again.attachmentsRestored()
        #expect(again.text == "half a thought, more")
        #expect(again.attachments.count == 1)
        #expect(again.attachments.first?.isImage == false)
        // Sending it clears the file.
        again.submit(secondary: false)
        await again.settled()
        #expect(await idle(fixture))
        #expect(try fixture.store.load(sessionID: fixture.id) == nil)
        await fixture.rig.finish()
    }

    @Test func anImageInTheDraftComesBackWithItsThumbnailAndGoesOutAsABlock() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        composer.attachImage(png, name: "shot.png")
        #expect(await waitUntil { composer.attachments.count == 1 })
        #expect(composer.attachments.first?.isImage == true)
        #expect(composer.attachments.first?.thumbnail != nil)
        composer.flushDraft()
        var environment = ComposerEnvironment()
        environment.draftDelay = .milliseconds(40)
        let again = ChatComposerModel(driver: fixture.driver, card: fixture.id, drafts: fixture.store, environment: environment)
        await again.attachmentsRestored()
        #expect(again.attachments.count == 1)
        #expect(again.attachments.first?.thumbnail != nil)
        #expect(again.hasContent)
        again.submit(secondary: false)
        await again.settled()
        #expect(await idle(fixture))
        #expect(await fixture.driver.snapshot().model.entries.contains { entry in
            if case let .user(prompt) = entry.body { !prompt.images.isEmpty } else { false }
        })
        await fixture.rig.finish()
    }

    @Test func aDeletedSessionTakesItsDraftAndTheDraftMovesWithAClear() async throws {
        let fixture = try await make()
        fixture.composer.textChanged("kept for the clear")
        fixture.composer.flushDraft()
        let new = UUID()
        fixture.composer.moveDraft(to: new)
        #expect(try fixture.store.load(sessionID: fixture.id) == nil)
        #expect(try fixture.store.load(sessionID: new)?.text == "kept for the clear")
        fixture.host.forget(sessionID: new)
        #expect(try fixture.store.load(sessionID: new) == nil)
        await fixture.rig.finish()
    }

    // MARK: History

    @Test func upRecallsEarlierMessagesOfTheSessionAndDownWalksBackToAnEmptyField() async throws {
        let fixture = try await make()
        for text in ["one", "two"] {
            try await fixture.driver.send(text)
            #expect(await idle(fixture))
        }
        fixture.composer.environment.historyTexts = { ["one", "two"] }
        fixture.composer.recallOlder()
        #expect(fixture.composer.text == "two")
        fixture.composer.recallOlder()
        #expect(fixture.composer.text == "one")
        fixture.composer.recallNewer()
        #expect(fixture.composer.text == "two")
        fixture.composer.recallNewer()
        #expect(fixture.composer.text.isEmpty)
        fixture.composer.recallOlder()
        // An edit ends the walk: ↑ does not replace what was typed.
        fixture.composer.textChanged("two, edited")
        #expect(!fixture.composer.history.isRecalling)
        await fixture.rig.finish()
    }

    // MARK: The bar: mode, model, effort, context, compact

    @Test func theChipsChangeTheRunOneAfterTheOtherAndTheBarReadsThem() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        // Before any turn the model chip reads Default model; the mode is the one the CLI reported.
        #expect(ComposerBarText.modelTitle(composer.state) == "Default model" || composer.state.resolvedModel != nil)
        await composer.setEffort("high").value
        await composer.setMode("acceptEdits").value
        #expect(composer.state.permissionMode == "acceptEdits")
        #expect(ComposerBarText.modeTitle(permissionMode: composer.state.permissionMode, choices: composer.state.choices) == "Accept edits")
        await composer.setMode("plan").value
        await composer.setModel("sonnet").value
        await composer.setEffort("low").value
        #expect(composer.state.permissionMode == "plan")
        #expect(composer.state.choices.effort == "low")
        #expect(composer.state.choices.model == "sonnet")
        #expect(ComposerBarText.effortTitle(composer.state) == "Low")
        // A mode the CLI refuses leaves the chip as it was and says so.
        await composer.setMode("not-a-mode").value
        #expect(composer.state.permissionMode == "plan")
        #expect(composer.notice?.text == "The mode was not changed.")
        await fixture.rig.finish()
    }

    @Test func theRingReadsTheContextAndCompactNowAsksClaudeOnlyWhenIdle() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("hello")
        #expect(await idle(fixture))
        await composer.refresh()
        let usage = ComposerBarText.contextUsage(composer.state, fallback: nil)
        #expect((usage?.tokens ?? 0) > 0)
        try await fixture.driver.send("/scenario work 4000")
        #expect(await working(fixture))
        composer.compactNow()
        await composer.settled()
        #expect(await prompt("/compact", fixture) == nil)
        #expect(await idle(fixture))
        composer.compactNow()
        await composer.settled()
        #expect(await waitUntil { await prompt("/compact", fixture) != nil })
        await fixture.rig.finish()
    }

    // MARK: Menus

    @Test func slashOpensCommandsFromTheFirstCharacterAndAChoiceInsertsItsName() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let editor = FakeComposerEditor(model: composer)
        try await fixture.driver.send("hello")
        #expect(await idle(fixture))
        await composer.refresh()
        editor.type("/")
        let menu = try #require(composer.menu)
        #expect(menu.kind == .commands)
        #expect(menu.items.contains { $0.title == "/compact" })
        editor.type("comp")
        #expect(composer.menu?.items.first?.title == "/compact")
        composer.chooseSelected()
        #expect(editor.text == "/compact ")
        #expect(composer.menu == nil)
        // A slash in the middle of a message opens nothing.
        composer.setText("")
        editor.type("see a/b")
        #expect(composer.menu == nil)
        await fixture.rig.finish()
    }

    @Test func atListsFilesOfTheSessionsFolderAndAChoiceInsertsAMention() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-mention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        for name in ["README.md", "docs/readme-draft.md", "Package.swift"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try await make(files: folder.path)
        let composer = fixture.composer
        let editor = FakeComposerEditor(model: composer)
        editor.type("look at @read")
        #expect(await waitUntil { composer.menu?.items.contains { $0.title == "README.md" } == true })
        #expect(composer.menu?.kind == .mention)
        #expect(composer.menu?.loading == false)
        composer.chooseSelected()
        #expect(editor.text == "look at @README.md ")
        // Esc closes the menu and the same trigger stays closed.
        composer.setText("")
        editor.type("@Pack")
        #expect(await waitUntil { composer.menu != nil })
        composer.closeMenuState()
        #expect(composer.menu == nil)
        await fixture.rig.finish()
    }

    @Test func aSessionInTheHomeFolderMentionsSessionsOnlyAndNeverScansIt() async throws {
        let fixture = try await make(files: NSHomeDirectory())
        let composer = fixture.composer
        var environment = composer.environment
        environment.sessionCandidates = {
            [ComposerSessionCandidate(id: UUID(), title: "Fix the login bug", project: "Web", lastActivity: Date())]
        }
        composer.environment = environment
        let editor = FakeComposerEditor(model: composer)
        editor.type("@login")
        #expect(await waitUntil { composer.menu?.items.contains { $0.kind == .session } == true && composer.menu?.loading == false })
        #expect(composer.menu?.items.allSatisfy { $0.kind == .session } == true)
        await fixture.rig.finish()
    }

    // MARK: Typing cost

    @Test func typingCostsTheSameAtAnyLength() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let editor = FakeComposerEditor(model: composer)
        let base = String(repeating: "lorem ipsum dolor sit amet ", count: 40_000) // about 1 MB
        editor.text = base
        editor.caret = base.utf16.count
        composer.textChanged(base)
        let reads = composer.fullTextReads
        var text = base
        for _ in 0..<400 {
            text += "x"
            editor.text = text
            editor.caret = text.utf16.count
            composer.textChanged(text)
        }
        // A keystroke stores the text once and looks at the few characters before the caret: no read of the whole text.
        #expect(composer.fullTextReads == reads)
        #expect(composer.menu == nil)
        await fixture.rig.finish()
    }

    /// Test gap (V17): typing in the real field costs about the same at any length (the field's text is read once per
    /// keystroke and the model keeps no second copy of it).
    @Test func typingInTheRealFieldStaysCheapWithAMegabyteOfText() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let height = Binding<CGFloat>.constant(60)
        let editor = ComposerTextEditor(host: composer, height: height, minimumHeight: 60, maximumHeight: 220)
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextEditor.ComposerTextView()
        view.coordinator = coordinator
        coordinator.textView = view
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        composer.editorAttached(view)
        func average(_ keystrokes: Int) -> Double {
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<keystrokes {
                view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return (ProcessInfo.processInfo.systemUptime - started) / Double(keystrokes) * 1000
        }
        let small = average(100)
        composer.setText(String(repeating: "lorem ipsum dolor sit amet ", count: 40_000))
        let large = average(100)
        print("typing cost: small \(small) ms, 1 MB \(large) ms per keystroke")
        #expect(large < 30, "a keystroke in a megabyte of text took \(large) ms (small: \(small) ms)")
        await fixture.rig.finish()
    }

    // MARK: Fix round (V17)

    /// Fix 2: a send that fails puts the attachments back with the text, and their files stay beside the draft.
    @Test func aFailedSendKeepsItsAttachmentsAndTheirFiles() async throws {
        let fixture = try await make(started: false)
        let composer = fixture.composer
        type("do not lose me", into: fixture)
        composer.addPastedText(String(repeating: "pasted line\n", count: 4_000))
        composer.submit(secondary: false)
        await composer.settled()
        #expect(await waitUntil { composer.notice != nil && composer.text == "do not lose me" })
        #expect(composer.attachments.count == 1, "the attachment came back with the text")
        await composer.attachmentFilesWritten()
        composer.flushDraft()
        let draft = try #require(try fixture.store.load(sessionID: fixture.id))
        #expect(draft.attachments.count == 1)
        #expect(fixture.store.attachmentData(id: draft.attachments[0].id, sessionID: fixture.id) != nil)
        await fixture.rig.finish()
    }

    /// Fix 3: Update refuses while the composer holds attachments, and loses none.
    @Test func updateRefusesWhileAttachmentsArePresent() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario work 9000")
        #expect(await working(fixture))
        type("queued", into: fixture)
        composer.submit(secondary: true)
        await composer.settled()
        composer.interrupt()
        #expect(await idle(fixture))
        let id = try #require(composer.state.queue.items.first?.id)
        composer.beginEdit(id)
        type("queued, changed", into: fixture)
        composer.addPastedText(String(repeating: "pasted line\n", count: 4_000))
        composer.updateQueuedMessage()
        try await Task.sleep(for: .milliseconds(300))
        #expect(composer.editing != nil, "the edit goes on")
        #expect(composer.attachments.count == 1)
        #expect(composer.notice?.text.contains("text only") == true)
        #expect(composer.state.queue.items.map(\.text) == ["queued"], "nothing was saved")
        await fixture.rig.finish()
    }

    /// Fix 6: a queued message the queue sent while it was edited gives back the user's own draft when the edit was not
    /// changed; Remove and Clear end the edit without saying it was sent.
    @Test func aQueuedMessageSentWhileEditedKeepsTheTextOnlyIfChangedAndRemoveIsNotASend() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        try await fixture.driver.send("/scenario work 9000")
        #expect(await working(fixture))
        for text in ["q1", "q2", "q3"] {
            type(text, into: fixture)
            composer.submit(secondary: true)
            await composer.settled()
        }
        composer.interrupt()
        #expect(await idle(fixture))
        let ids = composer.state.queue.items.map(\.id)
        #expect(ids.count == 3)
        // Remove the item being edited: the draft comes back and nothing says "sent".
        type("my own draft", into: fixture)
        composer.beginEdit(ids[2])
        composer.removeQueued(ids[2])
        #expect(await waitUntil { await composer.refresh(); return composer.state.queue.items.count == 2 })
        #expect(composer.editing == nil && composer.text == "my own draft")
        #expect(composer.notice?.text.contains("sent while you edited") != true)
        // The queue sends the item being edited, unchanged: the user's draft comes back and the text is not duplicated.
        composer.beginEdit(ids[0])
        composer.resumeQueue()
        #expect(await waitUntil { composer.editing == nil })
        #expect(composer.text == "my own draft", "\(composer.text)")
        #expect(composer.notice?.text == "That message was sent while you edited it.")
        #expect(await idle(fixture))
        await fixture.rig.finish()
    }

    /// Fix 8 and 11 are the driver's (`ChatFixRoundDriverTests`); fix 13's identity check:
    @Test func anEditorThatIsNotTheCurrentOneCannotDetachTheCurrentOne() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let old = FakeComposerEditor(model: composer)
        let current = FakeComposerEditor(model: composer)
        composer.editorFocusChanged(true)
        composer.editorDetached(old)
        #expect(composer.editor === current, "the old field going away leaves the new one attached")
        #expect(composer.hasEditorFocus)
        composer.editorDetached(current)
        #expect(composer.editor == nil && !composer.hasEditorFocus, "the field going away is a loss of focus")
        await fixture.rig.finish()
    }

    /// Fix 14: a composer the host forgot (its session was deleted) writes no draft any more.
    @Test func aForgottenComposerWritesNoDraft() async throws {
        let fixture = try await make()
        let composer = fixture.host.attachment(for: fixture.driver) { fixture.composer }
        type("about to be forgotten", into: fixture)
        composer.flushDraft()
        #expect(try fixture.store.load(sessionID: fixture.id)?.text == "about to be forgotten")
        fixture.host.forget(sessionID: fixture.id)
        #expect(try fixture.store.load(sessionID: fixture.id) == nil, "forget removes the draft")
        type("typed after", into: fixture)
        composer.flushDraft()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try fixture.store.load(sessionID: fixture.id) == nil, "and nothing writes it back")
        await fixture.rig.finish()
    }

    /// Fix 10: a paste over the chip limit is refused with a notice; nothing is kept.
    @Test func aPasteOverTheLimitIsRefusedWithANotice() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        composer.addPastedText(String(repeating: "x", count: ComposerPaste.maximumChipBytes + 1))
        #expect(composer.attachments.isEmpty)
        #expect(composer.notice?.text.contains("16 MB") == true)
        await fixture.rig.finish()
    }
}

// MARK: The text view

@MainActor
struct ComposerTextViewTests {
    /// Text the model puts in (a menu choice, a recall) carries the composer's font and colour. Without the typing
    /// attributes it took the storage's default: small and black on a dark card (seen in the first evidence run).
    @Test func textInsertedThroughTheBridgeKeepsTheComposersFontAndColour() throws {
        let view = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        view.isRichText = false
        view.font = NSFont.systemFont(ofSize: LoomTheme.TypeScale.readingSize)
        view.textColor = NSColor(LoomTheme.Text.primary)
        view.insertAtCaret("hello")
        let storage = try #require(view.textStorage)
        #expect(storage.length == 5)
        let attributes = storage.attributes(at: 0, effectiveRange: nil)
        #expect(attributes[.font] as? NSFont == view.font)
        #expect(attributes[.foregroundColor] as? NSColor == view.textColor)
        view.replace(NSRange(location: 0, length: 5), with: "bye")
        let after = storage.attributes(at: 0, effectiveRange: nil)
        #expect(after[.font] as? NSFont == view.font)
        #expect(after[.foregroundColor] as? NSColor == view.textColor)
    }
}
