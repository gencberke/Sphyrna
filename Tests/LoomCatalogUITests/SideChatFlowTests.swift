import AppKit
import CryptoKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat

/// V22 part 3: the Side tab's flows on the model, the real runtime and the Chat driver over the fake provider (a forkable
/// one): the first question forks, a stopped side chat resumes, "New side chat" forks again, "/" is refused where it stands,
/// "Allow edits" reaches the driver and resets, a waiting side chat raises nothing outside the tab, "Send to main as a note"
/// reaches the parent as one `next` message, and Discard goes through part 2's path. A side chat's messages that must reach
/// the fake as a scenario begin with `~scenario` (a side chat sends no text that starts with a slash).
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(8)))
struct SideChatFlowTests {
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

    private func make(forkable: Bool = true) async throws -> Fixture {
        let rig = try await LiveRig.make(forkable: forkable)
        let model = CatalogModel(
            catalog: await rig.runtime.catalog, events: await rig.runtime.supervisor.events,
            preferences: UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: rig.runtime, model: model)
        await controller.begin()
        await model.start()
        model.installChatSessions(runtime: rig.runtime, dataRoot: rig.root)
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

    private func startFromDraft(_ model: CatalogModel, text: String) async throws -> UUID {
        model.showDraft(projectID: nil)
        model.setDraftText(text, projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.destination?.sessionID != nil })
        return try #require(model.destination?.sessionID)
    }

