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
    private func prompts(_ driver: ChatSessionDriver) async -> [(text: String, delivery: UserPrompt.Delivery)] {
        await driver.snapshot().model.entries.compactMap { entry in
            if case let .user(prompt) = entry.body { (prompt.text, prompt.delivery) } else { nil }
        }
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
}
