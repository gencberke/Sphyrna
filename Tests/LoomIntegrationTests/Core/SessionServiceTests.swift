import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private typealias HostFailure = SessionServiceShared.HostFailure
private typealias HostStopping = SessionServiceShared.HostStopping
private typealias Gate = SessionServiceShared.Gate
private typealias FakeHost = SessionServiceShared.FakeHost
private typealias FakeSinks = SessionServiceShared.FakeSinks
private typealias Told = SessionServiceShared.Told

/// R5a: the session service owns the lifecycle's orchestration and its transition state. Both faces are fakes (a structured
/// host that records what it was asked and a terminal that hands out sinks); the runtime is the real one over the fake
/// provider, so a terminal run and its Stop are real. Nothing waits on a clock: each test awaits the task an operation returns.

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
@MainActor
struct SessionServiceTests: SessionServiceFixtures {
    // MARK: Faces

    @Test func aCodexTerminalIsShownBeforeIdentityButItsFailureIsReportedAsAStartFailure() async throws {
        let rig = try await makeRig(extraEnvironment: ["LOOM_FAKE_CODEX_EXIT_AT_START": "1"])
        defer { rig.context.cleanup() }
        var outcomes: [Bool] = []
        let draft = NewSessionLaunch(firstMessage: "keep this draft", choices: HarnessLaunchChoices(harness: .codex, mode: .askBeforeEdits))
        let task = rig.service.startSession(projectID: nil, launch: draft,
            cardCreated: { rig.told.card($0) }, notStarted: { rig.told.none() }, startResolved: { outcomes.append($0) })
        await task?.value
        #expect(rig.host.newSessions.isEmpty)
        #expect(rig.sinks.adopted.count == 1 && rig.told.cards.count == 1)
        #expect(outcomes == [false], "showing the terminal does not make the draft start successful")
        #expect((await rig.context.runtime.shutdown()).succeeded)
    }

    @Test func aStartGoesToTheFaceThePolicyNames() async throws {
        let chat = try await makeRig(runsIn: .chat)
        defer { chat.context.cleanup() }
        await start(chat)?.value
        #expect(chat.host.newSessions.count == 1 && chat.sinks.requested == 0)
        #expect(chat.told.cards == [chat.host.newSessions[0].session])

        // The switch on Terminal, or no structured host: the terminal starts it.
        for (runsIn, hasHost) in [(SessionLiveFace.terminal, true), (.chat, false)] {
            let terminal = try await makeRig(runsIn: runsIn, host: hasHost)
            defer { terminal.context.cleanup() }
            await start(terminal)?.value
            #expect(terminal.host.newSessions.isEmpty)
            #expect(terminal.sinks.requested == 1 && terminal.sinks.adopted.count == 1)
            #expect(terminal.told.cards == [terminal.sinks.adopted[0].sessionID])
            #expect(terminal.service.transitions.busy.isEmpty && terminal.service.transitions.startingKeys.isEmpty)
            _ = await terminal.context.runtime.shutdown()
        }
    }

    @Test func aHarnessThatCannotBeStartedStartsNothingInEitherFace() async throws {
        for runsIn in [SessionLiveFace.chat, .terminal] {
            let rig = try await makeRig(runsIn: runsIn, startable: [.codex])
            defer { rig.context.cleanup() }
            #expect(start(rig) == nil)
            #expect(rig.told.notStarted == 1 && rig.told.cards.isEmpty)
            #expect(rig.host.newSessions.isEmpty && rig.sinks.requested == 0)
        }
    }

    @Test func aResumeGoesToTheFaceThePolicyNames() async throws {
        let id = UUID()
        let chat = try await makeRig(runsIn: .chat)
        defer { chat.context.cleanup() }
        var shown: [UUID] = []
        await chat.service.resume(sessionID: id, knownProvider: .claude, shown: { shown.append($0) })?.value
        #expect(chat.host.resumed == [id] && shown == [id] && chat.sinks.requested == 0)
        #expect(chat.service.transitions.busy[id] == nil)

        // In the terminal the runtime resumes it; a session it does not know fails there, and the sink is let go.
        let terminal = try await makeRig(runsIn: .terminal)
        defer { terminal.context.cleanup() }
        await terminal.service.resume(sessionID: id, knownProvider: .claude, shown: { shown.append($0) })?.value
        #expect(terminal.host.resumed.isEmpty && terminal.sinks.requested == 1 && terminal.sinks.failed == 1)
        #expect(terminal.told.failures == [.resumeFailed] && shown == [id])
        #expect(terminal.service.transitions.busy[id] == nil)
    }

