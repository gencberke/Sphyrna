import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore

// Release B fix round 2, the driver part: a handover that ends without a move, the stored choices of a stopped session, the
// hold that outlives the stop, messages in the draft file until Claude reads them, Ask after a reset, a held pick that
// failed, the cost of reading the composer's state, images the rows keep, one plan-approval path, and the host's cleanup.

/// A latch a test opens to let a parked task go on.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private func tools(_ snapshot: ChatDriverSnapshot) -> [ToolCall] {
    snapshot.model.entries.compactMap { if case let .tool(call) = $0.body { call } else { nil } }
}

private func userPrompt(_ snapshot: ChatDriverSnapshot, _ id: String) -> UserPrompt? {
    guard case let .user(prompt) = snapshot.model.entry(id: id)?.body else { return nil }
    return prompt
}

private final class FixScreen: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func receive(_ data: Data) { lock.withLock { buffer += String(decoding: data, as: UTF8.self) } }
    var text: String { lock.withLock { buffer } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(8)))
struct ChatFixRound2DriverTests {
    // MARK: D1, D3: the handover

    /// D1: the turn the handover waited for ends while the hold is on, so the queue's release is skipped; the handover then ends
    /// without a move (Cancel, here while it waits for a mode change that was on its way). The "After this turn" item must go out
    /// then: nothing else would release it.
    @Test func anAfterThisTurnItemGoesOutWhenTheHandoverEndsWithoutAMove() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 1500")
        #expect(await waitUntil(15) { !tools(await driver.snapshot()).isEmpty })
        let parked = Gate()
        await driver.setHandoverParked { await parked.wait() }
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        let queued = try await driver.send("after the turn", timing: .afterTurn)
        guard case .queued = queued else { Issue.record("not queued: \(queued)"); return }
        // The turn ends under the hold, with the handover parked before its decision: the queue's release is skipped.
        #expect(await waitUntil(15) { let snap = await driver.snapshot(); return !snap.turnRunning })
        try await Task.sleep(for: .milliseconds(300))
        let held = await driver.snapshot()
        #expect(held.queue.items.count == 1 && !held.texts.contains("Fake answer to: after the turn"), "the hold kept the queue back")
        #expect(await driver.isHandingOver)
        await driver.cancelHandover()
        await parked.open()
        await #expect(throws: CancellationError.self) { try await handover.value }
        #expect(await waitUntil(15) { await driver.snapshot().texts.contains("Fake answer to: after the turn") },
                "the queued item was sent once the handover ended without a move")
        #expect(await driver.snapshot().queue.isEmpty)
        #expect(!(await driver.isHandingOver))
        await rig.finish()
    }

    /// D3: the driver keeps its hold from the stop until the caller says the other face has the session (or the move failed):
    /// a send in that window is refused and nothing of it is kept in the stream; afterwards it resumes the session.
    @Test func theHoldOutlivesTheStopUntilTheCallerFinishesTheMove() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        try await driver.handOverToTerminal()
        #expect(await driver.currentPhase == .stopped)
        #expect(await driver.isHandingOver, "the terminal does not have the session yet")
        await #expect(throws: ChatDriverError.handingOver) { _ = try await driver.send("too soon") }
        let item = try await driver.enqueue("queued")
        await #expect(throws: ChatDriverError.handingOver) { _ = try await driver.sendQueuedNow(id: item) }
        let held = await driver.snapshot()
        #expect(held.phase == .stopped && held.runID == nil, "no run was started")
        #expect(!held.model.entries.contains { if case let .user(prompt) = $0.body { prompt.text == "too soon" } else { false } })
        // The caller finishes the move (here: it failed): the driver is its own again, and a send resumes the session.
        await driver.finishHandover()
        #expect(!(await driver.isHandingOver))
        try await driver.send("now it goes")
        #expect(await waitUntil { await driver.snapshot().texts.last == "Fake answer to: now it goes" })
        await rig.finish()
    }

    /// D14, the planner's call: coming back to Chat (a resume once the terminal run ended) keeps the queue paused for the
    /// move. What was queued before the session went to the terminal may not fit what was done there, so nothing goes out
    /// until the user resumes the queue.
    @Test func aResumeAfterTheTerminalKeepsTheQueuePausedUntilTheUserResumesIt() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let host = await MainActor.run { ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root) }
        let driver = try await host.startNewSession(projectID: nil, sessionID: id, draft: NewSessionLaunch(firstMessage: "hello"))
        #expect(await idle(driver))
        _ = try await driver.enqueue("for later")
        try await driver.handOverToTerminal()
        #expect(await driver.snapshot().queue.paused == .handover)
        let screen = FixScreen()
        _ = try await rig.runtime.resumeConversation(sessionID: id, outputSink: screen)
        await driver.finishHandover()
        #expect(await waitUntil { screen.text.lowercased().contains("resumed \(id.uuidString.lowercased())") })

        _ = try await rig.runtime.stopConversation(sessionID: id)
        try await driver.resume()
        #expect(await idle(driver))
        try await Task.sleep(for: .milliseconds(500))
        let back = await driver.snapshot()
        #expect(back.queue.paused == .handover, "the queue still waits for the user")
        #expect(!back.texts.contains("Fake answer to: for later"), "nothing queued went out by itself")
        try await driver.resumeQueue()
        #expect(await waitUntil(15) { await driver.snapshot().texts.contains("Fake answer to: for later") }, "Resume sends it")
        #expect(await driver.snapshot().queue.isEmpty)
        await rig.finish()
    }

    // MARK: D2: stored choices

    /// D2: a driver made for a stopped session that has stored choices shows them before any launch, as it does after Loom
    /// started again (the earlier driver and its memory are gone).
    @Test func aStoppedSessionShowsItsStoredChoicesBeforeAnyLaunch() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let first = rig.driver(id)
        try await first.startNew(projectID: nil, draft: NewSessionLaunch(
            firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "opus")))
        _ = try await first.stop()
        #expect(await waitUntil { await first.currentPhase == .stopped })

        let reopened = rig.driver(id)
        #expect(await reopened.currentPhase == .stopped)
        #expect(await waitUntil {
            let state = await reopened.composerState()
            return state.choices.permissionMode == "acceptEdits" && state.choices.model == "opus"
        }, "the bar shows the stored mode and model, not 'Mode' and 'Default model'")
        await rig.finish()
    }

    // MARK: D5: messages sent mid-turn

    private func midTurn(_ rig: Rig, _ drafts: ChatDraftStore, id: UUID) async throws -> (ChatSessionDriver, ChatSendReceipt) {
        let driver = rig.driver(id, drafts: drafts)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { !tools(await driver.snapshot()).isEmpty })
        let held = try await driver.send("mid-turn words", attachments: [.pastedText("pasted body")])
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        return (driver, held)
    }

    /// D5: a message written while a turn runs is in the draft file at once, with its attachment, and gone when Claude reads it.
    @Test func aMessageSentMidTurnIsInTheDraftFileUntilClaudeReadsIt() async throws {
        let rig = try await Rig.make()
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("drafts", isDirectory: true))
        let id = UUID()
        let (driver, _) = try await midTurn(rig, drafts, id: id)
        let onDisk = try #require(try drafts.load(sessionID: id))
        #expect(onDisk.held.map(\.text) == ["mid-turn words"])
        #expect(onDisk.held.first?.attachments.count == 1)
        #expect(onDisk.text.isEmpty, "it is held, not yet text: the composer's draft is untouched")
        let attachment = try #require(onDisk.held.first?.attachments.first)
        #expect(drafts.attachmentData(id: attachment.id, sessionID: id) == Data("pasted body".utf8))

        #expect(await idle(driver, 20))
        #expect(try drafts.load(sessionID: id) == nil, "Claude read it: the draft file and its attachment are gone")
        #expect(!FileManager.default.fileExists(atPath: drafts.folder(for: id).path))
        await rig.finish()
    }

    /// D5: a crash (here: a driver made on the same stores while the first never ended its run) leaves the message once in the
    /// text, with its attachment, and the held list empty. The messages the child never read when it was killed are not doubled.
    @Test func aDriverMadeAfterACrashFindsTheMessageOnce() async throws {
        let rig = try await Rig.make()
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("drafts", isDirectory: true))
        let id = UUID()
        let (_, _) = try await midTurn(rig, drafts, id: id)
        let after = rig.driver(id, drafts: drafts)
        let recovered = try #require(try drafts.load(sessionID: id))
        #expect(recovered.text == "mid-turn words" && recovered.held.isEmpty)
        #expect(recovered.attachments.count == 1 && recovered.attachments.first?.kind == .pastedText)
        #expect(await after.takeReturnedDrafts().isEmpty, "the recovered message reaches a composer through the file, once")
        // Asked again, nothing more is found.
        _ = rig.driver(id, drafts: drafts)
        #expect(try drafts.load(sessionID: id)?.text == "mid-turn words")
        await rig.finish()
    }

    /// D5: the child is killed with the message unread: it is in the text once (the held copy moved there).
    @Test func aKilledChildLeavesTheUnreadMessageOnceInTheText() async throws {
        let rig = try await Rig.make()
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("drafts", isDirectory: true))
        let id = UUID()
        let (driver, _) = try await midTurn(rig, drafts, id: id)
        let pid = try #require(await driver.snapshot().processID)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await waitUntil { await driver.currentPhase == .failed(.ended) })
        let draft = try #require(try drafts.load(sessionID: id))
        #expect(draft.text == "mid-turn words" && draft.held.isEmpty, "\(draft)")
        await rig.finish()
    }

    // MARK: D6: Ask after a reset

    /// D6: a queued message released by the `/clear` turn's own `result` goes out only after Ask's layer is back on. The CLI
    /// forgets its live settings on a reset and answers the layer slowly: without the wait the message ran with no rules.
    @Test func aMessageReleasedRightAfterAResetInAskGoesOutOnlyAfterTheLayer() async throws {
        let userRules = #"[{"behavior":"allow","source":"userSettings","rule":"Bash(touch:*)"}]"#
        let rig = try await Rig.make(environment: [
            "LOOM_FAKE_CHAT_RESET_FORGETS_SETTINGS": "1", "LOOM_FAKE_CHAT_USER_RULES": userRules,
            "LOOM_FAKE_CHAT_CONTROL_DELAY_MS": "250",
        ])
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(
            firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "ask")))
        try await driver.send("/clear")
        let queued = try await driver.send("/scenario run touch cleared.txt", timing: .afterTurn)
        guard case .queued = queued else { Issue.record("not queued: \(queued)"); return }
        #expect(await waitUntil(20) { await driver.snapshot().sessionID != id }, "the reset moved the run")
        #expect(await waitUntil(30) {
            let snap = await driver.snapshot()
            return snap.queue.isEmpty && !tools(snap).isEmpty
        })
        #expect(await idle(driver, 20))
        #expect(!FileManager.default.fileExists(atPath: rig.home.appendingPathComponent("cleared.txt").path),
                "the user's allow rule was not in force yet when the message ran")
        #expect(await driver.liveState().isAsk)
        await rig.finish()
    }

    // MARK: D7: a held pick that failed

    /// D7: a model and an effort picked while a handover holds the session are recorded at once; when the handover ends with the
    /// run still here and the CLI refuses them, the choice, the chip and the catalog go back to what the child runs.
    @Test func aHeldModelAndEffortThatTheChildRefusesAreTakenBack() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_FAIL_PICKS": "model,effort"])
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let before = await driver.composerState()
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })

        try await driver.setModel("opus")
        try await driver.setEffort("high")
        let held = await driver.composerState()
        #expect(held.choices.model == "opus" && held.choices.effort == "high" && held.resolvedModel == "claude-opus-fake-5-1",
                "held: recorded and shown at once")
        #expect(try await rig.catalog.launchChoices(sessionID: id).model == "opus")

        await driver.cancelHandover()
        await #expect(throws: CancellationError.self) { try await handover.value }
        #expect(await idle(driver, 20))
        let after = await driver.composerState()
        #expect(after.choices.model == before.choices.model && after.choices.effort == before.choices.effort,
                "the choice is what the child runs: \(after.choices)")
        #expect(after.resolvedModel != "claude-opus-fake-5-1", "the chip no longer shows the refused model")
        let stored = try await rig.catalog.launchChoices(sessionID: id)
        #expect(stored.model == nil && stored.effort == nil, "the catalog is back too: \(stored)")
        #expect(rig.reports.choices.withLock { $0.last }?.model == nil, "the UI was told")
        await rig.finish()
    }

    // MARK: D8: the composer's state costs the unread messages, not the stream

    /// D8: `composerState()` was O(entries) on every read (each stdout read makes the composer's follower call it). The unread
    /// rows come from the payloads kept now, so the cost is flat with the stream.
    @Test func composerStateCostsTheSameAt1kAnd10kAnd50kEntries() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        var rows = 0
        var means: [Int: Double] = [:]
        for target in [1_000, 10_000, 50_000] {
            try await driver.send("/scenario flood \(target - rows)")
            #expect(await idle(driver, 120))
            rows = await driver.snapshot().model.entries.count
            #expect(rows >= target)
            let reads = 200
            let started = ContinuousClock.now
            for _ in 0..<reads { _ = await driver.composerState() }
            let elapsed = started.duration(to: .now)
            let mean = (Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12) / Double(reads)
            means[target] = mean
            print("BUDGET composerState entries=\(rows) mean=\(String(format: "%.1f", mean)) us")
        }
        let small = try #require(means[1_000]), large = try #require(means[50_000])
        #expect(large < small * 3 + 300, "flat: \(small) us at 1k, \(large) us at 50k")
        await rig.finish()
    }

    // MARK: D9: images

    /// D9: an image Loom sent keeps in its row what a history row keeps: over 2 MiB, no payload. The driver holds the full
    /// payload until Claude reads the message, and the echo keeps the row's copy, so it would stay for the life of the model.
    @Test func anImageOverTheLimitLeavesNoPayloadInItsRow() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        let big = Data(count: 3_000_000).base64EncodedString()
        let small = Data(count: 1_000).base64EncodedString()
        let one = try await driver.send("big one", attachments: [.image(mediaType: "image/png", base64: big)])
        let two = try await driver.send("small one", attachments: [.image(mediaType: "image/png", base64: small)])
        #expect(await idle(driver, 20))
        let snapshot = await driver.snapshot()
        let bigRow = try #require(userPrompt(snapshot, one.id)?.images.first)
        let smallRow = try #require(userPrompt(snapshot, two.id)?.images.first)
        #expect(bigRow.data == nil && bigRow.byteCount == big.utf8.count, "the row says how big it was and keeps nothing")
        #expect(smallRow.data == small, "a small image is still drawn")
        await rig.finish()
    }

    // MARK: D10: one plan-approval path

    /// D10: keep planning with empty feedback sends "Keep planning." (the test-only helper sent the empty text as it was).
    @Test func keepPlanningWithEmptyFeedbackSendsTheDefaultWords() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        for feedback in [nil, "", "  \n"] as [String?] {
            try await driver.send("/scenario plan")
            #expect(await waitUntil { await driver.snapshot().requests.first?.kind == .plan })
            let plan = try #require(await driver.snapshot().requests.first)
            // What goes to the CLI is the production builder's word, and the card keeps one line of it.
            let built = try plan.answerPlan(for: .keepPlanning(feedback: feedback))
            #expect(built.decision == .deny(message: "Keep planning.", interrupt: false), "feedback \(String(describing: feedback))")
            try await driver.answer(requestID: plan.requestID, .keepPlanning(feedback: feedback))
            #expect(await idle(driver))
            #expect(await driver.snapshot().texts.last == "Staying in plan mode.")
        }
        await rig.finish()
    }

    // MARK: D12: the host's cleanup is a forgetter

    /// D12: a deletion the runtime finishes by itself (launch recovery has no UI model) removes the host's queue, draft and driver.
    @Test func aDeletionTheRuntimeFinishesRemovesTheHostsQueueDraftAndDriver() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let host = await MainActor.run { ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root) }
        let driver = try await host.startNewSession(projectID: nil, sessionID: id, draft: NewSessionLaunch(firstMessage: "hello"))
        #expect(await idle(driver))
        let (drafts, queues) = await MainActor.run { (host.draftStore, host.queueStore) }
        _ = try await driver.enqueue("queued words")
        try drafts.prepend(texts: ["a draft"], attachments: [], sessionID: id)
        let queueFile = queues.directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
        #expect(FileManager.default.fileExists(atPath: queueFile.path))
        #expect(try drafts.load(sessionID: id) != nil)

        let outcome = try await rig.runtime.deleteConversation(id: id)
        #expect(outcome == .deleted)
        #expect(!FileManager.default.fileExists(atPath: queueFile.path), "the queue went with the session")
        #expect(try drafts.load(sessionID: id) == nil, "the draft went with the session")
        #expect(await host.existingDriver(for: id) == nil)
        await rig.finish()
    }

    // MARK: D14: the registry

    /// D14: a driver whose run moved is not put over another driver already under the new card: the move is refused.
    @Test func theRegistryDoesNotOverwriteAnExistingEntryWhenADriverMoves() async throws {
        let rig = try await Rig.make()
        let registry = ChatDriverRegistry()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let mover = rig.driver(a), occupant = rig.driver(b)
        registry[a] = mover
        registry[b] = occupant
        #expect(registry.move(from: a, to: b) == false)
        #expect(registry[b] === occupant && registry[a] === mover, "both stay where they were")
        #expect(registry.move(from: a, to: c))
        #expect(registry[c] === mover && registry[a] == nil)
        await rig.finish()
    }
}
