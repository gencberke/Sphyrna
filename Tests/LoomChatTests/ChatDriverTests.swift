import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCore

// The Chat driver (V16) on the fake provider, through the real runtime: a scoped supervisor (pipe children live in run
// scopes), the runtime's Chat-face start and resume, the fake's chat engine behind real pipes. Every transition of
// concept §5.6 plus delivery, the queue, requests, stop order, drift and face switches.

private final class DriverBundleAnchor: NSObject {}

private enum DriverFixture {
    static var binaries: URL { Bundle(for: DriverBundleAnchor.self).bundleURL.deletingLastPathComponent() }
}

/// What the driver's callbacks reported.
final class Reports: Sendable {
    let windows = Mutex<[String: Int]>([:])
    let choices = Mutex<[ClaudeLaunchChoices]>([])
}

struct Rig {
    let root: URL
    let home: URL
    let profile: URL
    let socketDirectory: URL
    let catalog: SessionCatalog
    let supervisor: ProcessSupervisor
    let runtime: SessionRuntime
    let reports = Reports()

    var events: SessionEventHub { supervisor.events }

    static func make(environment: [String: String] = [:], version: String = "fake 1") async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let profile = root.appendingPathComponent("claude-config", isDirectory: true)
        for directory in [home, profile] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/lc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        // Run hosts are their own TCC-responsible apps: a scoped child runs a copy from a temporary folder.
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("loom-fake-provider")
        try FileManager.default.copyItem(at: DriverFixture.binaries.appendingPathComponent("loom-fake-provider"), to: fake)
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: DriverFixture.binaries.appendingPathComponent("loom-run-host"), in: root
        )
        let supervisor = try await ProcessSupervisor.restoring(
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs"))
        )
        let fakePath = fake.path
        let resolver: ProviderToolchainResolver = { provider in
            ProviderToolchain(
                provider: provider, executable: fakePath,
                capabilities: ProviderCapabilities(
                    version: version,
                    help: "--settings <settings> --session-id <id> --effort <level> -n, --name <name> --plugin-dir <path> "
                        + "--permission-mode <mode> --model <model>",
                    serverHelp: "--listen <URL>"
                ),
                environment: ["PATH": "/usr/bin:/bin", "HOME": home.path].merging(environment) { _, new in new },
                profileDirectory: profile, extraArguments: []
            )
        }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: resolver,
                hookHelperPath: DriverFixture.binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path,
                idlePolicy: SessionIdlePolicy(), codexIdentityTimeout: 3,
                hookSilenceGrace: 3, catalogBackupDelay: nil
            )
        )
        try await runtime.start()
        return Rig(root: root, home: home, profile: profile, socketDirectory: socketDirectory, catalog: catalog,
                   supervisor: supervisor, runtime: runtime)
    }

    func driver(_ sessionID: UUID = UUID(), queue: ChatQueueStore? = nil, drafts: ChatDraftStore? = nil,
                readyTimeout: Duration = .seconds(20)) -> ChatSessionDriver {
        let reports = reports
        return ChatSessionDriver(
            sessionID: sessionID, runtime: runtime, queueStore: queue, draftStore: drafts, readyTimeout: readyTimeout,
            onChoicesChanged: { value in reports.choices.withLock { $0.append(value) } },
            onContextWindow: { model, window in reports.windows.withLock { $0[model] = window } }
        )
    }

    func status(_ sessionID: UUID) async -> AgentActivity? {
        await events.snapshot().sessions[sessionID]?.status?.activity
    }

    func issue(_ sessionID: UUID) async -> String? {
        await events.snapshot().sessions[sessionID]?.issue
    }

    func finish() async {
        let report = await runtime.shutdown()
        #expect(report.succeeded)
        RunScopeLauncher.removeOwnedBundle(in: root)
        try? FileManager.default.removeItem(at: socketDirectory)
        try? FileManager.default.removeItem(at: root)
    }
}

func waitUntil(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}

extension ChatDriverSnapshot {
    var texts: [String] {
        model.entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } }
    }

    func delivery(_ id: String) -> UserPrompt.Delivery? {
        guard case let .user(prompt) = model.entry(id: id)?.body else { return nil }
        return prompt.delivery
    }

    var markers: [Marker] {
        model.entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } }
    }

    var youStopped: Bool { markers.contains { if case .interrupted = $0 { true } else { false } } }

    var isIdle: Bool { phase == .ready && !turnRunning }
}

extension ChatSendReceipt {
    var id: String {
        switch self {
        case let .sent(id), let .queued(id): id
        }
    }
}

