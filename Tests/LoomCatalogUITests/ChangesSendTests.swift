import AppKit
import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomChat

/// V20: the Changes tab's comments go to Claude as one message through the path the composer's Return takes, with the real
/// model, controller, runtime and Chat driver on the fake provider. A terminal-face session shows the diffs and cannot send.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ChangesSendTests {
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

    private func make() async throws -> Fixture {
        let rig = try await LiveRig.make()
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

    private func prompts(_ driver: ChatSessionDriver) async -> [(text: String, delivery: UserPrompt.Delivery)] {
        await driver.snapshot().model.entries.compactMap { entry in
            if case let .user(prompt) = entry.body { (prompt.text, prompt.delivery) } else { nil }
        }
    }

    private func comment(_ model: CatalogModel, _ id: UUID, line: Int, _ text: String) {
        model.changes.session(for: id).saveComment(
            text, at: ChangeAnchor(fileID: "/w/src/a.swift", line: line, removed: false, text: "let value = \(line)"),
            displayPath: "src/a.swift", in: .lastTurn)
    }

    @Test func aLiveChatSessionGetsOneMessageSentAsNextAndTheCommentsClearAfterIt() async throws {
        let fixture = try await make()
        let model = fixture.model
        let id = try await startFromDraft(model, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        #expect(model.changesSendAvailability(for: id) == .ready)

        // A turn is under way: ↵ is `next`, so the message is held by the CLI until the step ends (it neither interrupts
        // nor waits in Loom's queue for the turn to end).
        let hold = fixture.rig.root.appendingPathComponent("hold-steps")
        #expect(FileManager.default.createFile(atPath: hold.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: hold) }
        try await driver.send("/scenario work 4000 hold \(hold.path)")
        #expect(await waitUntil { await driver.snapshot().turnRunning })

        comment(model, id, line: 3, "Name this better.")
        comment(model, id, line: 9, "Why not a constant?")
        let expected = """
        Comments on the changes (Last turn):

        src/a.swift:3
        > let value = 3
        Name this better.

        src/a.swift:9
        > let value = 9
        Why not a constant?
        """
        await model.sendChangeComments(for: id)
        #expect(model.changes.session(for: id).comments(in: .lastTurn).isEmpty, "an accepted send clears the comments")
        #expect(model.changes.session(for: id).sendStatus == .idle)
        #expect(await waitUntil { await prompts(driver).contains { $0.text == expected && $0.delivery == .queued } })
        #expect(await prompts(driver).filter { $0.text == expected }.count == 1, "one message, not one per comment")
        try FileManager.default.removeItem(at: hold)
        #expect(await waitUntil(30) { await prompts(driver).contains { $0.text == expected && $0.delivery == .read } })
        await fixture.cleanup()
    }

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
