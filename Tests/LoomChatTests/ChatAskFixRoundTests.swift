import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// V24 fix round (the strict review of 18 Oct): the mode chain, Ask's failure paths, the markers, the effort and the
// withdrawal of a retried message. Everything runs on the fake provider's mirror of the CLI's rules.

// MARK: Pure parts

struct ChatAskFixRoundPureTests {
    /// S6: a retried message is taken out of the draft only as a whole message, never as the start of the user's own words.
    @Test func aRetriedWordIsNotCutOutOfALongerOne() {
        #expect(ChatDraftText.removing("yes", from: "yesterday's build failed") == "yesterday's build failed")
        #expect(ChatDraftText.removing("yes", from: "I said yes") == "I said yes")
        #expect(ChatDraftText.removing("yes", from: "yesterday's build failed\n\nyes") == "yesterday's build failed")
        #expect(ChatDraftText.removing("yes", from: "yes\n\nyesterday's build failed") == "yesterday's build failed")
        // The first occurrence that is a message goes, not the first one that matches.
        #expect(ChatDraftText.removing("yes", from: "yesterday\n\nyes\n\nlater") == "yesterday\n\nlater")
        #expect(ChatDraftText.removing("yes", from: "yes") == "")
        #expect(ChatDraftText.removing("", from: "yes") == "yes")
    }

    /// M2: an effort a model does not offer is clamped to the nearest level below it (else the lowest), and a model without
    /// effort takes none.
    @Test func anEffortTheModelLacksIsClampedOrDropped() {
        let sonnet = ["low", "medium", "high"]
        #expect(ChatEffort.clamped("max", to: sonnet) == "high")
        #expect(ChatEffort.clamped("xhigh", to: sonnet) == "high")
        #expect(ChatEffort.clamped("medium", to: sonnet) == "medium")
        #expect(ChatEffort.clamped("low", to: ["medium", "high"]) == "medium")
        #expect(ChatEffort.clamped("high", to: []) == nil)
        #expect(ChatEffort.clamped("max", to: ["low", "medium", "high", "xhigh", "max"]) == "max")
    }
}

// MARK: On the fake provider

private let userRules = """
[{"behavior":"allow","source":"userSettings","rule":"Bash(touch:*)"}]
"""

private func tools(_ snapshot: ChatDriverSnapshot) -> [ToolCall] {
    snapshot.model.entries.compactMap { if case let .tool(call) = $0.body { call } else { nil } }
}

private func exists(_ name: String, in rig: Rig) -> Bool {
    FileManager.default.fileExists(atPath: rig.home.appendingPathComponent(name).path)
}

private func ask() -> NewSessionLaunch {
    NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "ask"))
}