func idle(_ driver: ChatSessionDriver, _ seconds: Double = 10) async -> Bool {
    await waitUntil(seconds) { await driver.snapshot().isIdle }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct ChatDriverTests {
    // MARK: Starting, Ready, Working, Finished

    @Test func aNewSessionStartsIsReadyWorksAndFinishes() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        let starting = Task { try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: "", title: "Chat test")) }
        #expect(await waitUntil { await driver.currentPhase != .stopped })
        try await starting.value
        var snapshot = await driver.snapshot()
        // Ready is the `initialize` answer; its mode is the starting mode. No turn ran, so no `system/init` yet.
        #expect(snapshot.phase == .ready)
        #expect(snapshot.permissionMode == "default")
        #expect(snapshot.model.ready != nil)
        #expect(snapshot.model.latestInit == nil)
        #expect(await rig.status(id) == .atPrompt)

        let sent = try await driver.send("/scenario work 600")
        #expect(await waitUntil { await rig.status(id) == .working })
        #expect(await driver.currentPhase == .working)
        #expect(await idle(driver))
        snapshot = await driver.snapshot()
        #expect(snapshot.delivery(sent.id) == .read)
        #expect(snapshot.model.turns.last?.status == .succeeded)
        #expect(snapshot.texts.last == "All three steps finished.")
        #expect(await rig.status(id) == .turnComplete)
        // The session is bound to the conversation the CLI named.
        let bound = await rig.supervisor.session(id: id)?.providerConversationID
        // `--session-id` names the conversation after the Loom session.
        #expect(bound?.lowercased() == id.uuidString.lowercased(), "bound \(String(describing: bound))")
        await rig.finish()
    }

    // MARK: Needs you

    @Test func aRequestWaitsForTheUserInEveryModeAndIsNeverAnsweredByTheDriver() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        for mode in ["default", "acceptEdits", "bypassPermissions", "dontAsk"] {
            try await driver.setPermissionMode(mode)
            #expect(await driver.snapshot().permissionMode == mode)
            try await driver.send("/scenario approval")
            #expect(await waitUntil { await driver.currentPhase == .needsYou })
            #expect(await rig.status(id) == .waitingForApproval)
            // Home, the sidebar and the Dock see the request through the hub, provider-independent.
            let published = await rig.events.snapshot().sessions[id]?.pendingRequests
            #expect(published?.map(\.kind) == [.approval])
            #expect(published?.first?.toolName == "Bash")
            #expect(await rig.events.snapshot().sessions[id]?.runEndpoint == .pipe)
            try await Task.sleep(for: .milliseconds(300))
            let waiting = await driver.snapshot()
            #expect(waiting.requests.count == 1)
            #expect(waiting.requests.first?.kind == .approval)
            #expect(waiting.phase == .needsYou)
            let request = try #require(waiting.requests.first)
            try await driver.respond(to: request.requestID, with: .allow(updatedInput: request.request.input),
                                     record: RequestRecord(kind: .approval, summary: "Allowed once: rm -rf build"))
            #expect(await idle(driver))
            let done = await driver.snapshot()
            #expect(done.requests.isEmpty)
            #expect(done.texts.last == "The build folder is gone.")
            #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty == true)
        }
        // A question is answered with the user's answers in `updatedInput`.
        try await driver.send("/scenario question")
        #expect(await waitUntil { await driver.snapshot().requests.first?.kind == .question })
        let question = try #require(await driver.snapshot().requests.first)
        var input = question.request.input.object ?? [:]
        input["answers"] = ["Which database should the app use?": "SQLite", "Which extras do you want?": "Logging"]
        try await driver.respond(to: question.requestID, with: .allow(updatedInput: .object(input)))
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "You chose: SQLite; Logging")
        // The choices the user made live are recorded for the next spawn.
        #expect(await driver.snapshot().choices.permissionMode == "dontAsk")
        #expect(rig.reports.choices.withLock { $0.last?.permissionMode } == "dontAsk")
        #expect(try await rig.catalog.launchChoices(sessionID: id).permissionMode == "dontAsk")
        await rig.finish()
    }

    @Test func aPlanIsApprovedWithItsModeOrKeptPlanningWithFeedback() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario plan")
        #expect(await waitUntil { await driver.snapshot().requests.first?.kind == .plan })
        #expect(await driver.snapshot().permissionMode == "plan")
        var plan = try #require(await driver.snapshot().requests.first)
        try await driver.keepPlanning(requestID: plan.requestID, feedback: "Add a rollback step.")
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "Staying in plan mode.")
        #expect(await driver.snapshot().permissionMode == "plan")

        try await driver.send("/scenario plan")
        #expect(await waitUntil { await driver.snapshot().requests.first?.kind == .plan })
        plan = try #require(await driver.snapshot().requests.first)
        // The plan card got the plan from the request.
        try await driver.approvePlan(requestID: plan.requestID, mode: "acceptEdits")
        #expect(await idle(driver))
        let done = await driver.snapshot()
        #expect(done.texts.last == "Implementing the plan in acceptEdits mode.")
        #expect(done.permissionMode == "acceptEdits")
        #expect(done.choices.permissionMode == "acceptEdits")
        await rig.finish()
    }

    // MARK: Interrupt, Read now, delivery

    @Test func anInterruptReturnsUnreadMessagesPausesTheQueueAndIsNotAFailure() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        // `next` waits for the running tool: the CLI holds it, unread.
        let held = try await driver.send("held message")
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        let queued = try await driver.send("after the turn", timing: .afterTurn)
        guard case .queued = queued else { Issue.record("not queued"); return }
        await driver.interrupt()
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(snapshot.model.turns.last?.status == .interrupted)
        #expect(snapshot.youStopped)
        #expect(snapshot.delivery(held.id) == .cancelled)
        #expect(await driver.takeReturnedDrafts() == [ChatReturnedDraft(messageID: held.id, text: "held message")])
        #expect(snapshot.queue.paused == .interrupted)
        #expect(snapshot.queue.items.map(\.text) == ["after the turn"])
        // The interrupt's own result (error_during_execution, is_error) is not a failed turn.
        #expect(await rig.status(id) == .turnComplete)
        #expect(snapshot.drift.isEmpty)
        // Resume sends the queued item as the next turn.
        try await driver.resumeQueue()
        #expect(await waitUntil { await driver.snapshot().texts.last == "Fake answer to: after the turn" })
        #expect(await driver.snapshot().queue.isEmpty)
        await rig.finish()
    }

    /// Regression: a `now` send that cuts a streaming answer ends the turn with `aborted_streaming` on a success; it is
    /// not the user's stop and must never read "You stopped".
    @Test func aNowSendThatCutsAStreamIsNotYouStopped() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_DELAY_MS": "60"])
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario answer")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains {
            if case let .assistantText(text) = $0.body { text.isStreaming } else { false } } })
        let item = try await driver.enqueue("cut in")
        try await driver.sendQueuedNow(id: item)
        #expect(await waitUntil(15) { await driver.snapshot().texts.last == "Fake answer to: cut in" })
        #expect(await idle(driver))
        let snapshot = await driver.snapshot()
        #expect(!snapshot.youStopped)
        #expect(snapshot.model.turns.allSatisfy { $0.status == .succeeded })
        await rig.finish()
    }

    @Test func readNowTakesTheMessageBackAndSendsItNowInTheSameRow() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 4500")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let waiting = try await driver.send("look at this now")
        #expect(await waitUntil { await driver.snapshot().delivery(waiting.id) == .queued })
        let rowCount = await driver.snapshot().model.entries.count
        #expect(try await driver.readNow(messageID: waiting.id))
        // The row keeps its place and its id, and was read at once (the running Bash moved to the background); the
        // CLI knows it by the new uuid, the one `rewind_files` will name.
        #expect(await waitUntil { await driver.snapshot().delivery(waiting.id) == .read })
        let afterReadNow = await driver.snapshot()
        #expect(afterReadNow.model.sentUUID(ofRow: waiting.id) != waiting.id)
        #expect(afterReadNow.model.entries.count >= rowCount)
        #expect(afterReadNow.model.entries.filter { entry in
            if case let .user(prompt) = entry.body { prompt.text == "look at this now" } else { false }
        }.count == 1)
        #expect(await idle(driver, 15))
        #expect(!(await driver.snapshot().youStopped))
        await rig.finish()
    }

    // MARK: Queue

    @Test func theQueueSendsAfterTheTurnIsKeptOnDiskAndPausesOnAFailedTurnAndARelaunch() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let store = ChatQueueStore(directory: rig.root.appendingPathComponent("chat-queues"))
        let driver = rig.driver(id, queue: store)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 900")
        let receipt = try await driver.send("second", timing: .afterTurn)
        guard case .queued = receipt else { Issue.record("not queued"); return }
        #expect(try store.load(sessionID: id).items.map(\.text) == ["second"])
        #expect(await waitUntil { await driver.snapshot().texts.last == "Fake answer to: second" })
        #expect(try store.load(sessionID: id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: id).path))

        // A failed turn pauses the queue.
        try await driver.send("/scenario result error_max_turns")
        _ = try await driver.send("third", timing: .afterTurn)
        #expect(await waitUntil { await driver.snapshot().queue.paused == .failedTurn })
        #expect(await waitUntil { await rig.status(id) == .failed("max_turns") })
        #expect(await driver.snapshot().queue.items.map(\.text) == ["third"])

        // Loom starts again: what is still queued waits for the user.
        let relaunched = rig.driver(id, queue: store)
        let snapshot = await relaunched.snapshot()
        #expect(snapshot.queue.items.map(\.text) == ["third"])
        #expect(snapshot.queue.paused == .failedTurn)
        try store.save(ChatQueue(items: [ChatQueue.Item(text: "fourth")]), sessionID: id)
        #expect(await rig.driver(id, queue: store).snapshot().queue.paused == .relaunch)
        await rig.finish()
    }

    // MARK: Stop, resume, process death, Quit

    @Test func stopInterruptsWaitsForTheResultClosesStdinAndSendsNoSignal() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        try await Task.sleep(for: .milliseconds(200))
        let report = try await driver.stop()
        #expect(report.succeeded)
        // Never a signal in the middle of a turn: the turn ended by its interrupt, then the child left on EOF. (No
        // bound on the time: under load the order is what is checked, not how long it took.)
        #expect(report.signals.isEmpty, "signals \(report.signals) after \(report.elapsedSeconds) s")
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        let snapshot = await driver.snapshot()
        #expect(snapshot.model.turns.last?.status == .interrupted)
        #expect(snapshot.youStopped)
        #expect(snapshot.drift.isEmpty)
        #expect(await rig.issue(id) == nil)

        // Stopped, then a send: the session resumes and the message runs.
        let sent = try await driver.send("after the stop")
        #expect(await idle(driver))
        #expect(await driver.snapshot().delivery(sent.id) == .read)
        #expect(await driver.snapshot().texts.last == "Fake answer to: after the stop")

        // A waiting card is withdrawn by the interrupt before stdin closes (closing stdin alone would fail the
        // request as a tool error and let Claude carry on).
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        let cardStop = try await driver.stop()
        #expect(cardStop.succeeded)
        #expect(cardStop.signals.isEmpty)
        let afterCard = await driver.snapshot()
        #expect(afterCard.requests.isEmpty)
        #expect(afterCard.model.turns.last?.status == .interrupted)
        #expect(!afterCard.texts.contains("The command could not run because the permission request failed."))
        await rig.finish()
    }

    @Test func theProcessDyingMidTurnEndsTheTurnAndASendResumes() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } } })
        let held = try await driver.send("never read")
        _ = try await driver.send("later", timing: .afterTurn)
        #expect(await waitUntil { await driver.snapshot().delivery(held.id) == .queued })
        // Regression (V16 fix round): the supervisor's stop after the leader's own exit (`processExited`) reaches the
        // leave hook first in the worst interleaving; it must not take the crash for a Stop Loom asked for. Called
        // here before the kill, so the order is fixed rather than left to scheduling.
        await driver.leave(ManagedRunLeave(graceSeconds: 2, reason: .processExited))
        #expect(await driver.currentPhase == .working)
        let pid = try #require(await driver.snapshot().processID)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await waitUntil { await driver.currentPhase == .failed(.ended) })
        let snapshot = await driver.snapshot()
        #expect(snapshot.model.turns.last?.status == .interrupted)
        #expect(!snapshot.youStopped)
        #expect(snapshot.markers.contains(.notice("The session ended before this turn finished.")))
        #expect(snapshot.delivery(held.id) == .notDelivered)
        #expect(snapshot.queue.paused == .processEnded)
        #expect(await rig.issue(id) == "Claude ended unexpectedly. Send a message to resume the session.")
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty != false)
        // The run is released; a send resumes the session.
        #expect(await waitUntil { await rig.supervisor.session(id: id)?.currentRun == nil })
        try await driver.send("hello again")
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "Fake answer to: hello again")
        await rig.finish()
    }

    @Test func quitLeavesAChatRunInTheSameOrderAsStop() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        try await Task.sleep(for: .milliseconds(200))
        let report = await rig.runtime.shutdown()
        #expect(report.succeeded)
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        let snapshot = await driver.snapshot()
        #expect(snapshot.model.turns.last?.status == .interrupted)
        #expect(snapshot.youStopped)
        RunScopeLauncher.removeOwnedBundle(in: rig.root)
        try? FileManager.default.removeItem(at: rig.socketDirectory)
    }

    // MARK: Status precedence, context window, drift

    /// Regression: hooks still fire for a stream child (S1 §D7). The driver is the one authority for its run's work
    /// state, so a hook that comes after the `result` (here a Stop after a failed turn) must not overwrite it.
    @Test func hooksOfAChatRunDoNotOverrideTheDriversState() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario result error_max_turns")
        #expect(await idle(driver))
        #expect(await waitUntil { await rig.status(id) == .failed("max_turns") })
        try await Task.sleep(for: .milliseconds(800))
        #expect(await rig.status(id) == .failed("max_turns"))
        // The stream child's registry entry names itself; it is not read for the run.
        let entries = try FileManager.default.contentsOfDirectory(
            at: rig.profile.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: try #require(entries.first))) as? [String: Any]
        #expect(object?["entrypoint"] as? String == ClaudeRegistrySnapshot.streamEntrypoint)
        await rig.finish()
    }

    @Test func eachResultFeedsTheContextWindowUnderTheModelsKey() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(model: "claude-fake-5-1")))
        try await driver.send("hello")
        #expect(await idle(driver))
        #expect(await driver.snapshot().contextWindows == ["claude-fake-5-1": 200_000])
        #expect(await waitUntil { rig.reports.windows.withLock { $0["claude-fake-5-1"] } == 200_000 })
        await rig.finish()

        // The extended variant keeps its own key.
        let extended = try await Rig.make()
        let driver1m = extended.driver()
        try await driver1m.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(model: "claude-fake-5-1[1m]")))
        try await driver1m.send("hello")
        #expect(await idle(driver1m))
        #expect(await driver1m.snapshot().contextWindows.keys.contains("claude-fake-5-1[1m]"))
        await extended.finish()
    }

    @Test func driftIsNotedOncePerSignalAndPolicyErrorsRaiseTheirState() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario unknown")
        #expect(await idle(driver))
        try await driver.send("/scenario unknown")
        #expect(await idle(driver))
        var snapshot = await driver.snapshot()
        #expect(snapshot.drift.filter { if case .unknownRecord = $0 { true } else { false } }.count == 1)
        // The records are kept raw.
        #expect(snapshot.model.unknownRecordCount >= 2)

        try await driver.send("/scenario result api_error 404 model_not_found")
        #expect(await idle(driver))
        snapshot = await driver.snapshot()
        #expect(snapshot.drift.contains(.apiError(category: "model_not_found", status: nil)))
        #expect(snapshot.policySignal == nil)
        #expect(snapshot.model.turns.last.map { if case .failed = $0.status { true } else { false } } == true)

        try await driver.send("/scenario result api_error 400 billing_error")
        #expect(await idle(driver))
        #expect(await driver.snapshot().policySignal == ChatPolicySignal(category: "billing_error", source: .assistantError))
        await rig.finish()

        // A CLI whose `system/init` lacks `msg_lifecycle_v1`: drift, and delivery still follows the echo.
        let old = try await Rig.make(environment: ["LOOM_FAKE_CHAT_CAPABILITIES": "ui_surface_v1"])
        let oldDriver = old.driver()
        try await oldDriver.startNew(projectID: nil)
        let sent = try await oldDriver.send("hello")
        #expect(await idle(oldDriver))
        let oldSnapshot = await oldDriver.snapshot()
        #expect(oldSnapshot.drift == [.missingCapability("msg_lifecycle_v1")])
        #expect(oldSnapshot.delivery(sent.id) == .read)
        await old.finish()
    }

    // MARK: Switching faces

    @Test func chatToTerminalDuringATurnAndWithACardWaiting() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let host = await MainActor.run { ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root) }
        let driver = try await host.startNewSession(projectID: nil, sessionID: id, draft: NewSessionLaunch(
            firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "claude-fake-5-1")))
        try await driver.send("/scenario work 6000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        try await host.leaveChat(sessionID: id)
        // The child's end of output is read on its own: wait for it.
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        #expect(await driver.snapshot().markers.contains(.face(.continuedInTerminal)))
        let screen = TestScreen()
        // The terminal resume passes the session's own choices from the catalog: no UI involved.
        #expect(try await rig.catalog.launchChoices(sessionID: id).permissionMode == "acceptEdits")
        _ = try await rig.runtime.resumeConversation(sessionID: id, outputSink: screen)
        #expect(await waitUntil { screen.text.lowercased().contains("resumed \(id.uuidString.lowercased())") }, "\(screen.text)")
        // Terminal → Chat: the terminal run is stopped, the session resumes in the Chat face.
        _ = try await host.enterChat(sessionID: id)
        #expect(await driver.currentPhase == .ready)
        #expect(await driver.snapshot().markers.contains(.face(.backInChat)))

        // With a card waiting.
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        try await host.leaveChat(sessionID: id)
        #expect(await driver.snapshot().requests.isEmpty)
        #expect(await rig.supervisor.lastStopReport(sessionID: id)?.signals.isEmpty == true)
        let again = TestScreen()
        _ = try await rig.runtime.resumeConversation(sessionID: id, outputSink: again)
        #expect(await waitUntil { again.text.contains("RESUMED") })
        await rig.finish()
    }

    @Test func terminalToChatWithAnApprovalWaitingInTheTerminal() async throws {
        let rig = try await Rig.make()
        let screen = TestScreen()
        let launch = try await rig.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        let id = launch.sessionID
        #expect(await waitUntil { screen.text.contains("FAKE-CLAUDE READY") })
        #expect(await waitUntil { await rig.supervisor.session(id: id)?.providerConversationID != nil })
        _ = try await launch.terminal.write(Data("/approve\r".utf8))
        #expect(await waitUntil { screen.text.contains("NEEDS-APPROVAL") })
        let host = await MainActor.run { ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root) }
        let driver = try await host.enterChat(sessionID: id)
        #expect(await driver.currentPhase == .ready)
        try await driver.send("hello from chat")
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "Fake answer to: hello from chat")
        await rig.finish()
    }
}

