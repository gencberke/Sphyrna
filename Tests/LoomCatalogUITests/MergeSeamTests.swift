import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The seams between V19 (Chat first, the handover) and V24 (the chat bar, Ask), end to end with the real model, controller,
// runtime and driver on the fake provider: every path that would run Ask in the terminal runs Ask before edits and says so,
// the stopped session's composer carries the bar's picks to the resume, a pick while a handover waits is kept, and the markers
// read Loom's names.

private let askNotice = "Ask works in Chat. This terminal session runs in Ask before edits."
private let userRules = """
[{"behavior":"allow","source":"userSettings","rule":"Bash(touch:*)"}]
"""

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(10)))
struct MergeSeamTests {
    struct Fixture {
        let rig: LiveRig
        let model: CatalogModel
        let controller: ConversationController

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            await rig.finish()
        }

        var home: URL { rig.root.appendingPathComponent("home", isDirectory: true) }
    }

    private func makeFixture(environment: [String: String] = [:]) async throws -> Fixture {
        let rig = try await LiveRig.make(environment: environment)
        let model = CatalogModel(
            catalog: await rig.runtime.catalog, events: await rig.runtime.supervisor.events,
            preferences: UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: rig.runtime, model: model)
        controller.handoverSettle = .milliseconds(300)
        await controller.begin()
        await model.start()
        model.installChatSessions(runtime: rig.runtime, dataRoot: rig.root)
        model.setClaudeConfigDirectory(rig.profile)
        return Fixture(rig: rig, model: model, controller: controller)
    }

    private func waitUntil(_ seconds: Double = 15, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// A start from the draft's send with `mode` chosen, as the controller gets it.
    private func start(_ fixture: Fixture, mode: String?, text: String = "hello") async throws -> UUID {
        var started: UUID?
        var failed = false
        fixture.controller.startSession(
            projectID: nil, launch: NewSessionLaunch(firstMessage: text, choices: ClaudeLaunchChoices(permissionMode: mode)),
            focus: .session
        ) { outcome in
            switch outcome {
            case let .started(id): started = id
            case .failed: failed = true
            }
        }
        #expect(await waitUntil { started != nil || failed })
        return try #require(started)
    }

    private func catalogMode(_ fixture: Fixture, _ id: UUID) async -> String? {
        try? await fixture.rig.runtime.catalog.launchChoices(sessionID: id).permissionMode
    }

    private func endpoint(_ fixture: Fixture, _ id: UUID) async -> RunEndpointKind? {
        try? await fixture.rig.runtime.catalog.runEndpoint(sessionID: id)
    }

    private func notice(_ fixture: Fixture, _ id: UUID) async -> String? {
        await fixture.rig.runtime.supervisor.events.snapshot().sessions[id]?.issue
    }

    private func chatDriver(_ fixture: Fixture, _ id: UUID) async throws -> ChatSessionDriver {
        #expect(await waitUntil { fixture.model.chatSessions?.existingDriver(for: id) != nil })
        let driver = try #require(fixture.model.chatSessions?.existingDriver(for: id))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        return driver
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

        // And back: Chat comes back in Ask before edits. Ask returns only when the user picks it again.
        model.continueIn(.chat, sessionID: chat)
        #expect(await waitUntil { await endpoint(fixture, chat) == .pipe && model.handovers[chat] == nil })
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

    // MARK: Seam 2, a pick while a handover waits

    /// The bar's mode, model and effort picked while Continue in Terminal waits are the session's choice: the chain and the
    /// hold return at once, the child is not told, and the terminal's resume finds them in the catalog.
    @Test func theBarsPicksWhileAHandoverWaitsAreKeptForTheTerminalLaunch() async throws {
        let fixture = try await makeFixture(environment: ["LOOM_FAKE_CHAT_FAIL_MODE": "acceptEdits"])
        let model = fixture.model
        let id = try await start(fixture, mode: "default")
        let driver = try await chatDriver(fixture, id)
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { model.handovers[id]?.phase == .waiting })

        #expect(await waitUntil { model.selectedRow != nil })
        let row = try #require(model.selectedRow)
        let shown = try #require(model.liveChatDriverForDisplay(of: row))
        let feed = try #require(model.liveChatFeed(for: shown, card: id, conversationID: row.record.session.providerConversationID,
                                                   workingDirectory: row.record.session.workingDirectory))
        let composer = try #require(model.liveChatComposer(for: shown, row: row, feed: feed))
        composer.start()
        await composer.refresh()
        let picks = [composer.setMode("acceptEdits"), composer.setModel("opus"), composer.setEffort("high")]
        let done = Done()
        Task { for pick in picks { await pick.value }; done.raise() }
        #expect(await waitUntil(10) { done.isRaised }, "the mode chain and the handover hold do not lock each other")
        #expect(composer.notice == nil, "the fake refuses acceptEdits: a pick that reached the child would have said so")
        #expect(composer.state.choices.permissionMode == "acceptEdits" && composer.state.choices.model == "opus")

        #expect(await waitUntil { await endpoint(fixture, id) == .terminal && model.handovers[id] == nil })
        let launch = try await fixture.rig.runtime.catalog.launchChoices(sessionID: id)
        #expect(launch.permissionMode == "acceptEdits" && launch.model == "opus" && launch.effort == "high")
        await fixture.cleanup()
    }

    // MARK: The composer outlives its feed

    /// V24 lets the host release a feed nobody shows while the composer stays. The composer is bound to the feed of the view
    /// that shows it now, so "Continue in Terminal", the handover notice and the folder keep answering after the swap.
    @Test func aComposerThatOutlivesItsFeedIsBoundToTheNewOneAndStillSaysTheSessionMoves() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let id = try await start(fixture, mode: "default")
        let driver = try await chatDriver(fixture, id)
        #expect(await waitUntil { model.selectedRow != nil })
        let row = try #require(model.selectedRow)
        let shown = try #require(model.liveChatDriverForDisplay(of: row))
        let host = try #require(model.chatSessions)
        func compose() -> ChatComposerModel? {
            guard let feed = model.liveChatFeed(for: shown, card: id, conversationID: row.record.session.providerConversationID,
                                                workingDirectory: row.record.session.workingDirectory) else { return nil }
            return model.liveChatComposer(for: shown, row: row, feed: feed)
        }
        let composer = try #require(compose())
        host.releaseAttachment(for: driver)
        // A new view, a new feed: the same composer.
        let again = try #require(compose())
        #expect(again === composer)
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        model.continueIn(.terminal, sessionID: id)
        #expect(await waitUntil { model.handovers[id]?.phase == .waiting })
        #expect(composer.handoverPending == "Moving to the terminal\u{2026}")
        #expect(composer.environment.continueInTerminalRefusal() == "This session is already moving.")
        await fixture.cleanup()
    }

    // MARK: Seam 3, markers read Loom's names

    @Test func theMarkersReadLoomsNamesForEveryModeWord() async throws {
        #expect(ChatMarkerText.text(.sessionStart(model: nil, permissionMode: "default")) == "Session started \u{00B7} Ask before edits")
        #expect(ChatMarkerText.text(.sessionStart(model: nil, permissionMode: "dontAsk")) == "Session started \u{00B7} Ask")
        #expect(ChatMarkerText.text(.sessionStart(model: nil, permissionMode: "bypassPermissions")) == "Session started \u{00B7} Full access")
        #expect(ChatMarkerText.text(.sessionStart(model: nil, permissionMode: "acceptEdits")) == "Session started \u{00B7} Accept edits")
        #expect(ChatMarkerText.text(.modeChanged("default")) == "Mode changed to Ask before edits")
        #expect(ChatMarkerText.text(.modeChanged("dontAsk")) == "Mode changed to Ask")
        // The live session's own start marker, from `initialize`, read as the row shows it.
        let fixture = try await makeFixture()
        let id = try await start(fixture, mode: nil)
        let driver = try await chatDriver(fixture, id)
        let first = await driver.snapshot().model.entries.compactMap { entry -> String? in
            if case let .marker(marker) = entry.body, case .sessionStart = marker { ChatMarkerText.text(marker) } else { nil }
        }
        #expect(first == ["Session started \u{00B7} Ask before edits"], "\(first)")
        await fixture.cleanup()
    }

    // MARK: Seam 5, the stopped session's composer with the bar's picks

    /// A stopped Chat session shows its composer and the bar: the mode picked there is the resume's (the catalog and the
    /// child), and a stopped Ask session resumes in Ask with the layer on before its first message.
    @Test func theStoppedComposerCarriesTheBarsPicksToTheResumeAndAskResumesInAsk() async throws {
        let fixture = try await makeFixture(environment: ["LOOM_FAKE_CHAT_USER_RULES": userRules])
        let model = fixture.model

        func stoppedComposer(_ id: UUID, _ driver: ChatSessionDriver) async throws -> ChatComposerModel {
            _ = try await driver.stop()
            #expect(await waitUntil { await driver.currentPhase == .stopped && model.busy[id] == nil })
            model.select(id)
            #expect(await waitUntil { model.selectedRow?.live?.runID == nil && model.selectedRow?.record.runEndpoint == .pipe })
            let row = try #require(model.selectedRow)
            #expect(model.showsStoppedLiveChat(row))
            let shown = try #require(model.liveChatDriverForDisplay(of: row))
            let feed = try #require(model.liveChatFeed(for: shown, card: id, conversationID: row.record.session.providerConversationID,
                                                       workingDirectory: row.record.session.workingDirectory))
            let composer = try #require(model.liveChatComposer(for: shown, row: row, feed: feed))
            composer.start()
            await composer.refresh()
            return composer
        }

        // A plain session: the bar's Ask, picked while it is stopped, is on before the first message of the resume.
        let plain = try await start(fixture, mode: "default")
        let plainDriver = try await chatDriver(fixture, plain)
        let composer = try await stoppedComposer(plain, plainDriver)
        await composer.setMode("ask").value
        #expect(composer.state.choices.permissionMode == "ask")
        composer.setText("/scenario run touch asked.txt")
        composer.submit(secondary: false)
        #expect(await waitUntil(20) {
            await plainDriver.snapshot().model.entries.contains { if case let .tool(call) = $0.body { call.status == .refusedInAsk } else { false } }
        }, "Ask's layer was on before the first message of the resume")
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("asked.txt").path))
        #expect(await plainDriver.liveState().isAsk)

        // A stopped Ask session resumes in Ask (Chat face) with no pick at all.
        let ask = try await start(fixture, mode: "ask")
        let askDriver = try await chatDriver(fixture, ask)
        let askComposer = try await stoppedComposer(ask, askDriver)
        #expect(askComposer.state.choices.permissionMode == "ask")
        askComposer.setText("/scenario run touch resumed.txt")
        askComposer.submit(secondary: false)
        #expect(await waitUntil(20) {
            await askDriver.snapshot().model.entries.contains { if case let .tool(call) = $0.body { call.status == .refusedInAsk } else { false } }
        })
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("resumed.txt").path))
        let resumedAsk = await askDriver.liveState().isAsk
        let resumedWire = await askDriver.snapshot().permissionMode
        #expect(resumedAsk && resumedWire == "dontAsk")

        // Another mode picked on the stopped bar is the child's at the resume, and the catalog's.
        let other = try await start(fixture, mode: "default")
        let otherDriver = try await chatDriver(fixture, other)
        let otherComposer = try await stoppedComposer(other, otherDriver)
        await otherComposer.setMode("acceptEdits").value
        await otherComposer.setModel("opus").value
        otherComposer.setText("hello again")
        otherComposer.submit(secondary: false)
        #expect(await waitUntil(20) { await otherDriver.snapshot().permissionMode == "acceptEdits" })
        let choices = try await fixture.rig.runtime.catalog.launchChoices(sessionID: other)
        #expect(choices.permissionMode == "acceptEdits" && choices.model == "opus")
        await fixture.cleanup()
    }
}

private final class Done: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}
