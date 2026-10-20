import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// V19, Chat first, end to end with the real model, controller, runtime and driver on the fake provider: a new session
// starts in the face Settings name (Chat by default), a stopped Chat session shows its composer and a send resumes it in
// Chat, and the handover moves a session between the faces without cutting a turn or losing a message.

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(10)))
struct ChatFirstTests {
    struct Fixture {
        let rig: LiveRig
        let model: CatalogModel
        let controller: ConversationController

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            await rig.finish()
        }
    }

    private func makeFixture(environment: [String: String] = [:]) async throws -> Fixture {
        let rig = try await LiveRig.make(environment: environment)
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

    /// A start in a fresh rig captures the environment and opens a run scope first; under a full run's load that took more
    /// than 15 s once. The deadline only bounds a failure, so it is one that load does not cross.
    private func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// Sends the project-less draft and returns the session it started.
    private func startFromDraft(_ fixture: Fixture, text: String) async throws -> UUID {
        let model = fixture.model
        model.showDraft(projectID: nil)
        model.setDraftText(text, projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.destination?.sessionID != nil })
        return try #require(model.destination?.sessionID)
    }

    private func endpoint(_ fixture: Fixture, _ id: UUID) async -> RunEndpointKind? {
        try? await fixture.rig.runtime.catalog.session(id: id)?.runEndpoint
    }

    // MARK: The default face and the setting

    @Test func aNewSessionStartsInChatByDefaultAndInTheTerminalWhenSettingsSaySo() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        #expect(model.newSessionFace == .chat)
        let chat = try await startFromDraft(fixture, text: "hello from the draft")
        #expect(await waitUntil { await endpoint(fixture, chat) == .pipe })
        #expect(await waitUntil { model.detailRouteKind == "chat" })
        let driver = try #require(model.chatSessions?.existingDriver(for: chat))
        #expect(await waitUntil {
            await driver.snapshot().model.entries.contains { if case let .user(prompt) = $0.body { prompt.text == "hello from the draft" } else { false } }
        })
        // The draft was cleared once the session started, and the project remembers nothing odd.
        #expect(model.newSession.draft(for: nil)?.isVisible != true)

        // The switch moves every new session to the terminal; the first one keeps its face.
        model.setNewSessionFace(.terminal)
        let terminal = try await startFromDraft(fixture, text: "hello from the terminal draft")
        #expect(terminal != chat)
        #expect(await waitUntil { await endpoint(fixture, terminal) == .terminal })
        #expect(await waitUntil { model.detailRouteKind == "terminal" })
        #expect(await endpoint(fixture, chat) == .pipe)
        await fixture.cleanup()
    }

    // MARK: The session's title

    /// The ai-title records of the session's transcript (the fake writes one when the driver asks Claude for a title and
    /// asks to persist it).
    private func aiTitleCount(_ fixture: Fixture, _ id: UUID) async -> Int {
        guard let conversation = try? await fixture.rig.runtime.catalog.session(id: id)?.session.providerConversationID,
              let file = ClaudeTranscriptEffort.transcript(
                conversationID: conversation, projectsDirectory: fixture.rig.profile.appendingPathComponent("projects")),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "\"ai-title\"").count - 1
    }

    private func title(_ fixture: Fixture, _ id: UUID) async -> String? {
        try? await fixture.rig.runtime.catalog.session(id: id)?.title
    }

    @Test func aChatSessionIsNamedByClaudeFromItsFirstMessage() async throws {
        let fixture = try await makeFixture()
        let id = try await startFromDraft(fixture, text: "Explain binary search in one sentence")
        #expect(await waitUntil { await title(fixture, id) == "Fake title: Explain binary search" })
        let record = try #require(try await fixture.rig.runtime.catalog.session(id: id))
        #expect(!record.titleIsCustom)
        #expect(await aiTitleCount(fixture, id) == 1)
        // The row shows it, and a second message asks for nothing more.
        #expect(await waitUntil { fixture.model.rowModels[id]?.record.title == "Fake title: Explain binary search" })
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        try await driver.send("something else entirely")
        #expect(await waitUntil { await driver.snapshot().model.assistantTexts.last == "Fake answer to: something else entirely" })
        #expect(await aiTitleCount(fixture, id) == 1)
        #expect(await title(fixture, id) == "Fake title: Explain binary search")
        await fixture.cleanup()
    }

    @Test func aRenameMadeWhileTheTitleIsOnItsWayStays() async throws {
        // The fake persists the title, then answers 800 ms later: the rename lands in between.
        let fixture = try await makeFixture(environment: ["LOOM_FAKE_CHAT_CONTROL_DELAY_MS": "800"])
        let id = try await startFromDraft(fixture, text: "Explain binary search in one sentence")
        #expect(await waitUntil { await aiTitleCount(fixture, id) == 1 })
        try await fixture.model.rename(sessionID: id, to: "My own name")
        try await Task.sleep(for: .milliseconds(2000))
        let record = try #require(try await fixture.rig.runtime.catalog.session(id: id))
        #expect(record.title == "My own name" && record.titleIsCustom)
        await fixture.cleanup()
    }

    @Test func aSlashCommandAsksForNoTitleAndTheNextMessageDoes() async throws {
        let fixture = try await makeFixture()
        let id = try await startFromDraft(fixture, text: "/scenario work 100")
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        try await Task.sleep(for: .milliseconds(500))
        #expect(await aiTitleCount(fixture, id) == 0)
        #expect(await title(fixture, id) == nil)
        try await driver.send("now a real message")
        #expect(await waitUntil { await title(fixture, id) == "Fake title: now a real" })
        #expect(await aiTitleCount(fixture, id) == 1)
        await fixture.cleanup()
    }

    @Test func aTitleThatCannotBeMadeLeavesTheSessionUntitledAndSilent() async throws {
        for failure in ["title", "titlenull"] {
            let fixture = try await makeFixture(environment: ["LOOM_FAKE_CHAT_FAIL_PICKS": failure])
            let id = try await startFromDraft(fixture, text: "Explain binary search in one sentence")
            let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
            #expect(await waitUntil { await driver.snapshot().model.assistantTexts.last == "Fake answer to: Explain binary search in one sentence" })
            try await Task.sleep(for: .milliseconds(500))
            #expect(await title(fixture, id) == nil, "\(failure)")
            let snapshot = await driver.snapshot()
            #expect(snapshot.phase == .ready && snapshot.queueIssue == nil, "\(failure)")
            #expect(fixture.model.errorMessage == nil && fixture.model.infoMessage == nil, "\(failure)")
            await fixture.cleanup()
        }
    }

    /// X-1: a title that comes back after a `/clear` moved the run names the card it was asked for, and the new card asks for
    /// its own. The fake answers the first title only after the reset, right before it takes the next message.
    @Test func aTitleAnsweredAfterAClearNamesTheCardItWasAskedFor() async throws {
        let fixture = try await makeFixture(environment: ["LOOM_FAKE_CHAT_TITLE_DEFER": "reset"])
        let id = try await startFromDraft(fixture, text: "Explain binary search in one sentence")
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { await aiTitleCount(fixture, id) == 1 }, "the title request reached the CLI")
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        try await driver.send("/clear")
        #expect(await waitUntil { await driver.sessionID != id })
        let card = await driver.sessionID
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        try await driver.send("Tell me about heaps")
        #expect(await waitUntil { await title(fixture, id) == "Fake title: Explain binary search" })
        #expect(await waitUntil { await title(fixture, card) == "Fake title: Tell me about" })
        await fixture.cleanup()
    }

    /// RS-6: a card whose title cannot be made is asked for it three times at most, not on every message.
    @Test func aTitleThatKeepsFailingIsAskedForThreeTimesAtMost() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("loom-title-log-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: log) }
        let fixture = try await makeFixture(environment: [
            "LOOM_FAKE_CHAT_FAIL_PICKS": "title", "LOOM_FAKE_CHAT_TITLE_LOG": log.path,
        ])
        let id = try await startFromDraft(fixture, text: "the first message")
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        for text in ["the second message", "the third message", "the fourth message", "the fifth message"] {
            #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
            try await driver.send(text)
            #expect(await waitUntil { await driver.snapshot().model.assistantTexts.last == "Fake answer to: \(text)" })
        }
        try await Task.sleep(for: .milliseconds(500))
        let requests = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").count ?? 0
        #expect(requests == 3, "\(requests) title requests for five messages")
        #expect(await title(fixture, id) == nil)
        await fixture.cleanup()
    }

    @Test func theSettingIsKeptAndAnOlderFileReadsAsChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-face-pref-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(UIPreferences().newSessionFace == .chat)
        let old = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"viewMode":"activity"}"#.utf8))
        #expect(old.newSessionFace == .chat)
        let store = UIPreferencesStore(url: root.appendingPathComponent("p.json"))
        try store.update { $0.newSessionFace = .terminal }
        try store.flush()
        #expect(UIPreferencesStore(url: root.appendingPathComponent("p.json")).current.newSessionFace == .terminal)
    }

    // MARK: A stopped Chat session

    @Test func aStoppedChatSessionShowsItsComposerAndASendResumesItInChat() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let id = try await startFromDraft(fixture, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        // A long turn with a message Claude never reads, then a Stop: the message comes back as the draft.
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        _ = try await driver.send("never read")
        model.stopConversation(id)
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        // A verified Stop closes the session's tab; the user opens the session again.
        #expect(await waitUntil { model.busy[id] == nil })
        model.select(id)
        #expect(await waitUntil { model.selectedRow?.live?.runID == nil })
        #expect(await waitUntil { model.selectedRow?.record.runEndpoint == .pipe })

        // The stopped session the Chat face owns shows its live chat, not the "not running" screen.
        let row = try #require(model.selectedRow)
        #expect(model.detailRoute == .chat(sessionID: id))
        #expect(model.showsStoppedLiveChat(row) && !model.canChooseFace)
        #expect(model.owningFace(of: row) == .chat)
        let shown = try #require(model.liveChatDriverForDisplay(of: row))
        let feed = try #require(model.liveChatFeed(for: shown, card: id, conversationID: row.record.session.providerConversationID,
                                                   workingDirectory: row.record.session.workingDirectory))
        let composer = try #require(model.liveChatComposer(for: shown, row: row, feed: feed))
        composer.start()
        await composer.refresh()
        // The unsent message is in the field, in front of nothing, and the draft file holds it too.
        #expect(composer.text.contains("never read"))
        #expect(try model.chatSessions?.draftStore.load(sessionID: id)?.text.contains("never read") == true)

        composer.setText("and now a new message")
        composer.submit(secondary: false)
        #expect(await waitUntil { await driver.snapshot().model.assistantTexts.last == "Fake answer to: and now a new message" })
        // It resumed in the Chat face: a pipe run, the same owner.
        // The row gets it from two hub frames (`.runStarted` resets the endpoint, `.runEndpoint` sets it), and the
        // answer can arrive before both: wait for the state, and say which one it was.
        let resumedEndpoint = await waitUntil { model.selectedRow.map { model.runEndpoint(of: $0) } == .pipe }
        #expect(resumedEndpoint, "the resumed run's row should show a pipe run; selected: \(model.selectedSessionID == id), live run: \(String(describing: model.selectedRow?.live?.runID)), endpoint: \(String(describing: model.selectedRow.map { model.runEndpoint(of: $0) }))")
        #expect(await endpoint(fixture, id) == .pipe)
        await fixture.cleanup()
    }

    // MARK: The handover

    @Test func continueInTerminalMovesTheSessionWithoutTwoOwners() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let id = try await startFromDraft(fixture, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await waitUntil { model.selectedRow?.record.runEndpoint == .pipe })
        let row = try #require(model.selectedRow)
        #expect(model.canContinue(in: .terminal, row: row) && !model.canContinue(in: .chat, row: row))

        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { await endpoint(fixture, id) == .terminal })
        #expect(await waitUntil { model.detailRouteKind == "terminal" && model.handovers[id] == nil })
        #expect(await driver.currentPhase == .stopped)
        #expect(await driver.snapshot().model.markerList.contains(.face(.continuedInTerminal)))
        let afterTerminal = try #require(model.selectedRow)
        #expect(model.owningFace(of: afterTerminal) == .terminal)
        #expect(!model.canContinue(in: .chat, row: afterTerminal) && !model.canContinue(in: .terminal, row: afterTerminal))

        // The way back is gone (no release build reached it): nothing moves to Chat, the terminal keeps the session.
        model.continueIn(.chat, sessionID: id)
        #expect(model.handovers[id] == nil)
        #expect(await endpoint(fixture, id) == .terminal)
        #expect(model.terminalView(for: id) != nil)
        await fixture.cleanup()
    }

    @Test func aHandoverWaitsForARunningTurnAndRefusesAWaitingRequest() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let id = try await startFromDraft(fixture, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await waitUntil { model.selectedRow?.record.runEndpoint == .pipe })

        // A request waits: refused, with the reason on the banner, and nothing moved.
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { model.errorMessage != nil })
        #expect(model.errorMessage?.contains("waiting for your answer") == true)
        #expect(model.handovers[id] == nil)
        #expect(await endpoint(fixture, id) == .pipe && model.terminalView(for: id) == nil)
        model.dismissError()
        try await model.answerFirstChatRequest(id, allow: true)
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })

        // A turn runs: the handover waits for it, shows that it waits, and the turn is not cut.
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { model.handovers[id]?.phase == .waiting })
        #expect(model.handoverNotice(of: id) == "Continuing in Terminal when this turn ends")
        #expect(await endpoint(fixture, id) == .pipe)
        #expect(await waitUntil { await endpoint(fixture, id) == .terminal })
        #expect(await waitUntil { model.handovers[id] == nil })
        let snapshot = await driver.snapshot()
        #expect(snapshot.model.turns.last?.status == .succeeded
            && !snapshot.model.markerList.contains { if case .interrupted = $0 { true } else { false } })
        await fixture.cleanup()
    }

    // MARK: Fix round

    /// Holds a handover at its point of no return (`ConversationController.handoverGate`) until the test lets it go.
    @MainActor private final class PointGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var reached: [SessionFace] = []

        func hold(_ target: SessionFace) async {
            reached.append(target)
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A Chat session that has answered once and then moved to the terminal, which has resumed it and rests at its prompt.
    private func terminalSession(_ fixture: Fixture) async throws -> UUID {
        let model = fixture.model
        let id = try await startFromDraft(fixture, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await waitUntil { model.selectedRow?.record.runEndpoint == .pipe })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { await endpoint(fixture, id) == .terminal && model.handovers[id] == nil })
        #expect(await waitUntil {
            fixture.controller.terminalEvidence(tokens: ["RESUMED"]).first?.tokenPresence["RESUMED"] == true
        })
        return id
    }

    private func hub(_ fixture: Fixture, _ id: UUID) async -> SessionViewState? {
        await fixture.rig.runtime.supervisor.events.snapshot().sessions[id]
    }

    private func chatSession(_ fixture: Fixture) async throws -> (UUID, ChatSessionDriver) {
        let id = try await startFromDraft(fixture, text: "hello")
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await waitUntil { fixture.model.selectedRow?.record.runEndpoint == .pipe })
        return (id, driver)
    }

    /// The refusal reaches the user in the words of the gate.
    @Test func aRefusalReadsTheSameWhoeverMadeIt() {
        #expect(ConversationController.refusal(ChatDriverError.requestWaiting) == .requestWaiting)
        #expect(ConversationController.refusal(ChatDriverError.backgroundWork) == .backgroundWork)
        #expect(ConversationController.refusal(ChatDriverError.clearedDuringHandover) == .cleared)
        #expect(HandoverRefusal.cleared.description.contains("cleared"))
        #expect(ConversationController.refusal(CancellationError()) == nil)
    }

    /// S1, Chat to Terminal, before the point: Cancel ends the wait and the session goes on in Chat; Stop ends it and the
    /// session stays stopped, with no terminal.
    @Test func cancelAndStopDuringTheWaitKeepTheSessionInChat() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let (id, driver) = try await chatSession(fixture)

        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { model.handovers[id]?.phase == .waiting })
        model.cancelHandover(sessionID: id)
        #expect(await waitUntil { model.handovers[id] == nil })
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(await endpoint(fixture, id) == .pipe && model.terminalView(for: id) == nil)
        #expect(await driver.snapshot().runID != nil, "the Chat run lives")

        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { model.handovers[id]?.phase == .waiting })
        model.stopConversation(id)
        #expect(await waitUntil { model.handovers[id] == nil && model.busy[id] == nil })
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        #expect(await endpoint(fixture, id) == .pipe && model.terminalView(for: id) == nil)
        await fixture.cleanup()
    }

    /// S1, Chat to Terminal, at the point: the phase is `.switching` (Cancel is not offered and does nothing), and the move
    /// goes on.
    @Test func cancelAtThePointOfNoReturnDoesNothingAndTheTerminalStarts() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let gate = PointGate()
        fixture.controller.handoverGate = { _, target in await gate.hold(target) }
        let (id, _) = try await chatSession(fixture)
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { gate.reached == [.terminal] })
        #expect(model.handovers[id]?.phase == .switching)
        #expect(model.handoverNotice(of: id) == "Moving to Terminal…")
        model.cancelHandover(sessionID: id)
        #expect(model.handovers[id]?.phase == .switching, "Cancel is not offered after the point")
        gate.release()
        #expect(await waitUntil { await endpoint(fixture, id) == .terminal && model.handovers[id] == nil })
        await fixture.cleanup()
    }

    /// S1, Chat to Terminal, at the point: a Stop ends the terminal's start. The session stays stopped in Chat.
    @Test func aStopAtThePointOfNoReturnEndsTheTerminalStart() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let gate = PointGate()
        fixture.controller.handoverGate = { _, target in await gate.hold(target) }
        let (id, driver) = try await chatSession(fixture)
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { gate.reached == [.terminal] })
        model.stopConversation(id)
        #expect(await waitUntil { model.busy[id] == .stopping })
        gate.release()
        #expect(await waitUntil { model.handovers[id] == nil && model.busy[id] == nil })
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        #expect(await endpoint(fixture, id) == .pipe, "no terminal run took the session")
        #expect(model.terminalView(for: id) == nil)
        await fixture.cleanup()
    }

    /// S2: a stopped Chat session resumes in Chat when nothing in the window has a row for it (Home's Continue card and
    /// other paths): the face comes from the catalog.
    @Test func aChatOwnedSessionResumesInChatWithNoRow() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let (id, driver) = try await chatSession(fixture)
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped && model.busy[id] == nil })
        model.rowModels.removeAll()
        fixture.controller.resume(sessionID: id)
        #expect(await waitUntil { await driver.currentPhase == .ready })
        #expect(await endpoint(fixture, id) == .pipe)
        #expect(model.terminalView(for: id) == nil)
        await fixture.cleanup()
    }

    /// D-69: the face of a resume is the app-wide switch, not the endpoint of the session's last run.
    @Test func aResumeTakesItsFaceFromTheSwitchNotFromTheLastRun() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let (id, driver) = try await chatSession(fixture)
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped && model.busy[id] == nil })
        #expect(await endpoint(fixture, id) == .pipe, "the last run was a Chat run")

        model.setNewSessionFace(.terminal)
        fixture.controller.resume(sessionID: id)
        #expect(await waitUntil { await endpoint(fixture, id) == .terminal })
        #expect(await waitUntil { model.terminalView(for: id) != nil })

        model.stopConversation(id)
        #expect(await waitUntil { await hub(fixture, id)?.runID == nil && model.busy[id] == nil && model.terminalView(for: id) == nil })
        model.setNewSessionFace(.chat)
        fixture.controller.resume(sessionID: id)
        #expect(await waitUntil { await endpoint(fixture, id) == .pipe })
        #expect(model.terminalView(for: id) == nil)
        await fixture.cleanup()
    }

    /// D-69: a running session keeps its face when the switch changes; a stopped one follows the switch, whichever face ran
    /// it last. On Chat it shows its live chat with the composer; on Terminal the stopped screen of the terminal face.
    @Test func aRunningSessionKeepsItsFaceAndAStoppedOneFollowsTheSwitch() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let (id, driver) = try await chatSession(fixture)
        model.setNewSessionFace(.terminal)
        let running = try #require(model.selectedRow)
        #expect(model.runEndpoint(of: running) == .pipe && model.detailRoute == .chat(sessionID: id), "a running session keeps its face")

        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped && model.busy[id] == nil })
        model.select(id)
        #expect(await waitUntil { model.selectedRow?.live?.runID == nil })
        var row = try #require(model.selectedRow)
        #expect(!model.showsStoppedLiveChat(row) && model.canChooseFace, "Terminal: no live chat, the terminal face's stopped screen")
        model.setNewSessionFace(.chat)
        row = try #require(model.selectedRow)
        #expect(model.showsStoppedLiveChat(row) && !model.canChooseFace, "Chat: the live chat with its composer")

        // A session whose last run was the terminal's follows the switch as well (it is moved there by a handover).
        let terminal = try await terminalSession(fixture)
        model.stopConversation(terminal)
        #expect(await waitUntil { await hub(fixture, terminal)?.runID == nil && model.busy[terminal] == nil && model.terminalView(for: terminal) == nil })
        model.select(terminal)
        #expect(await endpoint(fixture, terminal) == .terminal)
        model.setNewSessionFace(.chat)
        #expect(await waitUntil { model.selectedRow.map { model.showsStoppedLiveChat($0) } == true })
        model.setNewSessionFace(.terminal)
        #expect(model.selectedRow.map { model.showsStoppedLiveChat($0) } == false)
        await fixture.cleanup()
    }

    /// D-69: the policy banner keeps a way out. Its action sets the switch to Terminal and moves this session with the handover.
    @Test func thePolicyBannersActionSetsTheSwitchToTerminalAndMovesTheSession() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let terminal = try await terminalSession(fixture)
        // A session the terminal already runs cannot be moved there: the switch stays.
        model.switchToTerminal(sessionID: terminal)
        #expect(model.newSessionFace == .chat && model.handovers[terminal] == nil)

        let (id, _) = try await chatSession(fixture)
        model.switchToTerminal(sessionID: id)
        #expect(model.newSessionFace == .terminal)
        #expect(await waitUntil { await endpoint(fixture, id) == .terminal && model.handovers[id] == nil })
        model.flushPreferences()
        let kept = UIPreferencesStore(url: fixture.rig.root.appendingPathComponent("ui-preferences.json")).current
        #expect(kept.newSessionFace == .terminal, "the switch is kept")
        await fixture.cleanup()
    }

    /// S5 / M4: a Chat start whose child dies before Ready tells the draft page it failed, and nothing else: the text stays
    /// on the draft page, no card is created and the first message is not kept twice.
    @Test func aChatStartThatFailsBeforeReadyKeepsTheTextOnTheDraftPage() async throws {
        let fixture = try await makeFixture(environment: ["LOOM_FAKE_CHAT_INIT": "exit"])
        let model = fixture.model
        model.showDraft(projectID: nil)
        model.setDraftText("do the thing", projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.errorMessage != nil })
        #expect(await waitUntil { !model.newSession.isSending(nil) })
        #expect(model.destination == .draft(projectID: nil), "no session was shown")
        #expect(model.newSession.draft(for: nil)?.text == "do the thing")
        // The failed start's card stays in the catalog (as after a terminal start that failed) and the sidebar shows it once
        // the lists are read again; how soon that happens is timing. Read its row first, so the check below sees the same
        // state on every run: no session of the window keeps a Chat driver for a start that never answered.
        let cards = try await fixture.rig.runtime.catalog.sessions().map(\.session.id)
        for card in cards { #expect(await waitUntil { model.rowModels[card] != nil }) }
        let ids = model.chatSessions.map { host in model.rowModels.keys.filter { host.existingDriver(for: $0) != nil } } ?? []
        #expect(ids.isEmpty)
        for card in cards { #expect(model.chatSessions?.existingDriver(for: card) == nil) }
        await fixture.cleanup()
    }

    /// Holds a Chat start right after Ready, before its first message goes out, until the test lets it go.
    @MainActor private final class StartGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var reached = false

        func hold() async {
            reached = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A start is over once the draft was told (Ready), not when its first message has gone out: the next draft of the
    /// project can start while the first message is still on its way. Before, the project stayed "starting" until the
    /// first message was sent, and a send in that moment was dropped without a word.
    @Test func aProjectCanStartAgainOnceTheLastStartWasToldEvenWhileItsFirstMessageIsOnItsWay() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let gate = StartGate()
        fixture.model.chatSessions?.afterReadyForTesting = { await gate.hold() }
        model.showDraft(projectID: nil)
        model.setDraftText("first", projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { gate.reached })
        #expect(await waitUntil { model.destination?.sessionID != nil }, "the session is shown at Ready")
        #expect(!model.isStarting(.claude, projectID: nil))
        model.showDraft(projectID: nil)
        model.setDraftText("second", projectID: nil)
        #expect(model.canSendDraft(projectID: nil), "the next draft may start")
        gate.release()
        await fixture.cleanup()
    }

    /// M1 / M8: while a session moves, the composer says so, keeps the text and its send is off; the `/` menu offers no move.
    @Test func theComposerSaysWhyWhileTheSessionMovesAndTheMenuOffersNoMove() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let (id, driver) = try await chatSession(fixture)
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { model.handovers[id]?.phase == .waiting })

        let row = try #require(model.selectedRow)
        let shown = try #require(model.liveChatDriverForDisplay(of: row))
        let feed = try #require(model.liveChatFeed(for: shown, card: id, conversationID: row.record.session.providerConversationID,
                                                   workingDirectory: row.record.session.workingDirectory))
        let composer = try #require(model.liveChatComposer(for: shown, row: row, feed: feed))
        composer.start()
        await composer.refresh()
        let editor = FakeComposerEditor(model: composer)
        editor.replaceAll(with: "typed meanwhile")
        composer.textChanged("typed meanwhile")
        #expect(composer.handoverPending == "Moving to the terminal…")
        #expect(composer.sendKind(commandHeld: false) == .sendDisabled)
        composer.submit(secondary: false)
        #expect(composer.notice?.text.contains("Moving to the terminal") == true, "a refused send says why")
        #expect(composer.text == "typed meanwhile" && editor.text == "typed meanwhile", "the text stays")
        // The `/` menu offers no move to the terminal any more (D-69): not enabled, not disabled.
        editor.replaceAll(with: "")
        composer.textChanged("")
        editor.type("/")
        #expect(composer.menu?.items.contains { $0.title == "Continue in Terminal" || $0.id.hasPrefix("action:") } != true)
        await fixture.cleanup()
    }

    // MARK: Fix round 2

    /// D4, Chat to Terminal: a `/clear` moves the run to a new card after the point of no return. The terminal resumes the card
    /// the run is on now (the new conversation), not the one the move began on, and the old card gets no run.
    @Test func aCardChangeAfterThePointOfNoReturnResumesTheNewCardInTheTerminal() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let gate = PointGate()
        fixture.controller.handoverGate = { _, target in await gate.hold(target) }
        let (id, driver) = try await chatSession(fixture)
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { gate.reached == [.terminal] })
        let run = try #require(await driver.snapshot().runID)
        let card = try await fixture.rig.runtime.supervisor.adoptConversation(
            runID: run, conversationID: UUID().uuidString.lowercased(), transition: .automatic)
        #expect(card != id, "the run moved to a new card")
        gate.release()
        #expect(await waitUntil { model.handovers[id] == nil && model.busy[card] == nil })
        #expect(await driver.sessionID == card)
        #expect(await endpoint(fixture, card) == .terminal)
        #expect(await waitUntil { await hub(fixture, card)?.runID != nil }, "the terminal runs the new card")
        #expect(await hub(fixture, id)?.runID == nil, "the old card was not resumed")
        #expect(!(await driver.isHandingOver), "the move is over: the driver is its own again")
        await fixture.cleanup()
    }

    /// D5, end to end: a message sent while a turn runs is in the draft file; after Loom starts again (a new host and a new
    /// driver on the same data, the old child never ended its run) a new composer holds it once.
    @Test func aMessageSentMidTurnReachesTheComposerOfALaterLaunchOnce() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let (id, driver) = try await chatSession(fixture)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        // The turn's own prompt has been read once its first tool call shows; what is sent now is unread.
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        try await driver.send("sent while working")
        #expect(try model.chatSessions?.draftStore.load(sessionID: id)?.held.map(\.text) == ["sent while working"])

        // Loom starts again: a new host, and a driver and composer made on the data the first left.
        model.installChatSessions(runtime: fixture.rig.runtime, dataRoot: fixture.rig.root)
        let host = try #require(model.chatSessions)
        let fresh = host.driver(for: id)
        let row = try #require(model.selectedRow)
        let feed = try #require(model.liveChatFeed(for: fresh, card: id, conversationID: row.record.session.providerConversationID,
                                                   workingDirectory: row.record.session.workingDirectory))
        let composer = try #require(model.liveChatComposer(for: fresh, row: row, feed: feed))
        composer.start()
        await composer.refresh()
        await composer.attachmentsRestored()
        #expect(composer.text == "sent while working", "found once: \(composer.text)")
        #expect(try host.draftStore.load(sessionID: id)?.held.isEmpty == true)
        await fixture.cleanup()
    }

}

private extension TurnModel {
    var assistantTexts: [String] { entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } } }
    var markerList: [Marker] { entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } } }
}
