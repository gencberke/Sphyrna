import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// The seams between V19 (Chat first, the handover) and V24 (the chat bar, Ask), end to end with the real model, controller,
// runtime and driver on the fake provider: every path that would run Ask in the terminal runs Ask before edits and says so,
// the stopped session's composer carries the bar's picks to the resume, a pick while a handover waits is kept, and the markers
// read Loom's names.

private let askNotice = "Ask works in Chat. This terminal session runs in Ask before edits."

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(10)))
struct MergeSeamTests: MergeSeamFixtures {
    private func catalogMode(_ fixture: Fixture, _ id: UUID) async -> String? {
        try? await fixture.rig.runtime.catalog.launchChoices(sessionID: id).permissionMode
    }

    // MARK: Seam 1, the paths into the terminal

    /// The terminal setting, the start's fallback without a Chat host, a terminal resume and Continue in Terminal: each one
    /// starts the TUI in Ask before edits (never `dontAsk`), the catalog records what ran, and the session says so.
    @Test func everyPathIntoTheTerminalRunsAskInAskBeforeEditsAndSaysSo() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model

        // "New sessions start in: Terminal", with an Ask start (a draft cannot pick Ask there, but a remembered choice or a
        // preset can still reach the controller).
        model.setNewSessionFace(.terminal)
        let setting = try await start(fixture, mode: "ask")
        #expect(await waitUntil { await endpoint(fixture, setting) == .terminal })
        #expect(await waitUntil { await catalogMode(fixture, setting) == "default" })
        #expect(await waitUntil { await notice(fixture, setting) == askNotice })

        // No Chat host: the start falls back to the terminal.
        model.setNewSessionFace(.chat)
        let host = model.chatSessions
        model.chatSessions = nil
        let fallback = try await start(fixture, mode: "ask")
        #expect(await waitUntil { await endpoint(fixture, fallback) == .terminal })
        #expect(await waitUntil { await catalogMode(fixture, fallback) == "default" })
        #expect(await waitUntil { await notice(fixture, fallback) == askNotice })
        model.chatSessions = host

        // Continue in Terminal from an Ask session in Chat.
        let chat = try await start(fixture, mode: "ask")
        let driver = try await chatDriver(fixture, chat)
        let askOn = await driver.liveState().isAsk
        let owner = await endpoint(fixture, chat)
        #expect(askOn && owner == .pipe)
        #expect(await waitUntil { model.selectedRow?.record.runEndpoint == .pipe })
        model.continueIn(.terminal, sessionID: chat)
        #expect(await waitUntil { await endpoint(fixture, chat) == .terminal && model.handovers[chat] == nil })
        #expect(await catalogMode(fixture, chat) == "default")
        #expect(await waitUntil { await notice(fixture, chat) == askNotice })

        // And back (the terminal is stopped, then the session resumes in Chat as the switch says): Chat comes back in Ask
        // before edits. Ask returns only when the user picks it again.
        model.stopConversation(chat)
        #expect(await waitUntil { model.busy[chat] == nil && model.terminalView(for: chat) == nil })
        fixture.controller.resume(sessionID: chat)
        #expect(await waitUntil { await endpoint(fixture, chat) == .pipe })
        let again = try await chatDriver(fixture, chat)
        let back = await again.snapshot()
        #expect(back.choices.permissionMode == "default" && back.permissionMode == "default")
        #expect(await again.liveState().isAsk == false)
        try await again.setPermissionMode("ask")
        #expect(await again.liveState().isAsk)
        _ = try await again.stop()

        // A terminal resume (no Chat host to resume in) of a session left in Ask.
        #expect(await waitUntil { await again.currentPhase == .stopped && model.busy[chat] == nil })
        #expect(await catalogMode(fixture, chat) == "ask")
        model.chatSessions = nil
        fixture.controller.resume(sessionID: chat)
        #expect(await waitUntil { await endpoint(fixture, chat) == .terminal })
        #expect(await waitUntil { await catalogMode(fixture, chat) == "default" })
        #expect(await waitUntil { await notice(fixture, chat) == askNotice })
        model.chatSessions = host
        await fixture.cleanup()
    }
}