    /// A parent that has answered once, with its driver.
    private func parent(_ fixture: Fixture, text: String = "hello") async throws -> (id: UUID, driver: ChatSessionDriver) {
        let id = try await startFromDraft(fixture.model, text: text)
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { await Self.hasAnswered(driver) })
        return (id, driver)
    }

    private func idle(_ driver: ChatSessionDriver, prompts count: Int) async -> Bool {
        await waitUntil {
            let snapshot = await driver.snapshot()
            return snapshot.phase == .ready && !snapshot.turnRunning && Self.prompts(snapshot).count >= count
        }
    }

    private static func hasAnswered(_ driver: ChatSessionDriver) async -> Bool {
        let snapshot = await driver.snapshot()
        return snapshot.phase == .ready && !snapshot.turnRunning && !snapshot.model.turns.isEmpty
    }

    private static func prompts(_ snapshot: ChatDriverSnapshot) -> [String] {
        snapshot.model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
    }

    private static func answers(_ snapshot: ChatDriverSnapshot) -> [String] {
        snapshot.model.entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } }
    }

    private func ask(_ model: CatalogModel, _ session: SideSession, _ parent: UUID, _ text: String) async {
        session.composerText = text
        await model.submitSideQuestion(in: parent)
    }

    private func transcript(named conversation: String, under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "\(conversation).jsonl" { return url }
        }
        return nil
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Asking

    @Test func theFirstQuestionForksAStoppedSideChatResumesAndNewSideChatForksAgain() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, parentDriver) = try await parent(fixture)
        let session = model.side.session(for: parent)

        // The first question, with no side chat open, starts a fork and goes to it.
        await ask(model, session, parent, "What does it do?")
        #expect(session.notice == nil)
        #expect(session.composerText.isEmpty)
        let first = try #require(session.openID)
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).map(\.session.id) == [first])
        // Reached as a side chat's driver, never the main session's: another object, and a side chat's.
        let driver = try #require(model.chatSessions?.existingDriver(for: first))
        #expect(await driver.isSideChat)
        #expect(driver !== parentDriver && model.liveChatDriver(for: parent) === parentDriver)
        #expect(await idle(driver, prompts: 1))
        #expect(Self.prompts(await driver.snapshot()) == ["What does it do?"])
        // The send wrote the first question's uuid and title to the card, and the tab read them.
        #expect(session.item(first)?.title == "What does it do?")
        #expect(session.item(first)?.firstUUID != nil)
        // The parent saw nothing of it.
        #expect(Self.prompts(await parentDriver.snapshot()) == ["hello"])

        // Close: the process stops, the thread stays, and the tab keeps the side chat open.
        await model.closeSideChat(first, in: parent)
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        #expect(await waitUntil { session.live(for: first)?.phase == .stopped })
        #expect(session.openID == first && session.items.count == 1)

        // The next question in the stopped side chat resumes that one: no second fork.
        await ask(model, session, parent, "And then?")
        #expect(session.notice == nil)
        #expect(await idle(driver, prompts: 2))
        #expect(Self.prompts(await driver.snapshot()) == ["What does it do?", "And then?"])
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).count == 1)
        #expect(session.openID == first)

        // "New side chat": an empty thread, and its first question forks again.
        model.startNewSideChat(in: parent)
        #expect(session.openID == nil)
        await ask(model, session, parent, "A different question")
        let second = try #require(session.openID)
        #expect(second != first)
        #expect(session.items.map(\.id) == [second, first], "newest first")
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).count == 2)
        let other = try #require(model.chatSessions?.existingDriver(for: second))
        #expect(await idle(other, prompts: 1))

        // Earlier side chats open from the menu; the tab remembers which one it showed, for the session.
        model.openSideChat(first, in: parent)
        #expect(session.openID == first)
        #expect(model.side.session(for: parent) === session)
        #expect(Self.prompts(await parentDriver.snapshot()) == ["hello"], "the main session never saw any of it")
        await fixture.cleanup()
    }

    @Test func aMessageThatBeginsWithASlashIsRefusedWhereItStandsAndForksNothing() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, _) = try await parent(fixture)
        let session = model.side.session(for: parent)

        // With no side chat open: nothing is forked, the text stays in the field, and the notice says why.
        await ask(model, session, parent, "/clear")
        #expect(session.notice == "Commands don't run in a side chat")
        #expect(session.composerText == "/clear", "refused in place: the text stays")
        #expect(session.openID == nil)
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).isEmpty, "a refused command made no fork")
        #expect(model.chatSessions?.existingDriver(for: parent) != nil)

        // With a side chat open: the same, and nothing reaches it.
        await ask(model, session, parent, "A real question")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))
        await ask(model, session, parent, "  /help")
        #expect(session.notice == "Commands don't run in a side chat")
        #expect(session.composerText == "  /help")
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.prompts(await driver.snapshot()) == ["A real question"])
        // A slash inside the text is not a command.
        await ask(model, session, parent, "what does a/b mean?")
        #expect(session.notice == nil)
        #expect(await idle(driver, prompts: 2))
        await fixture.cleanup()
    }

    @Test func aCLIThatCannotForkTurnsTheComposerOffAndLeavesNoCard() async throws {
        let fixture = try await make(forkable: false)
        let model = fixture.model
        let (parent, _) = try await parent(fixture)
        let session = model.side.session(for: parent)

        await ask(model, session, parent, "Anyone there?")
        #expect(session.notice == "This Claude version cannot fork a session")
        #expect(session.forkUnsupported)
        #expect(session.composerText == "Anyone there?", "the question is not lost")
        #expect(session.openID == nil && session.items.isEmpty)
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).isEmpty)
        // Off for the rest of the run: a second try asks nothing of the runtime.
        session.notice = nil
        await model.submitSideQuestion(in: parent)
        #expect(session.notice == "This Claude version cannot fork a session")
        await fixture.cleanup()
    }

    // MARK: Allow edits

    @Test func allowEditsReachesTheDriversPolicyAndIsOffAgainAfterARestart() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, _) = try await parent(fixture)
        let session = model.side.session(for: parent)
        await ask(model, session, parent, "Look around")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))
        #expect(await driver.sideChatState()?.allowsEdits == false, "off by default")
        #expect(await waitUntil { session.live(for: id) != nil })

        // On: the driver's policy turns a Write into a card instead of a refusal; the tab shows the dot meanwhile.
        await model.setSideAllowsEdits(true, chat: id, in: parent)
        #expect(await driver.sideChatState()?.allowsEdits == true)
        #expect(await waitUntil { session.live(for: id)?.allowsEdits == true })
        #expect(!model.sideChatIsWaiting(for: parent))
        await ask(model, session, parent, "~scenario approval write")
        #expect(await waitUntil { await driver.snapshot().requests.count == 1 })
        #expect(await waitUntil { model.sideChatIsWaiting(for: parent) })
        let request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .deny(note: nil))
        #expect(await idle(driver, prompts: 2))
        #expect(await waitUntil { !model.sideChatIsWaiting(for: parent) })

        // Close, then the next question starts the side chat again: edits are off, and a Write is refused with no card.
        await model.closeSideChat(id, in: parent)
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        #expect(await driver.sideChatState()?.allowsEdits == false, "closing takes the permission with the process")
        #expect(await waitUntil { session.live(for: id)?.allowsEdits == false })
        await ask(model, session, parent, "~scenario approval write")
        #expect(session.notice == nil, "\(session.notice ?? "")")
        let reached = await idle(driver, prompts: 3)
        let seen = Self.prompts(await driver.snapshot())
        let phase = await driver.currentPhase
        #expect(reached, "\(seen) \(phase)")
        #expect(await driver.sideChatState()?.allowsEdits == false, "off whenever the side chat starts again")
        #expect(await waitUntil { session.live(for: id)?.allowsEdits == false })
        #expect(await driver.snapshot().requests.isEmpty, "refused, not asked")
        #expect(await driver.sideChatState()?.refusedCount == 1)
        await fixture.cleanup()
    }

    @Test func aSideChatsCardsNeverOfferAllowForThisSession() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, parentDriver) = try await parent(fixture)
        let session = model.side.session(for: parent)
        await ask(model, session, parent, "Hi")
        let id = try #require(session.openID)
        let item = try #require(session.item(id))
        let feed = try #require(model.sideFeed(for: item, in: parent))
        #expect(!feed.cards.offersSessionGrants)
        // The main session's feed is made as it always was.
        let main = try #require(model.liveChatFeed(for: parentDriver, card: parent, conversationID: nil, workingDirectory: nil))
        #expect(main.cards.offersSessionGrants)
        await fixture.cleanup()
    }

    // MARK: Attention

    @Test func aWaitingSideChatRaisesNothingOutsideTheTab() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, parentDriver) = try await parent(fixture)
        let session = model.side.session(for: parent)
        // The parent is the session on screen, its turn seen: what the lists hold now is the baseline.
        model.select(parent)
        #expect(await waitUntil { model.selectedRow?.id == parent })
        try await Task.sleep(for: .milliseconds(300))
        let baseline = (count: model.attentionCount, sessions: model.sessionsNeedingAttention(),
                        needsYou: model.homeBoard().needsYou.map(\.id))
        await ask(model, session, parent, "Look around")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))
        await model.setSideAllowsEdits(true, chat: id, in: parent)
        await ask(model, session, parent, "~scenario approval write")
        #expect(await waitUntil { await driver.snapshot().requests.count == 1 })

        // The tab knows: the dot is up.
        #expect(await waitUntil { model.sideChatIsWaiting(for: parent) })
        // The hub knows the fork's request too (the lists' filter is what keeps it out of them).
        let events = await fixture.rig.runtime.supervisor.events
        #expect(await waitUntil { await events.snapshot().sessions[id]?.pendingRequests.isEmpty == false })
        try await Task.sleep(for: .milliseconds(300))
        func nothingOutside() {
            #expect(model.attentionCount == baseline.count, "the count")
            #expect(model.sessionsNeedingAttention() == baseline.sessions)
            #expect(model.menuBarSummary.approvals.isEmpty)
            #expect(model.homeBoard().needsYou.map(\.id) == baseline.needsYou)
            #expect(!model.activeIDs.contains(id))
            #expect(!model.paletteSessions().map(\.id).contains(id))
        }
        nothingOutside()

        // The control: the same wait in the main session shows up in those lists.
        try await parentDriver.send("/scenario approval write")
        #expect(await waitUntil { await parentDriver.snapshot().requests.count == 1 })
        #expect(await waitUntil { model.menuBarSummary.approvals == [parent] })
        #expect(model.sessionsNeedingAttention().contains(parent))
        #expect(model.attentionCount >= 1)
        #expect(model.homeBoard().needsYou.map(\.id).contains(parent))
        let mainRequest = try #require(await parentDriver.snapshot().requests.first)
        try await parentDriver.answer(requestID: mainRequest.requestID, .deny(note: nil))
        #expect(await waitUntil { model.menuBarSummary.approvals.isEmpty })
        // The side chat still waits, and still raises nothing.
        #expect(model.sideChatIsWaiting(for: parent))
        #expect(!model.sessionsNeedingAttention().contains(id) && !model.homeBoard().needsYou.map(\.id).contains(id))
        #expect(model.menuBarSummary.approvals.isEmpty && !model.activeIDs.contains(id))

        let request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .deny(note: nil))
        #expect(await waitUntil { !model.sideChatIsWaiting(for: parent) })
        await fixture.cleanup()
    }

    // MARK: Send to main

    @Test func sendToMainSendsOneNoteAsNextWithTheExactTextAndTheThreadStartsAtTheFirstQuestion() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, parentDriver) = try await parent(fixture, text: "the parent's own opening")
        let session = model.side.session(for: parent)
        await ask(model, session, parent, "Why this\n\nand that?")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))

        // The stream the tab shows: the fork's file starts with a copy of the parent's records, and the thread does not.
        let item = try #require(session.item(id))
        let forkConversation = try #require(item.conversationID)
        let forkFile = try #require(transcript(named: forkConversation, under: fixture.rig.profile))
        #expect(try String(contentsOf: forkFile, encoding: .utf8).contains("the parent's own opening"), "the copy is in the file")
        let feed = try #require(model.sideFeed(for: item, in: parent))
        feed.start()
        #expect(await waitUntil { feed.phase == .ready && feed.joinedModelForTesting.entries.contains { if case .assistantText = $0.body { true } else { false } } })
        let joined = feed.joinedModelForTesting
        let shownPrompts = joined.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
        #expect(shownPrompts == ["Why this\n\nand that?"], "\(shownPrompts)")
        let answerEntry = try #require(joined.entries.last { if case .assistantText = $0.body { true } else { false } })
        guard case let .assistantText(answer) = answerEntry.body else { return }

        // A turn is under way in the parent: ↵ is `next`, so the note is held by the CLI until the step ends.
        let hold = fixture.rig.root.appendingPathComponent("hold-steps")
        #expect(FileManager.default.createFile(atPath: hold.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: hold) }
        try await parentDriver.send("/scenario work 4000 hold \(hold.path)")
        #expect(await waitUntil { await parentDriver.snapshot().turnRunning })

        let notes = model.sideNotes(for: id, in: parent)
        #expect(notes.availability() == .ready)
        let expected = "A note from a side chat:\n\n> Why this\n>\n> and that?\n\n\(answer.text)"
        await model.sendSideNote(answerID: answerEntry.id, chat: id, in: parent)
        #expect(notes.status(for: answerEntry.id) == .sent)
        let sentPrompts = { () async -> [(text: String, delivery: UserPrompt.Delivery)] in
            await parentDriver.snapshot().model.entries.compactMap { entry in
                if case let .user(prompt) = entry.body { (prompt.text, prompt.delivery) } else { nil }
            }
        }
        #expect(await waitUntil { await sentPrompts().contains { $0.text == expected && $0.delivery == .queued } })
        // One message, through the composer's path (`next`), and a second click sends nothing more.
        await model.sendSideNote(answerID: answerEntry.id, chat: id, in: parent)
        #expect(await sentPrompts().filter { $0.text == expected }.count == 1)
        try FileManager.default.removeItem(at: hold)
        #expect(await waitUntil(30) { await sentPrompts().contains { $0.text == expected && $0.delivery == .read } })
        // The side chat itself got nothing back.
        #expect(Self.prompts(await driver.snapshot()) == ["Why this\n\nand that?"])
        await fixture.cleanup()
    }

    @Test func aStoppedChatParentResumesAndTakesTheNoteAndATerminalParentHasItOff() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, parentDriver) = try await parent(fixture)
        let session = model.side.session(for: parent)
        await ask(model, session, parent, "A question")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))
        let item = try #require(session.item(id))
        let feed = try #require(model.sideFeed(for: item, in: parent))
        feed.start()
        #expect(await waitUntil { feed.phase == .ready && feed.joinedModelForTesting.entries.contains { if case .assistantText = $0.body { true } else { false } } })
        let answerEntry = try #require(feed.joinedModelForTesting.entries.last { if case .assistantText = $0.body { true } else { false } })
        guard case let .assistantText(answer) = answerEntry.body else { return }

        // The parent stops: the note resumes it and is sent.
        try await model.stopChat(parent)
        #expect(await waitUntil { model.rowModels[parent].map { !model.isRunning($0) } == true })
        #expect(model.sideNoteAvailability(for: parent) == .ready)
        await model.sendSideNote(answerID: answerEntry.id, chat: id, in: parent)
        let expected = "A note from a side chat:\n\n> A question\n\n\(answer.text)"
        #expect(await waitUntil {
            Self.prompts(await parentDriver.snapshot()).contains(expected)
        })

        // A session the terminal face runs has no message to send to: the button is off, with the reason.
        model.setNewSessionFace(.terminal)
        let terminal = try await startFromDraft(model, text: "from the terminal")
        #expect(await waitUntil { (try? await fixture.rig.runtime.catalog.session(id: terminal)?.runEndpoint) == .terminal })
        #expect(model.sideNoteAvailability(for: terminal) == .off("Notes go to Claude in a Chat session"))
        #expect(model.chatSessions?.existingDriver(for: terminal) == nil)
        await fixture.cleanup()
    }

    // MARK: Discard

    @Test func discardAsksFirstThenGoesThroughPart2sPathAndLeavesTheParentAsItWas() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, _) = try await parent(fixture)
        let session = model.side.session(for: parent)
        await ask(model, session, parent, "Something to throw away")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))
        let item = try #require(session.item(id))
        let parentRecord = try await fixture.rig.runtime.catalog.session(id: parent)
        let parentConversation = try #require(parentRecord?.session.providerConversationID)
        let parentFile = try #require(transcript(named: parentConversation, under: fixture.rig.profile))
        let before = try sha256(parentFile)
        let forkConversation = try #require(item.conversationID)
        let forkFile = try #require(transcript(named: forkConversation, under: fixture.rig.profile))

        // The question: nothing is deleted by asking, nor by cancelling.
        model.requestDiscardSideChat(id, in: parent)
        #expect(session.discard?.id == id)
        model.cancelDiscardSideChat(in: parent)
        #expect(session.discard == nil)
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).map(\.session.id) == [id])
        #expect(FileManager.default.fileExists(atPath: forkFile.path))
        // A confirm with no question open does nothing.
        await model.confirmDiscardSideChat(in: parent)
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).count == 1)

        // Discard: the fork stops, its copy goes, the tab forgets it, and the parent's file is byte for byte what it was.
        model.requestDiscardSideChat(id, in: parent)
        await model.confirmDiscardSideChat(in: parent)
        #expect(try await fixture.rig.runtime.catalog.sideChats(of: parent).isEmpty)
        #expect(try await fixture.rig.runtime.catalog.session(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: forkFile.path))
        #expect(try sha256(parentFile) == before)
        #expect(session.openID == nil && session.items.isEmpty && session.discard == nil)
        #expect(session.discarding.isEmpty && session.discardFailures.isEmpty)
        #expect(model.chatSessions?.existingDriver(for: id) == nil)
        await fixture.cleanup()
    }

    // MARK: What the tab draws

    /// The tab hosted offscreen (a window that is never ordered front): the identifiers its parts expose.
    private func identifiers(of row: SessionRowModel, model: CatalogModel) async -> Set<String> {
        enableAccessibilityTree()
        let hosting = NSHostingController(rootView: SideTab(model: model, row: row).frame(width: 392, height: 640))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: 640), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 392, height: 640))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var ids: Set<String> = []
        for _ in 0..<30 {
            hosting.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            ids = Set(accessibilityElements(in: hosting.view).compactMap { $0.accessibilityIdentifier?() }.filter { !$0.isEmpty })
            if ids.contains("side-composer") { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Let the stream, if there is one, take its turn.
        try? await Task.sleep(for: .milliseconds(300))
        hosting.view.layoutSubtreeIfNeeded()
        return Set(accessibilityElements(in: hosting.view).compactMap { $0.accessibilityIdentifier?() }.filter { !$0.isEmpty }).union(ids)
    }

    @Test func theTabDrawsItsEmptyStateThenItsHeaderAndBarOnceASideChatIsOpen() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, _) = try await parent(fixture)
        model.select(parent)
        #expect(await waitUntil { model.selectedRow?.id == parent })
        let row = try #require(model.selectedRow)
        let session = model.side.session(for: parent)

        // Nothing open: the explanation, the model and Send; no Close, no toggle, no "…".
        let empty = await identifiers(of: row, model: model)
        #expect(empty.isSuperset(of: ["side-empty", "side-composer", "side-composer-text", "side-send", "side-model"]), "\(empty)")
        #expect(empty.isDisjoint(with: ["side-close", "side-allow-edits", "side-header-note", "side-new"]), "\(empty)")

        // A side chat open: its header with "New side chat", and the bar with Close, Allow edits and "…".
        await ask(model, session, parent, "What does it do?")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))
        let open = await identifiers(of: row, model: model)
        #expect(open.isSuperset(of: ["side-header-note", "side-new", "side-composer", "side-close", "side-allow-edits", "side-more", "side-send"]), "\(open)")
        #expect(!open.contains("side-empty"), "the question was asked: the thread is not empty")

        // A second side chat: the other one is in "Earlier side chats".
        model.startNewSideChat(in: parent)
        await ask(model, session, parent, "Another")
        let other = await identifiers(of: row, model: model)
        #expect(other.contains("side-earlier"), "\(other)")
        await fixture.cleanup()
    }

    // MARK: What the stream draws

    @Test func theSideStreamDrawsNoRewindFilesAndEveryRowOfTheMainChatKeepsItsComposerSeam() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, _) = try await parent(fixture)
        let session = model.side.session(for: parent)
        await ask(model, session, parent, "Hi")
        let id = try #require(session.openID)
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver, prompts: 1))
        let item = try #require(session.item(id))
        let feed = try #require(model.sideFeed(for: item, in: parent))
        let side = SideStreamView.makeModel(feed: feed, notes: model.sideNotes(for: id, in: parent))
        let context = side.controller.context
        #expect(context.rewind.availability == nil, "the side stream sets no rewind source")
        #expect(context.sideNotes != nil && context.columnPadding == LoomTheme.Side.threadInset)
        // The same user message that offers the action in a session with a composer offers none here.
        let message = ChatFixture.model([ChatFixture.user("fix the login", uuid: "5b2f0c7e-2a43-4f6c-9d6e-0a1b2c3d4e5f", at: 0)])
            .entries.first { ChatRewindAction.offers($0) }
        let entry = try #require(message, "the control entry offers the action")
        #expect(ChatRewindAction.state(for: entry, availability: .available) == .enabled)
        #expect(ChatRewindAction.state(for: entry, availability: context.rewind.availability) == .hidden)
        // And no read-now or retry either: there is no composer behind it.
        #expect(!context.canReadNow)
        side.close()
        await fixture.cleanup()
    }
}
