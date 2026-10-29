import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// V24: the Ask mode (D-63, spikes S9 and S9b) on the fake provider's mirror of the CLI's rules, and the follow-ups of the
// checkpoint review that live in the driver. Ask is the CLI's `dontAsk` plus deny rules for the edit tools plus an output style,
// all set by control requests; the fake keeps the launch layer and the live layer apart, the way the CLI does. Nothing here
// talks to a real Claude.

// MARK: Pure parts

struct ChatAskModePureTests {
    private func row(_ behavior: String, _ source: String, _ rule: String) -> PermissionRuleRow {
        PermissionRuleRow(behavior: behavior, source: source, rule: rule)
    }

    @Test func theDenyListHoldsTheEditToolsAndMirrorsEveryNonReadingAllowRuleOfTheUser() {
        #expect(ChatAskMode.denyList(mirroring: []) == ["Write", "Edit", "NotebookEdit"])
        let rules = [
            row("allow", "userSettings", "Bash(touch:*)"),
            row("allow", "projectSettings", "mcp__docs__search"),
            row("allow", "localSettings", "Read"),
            row("allow", "userSettings", "WebFetch(domain:example.com)"),
            row("allow", "userSettings", "Agent"),
            // Loom's own layer is not mirrored (it is replaced as a whole), nor is a deny or an ask rule.
            row("allow", "flagSettings", "WebFetch"),
            row("deny", "userSettings", "Bash(rm:*)"),
            row("ask", "userSettings", "Bash(git push:*)"),
            // Twice in two files: once in the list.
            row("allow", "projectSettings", "Bash(touch:*)"),
        ]
        #expect(ChatAskMode.denyList(mirroring: rules) == ["Write", "Edit", "NotebookEdit", "Bash(touch:*)", "mcp__docs__search"])
    }

    @Test func theLayerIsOneCompleteObjectThatNeverHoldsTheOneWayDoor() {
        let enter = ChatAskMode.enterSettings(mirroring: [row("allow", "userSettings", "Bash")])
        let permissions = enter.values["permissions"]
        #expect(permissions?["allow"]?.array?.compactMap(\.string) == ["WebFetch", "WebSearch"])
        #expect(permissions?["deny"]?.array?.compactMap(\.string) == ["Write", "Edit", "NotebookEdit", "Bash"])
        #expect(permissions?["disableBypassPermissionsMode"] == nil, "Full access would be gone for the whole process")
        #expect(enter.values["outputStyle"]?.string == ClaudeLoomPlugin.askStyleName)
        // Leaving sends both lists empty (the object is replaced as a whole) and removes the style with null.
        let leave = ChatAskMode.leaveSettings
        #expect(leave.values["permissions"]?["allow"]?.array?.isEmpty == true && leave.values["permissions"]?["deny"]?.array?.isEmpty == true)
        #expect(leave.values["outputStyle"] == .null)
        #expect(leave.values["permissions"]?["disableBypassPermissionsMode"] == nil)
    }

    @Test func aRefusalIsTheModesTextOrARuleTextWhileAskIsOn() {
        #expect(ChatAskMode.isRefusal(text: "Permission to use Write has been denied because Claude Code is running in don't ask mode.", askIsOn: false))
        #expect(ChatAskMode.isRefusal(text: "Permission to use Write has been denied.", askIsOn: true))
        #expect(!ChatAskMode.isRefusal(text: "Permission to use Write has been denied.", askIsOn: false), "a denial outside Ask stays a denial")
        #expect(!ChatAskMode.isRefusal(text: "File not found", askIsOn: true))
    }

    @Test func theCliTakesAskAsDontAskAndKeepsEveryOtherWord() {
        #expect(ChatAskMode.mode.rawValue == "dontAsk" && ClaudePermissionMode.ask.cliValue == "dontAsk")
        #expect(ClaudePermissionMode.allCases.filter { $0 != .ask }.allSatisfy { $0.cliValue == $0.rawValue })
    }
}

// MARK: On the fake provider

private let userRules = """
[{"behavior":"allow","source":"userSettings","rule":"Bash(touch:*)"},
 {"behavior":"allow","source":"projectSettings","rule":"Read"},
 {"behavior":"allow","source":"localSettings","rule":"WebFetch(domain:example.com)"}]
"""

private func tools(_ snapshot: ChatDriverSnapshot) -> [ToolCall] {
    snapshot.model.entries.compactMap { if case let .tool(call) = $0.body { call } else { nil } }
}