/// A terminal sink for the terminal side of a face switch.
private final class TestScreen: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func receive(_ data: Data) { lock.withLock { buffer += String(decoding: data, as: UTF8.self) } }

    var text: String { lock.withLock { buffer } }
}

extension ChatDriverTests {
    /// The live model's change stream (what the presentation model reads): a snapshot first, then changes with
    /// consecutive numbers that, applied to a copy, give the driver's model; a snapshot asked for continues the numbers.
    @Test func theModelChangeStreamRebuildsTheModelWithConsecutiveNumbers() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        let changes = await driver.modelChanges().changes
        let seen = SeenRows()
        let reader = Task {
            for await change in changes {
                let done = seen.state.withLock { state -> Bool in
                    if var copy = state.last {
                        state.gaps += change.sequence == state.sequence + 1 && copy.apply(change) ? 0 : 1
                        state.last = copy
                    } else {
                        #expect(change.kind == .replaced)
                        state.last = change.model
                    }
                    state.sequence = change.sequence
                    state.ids.formUnion(change.delta.inserted)
                    return state.last?.turns.last?.status == .succeeded
                }
                if done { break }
            }
        }
        let sent = try await driver.send("/scenario bash")
        #expect(await idle(driver))
        _ = await reader.value
        let (ids, last, sequence, gaps) = seen.state.withLock { ($0.ids, $0.last, $0.sequence, $0.gaps) }
        #expect(gaps == 0)
        #expect(ids.contains(sent.id))
        let final = try #require(last)
        let model = await driver.snapshot().model
        #expect(final.rowInputsEqual(model))
        let snapshot = await driver.snapshotChange()
        #expect(snapshot.kind == .replaced && snapshot.sequence >= sequence)
        #expect(snapshot.model?.rowInputsEqual(model) == true)
        await rig.finish()
    }
}

