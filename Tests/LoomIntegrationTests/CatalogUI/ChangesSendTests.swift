import AppKit
import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// V20: the Changes tab's comments go to Claude as one message through the path the composer's Return takes, with the real
/// model, controller, runtime and Chat driver on the fake provider. A terminal-face session shows the diffs and cannot send.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ChangesSendTests: ChangesSendFixtures {
    @Test func aStoppedChatSessionCanSendAndATerminalSessionCannot() async throws {
        let fixture = try await make()
        let model = fixture.model
        let chat = try await startFromDraft(model, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: chat))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        try await model.stopChat(chat)
        #expect(await waitUntil { model.rowModels[chat].map { !model.isRunning($0) } == true })
        #expect(model.changesSendAvailability(for: chat) == .ready, "the send resumes the session, as the stopped composer does")

        // A session the terminal face runs: the tab shows its diffs, and Send is off.
        model.setNewSessionFace(.terminal)
        let terminal = try await startFromDraft(model, text: "hello from the terminal")
        #expect(await waitUntil { (try? await fixture.rig.runtime.catalog.session(id: terminal)?.runEndpoint) == .terminal })
        #expect(model.changesSendAvailability(for: terminal) == .notChat)
        comment(model, terminal, line: 1, "a note")
        await model.sendChangeComments(for: terminal)
        #expect(model.changes.session(for: terminal).comments(in: .lastTurn).count == 1, "nothing was sent, nothing was lost")
        #expect(model.chatSessions?.existingDriver(for: terminal) == nil)
        await fixture.cleanup()
    }
}