private func exists(_ name: String, in rig: Rig) -> Bool {
    FileManager.default.fileExists(atPath: rig.home.appendingPathComponent(name).path)
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(5)))
struct ChatAskModeDriverTests {
    private func ask() -> NewSessionLaunch {
        NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "ask"))
    }

    /// The acceptance test of D-63: Ask changes nothing and asks nothing; leaving it makes the same edit work; neither switch
    /// restarts the process.
    @Test func askLeavesTheFolderAloneAndAsksNothingAndLeavingItMakesTheSameEditWork() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        let pid = try #require(await driver.snapshot().processID)

        try await driver.setPermissionMode("ask")
        let entered = await driver.snapshot()
        #expect(entered.choices.permissionMode == "ask" && entered.permissionMode == "dontAsk")
        #expect(await driver.liveState().isAsk)
        try await driver.send("/scenario file edited.txt first")
        #expect(await idle(driver))
        var snapshot = await driver.snapshot()
        #expect(!exists("edited.txt", in: rig), "Ask leaves the folder as it was")
        #expect(snapshot.requests.isEmpty && snapshot.settled.isEmpty, "Ask sends no request to the host")
        #expect(tools(snapshot).map(\.status) == [.refusedInAsk], "\(tools(snapshot).map(\.status))")
        #expect(snapshot.texts.last?.contains("Ask mode is read-only") == true, "the style is on: \(snapshot.texts)")
        #expect(snapshot.processID == pid, "turning Ask on does not restart the process")

        // Leaving through the picker clears the rules and the style: the same edit works.
        try await driver.setPermissionMode("acceptEdits")
        let left = await driver.snapshot()
        let stillAsk = await driver.liveState().isAsk
        #expect(left.permissionMode == "acceptEdits" && !stillAsk)
        try await driver.send("/scenario file edited.txt second")
        #expect(await idle(driver))
        snapshot = await driver.snapshot()
        #expect(try String(contentsOf: rig.home.appendingPathComponent("edited.txt"), encoding: .utf8) == "second")
        #expect(snapshot.requests.isEmpty)
        #expect(tools(snapshot).map(\.status) == [.refusedInAsk, .succeeded])
        #expect(snapshot.texts.last == "Done: wrote edited.txt.")
        #expect(snapshot.processID == pid, "turning Ask off does not restart the process")
        await rig.finish()
    }

    /// Without the style the model would say what it says in any mode: leaving Ask removes it (null), and the CLI's mode is the
    /// target's, never `dontAsk`.
    @Test func leavingAskForAskBeforeEditsBringsBackTheRequestsAndTheDefaultStyle() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.setPermissionMode("ask")
        try await driver.setPermissionMode("default")
        let left = await driver.snapshot()
        #expect(left.permissionMode == "default" && left.choices.permissionMode == "default")
        try await driver.send("/scenario file asked.txt body")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        let request = try #require(await driver.snapshot().requests.first)
        #expect(request.request.toolName == "Write")
        try await driver.answer(requestID: request.requestID, .deny(note: nil))
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(!exists("asked.txt", in: rig))
        #expect(snapshot.texts.last == "Nothing changed: wrote asked.txt was not allowed.", "the style is gone: \(snapshot.texts)")
        await rig.finish()
    }

    /// The user's own allow rules of Bash and MCP tools are mirrored into the deny list when Ask is entered: in `dontAsk` an
    /// allow rule of the user's runs the command (S9b), and a deny rule with the same text beats it. Research keeps working.
    @Test func aBashRuleOfTheUserIsRefusedInAskAndReadingToolsStayOpen() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_USER_RULES": userRules])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        // Control: outside Ask the user's rule runs `touch` without a request.
        try await driver.setPermissionMode("acceptEdits")
        try await driver.send("/scenario run touch before.txt")
        #expect(await idle(driver))
        #expect(exists("before.txt", in: rig), "the user's rule allows touch")
        #expect(await driver.snapshot().requests.isEmpty)

        try await driver.setPermissionMode("ask")
        try await driver.send("/scenario run touch inside.txt")
        #expect(await idle(driver))
        #expect(!exists("inside.txt", in: rig), "the allow rule of the user's did not open Bash in Ask")
        try await driver.send("/scenario run ls")
        #expect(await idle(driver))
        try await driver.send("/scenario web WebFetch")
        #expect(await idle(driver))
        try await driver.send("/scenario web WebSearch")
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        let ran = tools(snapshot).suffix(4).map { "\($0.name):\($0.status)" }
        #expect(ran == ["Bash:refusedInAsk", "Bash:succeeded", "WebFetch:succeeded", "WebSearch:succeeded"], "\(ran)")
        #expect(snapshot.requests.isEmpty && snapshot.settled.isEmpty)

        // Leaving Ask clears both lists: `touch` runs again by the user's rule.
        try await driver.setPermissionMode("acceptEdits")
        try await driver.send("/scenario run touch after.txt")
        #expect(await idle(driver))
        #expect(exists("after.txt", in: rig))
        await rig.finish()
    }

    /// Whatever writes or runs a program is refused in Ask, even when it looks read-only; plain reads run.
    @Test func askRefusesWhatWritesAndKeepsTheReadOnlyCommandsOfTheCli() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.setPermissionMode("ask")
        for command in ["mkdir made", "touch a.txt", "echo hi > b.txt", "ls && touch c.txt", "find . -delete"] {
            try await driver.send("/scenario run \(command)")
            let finished = await idle(driver)
            #expect(finished, Comment(rawValue: command))
        }
        for name in ["made", "a.txt", "b.txt", "c.txt"] { #expect(!exists(name, in: rig), Comment(rawValue: name)) }
        #expect(tools(await driver.snapshot()).allSatisfy { $0.status == .refusedInAsk })
        try await driver.send("/scenario run ls -la")
        #expect(await idle(driver))
        #expect(tools(await driver.snapshot()).last?.status == .succeeded)
        await rig.finish()
    }

    /// A session that is in Ask starts in it: the layer is applied after `initialize` and before the first message, so the first
    /// message already runs under it. A resume brings nothing back by itself (S9), so the driver applies it again.
    @Test func startingAndResumingInAskApplyTheLayerBeforeTheFirstMessage() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        let receipt = try await driver.startNew(
            projectID: nil, draft: NewSessionLaunch(firstMessage: "/scenario file first.txt hi",
                                                    choices: ClaudeLaunchChoices(permissionMode: "ask")))
        #expect(receipt != nil)
        #expect(await idle(driver))
        var snapshot = await driver.snapshot()
        #expect(!exists("first.txt", in: rig), "the first message ran under Ask")
        #expect(tools(snapshot).map(\.status) == [.refusedInAsk])
        #expect(snapshot.model.latestInit?.permissionMode == "dontAsk")
        #expect(snapshot.model.latestInit?.outputStyle == ClaudeLoomPlugin.askStyleName)
        #expect(snapshot.choices.permissionMode == "ask")

        // Stop, then a message resumes the session in a new process: still Ask.
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        try await driver.send("/scenario file again.txt hi")
        #expect(await idle(driver))
        snapshot = await driver.snapshot()
        #expect(!exists("again.txt", in: rig), "the resumed session is in Ask")
        #expect(tools(snapshot).last?.status == .refusedInAsk)
        #expect(snapshot.model.latestInit?.outputStyle == ClaudeLoomPlugin.askStyleName)
        await rig.finish()
    }

    /// Approving a plan in Ask keeps the session in Ask: any other mode would lift `dontAsk` and leave Bash open under the
    /// edit rules.
    @Test func approvingAPlanInAskStaysInAsk() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: ask())
        try await driver.send("/scenario plan")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        let request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .approvePlan(mode: "acceptEdits"))
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(snapshot.permissionMode == "dontAsk", "\(String(describing: snapshot.permissionMode))")
        #expect(snapshot.choices.permissionMode == "ask")
        #expect(await driver.liveState().isAsk)
        try await driver.send("/scenario file planned.txt body")
        #expect(await idle(driver))
        #expect(!exists("planned.txt", in: rig))
        await rig.finish()
    }

    /// A turn the CLI starts by itself (a background agent that ends, S9b) runs under Ask like any other: the model goes on with
    /// the agent's report, tries to write it, and is refused.
    @Test func aTurnTheCliStartsItselfRunsUnderAsk() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: ask())
        try await driver.send("/scenario bg-agent 600")
        #expect(await waitUntil { await driver.snapshot().backgroundTaskCount == 1 })
        #expect(await idle(driver))
        // The agent ends and the CLI starts a turn by itself: the session is still in Ask.
        #expect(await waitUntil(20) { await driver.snapshot().texts.last?.contains("Ask mode is read-only") == true })
        #expect(await waitUntil(15) { await driver.snapshot().backgroundTaskCount == 0 })
        #expect(await driver.liveState().isAsk)
        #expect(!exists("agent-report.txt", in: rig))
        let write = tools(await driver.snapshot()).last { $0.name == "Write" }
        #expect(write?.status == .refusedInAsk)
        #expect(await driver.snapshot().requests.isEmpty)
        await rig.finish()
    }

    /// Leaving Ask goes back to the mode it replaced when Loom knows it, else to Ask before edits; Loom never picks Full access.
    @Test func leavingAskGoesBackToTheModeItReplacedElseAskBeforeEdits() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.setPermissionMode("acceptEdits")
        try await driver.setPermissionMode("ask")
        try await driver.leaveAsk()
        let back = await driver.snapshot()
        #expect(back.choices.permissionMode == "acceptEdits" && back.permissionMode == "acceptEdits")
        // A session that was started in Ask has nothing to go back to.
        let second = rig.driver()
        try await second.startNew(projectID: nil, draft: ask())
        try await second.leaveAsk()
        let fresh = await second.snapshot()
        #expect(fresh.choices.permissionMode == "default" && fresh.permissionMode == "default")
        await rig.finish()
    }
}