private final class SeenRows: Sendable {
    struct State {
        var ids: Set<String> = []
        var last: TurnModel?
        var sequence = 0
        var gaps = 0
    }

    let state = Mutex(State())
}

// MARK: V16 fix round

extension ChatDriverTests {
    /// `/clear` starts a new conversation in the same process: the supervisor moves the run to a new card (both the
    /// stream's `conversation_reset` and the SessionStart hook with source `clear` say so, in either order). The driver
    /// follows it: the host finds it under the new card, the choices and the face go with it, the stream starts over
    /// with the marker, and Stop and requests work on the new card.
    @Test func clearMovesTheRunTheDriverAndItsChoicesToTheNewCard() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let moves = MoveCount()
        let host = await MainActor.run {
            ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root, driversChanged: { moves.value.withLock { $0 += 1 } })
        }
        let choices = ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "claude-fake-5-1", effort: "high")
        let driver = try await host.startNewSession(projectID: nil, sessionID: id,
                                                    draft: NewSessionLaunch(firstMessage: "", choices: choices))
        try await driver.send("hello before the clear")
        #expect(await idle(driver))
        // A paused queue item, to see it move with the driver (an interrupt pauses the queue).
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        _ = try await driver.enqueue("queued across the clear")
        await driver.interrupt()
        #expect(await idle(driver))
        #expect(await driver.snapshot().queue.paused == .interrupted)
        let store = await MainActor.run { host.queueStore }
        #expect(FileManager.default.fileExists(atPath: store.url(for: id).path))

        try await driver.send("/clear")
        #expect(await waitUntil { await driver.sessionID != id })
        let card = await driver.sessionID
        #expect(await idle(driver))
        // The host finds the driver under the new card only, and told the UI.
        #expect(await MainActor.run { host.existingDriver(for: card) } === driver)
        #expect(await MainActor.run { host.existingDriver(for: id) } == nil)
        #expect(await waitUntil { moves.value.withLock { $0 } >= 1 })
        // The supervisor's card semantics: the old card has no run, the new one has the pipe run.
        #expect(await rig.supervisor.session(id: id)?.currentRun == nil)
        #expect(await rig.supervisor.session(id: card)?.currentRun != nil)
        #expect(await rig.events.snapshot().sessions[card]?.runEndpoint == .pipe)
        // Choices and face follow the run.
        #expect(try await rig.catalog.launchChoices(sessionID: card) == choices)
        #expect(try await rig.catalog.runEndpoint(sessionID: card) == .pipe)
        // The stream starts over with the marker; the queue moved with the driver.
        let cleared = await driver.snapshot()
        #expect(cleared.sessionID == card)
        #expect(cleared.markers.contains(.reset(trigger: "clear")))
        #expect(!cleared.texts.contains("Fake answer to: hello before the clear"))
        #expect(!cleared.youStopped)
        #expect(cleared.queue.items.map(\.text) == ["queued across the clear"])
        #expect(FileManager.default.fileExists(atPath: store.url(for: card).path))
        #expect(!FileManager.default.fileExists(atPath: store.url(for: id).path))
        _ = await driver.clearQueue()

        // A request after the clear is the new card's.
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        #expect(await rig.events.snapshot().sessions[card]?.pendingRequests.map(\.kind) == [.approval])
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty != false)
        #expect(await rig.status(card) == .waitingForApproval)
        // A live change is recorded for the new card.
        try await driver.setEffort("max")
        #expect(try await rig.catalog.launchChoices(sessionID: card).effort == "max")
        #expect(try await rig.catalog.launchChoices(sessionID: id).effort == "high")

        // Stop after the clear stops the new card's run, in the verified order.
        let report = try await driver.stop()
        #expect(report.succeeded)
        #expect(report.sessionID == card)
        #expect(report.signals.isEmpty)
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        #expect(await driver.snapshot().requests.isEmpty)
        await rig.finish()
    }

    /// A Stop while the child starts cancels the start: no failure, no issue, nothing left running. Once while the
    /// child waits to answer `initialize`, once right away (most likely while it spawns).
    @Test func aStopDuringStartingCancelsTheStart() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_INIT": "silent"])
        let id = UUID()
        let driver = rig.driver(id)
        let starting = Task { try await driver.startNew(projectID: nil) }
        #expect(await waitUntil { await driver.snapshot().runID != nil })
        #expect(await driver.currentPhase == .starting)
        let report = try await driver.stop()
        #expect(report.succeeded)
        await #expect(throws: ChatDriverError.stopping) { try await starting.value }
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        let issue = await rig.issue(id)
        #expect(issue == nil, "\(issue ?? "")")
        #expect(await rig.supervisor.session(id: id)?.currentRun == nil)

        let other = UUID()
        let early = rig.driver(other)
        let racing = Task { try await early.startNew(projectID: nil) }
        #expect(await waitUntil { await early.currentPhase == .starting })
        _ = try? await early.stop()
        await #expect(throws: ChatDriverError.stopping) { try await racing.value }
        #expect(await waitUntil { await early.currentPhase == .stopped })
        #expect(await waitUntil { await rig.supervisor.session(id: other)?.currentRun == nil })
        let otherIssue = await rig.issue(other)
        #expect(otherIssue == nil, "\(otherIssue ?? "")")
        await rig.finish()
    }

    @Test func aChildThatNeverAnswersIsNotReadyAndIsStopped() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_INIT": "silent"])
        let id = UUID()
        let driver = rig.driver(id, readyTimeout: .milliseconds(800))
        await #expect(throws: ChatDriverError.couldNotStart("no answer to initialize")) {
            try await driver.startNew(projectID: nil)
        }
        #expect(await driver.currentPhase == .failed(.notReady))
        #expect(await rig.issue(id) == "Claude did not answer in the Chat face.")
        #expect(await waitUntil { await rig.supervisor.session(id: id)?.currentRun == nil })
        #expect(await driver.currentPhase == .failed(.notReady))
        await rig.finish()
    }

    @Test func aStartTheRuntimeRefusesCouldNotStart() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        let tooLong = String(repeating: "x", count: NewSessionLaunch.maxFirstMessageBytes + 1)
        await #expect(throws: (any Error).self) {
            try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: tooLong))
        }
        guard case .failed(.couldNotStart) = await driver.currentPhase else {
            Issue.record("phase \(await driver.currentPhase)")
            return
        }
        await rig.finish()
    }

    /// A child that exits at once (a bad flag, a resume the CLI refuses) says why on stderr: its first line is the
    /// issue, at a start and at a resume, never "ended unexpectedly".
    @Test func anExitAtStartOrResumeShowsTheFirstStderrLine() async throws {
        let line = "Error: the fake CLI could not start (LOOM_FAKE_CHAT_INIT=exit)"
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_INIT": "exit"])
        let id = UUID()
        let driver = rig.driver(id)
        await #expect(throws: ChatDriverError.couldNotStart(line)) { try await driver.startNew(projectID: nil) }
        #expect(await driver.currentPhase == .failed(.couldNotStart(line)))
        #expect(await waitUntil { await rig.issue(id) == "Claude ended before it was ready: \(line)" })
        await rig.finish()

        let resuming = try await Rig.make(environment: ["LOOM_FAKE_CHAT_INIT": "exit-on-resume"])
        let resumed = UUID()
        let second = resuming.driver(resumed)
        try await second.startNew(projectID: nil)
        try await second.send("hello")
        #expect(await idle(second))
        try await second.stop()
        #expect(await waitUntil { await second.currentPhase == .stopped })
        await #expect(throws: ChatDriverError.couldNotStart(line)) { try await second.send("after the stop") }
        #expect(await second.currentPhase == .failed(.couldNotStart(line)))
        #expect(await waitUntil { await resuming.issue(resumed) == "Claude ended before it was ready: \(line)" })
        await resuming.finish()
    }

    @Test func quitWhileIdleAndQuitWithACardWaiting() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        let idleQuit = await rig.runtime.shutdown()
        #expect(idleQuit.succeeded)
        #expect(idleQuit.signals.isEmpty)
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        RunScopeLauncher.removeOwnedBundle(in: rig.root)
        try? FileManager.default.removeItem(at: rig.socketDirectory)

        let waiting = try await Rig.make()
        let id = UUID()
        let card = waiting.driver(id)
        try await card.startNew(projectID: nil)
        try await card.send("/scenario approval")
        #expect(await waitUntil { await card.currentPhase == .needsYou })
        let quit = await waiting.runtime.shutdown()
        #expect(quit.succeeded)
        #expect(quit.signals.isEmpty)
        #expect(await waitUntil { await card.currentPhase == .stopped })
        let snapshot = await card.snapshot()
        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.model.turns.last?.status == .interrupted)
        #expect(!snapshot.texts.contains("The command could not run because the permission request failed."))
        RunScopeLauncher.removeOwnedBundle(in: waiting.root)
        try? FileManager.default.removeItem(at: waiting.socketDirectory)
    }

    /// Regression (V16 fix round): a Chat Stop can take longer than Quit's wait for operations under way (a CLI slow
    /// to end its turn, then the input-close grace). Quit right after it waits for that stop instead of failing.
    @Test func quitRightAfterAChatStopWaitsForThatStop() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_IGNORE_INTERRUPT": "1"])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 9000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        let stopping = Task { try await driver.stop() }
        #expect(await waitUntil { await driver.currentPhase == .stopping })
        let quit = await rig.runtime.shutdown()
        #expect(quit.succeeded, "\(quit.errors)")
        _ = try? await stopping.value
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        RunScopeLauncher.removeOwnedBundle(in: rig.root)
        try? FileManager.default.removeItem(at: rig.socketDirectory)
    }

    @Test func aPolicyCategoryOnAnAPIRetryRaisesThePolicySignal() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario api-retry 1 overloaded")
        #expect(await idle(driver))
        #expect(await driver.snapshot().policySignal == nil)
        try await driver.send("/scenario api-retry 1 oauth_org_not_allowed")
        #expect(await idle(driver))
        #expect(await driver.snapshot().policySignal == ChatPolicySignal(category: "oauth_org_not_allowed", source: .apiRetry))
        await rig.finish()
    }

    /// Regression (V16 fix round): work that outlives the turn (here a Bash a `now` send moved to the background) keeps
    /// the session under way after the turn's `result`, through the hub's pending work count, until it ends.
    @Test func backgroundWorkKeepsTheSessionUnderWayAfterTheTurn() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario work 9000")
        // The third (last) step: moved to the background, it outlives the turn.
        #expect(await waitUntil(15) {
            await driver.snapshot().model.entries.filter { if case .tool = $0.body { true } else { false } }.count == 3
        })
        let waiting = try await driver.send("look now")
        #expect(await waitUntil { await driver.snapshot().delivery(waiting.id) == .queued })
        #expect(try await driver.readNow(messageID: waiting.id))
        #expect(await waitUntil { await driver.snapshot().backgroundTaskCount == 1 })
        #expect(await idle(driver, 15))
        #expect(await driver.snapshot().backgroundTaskCount == 1)
        #expect(await waitUntil {
            let state = await rig.events.snapshot().sessions[id]
            return state?.status == ProviderWorkState(activity: .turnComplete, pendingProviderWorkCount: 1)
                && state?.activePhase == .underWay
        })
        let pending = await rig.supervisor.providerWorkState(sessionID: id)?.pendingProviderWorkCount
        #expect(pending == 1)
        // The task ends: the count goes to zero.
        #expect(await waitUntil(15) {
            let count = await rig.supervisor.providerWorkState(sessionID: id)?.pendingProviderWorkCount
            return await driver.snapshot().backgroundTaskCount == 0 && count == 0
        })
        await rig.finish()
    }

    /// Regression (V16 fix round): a queued item leaves the queue only once it is written. A resume that fails keeps
    /// it where it was, and the error says why.
    @Test func aQueuedItemIsNotLostWhenItCannotBeSent() async throws {
        let rig = try await Rig.make()
        let store = ChatQueueStore(directory: rig.root.appendingPathComponent("chat-queues"))
        // A session the runtime has no record of: every resume fails.
        let id = UUID()
        let driver = rig.driver(id, queue: store)
        let first = try await driver.enqueue("first")
        _ = try await driver.enqueue("second")
        await #expect(throws: (any Error).self) { try await driver.sendQueuedNow(id: first) }
        #expect(await driver.snapshot().queue.items.map(\.text) == ["first", "second"])
        await #expect(throws: (any Error).self) { try await driver.resumeQueue() }
        #expect(await driver.snapshot().queue.items.map(\.text) == ["first", "second"])
        #expect(try store.load(sessionID: id).items.map(\.text) == ["first", "second"])
        // The queue is bounded.
        _ = await driver.clearQueue()
        for i in 0..<ChatQueue.maximumItems { _ = try await driver.enqueue("item \(i)") }
        await #expect(throws: ChatDriverError.queueFull) { try await driver.enqueue("one too many") }
        await rig.finish()
    }

    /// `updates()` serves any number of readers; reading a snapshot changes nothing.
    @Test func updatesReachEveryReaderAndASnapshotConsumesNothing() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        let first = await driver.updates()
        let second = await driver.updates()
        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        _ = await a.next()
        _ = await b.next()
        _ = try await driver.enqueue("wakes both")
        #expect(await a.next() != nil)
        #expect(await b.next() != nil)
        let one = await driver.snapshot()
        let two = await driver.snapshot()
        #expect(one.queue == two.queue && one.model.entries == two.model.entries)
        await rig.finish()
    }

    /// The host forgets a deleted session: its driver and its queue file (the user's unsent text) go.
    @Test func aDeletedSessionLosesItsDriverAndItsQueue() async throws {
        let rig = try await Rig.make()
        let host = await MainActor.run { ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root) }
        let id = UUID()
        let driver = await MainActor.run { host.driver(for: id) }
        _ = try await driver.enqueue("unsent text")
        let store = await MainActor.run { host.queueStore }
        #expect(FileManager.default.fileExists(atPath: store.url(for: id).path))
        await MainActor.run { host.forget(sessionID: id) }
        #expect(!FileManager.default.fileExists(atPath: store.url(for: id).path))
        #expect(await MainActor.run { host.existingDriver(for: id) } == nil)
        // A file left by a session the catalog no longer has goes at the next sweep.
        let orphan = UUID()
        try store.save(ChatQueue(items: [ChatQueue.Item(text: "orphaned")]), sessionID: orphan)
        await host.removeQueuesOfDeletedSessions()
        #expect(!FileManager.default.fileExists(atPath: store.url(for: orphan).path))
        await rig.finish()
    }
}

private final class MoveCount: Sendable {
    let value = Mutex(0)
}

// MARK: The composer's chips (V17)

extension ChatDriverTests {
    /// The bar's mode, model and effort chips change the live run; one after the other, each keeps its own choice.
    @Test func theChipsChangeTheRunOneAfterTheOther() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver(UUID())
        try await driver.startNew(projectID: nil)
        try await driver.setEffort("high")
        try await driver.setPermissionMode("acceptEdits")
        #expect(await driver.composerState().permissionMode == "acceptEdits")
        try await driver.setPermissionMode("plan")
        try await driver.setEffort("low")
        let state = await driver.composerState()
        #expect(state.permissionMode == "plan")
        #expect(state.choices.effort == "low")
        await rig.finish()
    }
}
