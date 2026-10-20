import AppKit
import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomChat

/// V21 on the app's model: the real model, controller, runtime and Chat driver on the fake provider's file checkpoints. The
/// sheet's dry run with its marks, the confirm that restores the files, the marker, Undo, and the sheet's refusal while a turn
/// runs. Nothing is drawn.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct RewindModelFlowTests {
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

    private func idle(_ driver: ChatSessionDriver) async -> Bool {
        await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning }
    }

    private func startFromDraft(_ model: CatalogModel, text: String) async throws -> UUID {
        model.showDraft(projectID: nil)
        model.setDraftText(text, projectID: nil)
        model.sendDraft(projectID: nil)
        #expect(await waitUntil { model.destination?.sessionID != nil })
        return try #require(model.destination?.sessionID)
    }

    private func rowOf(_ receipt: ChatSendReceipt) -> String {
        switch receipt {
        case let .sent(id), let .queued(id): id
        }
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    @Test func theSheetShowsTheDryRunConfirmRestoresTheFilesAndTheMarkersUndoBringsThemBack() async throws {
        let fixture = try await make()
        let model = fixture.model
        let id = try await startFromDraft(model, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver))
        try await driver.setPermissionMode("acceptEdits")
        _ = try await driver.send("/scenario file a.txt one")
        #expect(await idle(driver))
        let second = try await driver.send("/scenario file a.txt two")
        #expect(await idle(driver))
        let directory = fixture.rig.root.appendingPathComponent("home", isDirectory: true).path
        let feed = try #require(model.liveChatFeed(for: driver, card: id, conversationID: nil, workingDirectory: directory))
        feed.start()
        let row = rowOf(second)
        #expect(await waitUntil {
            feed.presentation.model.entries.first { $0.id == row }.map(ChatRewindAction.offers) == true
        })

        // The sheet: the dry run's file relative to the folder, the totals, no mark (the scan found Claude's own record of the
        // file), and the message is not the newest prompt ("hello" was the first, this the last: it is the newest).
        model.requestRewind(driver: driver, card: id, feed: feed, rowID: row)
        let sheet = try #require(model.rewinds.sheet)
        #expect(sheet.phase == .loading)
        #expect(await waitUntil { sheet.content != nil })
        let content = try #require(sheet.content)
        #expect(content.files.map(\.displayPath) == ["a.txt"] && content.files.first?.mark == nil)
        #expect(content.insertions == 1 && content.deletions == 1 && content.newestTurn && content.canConfirm)
        #expect(sheet.title == "/scenario file a.txt two")

        // Cancel changes nothing.
        model.cancelRewind()
        #expect(model.rewinds.sheet == nil)
        let path = try #require(content.files.first?.path)
        #expect(text(path) == "two")

        // Confirm: the files go back, the sheet closes, the stream has its marker with Undo.
        model.requestRewind(driver: driver, card: id, feed: feed, rowID: row)
        let again = try #require(model.rewinds.sheet)
        #expect(await waitUntil { again.canConfirm })
        await model.confirmRewind()
        #expect(model.rewinds.sheet == nil)
        #expect(text(path) == "one")
        let rewindID = try #require(await driver.openUndoRewindID())
        #expect(await waitUntil {
            feed.presentation.model.entries.contains { if case .marker(.rewound) = $0.body { true } else { false } }
        })

        // Undo from the marker's closure path.
        model.undoRewind(driver: driver, rewindID: rewindID, directory: directory)
        #expect(await waitUntil { text(path) == "two" })
        #expect(await waitUntil { await driver.openUndoRewindID() == nil })
        await fixture.cleanup()
    }

    @Test func aFileChangedAfterTheRewindAsksBeforeUndoOverwritesItAndASheetWhileATurnRunsSaysWhyNot() async throws {
        let fixture = try await make()
        let model = fixture.model
        let id = try await startFromDraft(model, text: "hello")
        let driver = try #require(model.chatSessions?.existingDriver(for: id))
        #expect(await idle(driver))
        try await driver.setPermissionMode("acceptEdits")
        _ = try await driver.send("/scenario file a.txt one")
        #expect(await idle(driver))
        let second = try await driver.send("/scenario file a.txt two")
        #expect(await idle(driver))
        let feed = try #require(model.liveChatFeed(for: driver, card: id, conversationID: nil, workingDirectory: nil))
        feed.start()
        #expect(await waitUntil { feed.presentation.model.entries.contains { $0.id == rowOf(second) } })

        model.requestRewind(driver: driver, card: id, feed: feed, rowID: rowOf(second))
        let sheet = try #require(model.rewinds.sheet)
        #expect(await waitUntil { sheet.canConfirm })
        let path = try #require(sheet.content?.files.first?.path)
        await model.confirmRewind()
        let rewindID = try #require(await driver.openUndoRewindID())
        try "one, and the user's line".write(toFile: path, atomically: true, encoding: .utf8)

        // Undo names the file and waits for the user's word.
        model.undoRewind(driver: driver, rewindID: rewindID, directory: nil)
        #expect(await waitUntil { model.rewinds.undoPrompt != nil })
        #expect(model.rewinds.undoPrompt?.files.count == 1 && model.rewinds.undoPrompt?.rewindID == rewindID)
        #expect(text(path) == "one, and the user's line")
        model.confirmUndoOverwrite()
        #expect(await waitUntil { text(path) == "two" })
        #expect(model.rewinds.undoPrompt == nil)

        // A turn runs: the sheet opens and says why it cannot continue.
        _ = try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.snapshot().turnRunning })
        model.requestRewind(driver: driver, card: id, feed: feed, rowID: rowOf(second))
        let busy = try #require(model.rewinds.sheet)
        #expect(await waitUntil { busy.phase == .cannot("Rewind works while the session waits for you") })
        #expect(!busy.canConfirm && busy.canCancel)
        model.cancelRewind()
        await driver.interrupt()
        await fixture.cleanup()
    }
}
