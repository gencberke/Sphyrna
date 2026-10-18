import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore

// The seams between V19 (Chat first, the handover) and V24 (the chat bar, Ask), on the driver and the runtime with the fake
// provider: a mode, model or effort picked while a handover waits is the session's choice and never reaches a child that is
// going away; a handover to the terminal runs Ask in Ask before edits; and the mode chain and the handover hold do not lock
// each other.

private final class SeamScreen: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func receive(_ data: Data) { lock.withLock { buffer += String(decoding: data, as: UTF8.self) } }

    var text: String { lock.withLock { buffer } }
}

private let userRules = """
[{"behavior":"allow","source":"userSettings","rule":"Bash(touch:*)"}]
"""

private func modeMarkers(_ snapshot: ChatDriverSnapshot) -> [String] {
    snapshot.markers.compactMap { if case let .modeChanged(mode) = $0 { mode } else { nil } }
}

private func tools(_ snapshot: ChatDriverSnapshot) -> [ToolCall] {
    snapshot.model.entries.compactMap { if case let .tool(call) = $0.body { call } else { nil } }
}

/// Finishes `body` or reports a hang: a deadlock between the mode chain and the handover hold would never return.
private func finishes(_ seconds: Double = 15, _ body: @escaping @Sendable () async throws -> Void) async -> Bool {
    let done = SeamFlag()
    let task = Task { do { try await body() } catch {}; done.raise() }
    let finished = await waitUntil(seconds) { done.isRaised }
    if !finished { task.cancel() }
    return finished
}

private final class SeamFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ChatMergeSeamDriverTests {
    // MARK: Seam 2, a pick while a handover waits