    /// A Stop during a Chat-face Resume ends the resume's wait, with the face's stopping error or, by the order the face's
    /// actors ran in, as a start that failed: neither is a failure to report, and busy holds through the Stop (its process
    /// check) and is cleared after it, as for a plain Stop.
    @Test(arguments: [true, false])
    func aStopDuringAResumeReportsNothingAndBusyHoldsThroughTheStop(wordedAsStopping: Bool) async throws {
        let rig = try await makeRig(runsIn: .chat)
        defer { rig.context.cleanup() }
        // A real run, so the Stop has processes to check.
        await rig.service.start(provider: .claude, projectID: nil)?.value
        let id = try #require(rig.sinks.adopted.first?.sessionID)
        let gate = Gate()
        rig.host.resumeHold = (gate, wordedAsStopping ? HostStopping() as any Error : HostFailure())
        let resumeTask = rig.service.resume(sessionID: id, knownProvider: .claude, shown: { _ in })
        let resume = try #require(resumeTask)
        #expect(rig.service.transitions.busy[id] == .resuming)
        var afterResumeEnded: ConversationBusy?
        let stop = rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in
            // The Stop ended the resume's wait; the resume is over while the Stop has not released busy.
            gate.open()
            await resume.value
            afterResumeEnded = rig.service.transitions.busy[id]
        })
        #expect(rig.service.transitions.busy[id] == .stopping)
        await stop?.value
        // Never left waiting, whatever the Stop did.
        gate.open()
        await resume.value
        #expect(rig.host.resumed == [id])
        #expect(afterResumeEnded == .stopping, "the resume's end does not clear the Stop's busy")
        #expect(rig.told.failures.isEmpty, "a resume a Stop ended is not a failure")
        #expect(rig.service.transitions.busy[id] == nil)
        _ = await rig.context.runtime.shutdown()
    }

    @Test func aResumeIsRefusedWhileTheSessionIsBusyOrItsHarnessCannotStart() async throws {
        let rig = try await makeRig(startable: [.claude])
        defer { rig.context.cleanup() }
        let id = UUID()
        rig.service.transitions.setBusy(id, .stopping)
        #expect(rig.service.resume(sessionID: id, knownProvider: .claude, shown: { _ in }) == nil)
        #expect(rig.service.resume(sessionID: UUID(), knownProvider: .codex, shown: { _ in }) == nil)
        #expect(rig.host.resumed.isEmpty && rig.told.failures.isEmpty)
    }

    @Test func anApprovedOpeningGoesToTheFaceThePolicyNames() async throws {
        let request = UUID()
        let chat = try await makeRig(runsIn: .chat)
        defer { chat.context.cleanup() }
        await chat.service.approveOpen(requestID: request)?.value
        #expect(chat.host.opened.map(\.request) == [request] && chat.sinks.requested == 0)

        // In the terminal the runtime answers; a request it does not hold is a banner, and the sink is let go.
        let terminal = try await makeRig(runsIn: .terminal)
        defer { terminal.context.cleanup() }
        await terminal.service.approveOpen(requestID: request)?.value
        #expect(terminal.host.opened.isEmpty && terminal.sinks.requested == 1 && terminal.sinks.failed == 1)
        #expect(terminal.told.failures == [.openRequestNotAnswered])
    }

    @Test func anApprovedManagedTaskDoesNotAllocateOrRetainATerminalSink() async throws {
        let rig = try await makeRig(runsIn: .chat, extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                    scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { rig.context.cleanup() }
        do {
        let folder = rig.context.root.appendingPathComponent("service-task", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await rig.context.catalog.addProject(path: folder.path).project
        let parent = try await rig.context.runtime.startConversation(provider: .claude, projectID: project.id)
        let claim = try #require(await rig.context.runtime.taskRunPlans[parent.sessionID]?.claim)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while await rig.context.runtime.authenticateTaskRun(claim) == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.context.runtime.authenticateTaskRun(claim) != nil)
        let taskID = UUID()
        var request = SessionTaskWireRequest(command: "create", sessionID: claim.sessionID, runID: claim.managedRunID,
                                             generation: claim.generation, credential: claim.credential, taskID: taskID)
        request.operationID = UUID(); request.name = "Task child"; request.harness = "codex"; request.message = "Inspect"
        #expect(await rig.context.runtime.submitTaskRequest(request).status == "pending")
        let childID = try #require(await rig.context.runtime.openRequestSnapshot().first?.task?.childID)
        await rig.service.approveOpen(requestID: taskID, provider: .codex)?.value
        #expect(rig.host.opened.isEmpty)
        #expect(rig.sinks.requested == 0 && rig.sinks.adopted.isEmpty && rig.sinks.captured.isEmpty)
        #expect((await rig.context.supervisor.session(id: childID))?.currentRun != nil)
        } catch {
            _ = await rig.context.runtime.shutdown()
            throw error
        }
        #expect((await rig.context.runtime.shutdown()).succeeded)
    }

    @Test func anApprovedPeerSendDoesNotOpenAChildOrRequireAStartableHarness() async throws {
        let rig = try await makeRig(runsIn: .chat, startable: [], claudeVersion: "2.0.0")
        defer { rig.context.cleanup() }
        let folder = rig.context.root.appendingPathComponent("service-peer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await rig.context.catalog.addProject(path: folder.path).project
        let sender = try await rig.context.runtime.startConversation(provider: .claude, projectID: project.id)
        let target = try await rig.context.runtime.startConversation(provider: .claude, projectID: project.id)
        let claim = try #require(await rig.context.runtime.taskRunPlans[sender.sessionID]?.claim)
        let targetClaim = try #require(await rig.context.runtime.taskRunPlans[target.sessionID]?.claim)
        let runtime = rig.context.runtime
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            let first = await runtime.authenticateTaskRun(claim)
            let second = await runtime.authenticateTaskRun(targetClaim)
            if first != nil && second != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await runtime.authenticateTaskRun(claim) != nil)
        #expect(await runtime.authenticateTaskRun(targetClaim) != nil)
        let id = UUID()
        var call = SessionTaskWireRequest(command: "peer-send", sessionID: claim.sessionID, runID: claim.managedRunID,
                                          generation: claim.generation, credential: claim.credential)
        call.operationID = id; call.targetSessionID = target.sessionID; call.message = "Review this"
        let reply = Task { await rig.context.runtime.submitPeerSend(call) }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await runtime.openRequestSnapshot().contains(where: { $0.id == id }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await runtime.openRequestSnapshot().contains { $0.id == id })
        await rig.service.approveOpen(requestID: id, provider: .claude)?.value
        #expect(await reply.value.status == "sent")
        #expect(rig.host.opened.isEmpty && rig.sinks.requested == 0)
        #expect(try await rig.context.catalog.sessions().count == 2)
        #expect(try await rig.context.runtime.sessionMailboxHasUnread(sessionID: target.sessionID))
        #expect((await rig.context.runtime.shutdown()).succeeded)
    }

    @Test func anApprovalCannotUseAnotherHarnessGateToStartDisabledCodex() async throws {
        let rig = try await makeRig(runsIn: .terminal, startable: [.claude])
        defer { rig.context.cleanup() }
        let folder = rig.context.root.appendingPathComponent("approval-owner", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await rig.context.catalog.addProject(path: folder.path).project
        let requester = try await rig.context.runtime.startConversation(provider: .claude, projectID: project.id)
        let hooks = try #require(await rig.context.runtime.hookConfiguration)
        let socket = try #require(hooks.controlSocketPath)
        let wire = OpenSessionWireRequest(authenticationToken: hooks.authenticationToken, sessionID: requester.sessionID,
            managedRunID: requester.runID, title: "Codex", project: nil, message: "go", harness: "codex")
        let reply = Task.detached { try OpenSessionClient.exchange(wire, socketPath: socket) }
        let runtime = rig.context.runtime
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while await runtime.openRequestSnapshot().isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await runtime.openRequestSnapshot().count == 1)
        let pending = try #require(await rig.context.runtime.openRequestSnapshot().first)
        // The legacy caller supplies its default Claude gate, but the server-owned request says Codex.
        await rig.service.approveOpen(requestID: pending.id)?.value
        let after = await rig.context.runtime.openRequestSnapshot()
        #expect(after.first?.phase == .waiting)
        #expect(try await rig.context.catalog.sessions().count == 1)
        #expect(rig.told.failures == [.openRequestNotAnswered])
        if after.first != nil { try await rig.context.runtime.denyOpenRequest(pending.id) }
        _ = try await reply.value
        #expect((await rig.context.runtime.shutdown()).succeeded)
    }

    @Test func aSecondApprovalOfTheSameRequestIsRefusedWhileTheFirstRuns() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let gate = Gate()
        rig.host.script = .holdBeforeReady(gate)
        let request = UUID()
        let first = rig.service.approveOpen(requestID: request)
        #expect(first != nil && rig.service.approveOpen(requestID: request) == nil)
        gate.open()
        await first?.value
        #expect(rig.host.opened.count == 1)
        await rig.service.approveOpen(requestID: request)?.value
        #expect(rig.host.opened.count == 2)
    }

    // MARK: Start keys

    @Test func aSecondStartOfTheSameKeyIsRefusedWhileTheFirstRuns() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let gate = Gate()
        rig.host.script = .holdBeforeReady(gate)
        let project = UUID()
        let first = start(rig, projectID: project)
        let key = StartKey(provider: .claude, projectID: project)
        #expect(first != nil && rig.service.transitions.startingKeys == [key])
        // Another project's start is its own key.
        let other = start(rig, projectID: UUID())
        #expect(other != nil)

        #expect(start(rig, projectID: project) == nil)
        #expect(rig.told.notStarted == 1)

        gate.open()
        await first?.value
        await other?.value
        #expect(rig.host.newSessions.count == 2)
        #expect(rig.service.transitions.startingKeys.isEmpty && rig.service.transitions.preparingStarts.isEmpty)
        #expect(start(rig, projectID: project) != nil)
    }

    // MARK: Failures

    /// The unified log, read back as a diagnostics export reads it: one error in `Session` with the session's ref and the
    /// error's category, and nothing of the message or of the error's payload.
    @Test func aStartThatFailsWritesOneSessionErrorWithItsRefAndCategoryAndNoContent() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let since = Date()
        rig.host.script = .failBeforeReady(LoomError.message("/Users/someone/Secret Project/prompt words"))
        await rig.service.startSession(projectID: nil, launch: NewSessionLaunch(firstMessage: "my private first message"),
                                       cardCreated: { rig.told.card($0) }, notStarted: { rig.told.none() })?.value
        let session = try #require(rig.host.newSessions.first?.session)
        let ref = LoomLog.ref(session)
        #expect(ref.count == 10 && ref.hasPrefix("s:"))
        let lines = try await LogReadBack.lines(category: .session, since: since, containing: ref)
        let errors = lines.filter { $0.level == .error }
        #expect(errors.count == 1, "lines: \(lines.map(\.message))")
        let line = try #require(errors.first?.message)
        #expect(line.contains("Start \(ref) (chat) failed"))
        #expect(line.contains("LoomError.message"))
        for content in ["Secret", "/Users", "prompt words", "private first message"] {
            #expect(!line.contains(content), "\(content) in: \(line)")
        }
    }

    // MARK: Stop

    @Test func busyHoldsThroughAStopAndIsClearedAfterIt() async throws {
        let rig = try await makeRig(runsIn: .terminal)
        defer { rig.context.cleanup() }
        await start(rig)?.value
        let launch = try #require(rig.sinks.adopted.first)
        let id = launch.sessionID
        #expect(rig.service.transitions.busy[id] == nil)

        var during: ConversationBusy?
        var secondRefused = false
        var verified = false
        var run: UUID?
        let task = rig.service.stop(sessionID: id, liveRunID: nil, settled: { outcome in
            // The terminal settled first; busy still holds while the UI decides about the tab.
            during = rig.service.transitions.busy[id]
            secondRefused = rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in }) == nil
            verified = outcome.report.succeeded
            run = outcome.run
        })
        #expect(rig.service.transitions.busy[id] == .stopping)
        await task?.value
        #expect(during == .stopping && secondRefused && verified)
        #expect(run == launch.runID && rig.sinks.captured == [launch.runID] && rig.sinks.released == [launch.runID])
        // The screen is kept before any signal, and the surfaces settle before the UI is told.
        #expect(rig.sinks.order == ["adopt", "capture", "reconcile"])
        #expect(rig.service.transitions.busy[id] == nil)
        _ = await rig.context.runtime.shutdown()
    }

    @Test func busyIsClearedAfterAStopThatFailed() async throws {
        let rig = try await makeRig(runsIn: .terminal)
        defer { rig.context.cleanup() }
        let id = UUID()
        var settled = false
        let task = rig.service.stop(sessionID: id, liveRunID: UUID(), settled: { _ in settled = true })
        #expect(rig.service.transitions.busy[id] == .stopping)
        await task?.value
        // A session the runtime does not know cannot be stopped: a banner, no verdict, and the capture is let go.
        #expect(!settled && rig.told.failures == [.stopFailed])
        #expect(rig.service.transitions.busy[id] == nil)
        #expect(rig.sinks.released.count == 1)
        // And it may be stopped again.
        #expect(rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in }) != nil)
    }

    // MARK: Handover (Chat → terminal)

    @Test func aMoveIsRefusedWithoutAStructuredFaceAndAResumeIsRefusedDuringAMove() async throws {
        let none = try await makeRig(host: false)
        defer { none.context.cleanup() }
        #expect(handOver(none, UUID()) == nil)
        #expect(none.service.transitions.handovers.isEmpty)

        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        rig.host.move = .waits
        let task = handOver(rig, id)
        #expect(rig.service.resume(sessionID: id, knownProvider: .claude, shown: { _ in }) == nil)
        #expect(rig.service.transitions.busy[id] == nil && rig.host.resumed.isEmpty)
        // A busy session is not moved either.
        let busy = UUID()
        rig.service.transitions.setBusy(busy, .resuming)
        #expect(handOver(rig, busy) == nil)
        rig.service.cancelHandover(sessionID: id)
        await task?.value
        // Once the move is over the session resumes again.
        #expect(rig.service.resume(sessionID: id, knownProvider: .claude, shown: { _ in }) != nil)
    }

    // MARK: The session's own record

    @Test func renameAndPinGoThroughTheCatalogOfTheRuntime() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let session = ManagedSession(provider: .claude, providerConversationID: "titled-1", workingDirectory: rig.context.home.path)
        try await rig.context.supervisor.createSession(session)
        try await rig.service.renameSession(sessionID: session.id, to: "  Mine  ")
        try await rig.service.setPinned(sessionID: session.id, true)
        let record = try #require(try await rig.context.catalog.session(id: session.id))
        #expect(record.title == "Mine" && record.pinned)
        try await rig.service.setPinned(sessionID: session.id, false)
        #expect(try await rig.context.catalog.session(id: session.id)?.pinned == false)
        await #expect(throws: SessionCatalogError.self) { try await rig.service.renameSession(sessionID: UUID(), to: "x") }
    }

    // MARK: Answers

    @Test func anAnswerTheRuntimeCannotTakeIsABannerOnce() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        await rig.service.answer(sessionID: UUID(), requestID: "none", accept: true).value
        #expect(rig.told.failures == [.answerNotDelivered])
        await rig.service.denyOpen(requestID: UUID()).value
        await rig.service.dismissOpen(requestID: UUID()).value
        #expect(rig.told.failures == [.answerNotDelivered, .openRequestNotDenied, .openRequestNotDismissed])
    }

    // MARK: Side chats (D-72)
}
