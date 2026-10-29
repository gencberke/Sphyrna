import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// Slice V03: the reason a session shows its status, and the status fixes spike S0 recorded. The payloads
/// are the sanitized S0 recordings (`S0HookFixtures.swift`). Each correction has a test that fails without it.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct StatusReasonTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    private func ms(_ seconds: Double) -> Double { at(seconds).timeIntervalSince1970 * 1_000 }

    private func sample(_ status: String, at milliseconds: Double) -> ClaudeRegistryRead {
        .snapshot(ClaudeRegistrySnapshot(
            sessionID: S0Hooks.conversation, startedAt: ms(0) - 5_000, status: status, statusUpdatedAt: milliseconds))
    }

    /// A tracker that saw the SessionStart and one user prompt (at 0 s and 1 s).
    private func tracker() async throws -> (ClaudeHookStateTracker, UUID, UUID) {
        let session = UUID(), run = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: session, managedRunID: run)
        _ = try await tracker.receive(S0Hooks.envelope(S0Hooks.sessionStart, session: session, run: run, sentAt: at(0)), receivedAt: at(0))
        _ = try await tracker.receive(S0Hooks.envelope(S0Hooks.prompt("go"), session: session, run: run, sentAt: at(1)), receivedAt: at(1))
        return (tracker, session, run)
    }

    @discardableResult
    private func send(
        _ fields: [String: Any], to tracker: ClaudeHookStateTracker, _ session: UUID, _ run: UUID, at seconds: Double
    ) async throws -> ClaudeHookDisposition {
        try await tracker.receive(
            S0Hooks.envelope(fields, session: session, run: run, sentAt: at(seconds)), receivedAt: at(seconds))
    }

    // MARK: The reason

    @Test func anApprovalNamesTheToolAndTheCommandOrPath() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.bashPermission, to: tracker, session, run, at: 2)
        var status = await tracker.status()
        #expect(status.activity == .waitingForApproval)
        #expect(status.reason == StatusReason(
            .approval(tool: "Bash"), detail: "mkdir -p sub && touch sub/marker.txt",
            note: "Create sub directory and empty marker.txt file"))

        try await send(S0Hooks.writePermission, to: tracker, session, run, at: 3)
        status = await tracker.status()
        #expect(status.reason == StatusReason(.approval(tool: "Write"), detail: "/tmp/ws/hello.txt"))
        try await send(S0Hooks.editPermission, to: tracker, session, run, at: 4)
        #expect(await tracker.status().reason == StatusReason(.approval(tool: "Edit"), detail: "/tmp/ws/hello.txt"))
    }

    @Test func aQuestionNamesItsHeaderAndAPlanSaysPlanReadyWithoutKeepingThePlan() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.askUserQuestion, to: tracker, session, run, at: 2)
        #expect(await tracker.status().activity == .waitingForApproval)
        #expect(await tracker.status().reason == StatusReason(.question, detail: "Color"))

        try await send(S0Hooks.exitPlanMode, to: tracker, session, run, at: 3)
        let reason = try #require(await tracker.status().reason)
        #expect(reason == StatusReason(.planReady))
        #expect(reason.detail == nil && reason.note == nil)
    }

    @Test func aStopStatesTheFirstLineOfTheLastMessage() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.stopDone, to: tracker, session, run, at: 2)
        let status = await tracker.status()
        #expect(status.activity == .turnComplete)
        #expect(status.reason == StatusReason(
            .turnDone, detail: "I ran `mkdir -p sub && touch sub/marker.txt` in the working directory. It finished with no output."))
        // The next prompt ends the finished turn's reason.
        try await send(S0Hooks.prompt("again"), to: tracker, session, run, at: 3)
        #expect(await tracker.status().reason == nil)
    }

    @Test func aStopFailureStatesItsCategoryAndDetails() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.stopFailure, to: tracker, session, run, at: 2)
        let status = await tracker.status()
        #expect(status.activity == .failed("model_not_found"))
        #expect(status.reason == StatusReason(
            .failure(category: "model_not_found"),
            detail: "There's an issue with the selected model (claude-nonexistent-9). It may not exist or you may not have access to it."))
    }

    @Test func reasonTextIsOneBoundedCleanLine() throws {
        #expect(StatusReason.oneLine("  git \t push\n  origin   main \r\n") == "git push origin main")
        // Control, bidirectional and zero-width scalars never reach a card.
        #expect(StatusReason.oneLine("a\u{202E}b\u{200B}c\u{0007}d\u{FEFF}") == "abcd")
        #expect(StatusReason.oneLine(" \n\t ") == nil)
        #expect(StatusReason.firstLine("\n\n  \nsecond try\nthird") == "second try")
        // A cut never splits a character.
        let family = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 300)
        let cut = try #require(StatusReason.oneLine(family))
        #expect(cut.count == StatusReason.maximumDetailLength && cut.hasSuffix("…"))
        #expect(cut.dropLast().allSatisfy { String($0) == "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}" })
        // Only the head of a huge message is looked at.
        let huge = String(repeating: "x", count: 2_000_000)
        #expect(StatusReason.firstLine(huge)?.count == StatusReason.maximumDetailLength)
    }

    @Test func reasonContentIsRedactedWhereverItIsInterpolated() {
        let reason = StatusReason(.approval(tool: "Bash"), detail: "curl https://example.invalid/secret-token-123", note: "uses a token")
        let state = SessionViewState(reason: reason)
        for text in ["\(reason)", String(reflecting: reason), "\(state)", String(reflecting: state), "\(SessionEventChange.reason(reason))"] {
            #expect(!text.contains("secret-token-123") && !text.contains("uses a token"))
        }
    }

    // MARK: S0 correction 1: work and automatic turns

    @Test func workCountsFromTheStopsRunningTasksByKind() async throws {
        let (tracker, session, run) = try await tracker()
        // A task Claude lists as over is not work (fails when every listed entry counts).
        var fields = S0Hooks.stopWithShell
        var tasks = try #require(fields["background_tasks"] as? [[String: Any]])
        tasks.append(["id": "done1", "type": "shell", "status": "completed", "description": "old", "command": "true"])
        tasks.append(["id": "a1", "type": "subagent", "status": "running", "description": "d", "agent_type": "general-purpose"])
        tasks.append(["id": "w1", "type": "workflow", "status": "running"])
        fields["background_tasks"] = tasks
        fields["session_crons"] = [["id": "c1"]]
        try await send(fields, to: tracker, session, run, at: 2)
        let status = await tracker.status()
        #expect(status.activity == .turnComplete)
        #expect(status.reason?.work == BackgroundWork(shells: 1, subagents: 1, others: 1, scheduled: 1))
        #expect(status.backgroundTaskCount == 3 && status.scheduledTaskCount == 1)
    }

    @Test func aStopWithATaskLeftIsTurnDoneWorkRunningUntilTheAutomaticTurnEndsIt() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.stopWithShell, to: tracker, session, run, at: 2)
        var status = await tracker.status()
        #expect(status.activity == .turnComplete && status.backgroundTaskCount == 1)
        #expect(status.reason == StatusReason(.turnDone, detail: "started", work: BackgroundWork(shells: 1)))
        let used = status.lastUsedAt

        // The task ends and Claude starts a turn by itself: Claude works, but the user did not.
        try await send(S0Hooks.taskNotificationPrompt, to: tracker, session, run, at: 40)
        status = await tracker.status()
        #expect(status.activity == .working)
        #expect(status.reason == StatusReason(
            .automaticTurn, detail: "Background command \"Sleep 45 seconds in background\" completed (exit code 0)"))
        #expect(status.lastUsedAt == used, "an automatic turn is not the user's use")

        try await send(S0Hooks.stopAfterTask, to: tracker, session, run, at: 41)
        status = await tracker.status()
        #expect(status.activity == .turnComplete && status.backgroundTaskCount == 0)
        #expect(status.reason?.work.isEmpty == true)
    }

    @Test func aTaskNotificationTurnIsNotTheUsersPrompt() throws {
        let automatic = try ClaudeHookEvent(payload: JSONSerialization.data(withJSONObject: S0Hooks.taskNotificationPrompt))
        #expect(automatic.promptIsSynthetic)
        let typed = try ClaudeHookEvent(payload: JSONSerialization.data(withJSONObject: S0Hooks.prompt("fix <task-notification> parsing")))
        #expect(!typed.promptIsSynthetic)
    }

    // MARK: S0 correction 2: needs you comes from PermissionRequest

    @Test func theNeedsYouStateIsImmediateFromPermissionRequestAndNoNotificationIsNeeded() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.bashPermission, to: tracker, session, run, at: 2)
        #expect(await tracker.status().activity == .waitingForApproval)
        // The Notification about 6 s later changes nothing, neither the state nor the reason.
        let before = await tracker.status()
        try await send(S0Hooks.permissionPromptNotification, to: tracker, session, run, at: 8)
        let after = await tracker.status()
        #expect(after.activity == before.activity && after.reason == before.reason)
    }

    @Test func aLateNotificationAfterAQuickAnswerDoesNotBringTheApprovalBack() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.bashPermission, to: tracker, session, run, at: 2)
        // Answered at once: the registry reports busy again, and no Stop or other hook follows.
        let issue = await tracker.receiveRegistry(
            sample("busy", at: ms(2) + 1_500), generation: await tracker.registryGeneration(), now: at(10))
        #expect(issue == nil)
        let answered = await tracker.status()
        #expect(answered.activity == .working && answered.reason == nil)
        try await send(S0Hooks.permissionPromptNotification, to: tracker, session, run, at: 4)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.status().reason == nil)
    }

    @Test func theIdleReminderNeverReplacesWorkAnApprovalOrAFailure() async throws {
        let (tracker, session, run) = try await tracker()
        // Within the hook reorder window of the prompt it may simply be older than the prompt.
        try await send(S0Hooks.idlePromptNotification, to: tracker, session, run, at: 1.2)
        #expect(await tracker.status().activity == .working, "a reminder is not a state")
        #expect(await tracker.registryGeneration() != nil, "the pending registry check is kept")

        try await send(S0Hooks.bashPermission, to: tracker, session, run, at: 3)
        try await send(S0Hooks.idlePromptNotification, to: tracker, session, run, at: 4)
        #expect(await tracker.status().activity == .waitingForApproval)
        #expect(await tracker.status().reason?.kind == .approval(tool: "Bash"))

        try await send(S0Hooks.stopFailure, to: tracker, session, run, at: 5)
        try await send(S0Hooks.idlePromptNotification, to: tracker, session, run, at: 65)
        #expect(await tracker.status().activity == .failed("model_not_found"), "a failure stays until the next prompt")
        #expect(await tracker.status().reason?.kind == .failure(category: "model_not_found"))
    }

    @Test func anInterruptedTurnWhoseIdleSampleWasLostEndsOnTheIdleReminder() async throws {
        // A user interrupt runs no Stop. The registry's idle sample tied with the prompt's millisecond is
        // dropped as stale, so only the reminder a minute later can end the turn.
        let (tracker, session, run) = try await tracker()
        let issue = await tracker.receiveRegistry(
            sample("idle", at: ms(1)), generation: await tracker.registryGeneration(), now: at(30))
        #expect(issue == nil)
        #expect(await tracker.status().activity == .working, "the tied sample is stale")
        try await send(S0Hooks.idlePromptNotification, to: tracker, session, run, at: 61)
        #expect(await tracker.status().activity == .waitingForInput)
        #expect(await tracker.status().reason == nil)
    }

    // MARK: A lost PermissionRequest

    @Test func aPermissionPromptNotificationBacksUpAPermissionRequestThatNeverArrived() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.permissionPromptNotification, to: tracker, session, run, at: 8)
        var status = await tracker.status()
        #expect(status.activity == .waitingForApproval && status.reason == nil)
        // Esc on that dialog still ends it through the registry.
        _ = await tracker.receiveRegistry(
            sample("idle", at: ms(8) + 3_000), generation: await tracker.registryGeneration(), now: at(30))
        status = await tracker.status()
        #expect(status.activity == .waitingForInput && status.reason == nil)
    }

    @Test func aRegistryWaitingSampleBacksUpAPermissionRequestThatNeverArrived() async throws {
        let (tracker, session, run) = try await tracker()
        _ = (session, run)
        let issue = await tracker.receiveRegistry(
            sample("waiting", at: ms(1) + 2_000), generation: await tracker.registryGeneration(), now: at(30))
        #expect(issue == nil)
        let status = await tracker.status()
        #expect(status.activity == .waitingForApproval && status.reason == nil)
        _ = await tracker.receiveRegistry(
            sample("busy", at: ms(1) + 4_000), generation: await tracker.registryGeneration(), now: at(30))
        #expect(await tracker.status().activity == .working)
    }

    @Test func aPlanDialogTheRegistryAnnouncedFirstGetsItsReasonAndEndsWithEsc() async throws {
        // Real Claude 2.1.300 (V03 recording plan-esc): the registry said "waiting" 40 ms before the
        // PermissionRequest hook, and Esc produced only a registry "idle" 3 s later.
        let (tracker, session, run) = try await tracker()
        _ = await tracker.receiveRegistry(
            sample("waiting", at: ms(2) - 40), generation: await tracker.registryGeneration(), now: at(30))
        #expect(await tracker.status().activity == .waitingForApproval)
        try await send(S0Hooks.exitPlanMode, to: tracker, session, run, at: 2)
        #expect(await tracker.status().reason == StatusReason(.planReady))
        _ = await tracker.receiveRegistry(
            sample("idle", at: ms(2) + 3_000), generation: await tracker.registryGeneration(), now: at(30))
        let status = await tracker.status()
        #expect(status.activity == .waitingForInput && status.reason == nil)
    }

    @Test func theIdleReminderAfterAStopStillMovesToWaitingAndKeepsTheLastMessage() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.stopDone, to: tracker, session, run, at: 2)
        let reason = await tracker.status().reason
        try await send(S0Hooks.idlePromptNotification, to: tracker, session, run, at: 62)
        #expect(await tracker.status().activity == .waitingForInput)
        #expect(await tracker.status().reason == reason)
    }

    // MARK: S0 correction 3: the prompt-suggestion agent

    @Test func aSubagentStopWithNoStartAndNoTypeChangesNothing() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.stopWithShell, to: tracker, session, run, at: 2)
        let before = await tracker.status()
        let disposition = try await send(S0Hooks.promptSuggestionStop, to: tracker, session, run, at: 4)
        guard case .applied = disposition else { Issue.record("dropped: \(disposition)"); return }
        #expect(await tracker.subagentRecords().isEmpty)
        // Its "last message" is a suggested next prompt, not Claude's answer.
        #expect(await tracker.status() == before)
    }

    // MARK: S0 correction 4: Esc on a dialog fires no hook

    @Test func anApprovalCancelledWithEscEndsOnTheRegistrysSampleAndTakesItsReasonAlong() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.bashPermission, to: tracker, session, run, at: 2)
        let generation = await tracker.registryGeneration()
        // While the dialog is open the registry says waiting: the approval and its reason hold.
        _ = await tracker.receiveRegistry(sample("waiting", at: ms(2) + 10), generation: generation, now: at(30))
        #expect(await tracker.status().activity == .waitingForApproval)
        #expect(await tracker.status().reason?.kind == .approval(tool: "Bash"))
        // Esc: no hook at all; the registry goes idle.
        let issue = await tracker.receiveRegistry(sample("idle", at: ms(2) + 20_000), generation: generation, now: at(30))
        #expect(issue == nil)
        #expect(await tracker.status().activity == .waitingForInput)
        #expect(await tracker.status().reason == nil, "no card says 'wants to run' after the dialog is gone")
    }

    @Test func aSubagentsAnsweredPromptReturnsTheTurnsReason() async throws {
        let (tracker, session, run) = try await tracker()
        try await send(S0Hooks.stopWithSubagent, to: tracker, session, run, at: 2)
        let turnReason = await tracker.status().reason
        try await send(S0Hooks.subagentBashPermission, to: tracker, session, run, at: 3)
        #expect(await tracker.status().activity == .waitingForApproval)
        #expect(await tracker.status().reason == StatusReason(
            .approval(tool: "Bash"), detail: "sleep 20", note: "Sleep for 20 seconds"))
        _ = await tracker.receiveRegistry(
            sample("busy", at: ms(3) + 2_000), generation: await tracker.registryGeneration(), now: at(30))
        #expect(await tracker.status().activity == .turnComplete)
        #expect(await tracker.status().reason == turnReason)
    }

    // MARK: Hub

    @Test func theHubKeepsTheReasonSuppressesEqualOnesAndDropsItWithTheRun() async {
        let hub = SessionEventHub()
        let id = UUID(), run = UUID()
        let reason = StatusReason(.approval(tool: "Bash"), detail: "ls")
        await hub.publish(sessionID: id, change: .runStarted(run))
        await hub.publish(sessionID: id, change: .reason(reason))
        #expect(await hub.snapshot().sessions[id]?.reason == reason)
        let base = await hub.snapshot().sequence
        await hub.publish(sessionID: id, change: .reason(reason))
        await hub.publish(sessionID: id, change: .reason(StatusReason(.approval(tool: "Bash"), detail: "ls")))
        #expect(await hub.snapshot().sequence == base, "an equal reason is silent")
        await hub.publish(sessionID: id, change: .reason(StatusReason(.approval(tool: "Bash"), detail: "ls -la")))
        #expect(await hub.snapshot().sequence == base + 1)

        await hub.publish(sessionID: id, change: .runEnded(run, .idle))
        #expect(await hub.snapshot().sessions[id]?.reason == nil, "an approval cannot be answered once the run is gone")
        // A late reason of the ended run does not come back; a clear does nothing.
        let ended = await hub.snapshot().sequence
        await hub.publish(sessionID: id, change: .reason(reason))
        await hub.publish(sessionID: id, change: .reason(nil))
        let after = await hub.snapshot()
        #expect(after.sequence == ended && after.sessions[id]?.reason == nil)

        let next = UUID()
        await hub.publish(sessionID: id, change: .runStarted(next))
        await hub.publish(sessionID: id, change: .reason(reason))
        await hub.publish(sessionID: id, change: .runDetached(next))
        #expect(await hub.snapshot().sessions[id]?.reason == nil)
        await hub.publish(sessionID: id, change: .runStarted(next))
        await hub.publish(sessionID: id, change: .reason(reason))
        await hub.publish(sessionID: id, change: .runStarted(UUID()))
        #expect(await hub.snapshot().sessions[id]?.reason == nil)
    }

    @Test func theLastLineOfAFinishedOrFailedTurnOutlivesItsRun() async {
        let hub = SessionEventHub()
        let id = UUID()
        let done = StatusReason(.turnDone, detail: "Tests pass.")
        let failed = StatusReason(.failure(category: "rate_limit"), detail: "Too many requests")
        for (reason, end) in [(done, false), (failed, false), (done, true), (failed, true)] {
            let run = UUID()
            await hub.publish(sessionID: id, change: .runStarted(run))
            await hub.publish(sessionID: id, change: .reason(reason))
            await hub.publish(sessionID: id, change: end ? .runDetached(run) : .runEnded(run, .idle))
            let state = await hub.snapshot().sessions[id]
            #expect(state?.reason == reason && state?.runID == nil && state?.status == nil)
        }
        // The next run starts clean; a deleted session keeps nothing.
        await hub.publish(sessionID: id, change: .runStarted(UUID()))
        #expect(await hub.snapshot().sessions[id]?.reason == nil)
        await hub.publish(sessionID: id, change: .reason(done))
        await hub.forget(sessionID: id)
        #expect(await hub.snapshot().sessions[id] == nil)
    }

    // MARK: Through the real adapter

    private var childPath: String {
        Products.directory
            .appendingPathComponent("loom-test-child").path
    }

    @Test func theAdapterPublishesTheReasonBeforeTheStatusItExplainsAndKeepsAFinishedTurnsLineAfterTheRun() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let session = UUID()
        try await supervisor.createSession(ManagedSession(
            id: session, provider: .claude, providerConversationID: S0Hooks.conversation,
            workingDirectory: FileManager.default.temporaryDirectory.path))
        let launched = try await supervisor.launch(
            sessionID: session, executable: childPath, arguments: ["stubborn"],
            environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: session))
        let run = try #require(launched.session.currentRun?.id)
        let adapter = ClaudeSessionAdapter(supervisor: supervisor)
        let frames = await supervisor.events.subscribe(bufferingPolicy: .unbounded)
        let log = FrameLog()
        let collector = Task {
            for await frame in frames { log.append(frame) }
        }
        defer { collector.cancel() }
        func deliver(_ fields: [String: Any], _ seconds: Double) async throws {
            _ = try await adapter.receive(S0Hooks.envelope(fields, session: session, run: run, sentAt: at(seconds)), receivedAt: at(seconds))
        }
        try await deliver(S0Hooks.sessionStart, 0)
        try await deliver(S0Hooks.prompt("go"), 1)
        try await deliver(S0Hooks.bashPermission, 2)
        var state = await supervisor.events.snapshot().sessions[session]
        #expect(state?.status?.activity == .waitingForApproval)
        #expect(state?.reason?.kind == .approval(tool: "Bash"))
        // The frame that first says Needs approval already says what for.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while log.firstFrame(where: { $0.sessions[session]?.status?.activity == .waitingForApproval }) == nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstWaiting = try #require(log.firstFrame { $0.sessions[session]?.status?.activity == .waitingForApproval })
        #expect(firstWaiting.sessions[session]?.reason?.kind == .approval(tool: "Bash"))

        try await deliver(S0Hooks.stopWithShell, 3)
        state = await supervisor.events.snapshot().sessions[session]
        #expect(state?.status == ProviderWorkState(activity: .turnComplete, pendingProviderWorkCount: 1))
        #expect(state?.reason == StatusReason(.turnDone, detail: "started", work: BackgroundWork(shells: 1)))

        // The same Stop again changes nothing the hub shows.
        let sequence = await supervisor.events.snapshot().sequence
        try await deliver(S0Hooks.stopWithShell, 4)
        #expect(await supervisor.events.snapshot().sequence == sequence)

        #expect(try await supervisor.stop(sessionID: session, graceSeconds: 0.05).succeeded)
        let ended = await supervisor.events.snapshot().sessions[session]
        #expect(ended?.runID == nil && ended?.reason == state?.reason, "the finished turn's last line stays for the unread card")
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }
}

private final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SessionEventFrame] = []
    func append(_ frame: SessionEventFrame) { lock.lock(); frames.append(frame); lock.unlock() }
    func firstFrame(where predicate: (SessionEventFrame) -> Bool) -> SessionEventFrame? {
        lock.lock(); defer { lock.unlock() }
        return frames.first(where: predicate)
    }
}
