import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// D-96 (W3-a): a session dropped on the live Chat composer, or picked in its `@` list, becomes a mention pill in the chip row.
// Nothing here sends a message to a real Claude: the driver is the fake provider's.

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ComposerMentionTests: ComposerMentionFixtures {
    // MARK: The drop

    @Test func aSessionDroppedOnTheFieldAddsOnePillAndNeverItsTitle() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let (view, keep) = textView(for: composer)
        defer { withExtendedLifetime(keep) {} }
        let board = pasteboard()
        defer { board.releaseGlobally() }
        SessionDrag.write(ComposerMentionShared.login.id, title: ComposerMentionShared.login.title, to: board)

        #expect(view.sessionDragOperation(board) == .copy)
        #expect(view.dropSession(board) == true)
        #expect(composer.mentions == [ComposerMentionShared.login])
        #expect(view.string.isEmpty, "the title the payload also carries is not inserted: \(view.string)")
        #expect(composer.text.isEmpty)
        #expect(composer.hasContent, "a pill alone is something to send")

        // A second drop of the same session does nothing, and the drag says so.
        #expect(view.sessionDragOperation(board) == [])
        #expect(view.dropSession(board) == false)
        #expect(composer.mentions.count == 1)
        #expect(view.string.isEmpty)

        // Plain text that looks like an id is no session: the field treats it as text, and no pill comes of it.
        let text = pasteboard()
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString(ComposerMentionShared.docs.id.uuidString, forType: .string)
        #expect(view.sessionDragOperation(text) == nil)
        #expect(view.dropSession(text) == nil)
        #expect(composer.mentions.count == 1)
        await fixture.rig.finish()
    }

    @Test func aDropTheComposerRefusesShowsNotAllowedAndChangesNothing() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let (view, keep) = textView(for: composer)
        defer { withExtendedLifetime(keep) {} }
        // Its own session, and a session the catalog does not offer (a side chat, a Codex session, one that is gone).
        for refused in [fixture.id, UUID()] {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            SessionDrag.write(refused, title: "Refused", to: board)
            #expect(view.sessionDragOperation(board) == [], "the drag shows the not-allowed feedback")
            #expect(view.dropSession(board) == false)
        }
        #expect(composer.mentions.isEmpty)
        #expect(view.string.isEmpty)
        #expect(!composer.hasContent)
        await fixture.rig.finish()
    }

    // MARK: The `@` list

    @Test func pickingASessionInTheAtListAddsAPillAndRemovesTheQuery() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let editor = FakeComposerEditor(model: composer)
        editor.type("look at @login")
        #expect(await waitUntil { composer.menu?.items.contains { $0.kind == .session } == true })
        let item = try #require(composer.menu?.items.first { $0.kind == .session })
        #expect(item.title == ComposerMentionShared.login.title)
        composer.choose(item)
        #expect(editor.text == "look at ", "the typed @query left the field: \(editor.text)")
        #expect(composer.mentions == [ComposerMentionShared.login])
        #expect(composer.menu == nil)

        // The same session again: the query goes, and no second pill comes.
        editor.type("@login")
        #expect(await waitUntil { composer.menu?.items.contains { $0.kind == .session } == true })
        composer.choose(try #require(composer.menu?.items.first { $0.kind == .session }))
        #expect(editor.text == "look at ")
        #expect(composer.mentions == [ComposerMentionShared.login])
        await fixture.rig.finish()
    }

    // MARK: The rules

    @Test func aMentionIsRefusedForItselfAnUnofferedSessionAndADuplicate() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        #expect(!composer.canMention(fixture.id))
        #expect(!composer.addMention(fixture.id), "never the composer's own session")
        #expect(!composer.addMention(UUID()), "never a session the catalog does not offer")
        #expect(composer.addMention(ComposerMentionShared.login.id))
        #expect(!composer.canMention(ComposerMentionShared.login.id))
        #expect(!composer.addMention(ComposerMentionShared.login.id), "no duplicates")
        #expect(composer.addMention(ComposerMentionShared.docs.id))
        #expect(composer.mentions.map(\.id) == [ComposerMentionShared.login.id, ComposerMentionShared.docs.id], "in the order they were added")
        composer.removeMention(ComposerMentionShared.login.id)
        #expect(composer.mentions == [ComposerMentionShared.docs])
        await fixture.rig.finish()
    }

    // MARK: Persistence

    @Test func pillsAreKeptInTheDraftAndComeBackAfterARelaunch() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        composer.addMention(ComposerMentionShared.login.id)
        composer.addMention(ComposerMentionShared.docs.id)
        composer.setText("half a thought")
        composer.flushDraft()
        let saved = try #require(try fixture.store.load(sessionID: fixture.id))
        #expect(saved.mentions == [ComposerMentionShared.login.id, ComposerMentionShared.docs.id], "the ids only, in pill order")
        #expect(saved.text == "half a thought", "no mention text in the draft's text")

        // A relaunch: a new composer for the same session reads the draft. One session is gone meanwhile: its pill stays,
        // and is left out on send.
        let relaunched = try await make(id: fixture.id, rig: fixture.rig, mentions: [ComposerMentionShared.docs])
        #expect(relaunched.composer.mentions.map(\.id) == [ComposerMentionShared.login.id, ComposerMentionShared.docs.id])
        #expect(relaunched.composer.mentions.last == ComposerMentionShared.docs, "the title is the catalog's")
        #expect(relaunched.composer.currentText() == "half a thought")

        // Removing the pills empties the draft.
        relaunched.composer.removeMention(ComposerMentionShared.login.id)
        relaunched.composer.removeMention(ComposerMentionShared.docs.id)
        relaunched.composer.setText("")
        relaunched.composer.flushDraft()
        #expect(try fixture.store.load(sessionID: fixture.id) == nil)
        await fixture.rig.finish()
    }

    @Test func aDraftWithPillsOnlyIsKeptAndAnOlderDraftWithoutThemLoads() async throws {
        let fixture = try await make()
        fixture.composer.addMention(ComposerMentionShared.login.id)
        fixture.composer.flushDraft()
        #expect(try fixture.store.load(sessionID: fixture.id)?.mentions == [ComposerMentionShared.login.id], "a pill alone is worth keeping")

        // A draft file written before mentions existed.
        let other = UUID()
        try FileManager.default.createDirectory(at: fixture.store.directory, withIntermediateDirectories: true)
        try Data(#"{"attachments":[],"text":"an old draft","updatedAt":"2026-10-01T10:00:00Z"}"#.utf8)
            .write(to: fixture.store.url(for: other))
        let old = try await make(id: other, rig: fixture.rig)
        #expect(old.composer.currentText() == "an old draft")
        #expect(old.composer.mentions.isEmpty)
        #expect(old.composer.notice == nil, "it read as a draft, not as an unreadable file")
        await fixture.rig.finish()
    }

    @Test func pillsSurviveASwitchToAnotherSessionAndBack() async throws {
        let rig = try await LiveRig.make()
        let attachments = ChatAttachments()
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root, driverForgotten: { attachments.driverForgotten($0) })
        let first = UUID(), second = UUID()
        func composer(for id: UUID) -> ChatComposerModel {
            let driver = host.driver(for: id)
            return attachments.attachment(for: driver) {
                var environment = ComposerEnvironment()
                environment.draftDelay = .milliseconds(40)
                environment.mentionTarget = { [ComposerMentionShared.login.id: ComposerMentionShared.login, ComposerMentionShared.docs.id: ComposerMentionShared.docs][$0] }
                return ChatComposerModel(driver: driver, card: id, drafts: host.draftStore, environment: environment)
            }
        }
        let a = composer(for: first)
        await a.attachmentsRestored()
        a.addMention(ComposerMentionShared.login.id)
        let b = composer(for: second)
        await b.attachmentsRestored()
        #expect(b.mentions.isEmpty, "the other session's composer has its own pills")
        b.addMention(ComposerMentionShared.docs.id)
        let back = composer(for: first)
        #expect(back === a)
        #expect(back.mentions == [ComposerMentionShared.login])
        #expect(b.mentions == [ComposerMentionShared.docs])
        await rig.finish()
    }

    // MARK: Sending

    @Test func sendingPutsTheMentionTextsBeforeTheTypedWordsAndClearsThePills() async throws {
        let fixture = try await make(started: true)
        let composer = fixture.composer
        #expect(await idle(fixture))
        composer.addMention(ComposerMentionShared.login.id)
        composer.addMention(ComposerMentionShared.docs.id)
        composer.setText("what changed?")
        composer.submit(secondary: false)
        #expect(composer.mentions.isEmpty)
        #expect(!composer.hasContent)
        await composer.settled()
        #expect(await idle(fixture))
        let expected = "[Another session, \"Fix the login bug\"] [Another session, \"Write the docs\"] what changed?"
        #expect(await prompts(fixture) == [expected])
        #expect(try fixture.store.load(sessionID: fixture.id) == nil, "the pills went with the send")
        #expect(composer.notice == nil)
        await fixture.rig.finish()
    }

    @Test func aPillWhoseSessionHasNoMentionIsSkippedWithANotice() async throws {
        // The docs session is gone, or has no transcript: the catalog gives no mention text for it.
        let fixture = try await make(started: true, texts: [ComposerMentionShared.login.id: "[Another session, \"Fix the login bug\"]"])
        let composer = fixture.composer
        #expect(await idle(fixture))
        composer.addMention(ComposerMentionShared.login.id)
        composer.addMention(ComposerMentionShared.docs.id)
        composer.setText("hi")
        composer.submit(secondary: false)
        await composer.settled()
        #expect(await idle(fixture))
        #expect(await prompts(fixture) == ["[Another session, \"Fix the login bug\"] hi"])
        #expect(composer.notice?.text.hasPrefix("One mention was skipped") == true, "\(composer.notice?.text ?? "no notice")")
        #expect(composer.mentions.isEmpty)
        await fixture.rig.finish()
    }

    @Test func aMessageQueuedWhileClaudeWorksCarriesItsMentions() async throws {
        let fixture = try await make(started: true)
        let composer = fixture.composer
        #expect(await idle(fixture))
        try await fixture.driver.send("/scenario work 3000")
        #expect(await working(fixture))
        composer.addMention(ComposerMentionShared.login.id)
        composer.setText("after this")
        #expect(composer.sendKind(commandHeld: true) == .afterTurn)
        composer.submit(secondary: true)
        await composer.settled()
        await composer.refresh()
        let expected = "[Another session, \"Fix the login bug\"] after this"
        #expect(composer.state.queue.items.map(\.text) == [expected], "the queue strip shows the message as it will be sent")
        #expect(composer.mentions.isEmpty)
        #expect(await waitUntil(20) { await prompts(fixture).contains(expected) })
        await fixture.rig.finish()
    }

    /// Review fix: a pill added while a queued message was edited is a change. When the queue sent that message, the edit
    /// counted as unchanged (the text was), and the composer's own draft came back without the pill.
    @Test func aPillAddedWhileEditingAQueuedMessageStaysWhenTheQueueSendsIt() async throws {
        let fixture = try await make(started: true)
        let composer = fixture.composer
        #expect(await idle(fixture))
        try await fixture.driver.send("/scenario work 9000")
        #expect(await working(fixture))
        composer.setText("queued one")
        composer.submit(secondary: true)
        await composer.settled()
        composer.interrupt()
        #expect(await idle(fixture))
        let id = try #require(composer.state.queue.items.first?.id)
        composer.beginEdit(id)
        composer.addMention(ComposerMentionShared.login.id)
        composer.resumeQueue()
        #expect(await waitUntil { composer.editing == nil })
        #expect(composer.mentions == [ComposerMentionShared.login], "the pill stays in the composer")
        #expect(composer.notice?.text.contains("Your changes are in the composer") == true, "\(composer.notice?.text ?? "no notice")")
        await fixture.rig.finish()
    }

    private func idle(_ fixture: Fixture) async -> Bool {
        await waitUntil { await fixture.composer.refresh(); return fixture.composer.state.phase == .ready && !fixture.composer.state.turnRunning }
    }

    private func prompts(_ fixture: Fixture) async -> [String] {
        await fixture.driver.snapshot().model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
    }
}

