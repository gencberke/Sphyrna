import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore

// The fix round after the strict reviews of V17 (composer) and V18 (pinned cards), driver side: each test fails without the
// fix it names.

private func pending(_ tool: String, _ input: JSONValue, suggestions: [JSONValue] = []) -> ChatPendingRequest {
    var fields: [String: JSONValue] = [
        "subtype": "can_use_tool", "tool_name": .string(tool), "input": input, "tool_use_id": "toolu_1",
    ]
    if !suggestions.isEmpty { fields["permission_suggestions"] = .array(suggestions) }
    return ChatPendingRequest(requestID: "req-1", request: ToolPermissionRequest(json: .object(fields))!,
                              arrivedAt: Date(timeIntervalSince1970: 0), agent: nil)
}

private let aSuggestion: JSONValue = [
    "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]], "behavior": "allow", "destination": "localSettings",
]

/// A latch a test opens to let a parked task go on.
private actor StopGate {
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

private func waiting(_ driver: ChatSessionDriver, _ count: Int = 1) async -> Bool {
    await waitUntil {
        let snapshot = await driver.snapshot()
        return snapshot.requests.count == count && snapshot.phase == .needsYou
    }
}

private func records(_ snapshot: ChatDriverSnapshot) -> [String] {
    snapshot.model.entries.compactMap { if case let .request(record) = $0.body { record.summary } else { nil } }
}

struct ChatRequestRuleTests {
    /// Fix 3 (V18): which commands write to a file. Quoted `>` and here-document bodies are not parsed; they count as a
    /// redirect (a missing button is the cost, never a wrong answer).
    @Test func theRedirectCheckKnowsDevNullAndDescriptorsFromFiles() {
        let toFile = [
            "echo hi > out.txt", "echo hi >out.txt", "make 2>> log.txt", "make 2> err.txt", "make &> all.txt", "make >| out.txt",
            "make >&out.txt", "make >& out.txt", "make > /tmp/x 2>&1", "echo 'a > b'", "cat <<EOF\nx > y\nEOF",
        ]
        let notToFile = [
            "make", "make 2>&1 | tail", "make >&2", "make >&-", "make >/dev/null", "make > /dev/null", "make 2>/dev/null",
            "make &>/dev/null", "make >>/dev/null", "make >/dev/null 2>&1", "git status | head",
        ]
        for command in toFile {
            #expect(ChatPendingRequest.writesToFile(command), "\(command) writes to a file")
            #expect(pending("Bash", ["command": .string(command)], suggestions: [aSuggestion]).redirectsOutput)
            #expect(!pending("Bash", ["command": .string(command)], suggestions: [aSuggestion]).canAllowForSession)
        }
        for command in notToFile {
            #expect(!ChatPendingRequest.writesToFile(command), "\(command) writes to no file")
            #expect(pending("Bash", ["command": .string(command)], suggestions: [aSuggestion]).canAllowForSession)
        }
    }

    /// Fix 13 (V18): with no suggestion the button names its scope.
    @Test func theSessionButtonNamesTheWholeToolWhenTheCliOfferedNoRule() {
        let bare = pending("WebFetch", ["url": "https://example.com"])
        #expect(bare.sessionButtonTitle == "Allow all WebFetch this session")
        let suggested = pending("WebFetch", ["url": "https://example.com"], suggestions: [aSuggestion])
        #expect(suggested.sessionButtonTitle == "Allow for this session")
    }

    /// Fix 9 (V18): a settled request keeps what its line needs, never the whole input (a Write's content, a long command).
    @Test func aSettledRequestKeepsNoInput() {
        let big = String(repeating: "x", count: 1_000_000)
        let request = pending("Write", ["file_path": "/tmp/a.txt", "content": .string(big)])
        let settled = ChatSettledRequest(request: request, outcome: .answered, summary: "Allowed once: /tmp/a.txt", settledAt: Date())
        let fields = Set(Mirror(reflecting: settled).children.compactMap(\.label))
        #expect(fields == ["id", "kind", "recordKind", "toolName", "subject", "outcome", "summary", "settledAt"])
        #expect(settled.subject == "/tmp/a.txt")
        #expect(settled.summary == "Allowed once: /tmp/a.txt")
    }

    /// Fix 11 (V18): the mode a `setMode` suggestion grants is the plan answer's mode.
    @Test func allowingForTheSessionThroughASetModeSuggestionIsRecordedLikeAPlansMode() throws {
        let mode: JSONValue = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        let edit = pending("Edit", ["file_path": "/tmp/a.swift", "old_string": "a", "new_string": "b"], suggestions: [mode])
        #expect(try edit.answerPlan(for: .allowForSession).mode == "acceptEdits")
        #expect(try edit.answerPlan(for: .allowOnce).mode == nil)
        let web = pending("WebFetch", ["url": "https://example.com"], suggestions: [aSuggestion])
        #expect(try web.answerPlan(for: .allowForSession).mode == nil)
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(4)))
struct ChatFixRoundDriverTests {
    /// Fix 1 (V18): Deny and stop ends the turn like an interrupt: nothing queued goes out behind it. (What the CLI held
    /// unread comes back through the same interrupt as ever; whether the CLI still holds it depends on its timing.)
    @Test func denyAndStopPausesTheQueueAndSendsNothingBehindIt() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let later = try await driver.send("after the turn", timing: .afterTurn)
        guard case .queued = later else { Issue.record("not queued"); return }
        let request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .denyAndStop(note: nil))
        #expect(await idle(driver))
        // The interrupted turn's `result` must not release the queue.
        try await Task.sleep(for: .milliseconds(500))
        let snapshot = await driver.snapshot()
        #expect(snapshot.queue.paused == .interrupted)
        #expect(snapshot.queue.items.map(\.text) == ["after the turn"])
        #expect(!snapshot.texts.contains("Fake answer to: after the turn"))
        await rig.finish()
    }

    /// Fix 2 (V18): no answers while the session stops. The Stop's `leave` hook is held open, so the session stays in
    /// `stopping` for as long as the test needs: the interrupt, the CLI's withdrawal of the request and the process exit
    /// are real, but nothing here races the length of the grace or a poll.
    @Test func nothingIsAnsweredWhileTheSessionStops() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let request = try #require(await driver.snapshot().requests.first)
        let held = StopGate()
        let runID = try #require(await rig.supervisor.session(id: id)?.currentRun?.id)
        try await rig.supervisor.registerStopHooks(runID: runID, hooks: ManagedRunStopHooks(
            prepare: {}, completed: {},
            leave: { leaving in
                await driver.leave(leaving)
                await held.wait()
            },
            moved: { card in await driver.followMove(to: card) }
        ))
        let stopping = Task { try await driver.stop() }
        // The phase is `stopping` from the moment the Stop begins and stays so until the gate opens.
        #expect(await waitUntil { await driver.currentPhase == .stopping })
        var refused = 0
        for answer in [ChatRequestAnswer.allowOnce, .allowForSession, .deny(note: nil)] {
            do { try await driver.answer(requestID: request.requestID, answer) } catch ChatDriverError.stopping { refused += 1 } catch {}
        }
        #expect(refused == 3, "a request answered during the Stop must be refused with `stopping`")
        #expect(await driver.currentPhase == .stopping)
        await held.open()
        _ = try await stopping.value
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        let snapshot = await driver.snapshot()
        #expect(!records(snapshot).contains { $0.hasPrefix("Allowed") }, "\(records(snapshot))")
        let state = try #require(await rig.events.snapshot().sessions[id])
        #expect(state.pendingRequests.isEmpty)
        await rig.finish()
    }

    /// Fix 5 (V18): Esc never ends a turn a card holds; the Interrupt button does.
    @Test func escapeDoesNothingWhileARequestWaitsAndInterruptsOtherwise() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        await driver.interruptFromEscape()
        try await Task.sleep(for: .milliseconds(400))
        let held = await driver.snapshot()
        #expect(held.requests.count == 1 && held.phase == .needsYou && !held.youStopped)
        // The explicit button still stops the turn and withdraws the card.
        await driver.interrupt()
        #expect(await idle(driver))
        #expect(await driver.snapshot().youStopped)
        // With no card, Esc interrupts a working turn.
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        await driver.interruptFromEscape()
        #expect(await idle(driver))
        #expect(await driver.snapshot().model.turns.last?.status == .interrupted)
        await rig.finish()
    }

    /// Fix 7 (V18): one answer per request; a second call never undoes the first, and the CLI's cancel wins over a late
    /// "Allowed once".
    @Test func oneAnswerPerRequestAndACancelDuringTheAnswerLeavesNoAllowedLine() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let request = try #require(await driver.snapshot().requests.first)
        async let first: Void = driver.answer(requestID: request.requestID, .denyAndStop(note: nil))
        async let second: Void = driver.answer(requestID: request.requestID, .allowOnce)
        var failures: [Error] = []
        do { try await first } catch { failures.append(error) }
        do { try await second } catch { failures.append(error) }
        #expect(failures.count == 1, "exactly one of two answers to one request goes through: \(failures)")
        if let error = failures.first as? ChatDriverError {
            #expect(error == .answerInProgress || error == .noSuchRequest(request.requestID))
        }
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(records(snapshot).count == 1, "\(records(snapshot))")
        await rig.finish()
    }

    /// Fix 12 (V18) and the destination gap: an "Allow for this session" the CLI suggested for `localSettings` goes out as
    /// `session`, the stream says so, and a `setMode` suggestion sets the session's mode.
    @Test func allowForTheSessionRewritesTheDestinationAndASetModeIsTheSessionsChoice() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval web")
        #expect(await waiting(driver))
        let web = try #require(await driver.snapshot().requests.first)
        #expect(web.request.permissionSuggestions.first?.destination == "localSettings", "the fake offers localSettings")
        try await driver.answer(requestID: web.requestID, .allowForSession)
        #expect(await idle(driver))
        let granted = try #require(await driver.snapshot().texts.last)
        #expect(granted.contains("\"destination\":\"session\""), "\(granted)")
        #expect(!granted.contains("localSettings"), "\(granted)")

        try await driver.send("/scenario approval edit")
        #expect(await waiting(driver))
        let edit = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: edit.requestID, .allowForSession)
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(snapshot.permissionMode == "acceptEdits")
        #expect(snapshot.choices.permissionMode == "acceptEdits", "a mode granted for the session is the session's choice")
        await rig.finish()
    }

    // MARK: V17

    /// Fix 1 (V17): a message Claude never read goes to the draft file when the run ends, even with no composer.
    @Test func messagesClaudeNeverReadAreWrittenToTheDraftFileWhenTheProcessEnds() async throws {
        let rig = try await Rig.make()
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("drafts", isDirectory: true))
        let id = UUID()
        let driver = rig.driver(id, drafts: drafts)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let held = try await driver.send("never read", attachments: [.pastedText("pasted body")])
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        let pid = try #require(await driver.snapshot().processID)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await waitUntil { await driver.currentPhase == .failed(.ended) })
        #expect(await driver.snapshot().delivery(held.id) == .notDelivered)
        let draft = try #require(try drafts.load(sessionID: id))
        #expect(draft.text.contains("never read"), "\(draft.text)")
        #expect(draft.attachments.count == 1)
        #expect(await driver.liveState().undelivered.count == 1)
        // A composer made later finds the draft; the driver's own copy is marked as persisted so it is not taken twice.
        #expect(await driver.takeReturnedDrafts().allSatisfy { $0.persistedAt != nil })
        await rig.finish()
    }

    /// Fix 1 (V17), Quit: the draft is written before the terminate reply, from the leave hook's interrupt.
    @Test func aQuitWithAnUnreadMessageLeavesItInTheDraftFile() async throws {
        let rig = try await Rig.make()
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("drafts", isDirectory: true))
        let id = UUID()
        let driver = rig.driver(id, drafts: drafts)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let held = try await driver.send("typed before quitting")
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        let report = await rig.runtime.shutdown()
        #expect(report.succeeded)
        #expect(try drafts.load(sessionID: id)?.text.contains("typed before quitting") == true)
        RunScopeLauncher.removeOwnedBundle(in: rig.root)
        try? FileManager.default.removeItem(at: rig.socketDirectory)
        try? FileManager.default.removeItem(at: rig.root)
    }

    /// Fix 4 (V17): the model chip shows the model the user chose, also before the next `system/init`.
    @Test func theModelChipShowsTheChosenModelAfterALiveChange() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        let state = await driver.composerState()
        let option = try #require(state.models.last, "the fake lists models in its initialize answer")
        #expect(state.resolvedModel != option.resolvedModel)
        try await driver.setModel(option.value)
        let after = await driver.composerState()
        // Before the next `system/init`, the chip has the chosen model's own name (never the old one, never nothing).
        #expect(after.resolvedModel == (option.resolvedModel ?? option.value), "\(String(describing: after.resolvedModel))")
        await rig.finish()
    }

    /// Test gap (V17): `retry(messageID:)` sends the text again, marks the old row, and keeps it out of `undelivered`.
    @Test func retryingAnUndeliveredMessageSendsItAgainAndMarksTheOldRow() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let held = try await driver.send("please retry me")
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        let pid = try #require(await driver.snapshot().processID)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await waitUntil { await driver.currentPhase == .failed(.ended) })
        #expect(await driver.liveState().undelivered == ["please retry me"])
        #expect(await waitUntil { await rig.supervisor.session(id: id)?.currentRun == nil })
        let again = try await driver.retry(messageID: held.id)
        #expect(again != held.id)
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(snapshot.texts.last == "Fake answer to: please retry me")
        #expect(await driver.liveState().undelivered.isEmpty)
        if case let .user(prompt)? = snapshot.model.entry(id: held.id)?.body { #expect(prompt.followUp == .sentAgain) }
        await rig.finish()
    }

    /// Fix 8 and 11 (V17): the "Waiting for the current step" mark exists only for a message sent while a turn ran, and ↑
    /// recalls only what was typed, not the pasted chips.
    @Test func aMessageRemembersWhetherATurnWasRunningAndWhatWasTyped() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        let idleSend = try await driver.send("typed while idle", attachments: [.pastedText("PASTED BODY")])
        #expect(await idle(driver))
        try await driver.send("/scenario work 4000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let busySend = try await driver.send("typed while working")
        #expect(await idle(driver, 20))
        let snapshot = await driver.snapshot()
        func prompt(_ id: String) -> UserPrompt? {
            if case let .user(prompt)? = snapshot.model.entry(id: id)?.body { prompt } else { nil }
        }
        #expect(prompt(idleSend.id)?.sentWhileWorking == false)
        #expect(prompt(busySend.id)?.sentWhileWorking == true)
        #expect(prompt(idleSend.id)?.recallText == "typed while idle")
        #expect(prompt(idleSend.id)?.text.contains("PASTED BODY") == true, "the row still shows the chip's text")
        await rig.finish()
    }

    /// D-62: every Chat spawn carries `--allow-dangerously-skip-permissions`, so a live switch to Full access works (the fake
    /// refuses it without the flag, as the CLI does), and back; the catalog records both.
    @Test func aLiveSwitchToFullAccessAndBackWorksAndTheCatalogRecordsIt() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.setPermissionMode("bypassPermissions")
        #expect(await driver.snapshot().permissionMode == "bypassPermissions")
        #expect(try await rig.catalog.launchChoices(sessionID: id).permissionMode == "bypassPermissions")
        try await driver.setPermissionMode("default")
        #expect(await driver.snapshot().permissionMode == "default")
        #expect(try await rig.catalog.launchChoices(sessionID: id).permissionMode == "default")
        // The mode survives a spawn: Full access picked, the next spawn starts in it (and still carries the flag).
        try await driver.setPermissionMode("bypassPermissions")
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        try await driver.resume()
        try await driver.setPermissionMode("plan")
        try await driver.setPermissionMode("bypassPermissions")
        #expect(await driver.snapshot().permissionMode == "bypassPermissions", "a resumed child takes the live switch too")
        await rig.finish()
    }
}