    /// The child's mode change is refused by the fake for `acceptEdits`: a pick that reached it would throw. Held, it does not;
    /// it is the session's choice, no marker is placed, and the terminal's launch finds it in the catalog.
    @Test func aPickWhileAHandoverWaitsIsHeldAsTheChoiceAndNeverSentToTheChildThatIsGoingAway() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_FAIL_MODE": "acceptEdits"])
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })

        // All three picks come back at once (the chain and the hold do not lock each other), and none of them throws.
        let picked = await finishes {
            try await driver.setPermissionMode("acceptEdits")
            try await driver.setModel("opus")
            try await driver.setEffort("high")
        }
        #expect(picked, "a pick during a waiting handover returns")
        let during = await driver.snapshot()
        #expect(during.choices.permissionMode == "acceptEdits" && during.choices.model == "opus" && during.choices.effort == "high")
        #expect(modeMarkers(during).isEmpty, "the child was not told, so no marker says it changed")

        try await handover.value
        #expect(await driver.currentPhase == .stopped)
        let launch = try await rig.catalog.launchChoices(sessionID: id)
        #expect(launch.permissionMode == "acceptEdits" && launch.model == "opus" && launch.effort == "high",
                "the target face's launch applies it: \(launch)")
        await rig.finish()
    }

    /// A handover that ends with the run still here tells the child what was picked meanwhile, as any pick would.
    @Test func picksHeldDuringAHandoverReachTheChildWhenTheHandoverIsCancelled() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        try await driver.setPermissionMode("acceptEdits")
        try await driver.setModel("opus")
        try await driver.setEffort("xhigh")
        #expect(modeMarkers(await driver.snapshot()).isEmpty)

        await driver.cancelHandover()
        await #expect(throws: CancellationError.self) { try await handover.value }
        let after = await driver.snapshot()
        #expect(after.permissionMode == "acceptEdits" && after.choices.permissionMode == "acceptEdits")
        #expect(modeMarkers(after) == ["acceptEdits"], "one marker, once the child confirmed it: \(modeMarkers(after))")
        #expect(after.choices.model == "opus" && after.choices.effort == "xhigh")
        #expect(await idle(driver))
        _ = try await driver.send("carry on")
        #expect(await idle(driver))
        await rig.finish()
    }

    /// Ask picked while the handover waits, and the handover cancelled: Ask's rules and style are on the child afterwards, so a
    /// command the user's own rule allows is refused. The child's mode before the pick is where the transition starts.
    @Test func anAskPickedDuringAHandoverIsAskOnTheChildOnceTheHandoverIsCancelled() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_USER_RULES": userRules])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        try await driver.setPermissionMode("ask")
        #expect(await driver.liveState().isAsk)
        await driver.cancelHandover()
        await #expect(throws: CancellationError.self) { try await handover.value }
        let snapshot = await driver.snapshot()
        #expect(snapshot.permissionMode == "dontAsk" && snapshot.choices.permissionMode == "ask")
        #expect(await idle(driver))
        try await driver.send("/scenario run touch nope.txt")
        #expect(await idle(driver))
        #expect(!FileManager.default.fileExists(atPath: rig.home.appendingPathComponent("nope.txt").path))
        #expect(tools(await driver.snapshot()).last?.status == .refusedInAsk)
        await rig.finish()
    }

    /// A held pick that the child then refuses on replay leaves the choice at what the child matches, not at the pick.
    @Test func aHeldPickTheChildRefusesLeavesTheChoiceWhereTheChildIs() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_FAIL_MODE": "acceptEdits"])
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "default")))
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        try await driver.setPermissionMode("acceptEdits")
        await driver.cancelHandover()
        await #expect(throws: CancellationError.self) { try await handover.value }
        let snapshot = await driver.snapshot()
        #expect(snapshot.choices.permissionMode == "default" && snapshot.permissionMode == "default")
        #expect(try await rig.catalog.launchChoices(sessionID: id).permissionMode == "default")
        await rig.finish()
    }

    /// A pick that is already on its way when the handover begins is let finish before the run ends; one that comes after is held.
    @Test func aPickInFlightWhenTheHandoverBeginsFinishesAndNothingDeadlocks() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        let all = await finishes(30) {
            async let first: Void = driver.setPermissionMode("acceptEdits")
            async let second: Void = driver.handOverToTerminal()
            async let third: Void = driver.setModel("opus")
            _ = try await (first, second, third)
        }
        #expect(all, "the mode chain and the handover hold finish together")
        #expect(await driver.currentPhase == .stopped)
        let launch = try await rig.catalog.launchChoices(sessionID: id)
        #expect(launch.permissionMode == "acceptEdits" && launch.model == "opus", "\(launch)")
        await rig.finish()
    }

    // MARK: Seam 1, Ask and the terminal

    /// Continue in Terminal from an Ask session: the terminal runs Ask before edits (the catalog records what ran, the session says
    /// so), and Continue in Chat after it comes back in that mode; Ask returns only when the user picks it again.
    @Test func continuingAnAskSessionInTheTerminalRunsAskBeforeEditsAndChatComesBackInThatMode() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "ask")))
        try await driver.send("hello")
        #expect(await idle(driver))
        #expect(await driver.liveState().isAsk)

        try await driver.handOverToTerminal()
        #expect(try await rig.catalog.launchChoices(sessionID: id).permissionMode == "ask", "the Chat run ended in Ask")
        let screen = SeamScreen()
        _ = try await rig.runtime.resumeConversation(sessionID: id, outputSink: screen)
        #expect(await waitUntil { screen.text.contains("FAKE-CLAUDE READY") })
        #expect(try await rig.catalog.launchChoices(sessionID: id).permissionMode == "default", "what really ran")
        #expect(await waitUntil {
            await rig.events.snapshot().sessions[id]?.issue == "Ask works in Chat. This terminal session runs in Ask before edits."
        })

        _ = try await rig.runtime.stopConversation(sessionID: id)
        // The same driver resumes (as the host's `enterChat` does for the driver it keeps).
        try await driver.resume()
        let again = driver
        #expect(await again.currentPhase == .ready)
        let back = await again.snapshot()
        #expect(back.choices.permissionMode == "default" && back.permissionMode == "default")
        #expect(await again.liveState().isAsk == false)
        // The change was marked when the run came back (before any message of its own), under Loom's name.
        #expect(modeMarkers(back) == ["default"], "\(modeMarkers(back))")
        // Ask is the user's pick again.
        try await again.setPermissionMode("ask")
        #expect(await again.liveState().isAsk)
        await rig.finish()
    }

    // MARK: Seam 3, a mode marker sits before the turn it affects

    /// A mode picked on the stopped bar is the resume's: the marker is placed when the run comes up, before the message that
    /// starts its first turn, and the next turn's `system/init` makes no second one.
    @Test func aModePickedOnTheStoppedBarIsMarkedWhenTheRunResumesBeforeTheFirstMessage() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        try await driver.setPermissionMode("acceptEdits")
        #expect(modeMarkers(await driver.snapshot()).isEmpty, "nothing runs yet: nothing to mark")
        try await driver.resume()
        var snapshot = await driver.snapshot()
        #expect(modeMarkers(snapshot) == ["acceptEdits"], "\(modeMarkers(snapshot))")
        try await driver.send("after the resume")
        #expect(await idle(driver))
        snapshot = await driver.snapshot()
        #expect(modeMarkers(snapshot) == ["acceptEdits"], "one marker, not a second from the turn's init")
        let entries = snapshot.model.entries
        let marker = try #require(entries.firstIndex { if case .marker(.modeChanged) = $0.body { true } else { false } })
        let message = try #require(entries.firstIndex { if case let .user(prompt) = $0.body { prompt.text == "after the resume" } else { false } })
        #expect(marker < message, "the marker sits before the turn it affects")
        await rig.finish()
    }
}