/// The catalog's half of the rules: only Claude sessions it lists, never a side chat.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ComposerMentionCatalogTests {
    /// Review fix: the mention text looked for the transcript with the unbounded locator, which lists every project folder on
    /// the main actor when the transcript is not in the session's own folder. Only that folder is read now: a transcript
    /// elsewhere is not found, and a pill for it is skipped on send.
    @Test func theMentionTextLooksForTheTranscriptOnlyInTheSessionsOwnFolder() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 0, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let config = rig.root.appendingPathComponent("claude-config", isDirectory: true)
        model.claudeConfigDirectory = config
        let id = UUID(), conversation = "conv-\(UUID().uuidString.lowercased())"
        let work = rig.projects[0].path
        try await rig.catalog.insertSession(
            ManagedSession(id: id, provider: .claude, providerConversationID: conversation, workingDirectory: work),
            title: "Elsewhere", createdAt: Date(), lastUsedAt: Date(), lifecycle: .active, projectID: rig.projects[0].id)
        let run = UUID()
        try await rig.feed(.runStarted(run), for: id)
        try await rig.feed(.runEndpoint(run, .pipe), for: id)
        for _ in 0..<300 where model.liveRecords[id] == nil && model.rowModels[id] == nil { try? await Task.sleep(for: .milliseconds(10)) }

        // The transcript sits in another project's folder: not looked for there.
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        let other = projects.appendingPathComponent("-somewhere-else", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: other.appendingPathComponent(conversation + ".jsonl"))
        #expect(model.sessionMentionText(for: id, requiringTranscript: true) == nil, "a transcript elsewhere is not found")

        // In the session's own folder it is.
        let own = projects.appendingPathComponent(ClaudeTranscriptLocator.folderName(forWorkingDirectory: work), isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: own.appendingPathComponent(conversation + ".jsonl"))
        let text = try #require(model.sessionMentionText(for: id, requiringTranscript: true))
        #expect(text.contains("transcript ") && text.contains(conversation + ".jsonl"))
    }
}