private func modeMarkers(_ snapshot: ChatDriverSnapshot) -> [String] {
    snapshot.markers.compactMap { if case let .modeChanged(mode) = $0 { mode } else { nil } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ChatAskFixRoundDriverTests {
    // MARK: S1, M5: a transition that fails halfway

    /// S1: the rules were taken off and the mode then failed: the rules go back on (a fresh mirror), the choice stays Ask, and
    /// the error says the session stays in Ask. The user's Bash rule is the proof: it runs unless Ask's mirror denies it.
    @Test func leavingAskThatFailsHalfwayPutsTheRulesBackAndStaysInAsk() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_FAIL_MODE": "acceptEdits", "LOOM_FAKE_CHAT_USER_RULES": userRules])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.setPermissionMode("ask")
        var thrown: ChatDriverError?
        do { try await driver.setPermissionMode("acceptEdits") } catch { thrown = error as? ChatDriverError }
        #expect(thrown == .modeNotChanged(staysInAsk: true), "\(String(describing: thrown))")
        let snapshot = await driver.snapshot()
        let stillAsk = await driver.liveState().isAsk
        #expect(snapshot.choices.permissionMode == "ask" && snapshot.permissionMode == "dontAsk" && stillAsk)
        try await driver.send("/scenario run touch kept.txt")
        #expect(await idle(driver))
        #expect(!exists("kept.txt", in: rig), "the user's allow rule runs `touch` when Ask's mirror is not on")
        #expect(tools(await driver.snapshot()).map(\.status) == [.refusedInAsk])
        await rig.finish()
    }

    /// M5: turning Ask on failed after the rules were set: the rules are taken off again before the mode is restored.
    @Test func aFailedAskEntryTakesTheRulesBackOff() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_FAIL_ASK_RULES": "1", "LOOM_FAKE_CHAT_USER_RULES": userRules])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.setPermissionMode("acceptEdits")
        await #expect(throws: (any Error).self) { try await driver.setPermissionMode("ask") }
        let snapshot = await driver.snapshot()
        #expect(snapshot.choices.permissionMode == "acceptEdits" && snapshot.permissionMode == "acceptEdits")
        try await driver.send("/scenario run touch left-behind.txt")
        #expect(await idle(driver))
        #expect(exists("left-behind.txt", in: rig), "no deny rule of a half-entered Ask is left behind")
        await rig.finish()
    }

    // MARK: S2, S4: requests and plan mode inside Ask

    /// S2: a tool approval that waits blocks Ask, and is not answered for the user; a question does not block.
    @Test func askIsRefusedWhileAToolApprovalWaitsButNotWhileAQuestionDoes() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        var thrown: ChatDriverError?
        do { try await driver.setPermissionMode("ask") } catch { thrown = error as? ChatDriverError }
        #expect(thrown == .requestWaiting)
        var snapshot = await driver.snapshot()
        #expect(snapshot.requests.count == 1 && snapshot.settled.isEmpty, "the waiting approval is neither denied nor answered")
        #expect(snapshot.choices.permissionMode != "ask" && snapshot.permissionMode == "default")
        let request = try #require(snapshot.requests.first)
        try await driver.answer(requestID: request.requestID, .allowOnce)
        #expect(await idle(driver))

        try await driver.send("/scenario question")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        try await driver.setPermissionMode("ask")
        snapshot = await driver.snapshot()
        #expect(snapshot.choices.permissionMode == "ask" && snapshot.requests.count == 1, "a question stays open")
        try await driver.answer(requestID: try #require(snapshot.requests.first).requestID, .denyAndStop(note: nil))
        await rig.finish()
    }

    /// S2's defence and S4: plan mode inside Ask takes the CLI out of `dontAsk`; an approval that arrives then is not
    /// allowed while Ask is on, and picking Ask puts `dontAsk` back.
    @Test func inPlanModeInsideAskNoApprovalIsAllowedAndPickingAskBringsDontAskBack() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: ask())
        try await driver.send("/scenario plan")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        try await driver.answer(requestID: try #require(await driver.snapshot().requests.first).requestID,
                                .keepPlanning(feedback: nil))
        #expect(await idle(driver))
        var snapshot = await driver.snapshot()
        let isAsk = await driver.liveState().isAsk
        #expect(snapshot.permissionMode == "plan" && snapshot.choices.permissionMode == "ask" && isAsk)

        // In plan mode the CLI asks about a command: the card can be denied, never allowed, while Ask is on.
        try await driver.send("/scenario run mkdir planned")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        let request = try #require(await driver.snapshot().requests.first)
        for answer in [ChatRequestAnswer.allowOnce, .allowForSession] {
            var refused: ChatDriverError?
            do { try await driver.answer(requestID: request.requestID, answer) } catch { refused = error as? ChatDriverError }
            #expect(refused == .notOffered, "\(answer)")
        }
        #expect(await driver.snapshot().requests.count == 1)
        try await driver.answer(requestID: request.requestID, .deny(note: nil))
        #expect(await idle(driver))
        #expect(!exists("planned", in: rig))

        // S4: Ask is the choice but the CLI is not in `dontAsk`: picking Ask sends the mode again.
        try await driver.setPermissionMode("ask")
        snapshot = await driver.snapshot()
        #expect(snapshot.permissionMode == "dontAsk", "\(String(describing: snapshot.permissionMode))")
        await rig.finish()
    }

    // MARK: S3: one chain

    /// S3: a pick made while an Ask session resumes waits for the start and for Ask's layer, then runs: the session ends in the
    /// mode picked, with no rule of Ask left on (the user's Bash rule runs again).
    @Test func aPickDuringTheStartOfAnAskResumeRunsAfterTheLayer() async throws {
        let rig = try await Rig.make(environment: [
            "LOOM_FAKE_CHAT_INIT_DELAY_MS": "700", "LOOM_FAKE_CHAT_CONTROL_DELAY_MS": "120", "LOOM_FAKE_CHAT_USER_RULES": userRules,
        ])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: ask())
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        let resuming = Task { try await driver.resume() }
        #expect(await waitUntil { await driver.currentPhase == .starting })
        try await driver.setPermissionMode("acceptEdits")
        try await resuming.value
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        let isAsk = await driver.liveState().isAsk
        #expect(snapshot.choices.permissionMode == "acceptEdits" && snapshot.permissionMode == "acceptEdits" && !isAsk)
        try await driver.send("/scenario run touch free.txt")
        #expect(await idle(driver))
        #expect(exists("free.txt", in: rig), "Ask's rules are off: the user's Bash rule runs")
        await rig.finish()
    }

    /// S3: two quick picks run one after the other: the session ends in the second, with Ask's rules off.
    @Test func twoQuickPicksEndInTheSecondModeWithNothingOfTheFirst() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_CONTROL_DELAY_MS": "120", "LOOM_FAKE_CHAT_USER_RULES": userRules])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        let first = Task { try await driver.setPermissionMode("ask") }
        try await Task.sleep(for: .milliseconds(60))
        try await driver.setPermissionMode("acceptEdits")
        try await first.value
        let snapshot = await driver.snapshot()
        let isAsk = await driver.liveState().isAsk
        #expect(snapshot.choices.permissionMode == "acceptEdits" && snapshot.permissionMode == "acceptEdits" && !isAsk)
        try await driver.send("/scenario run touch second.txt")
        #expect(await idle(driver))
        #expect(exists("second.txt", in: rig), "the first pick's rules did not outlive the second")
        await rig.finish()
    }

    // MARK: S5

    /// S5: a session without a process shows the mode chosen, not the last one the CLI reported.
    @Test func aStoppedSessionKeepsNoStaleCliMode() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        #expect(await driver.snapshot().permissionMode == "default")
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        #expect(await driver.snapshot().permissionMode == nil, "the process is gone, and its last word with it")
        try await driver.setPermissionMode("acceptEdits")
        let snapshot = await driver.snapshot()
        #expect(snapshot.permissionMode == nil && snapshot.choices.permissionMode == "acceptEdits")
        await rig.finish()
    }

    // MARK: M1: the markers

    /// M1: the mode marker sits where the change was made, before the turn it affects, and the next turn's init adds no second.
    @Test func aModeChangeIsMarkedBeforeTheNextTurnAndOnlyOnce() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("first")
        #expect(await idle(driver))
        try await driver.setPermissionMode("acceptEdits")
        let second = try await driver.send("second")
        #expect(await idle(driver))
        let entries = await driver.snapshot().model.entries
        let marker = entries.firstIndex { if case .marker(.modeChanged("acceptEdits")) = $0.body { true } else { false } }
        let secondID = try { () throws -> String in
            switch second { case let .sent(id), let .queued(id): return id }
        }()
        let message = entries.firstIndex { $0.id == secondID }
        #expect(marker != nil && message != nil && marker! < message!, "marker \(String(describing: marker)), message \(String(describing: message))")
        let marked = modeMarkers(await driver.snapshot())
        #expect(marked == ["acceptEdits"], Comment(rawValue: "\(marked)"))
        await rig.finish()
    }

    /// Entering Ask while background work runs is allowed, and the marker says the work goes on; the work's own turn, which the
    /// CLI starts later, runs under Ask (S9b).
    @Test func askEnteredWithBackgroundWorkSaysSoAndTheAgentsTurnRunsUnderAsk() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario bg-agent 2500")
        #expect(await waitUntil { await driver.snapshot().backgroundTaskCount == 1 })
        #expect(await idle(driver))
        try await driver.setPermissionMode("ask")
        let snapshot = await driver.snapshot()
        #expect(snapshot.markers.contains(.notice("Mode changed to Ask. Background work started earlier keeps running.")),
                "\(snapshot.markers)")
        #expect(modeMarkers(snapshot).isEmpty, "one marker, not two")
        // The agent ends and the CLI starts a turn by itself; the model tries to write the report, under Ask.
        #expect(await waitUntil(20) { await driver.snapshot().texts.last?.contains("Ask mode is read-only") == true })
        #expect(!exists("agent-report.txt", in: rig))
        let write = tools(await driver.snapshot()).last { $0.name == "Write" }
        #expect(write?.status == .refusedInAsk)
        await rig.finish()
    }

    // MARK: M2

    /// M2: a model change clamps or clears an effort the new model does not offer, live and in the catalog.
    @Test func changingTheModelClampsOrClearsAnEffortItDoesNotOffer() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(
            firstMessage: "", choices: ClaudeLaunchChoices(model: "opus", effort: "max")))
        func recorded() async throws -> String? { try await rig.catalog.launchChoices(sessionID: id).effort }

        try await driver.setModel("sonnet")
        #expect(await driver.snapshot().choices.effort == "high")
        #expect(try await recorded() == "high", "the next spawn passes the clamped level")
        try await driver.send("one")
        #expect(await idle(driver))
        #expect(await driver.snapshot().model.latestInit?.effort == "high", "the live process was told too")

        try await driver.setModel("haiku")
        #expect(await driver.snapshot().choices.effort == nil)
        #expect(try await recorded() == nil, "a model without effort gets no --effort")
        try await driver.send("two")
        #expect(await idle(driver))
        #expect(await driver.snapshot().model.latestInit?.effort == nil)

        // Nothing to clamp: the model keeps no effort the user did not choose.
        try await driver.setModel("opus")
        #expect(await driver.snapshot().choices.effort == nil)
        await rig.finish()
    }

    // MARK: M4: the fake is as strict as the CLI

    /// M4: the old scenarios' tool steps meet Ask's rules too: a read-only call runs, an edit, a write and a build step do not.
    @Test func theOlderScenariosMeetTheAskRules() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: ask())
        for scenario in ["bash", "edit", "write", "work 300", "read"] {
            try await driver.send("/scenario \(scenario)")
            let finished = await idle(driver)
            #expect(finished, Comment(rawValue: scenario))
        }
        let statuses = tools(await driver.snapshot()).map { "\($0.name):\($0.status)" }
        #expect(statuses == ["Bash:succeeded", "Edit:refusedInAsk", "Write:refusedInAsk", "Bash:refusedInAsk", "Bash:refusedInAsk",
                             "Bash:refusedInAsk", "Read:succeeded"], "\(statuses)")
        await rig.finish()
    }

    /// M4 and the missing plugin: the fake refuses a style no plugin provides, as the CLI does, so a session that is in Ask
    /// without Loom's plugin does not run unprotected: it does not start.
    @Test func anAskSessionWithoutThePluginDoesNotStart() async throws {
        let rig = try await Rig.make(plugin: false)
        let id = UUID()
        let driver = rig.driver(id)
        await #expect(throws: ChatDriverError.couldNotStart("ask")) { try await driver.startNew(projectID: nil, draft: ask()) }
        #expect(await rig.issue(id) == "Ask mode could not be turned on.")
        await rig.finish()
    }

    /// The missing plugin: entering Ask is refused with a clear error, and the session keeps its mode and its choice.
    @Test func withoutThePluginAskIsRefusedAndTheSessionKeepsItsMode() async throws {
        let rig = try await Rig.make(plugin: false)
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        var thrown: ChatDriverError?
        do { try await driver.setPermissionMode("ask") } catch { thrown = error as? ChatDriverError }
        #expect(thrown == .askUnavailable)
        let snapshot = await driver.snapshot()
        #expect(snapshot.permissionMode == "default" && snapshot.choices.permissionMode != "ask")
        await rig.finish()
    }

    // MARK: /clear

    /// After `/clear` (a `conversation_reset`) Ask's layer goes on again: the CLI may have dropped the live settings.
    @Test func askStaysOnAfterAClear() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_RESET_FORGETS_SETTINGS": "1", "LOOM_FAKE_CHAT_USER_RULES": userRules])
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil, draft: ask())
        try await driver.send("/clear")
        #expect(await waitUntil { await driver.snapshot().sessionID != id })
        try await Task.sleep(for: .milliseconds(500))
        try await driver.send("/scenario run touch cleared.txt")
        #expect(await idle(driver))
        #expect(!exists("cleared.txt", in: rig), "the user's allow rule is mirrored again after the reset")
        #expect(await driver.liveState().isAsk)
        await rig.finish()
    }
}
