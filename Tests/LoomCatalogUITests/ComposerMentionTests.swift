import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// D-96 (W3-a): a session dropped on the live Chat composer, or picked in its `@` list, becomes a mention pill in the chip row.
// Nothing here sends a message to a real Claude: the driver is the fake provider's.

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ComposerMentionTests {
    @MainActor struct Fixture {
        let rig: LiveRig
        let host: ChatSessionHost
        let driver: ChatSessionDriver
        let composer: ChatComposerModel
        let id: UUID
        var store: ChatDraftStore { host.draftStore }
    }

    /// The sessions the composer may mention, as the catalog would answer.
    static let login = ComposerMention(id: UUID(), title: "Fix the login bug", provider: .claude)
    static let docs = ComposerMention(id: UUID(), title: "Write the docs", provider: .claude)

    private func make(started: Bool = false, id: UUID = UUID(), rig existing: LiveRig? = nil,
                      mentions: [ComposerMention] = [login, docs], texts: [UUID: String]? = nil) async throws -> Fixture {
        let rig = if let existing { existing } else { try await LiveRig.make() }
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root, driverForgotten: { _ in })
        let driver = started ? try await host.startNewSession(projectID: nil, sessionID: id, draft: nil) : host.driver(for: id)
        var environment = ComposerEnvironment()
        environment.draftDelay = .milliseconds(40)
        environment.mentionDebounce = .milliseconds(10)
        let known = Dictionary(uniqueKeysWithValues: mentions.map { ($0.id, $0) })
        environment.mentionTarget = { known[$0] }
        let texts = texts ?? Dictionary(uniqueKeysWithValues: mentions.map { ($0.id, "[Another session, \"\($0.title)\"]") })
        environment.sessionMention = { texts[$0] }
        environment.sessionCandidates = {
            mentions.map { ComposerSessionCandidate(id: $0.id, title: $0.title, project: "Web", lastActivity: Date()) }
        }
        let composer = ChatComposerModel(driver: driver, card: id, drafts: host.draftStore, environment: environment)
        composer.start()
        await composer.refresh()
        await composer.attachmentsRestored()
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

    /// A real text view of the composer, never shown: its drop handling is called as a drag would call it. The view holds its
    /// coordinator weakly, so the caller keeps the coordinator.
    private func textView(for composer: ChatComposerModel) -> (view: ComposerTextEditor.ComposerTextView, keep: AnyObject) {
        let editor = ComposerTextEditor(host: composer, height: .constant(60), minimumHeight: 60, maximumHeight: 220)
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.coordinator = coordinator
        view.delegate = coordinator
        coordinator.textView = view
        composer.editorAttached(view)
        return (view, coordinator)
    }

    private func pasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("loom-mention-test-\(UUID())")) }

    // MARK: The drop

    @Test func aSessionDroppedOnTheFieldAddsOnePillAndNeverItsTitle() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let (view, keep) = textView(for: composer)
        defer { withExtendedLifetime(keep) {} }
        let board = pasteboard()
        defer { board.releaseGlobally() }
        SessionDrag.write(Self.login.id, title: Self.login.title, to: board)

        #expect(view.sessionDragOperation(board) == .copy)
        #expect(view.dropSession(board) == true)
        #expect(composer.mentions == [Self.login])
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
        text.setString(Self.docs.id.uuidString, forType: .string)
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

    @Test func theOtherComposersRefuseASessionDropWithoutInsertingItsTitle() async throws {
        let host = SideComposerProbeHost()
        let editor = ComposerTextEditor(host: host, height: .constant(60))
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        view.coordinator = coordinator
        coordinator.textView = view
        let board = pasteboard()
        defer { board.releaseGlobally() }
        SessionDrag.write(Self.login.id, title: Self.login.title, to: board)
        #expect(view.sessionDragOperation(board) == [])
        #expect(view.dropSession(board) == false)
        #expect(view.string.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    // MARK: The `@` list

    @Test func pickingASessionInTheAtListAddsAPillAndRemovesTheQuery() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        let editor = FakeComposerEditor(model: composer)
        editor.type("look at @login")
        #expect(await waitUntil { composer.menu?.items.contains { $0.kind == .session } == true })
        let item = try #require(composer.menu?.items.first { $0.kind == .session })
        #expect(item.title == Self.login.title)
        composer.choose(item)
        #expect(editor.text == "look at ", "the typed @query left the field: \(editor.text)")
        #expect(composer.mentions == [Self.login])
        #expect(composer.menu == nil)

        // The same session again: the query goes, and no second pill comes.
        editor.type("@login")
        #expect(await waitUntil { composer.menu?.items.contains { $0.kind == .session } == true })
        composer.choose(try #require(composer.menu?.items.first { $0.kind == .session }))
        #expect(editor.text == "look at ")
        #expect(composer.mentions == [Self.login])
        await fixture.rig.finish()
    }

    // MARK: The rules

    @Test func aMentionIsRefusedForItselfAnUnofferedSessionAndADuplicate() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        #expect(!composer.canMention(fixture.id))
        #expect(!composer.addMention(fixture.id), "never the composer's own session")
        #expect(!composer.addMention(UUID()), "never a session the catalog does not offer")
        #expect(composer.addMention(Self.login.id))
        #expect(!composer.canMention(Self.login.id))
        #expect(!composer.addMention(Self.login.id), "no duplicates")
        #expect(composer.addMention(Self.docs.id))
        #expect(composer.mentions.map(\.id) == [Self.login.id, Self.docs.id], "in the order they were added")
        composer.removeMention(Self.login.id)
        #expect(composer.mentions == [Self.docs])
        await fixture.rig.finish()
    }

    // MARK: Persistence

    @Test func pillsAreKeptInTheDraftAndComeBackAfterARelaunch() async throws {
        let fixture = try await make()
        let composer = fixture.composer
        composer.addMention(Self.login.id)
        composer.addMention(Self.docs.id)
        composer.setText("half a thought")
        composer.flushDraft()
        let saved = try #require(try fixture.store.load(sessionID: fixture.id))
        #expect(saved.mentions == [Self.login.id, Self.docs.id], "the ids only, in pill order")
        #expect(saved.text == "half a thought", "no mention text in the draft's text")

        // A relaunch: a new composer for the same session reads the draft. One session is gone meanwhile: its pill stays,
        // and is left out on send.
        let relaunched = try await make(id: fixture.id, rig: fixture.rig, mentions: [Self.docs])
        #expect(relaunched.composer.mentions.map(\.id) == [Self.login.id, Self.docs.id])
        #expect(relaunched.composer.mentions.last == Self.docs, "the title is the catalog's")
        #expect(relaunched.composer.currentText() == "half a thought")

        // Removing the pills empties the draft.
        relaunched.composer.removeMention(Self.login.id)
        relaunched.composer.removeMention(Self.docs.id)
        relaunched.composer.setText("")
        relaunched.composer.flushDraft()
        #expect(try fixture.store.load(sessionID: fixture.id) == nil)
        await fixture.rig.finish()
    }

    @Test func aDraftWithPillsOnlyIsKeptAndAnOlderDraftWithoutThemLoads() async throws {
        let fixture = try await make()
        fixture.composer.addMention(Self.login.id)
        fixture.composer.flushDraft()
        #expect(try fixture.store.load(sessionID: fixture.id)?.mentions == [Self.login.id], "a pill alone is worth keeping")

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
                environment.mentionTarget = { [Self.login.id: Self.login, Self.docs.id: Self.docs][$0] }
                return ChatComposerModel(driver: driver, card: id, drafts: host.draftStore, environment: environment)
            }
        }
        let a = composer(for: first)
        await a.attachmentsRestored()
        a.addMention(Self.login.id)
        let b = composer(for: second)
        await b.attachmentsRestored()
        #expect(b.mentions.isEmpty, "the other session's composer has its own pills")
        b.addMention(Self.docs.id)
        let back = composer(for: first)
        #expect(back === a)
        #expect(back.mentions == [Self.login])
        #expect(b.mentions == [Self.docs])
        await rig.finish()
    }

    // MARK: Sending

    @Test func sendingPutsTheMentionTextsBeforeTheTypedWordsAndClearsThePills() async throws {
        let fixture = try await make(started: true)
        let composer = fixture.composer
        #expect(await idle(fixture))
        composer.addMention(Self.login.id)
        composer.addMention(Self.docs.id)
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
        let fixture = try await make(started: true, texts: [Self.login.id: "[Another session, \"Fix the login bug\"]"])
        let composer = fixture.composer
        #expect(await idle(fixture))
        composer.addMention(Self.login.id)
        composer.addMention(Self.docs.id)
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
        composer.addMention(Self.login.id)
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
        composer.addMention(Self.login.id)
        composer.resumeQueue()
        #expect(await waitUntil { composer.editing == nil })
        #expect(composer.mentions == [Self.login], "the pill stays in the composer")
        #expect(composer.notice?.text.contains("Your changes are in the composer") == true, "\(composer.notice?.text ?? "no notice")")
        await fixture.rig.finish()
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
}

