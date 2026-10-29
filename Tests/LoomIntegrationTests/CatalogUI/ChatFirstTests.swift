import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// V19, Chat first, end to end with the real model, controller, runtime and driver on the fake provider: a new session
// starts in the face Settings name (Chat by default), a stopped Chat session shows its composer and a send resumes it in
// Chat, and the handover moves a session between the faces without cutting a turn or losing a message.

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(10)))
struct ChatFirstTests: ChatFirstFixtures {
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

    /// D-100: while the Chat face is frozen, a new file, an older file and a stored Chat all read as Terminal, and a stopped
    /// session's read-only chat is off.
    @Test func whileTheChatFaceIsFrozenEveryPreferenceReadsAsTerminal() throws {
        #expect(ChatFreeze.isFrozen)
        #expect(UIPreferences().newSessionFace == .terminal)
        let old = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"viewMode":"activity"}"#.utf8))
        #expect(old.newSessionFace == .terminal)
        let chat = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"newSessionFace":"chat"}"#.utf8))
        #expect(chat.newSessionFace == .terminal, "a stored Chat reads as Terminal")
        #expect(!SessionFaces().readOnlyChatEnabled)
        // Even with a host, a Claude start from the frozen preference never picks the pipe face.
        let policy = FacePolicy(runsIn: chat.newSessionFace == .chat ? .chat : .terminal, structuredHostAvailable: true)
        #expect(policy.faceOfStart(HarnessCapabilities.of(.claude, startable: [.claude])) == .terminal)
    }

    // MARK: Fix round

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
}

private extension TurnModel {
    var assistantTexts: [String] { entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } } }
    var markerList: [Marker] { entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } } }
}