// MARK: Follow-ups of the checkpoint review

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(4)))
struct ChatV24FollowUpDriverTests {
    /// `sendQueuedNow` sent `now` into a waiting request. It refuses, and the queue keeps the item.
    @Test func sendQueuedNowRefusesWhileARequestWaitsAndKeepsTheItem() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        let queued = try await driver.send("after the card", timing: .afterTurn)
        guard case let .queued(itemID) = queued else { Issue.record("not queued"); return }
        await #expect(throws: ChatDriverError.requestWaiting) { try await driver.sendQueuedNow(id: itemID) }
        let snapshot = await driver.snapshot()
        #expect(snapshot.queue.items.map(\.text) == ["after the card"], "the item stays in the queue")
        #expect(snapshot.requests.count == 1 && snapshot.phase == .needsYou, "the request still waits, unanswered")
        // Answered, the turn ends and the queue goes out by itself, in order.
        try await driver.answer(requestID: snapshot.requests[0].requestID, .allowOnce)
        #expect(await waitUntil { await driver.snapshot().texts.last == "Fake answer to: after the card" })
        await rig.finish()
    }

    /// A message that came back as a draft and was then sent again (Retry) left a second copy in the composer and the draft
    /// file. It goes from both, and the composer that already took it is told to drop it.
    @Test func aRetriedMessageLeavesNoCopyInTheDraftFileOrTheReturnedDrafts() async throws {
        let rig = try await Rig.make()
        let drafts = ChatDraftStore(directory: rig.root.appendingPathComponent("drafts", isDirectory: true))
        let id = UUID()
        let driver = rig.driver(id, drafts: drafts)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let held = try await driver.send("please retry me")
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        let pid = try #require(await driver.snapshot().processID)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await waitUntil { await driver.currentPhase == .failed(.ended) })
        #expect(try drafts.load(sessionID: id)?.text.contains("please retry me") == true, "it came back as a draft")
        #expect(await waitUntil { await rig.supervisor.session(id: id)?.currentRun == nil })
        // A composer took it already (the first hand-over), then the user presses Retry.
        let taken = await driver.takeReturnedDrafts()
        #expect(taken.map(\.text) == ["please retry me"])
        _ = try await driver.retry(messageID: held.id)
        #expect(await idle(driver))
        #expect(try drafts.load(sessionID: id)?.text.contains("please retry me") != true, "the draft file no longer holds it")
        #expect(await driver.takeReturnedDrafts().isEmpty)
        #expect(await driver.takeWithdrawnDrafts().map(\.text) == ["please retry me"], "the composer is told to drop its copy")
        #expect(await driver.takeWithdrawnDrafts().isEmpty, "told once")
        await rig.finish()
    }

    /// A message the CLI has read keeps no payload in the driver; an unread one keeps it (Read now and Retry need it).
    @Test func aReadMessageDropsItsPayloadAndAnUnreadOneKeepsIt() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let held = try await driver.send("with a paste", attachments: [.pastedText(String(repeating: "pasted line\n", count: 200))])
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        #expect(await driver.heldPayloads.contains(held.id), "unread: the payload is kept")
        #expect(await idle(driver, 20))
        #expect(await driver.snapshot().delivery(held.id) == .read)
        #expect(await waitUntil { await driver.heldPayloads.isEmpty }, "read: the payload is dropped")
        await rig.finish()
    }

    /// A request that arrives while the session stops is not shown as a card: nothing is answered during the Stop. The fake
    /// ignores the interrupt and is slow, so the request comes after the Stop began.
    @Test func aRequestThatArrivesDuringStopIsNotShown() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_IGNORE_INTERRUPT": "1", "LOOM_FAKE_CHAT_DELAY_MS": "120"])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        // The turn runs (the fake streams its words slowly), so the Stop has a turn to interrupt, and the request comes after it.
        #expect(await waitUntil { await driver.snapshot().turnRunning })
        let stopping = Task { try await driver.stop() }
        #expect(await waitUntil { await driver.currentPhase == .stopping })
        var shown = false
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            // A listed request would also move the phase to `needsYou`, out of `stopping`.
            let now = await driver.snapshot()
            if !now.requests.isEmpty || now.phase == .needsYou { shown = true }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!shown, "no card appears while the session stops")
        _ = try await stopping.value
        #expect(await driver.snapshot().requests.isEmpty)
        await rig.finish()
    }
}