/// A composer that is not the live one (the Side tab's, the quick question's, the new-session draft's): the protocol's default.
@MainActor
private final class SideComposerProbeHost: ComposerEditorHost {
    var keyMode: ComposerKeys.Mode { .quick }
    var syncsByRevision: Bool { false }
    var textRevision: Int { 0 }
    var modelText: String { "" }
    func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State {
        ComposerKeys.State()
    }
    func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool { false }
    func textChanged(_ text: String) {}
    func editorEndedEditing() {}
    func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool { false }
    func drop(_ pasteboard: NSPasteboard) -> Bool { false }
    func editorAttached(_ bridge: (any ComposerEditorBridge)?) {}
}

/// The catalog's half of the rules: only Claude sessions it lists, never a side chat.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ComposerMentionCatalogTests {
    @Test func theCatalogOffersClaudeSessionsOnlyAndNeverASideChat() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let project = rig.projects[0].id
        let claude = try #require(rig.ids[project]?.first)
        let codex = try #require(rig.ids[project]?.last)
        let sideID = UUID()
        try await rig.catalog.insertSession(
            ManagedSession(id: sideID, provider: .claude, providerConversationID: "side-conv", workingDirectory: rig.root.path),
            title: "Side", createdAt: Date(), lastUsedAt: Date(), lifecycle: .active, projectID: project,
            sideChat: SideChatLink(parentSessionID: claude, forkedAt: Date()))
        // Live, so the model holds its record (a side chat is in no list).
        let run = UUID()
        try await rig.feed(.runStarted(run), for: sideID)
        try await rig.feed(.runEndpoint(run, .pipe), for: sideID)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: sideID)
        for _ in 0..<300 where model.liveRecords[sideID] == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.liveRecords[sideID]?.isSideChat == true)

        let target = try #require(model.composerMentionTarget(for: claude))
        #expect(target.id == claude && target.provider == .claude && target.title.hasPrefix("Alpha"))
        #expect(target.accessibilityLabel == "Mentions session \(target.title)")
        #expect(model.composerMentionTarget(for: codex) == nil, "a Codex session is not mentioned")
        #expect(model.composerMentionTarget(for: sideID) == nil, "a side chat is not mentioned")
        #expect(model.composerMentionTarget(for: UUID()) == nil, "a session the catalog does not know")
    }

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
