import Foundation
import Testing
@testable import LoomCore

/// R5a: the session service owns the lifecycle's orchestration and its transition state. Both faces are fakes (a structured
/// host that records what it was asked and a terminal that hands out sinks); the runtime is the real one over the fake
/// provider, so a terminal run and its Stop are real. Nothing waits on a clock: each test awaits the task an operation returns.

private struct HostFailure: Error {}
private struct HostStopping: Error {}

@MainActor
private final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }
}

@MainActor
private final class FakeHost: StructuredFaceHost {
    enum Script {
        /// Ready, then done.
        case ready
        /// Fails before Ready with this error.
        case failBeforeReady(any Error)
        /// Ready, then fails (a first message that went wrong).
        case failAfterReady
        /// Ready, then waits for the gate.
        case readyThenHold(Gate)
        /// Waits for the gate before Ready.
        case holdBeforeReady(Gate)
    }

    var script = Script.ready
    private(set) var newSessions: [(project: UUID?, session: UUID, draft: NewSessionLaunch?)] = []
    private(set) var opened: [(request: UUID, session: UUID)] = []
    private(set) var resumed: [UUID] = []
    private(set) var forgotten: [UUID] = []

    func beginNewSession(projectID: UUID?, sessionID: UUID, draft: NewSessionLaunch?,
                         onReady: (@Sendable () async -> Void)?) async throws {
        newSessions.append((projectID, sessionID, draft))
        try await run(onReady)
    }

    func beginOpenedSession(requestID: UUID, sessionID: UUID, onReady: (@Sendable () async -> Void)?) async throws {
        opened.append((requestID, sessionID))
        try await run(onReady)
    }

    private func run(_ onReady: (@Sendable () async -> Void)?) async throws {
        switch script {
        case .ready:
            await onReady?()
        case let .failBeforeReady(error):
            throw error
        case .failAfterReady:
            await onReady?()
            throw HostFailure()
        case let .readyThenHold(gate):
            await onReady?()
            await gate.wait()
        case let .holdBeforeReady(gate):
            await gate.wait()
            await onReady?()
        }
    }

    /// Held by `resumeSession` until it opens, then thrown (a Stop that ended the wait for `initialize`).
    var resumeHold: (gate: Gate, error: any Error)?

    func resumeSession(sessionID: UUID) async throws {
        resumed.append(sessionID)
        guard let resumeHold else { return }
        await resumeHold.gate.wait()
        throw resumeHold.error
    }

    func forget(sessionID: UUID) { forgotten.append(sessionID) }

    func errorKind(of error: any Error) -> StructuredFaceErrorKind {
        if error is HostStopping { return .stopping }
        return error is HostFailure ? .failure : .other
    }

    // The move to the terminal.
    enum Move {
        /// Passes the point of no return, ends the run and answers the card it ended on.
        case moves(card: UUID)
        /// Waits for a Cancel, then throws `CancellationError` (the Chat face's wait).
        case waits
        /// Refuses before the point of no return.
        case refuses(any Error)
        /// Passes the point of no return, then fails.
        case failsAfterPoint(any Error)
    }

    var move = Move.waits
    private let cancel = Gate()
    private(set) var moveBegan: [UUID] = []
    private(set) var cancelled: [UUID] = []
    private(set) var movesFailed: [UUID] = []
    private(set) var continuedInTerminal: [UUID] = []
    private(set) var finished: [UUID] = []

    func handOverToTerminal(sessionID: UUID, pointOfNoReturn: @escaping @Sendable () async -> Void) async throws -> UUID {
        moveBegan.append(sessionID)
        switch move {
        case let .moves(card):
            await pointOfNoReturn()
            return card
        case .waits:
            await cancel.wait()
            throw CancellationError()
        case let .refuses(error):
            throw error
        case let .failsAfterPoint(error):
            await pointOfNoReturn()
            throw error
        }
    }

    func cancelHandover(sessionID: UUID) {
        cancelled.append(sessionID)
        cancel.open()
    }

    func handoverFailed(sessionID: UUID) async { movesFailed.append(sessionID) }
    func noteContinuedInTerminal(sessionID: UUID) async { continuedInTerminal.append(sessionID) }
    func finishHandover(sessionID: UUID) async { finished.append(sessionID) }
    func handoverRefusal(of error: any Error) -> HandoverRefusal? { error as? HandoverRefusal }

    // What a session's run is doing: set by the test, by id.
    var live: Set<UUID> = []
    var settled: Set<UUID> = []
    var handingOver: Set<UUID> = []
    var closeFailure: (any Error)?
    private(set) var closed: [UUID] = []

    func isLive(sessionID: UUID) async -> Bool { live.contains(sessionID) }
    func isLiveAndSettled(sessionID: UUID) async -> Bool { live.contains(sessionID) && settled.contains(sessionID) }
    func isHandingOver(sessionID: UUID) async -> Bool { handingOver.contains(sessionID) }

    func closeSession(sessionID: UUID) async throws {
        closed.append(sessionID)
        if let closeFailure { throw closeFailure }
        live.remove(sessionID)
    }
}

@MainActor
private final class FakeSinks: TerminalFaceSinks {
    private(set) var requested = 0
    private(set) var adopted: [RuntimeLaunch] = []
    private(set) var failed = 0
    private(set) var reconciles = 0
    private(set) var captured: [UUID] = []
    private(set) var released: [UUID] = []
    private(set) var order: [String] = []
    private let screen = SessionRuntimeTests.Screen()

    func newRunSink() -> TerminalRunSink? {
        requested += 1
        return TerminalRunSink(rows: 24, columns: 80, output: screen, handle: NSObject())
    }

    func adopt(_ launch: RuntimeLaunch, into sink: TerminalRunSink) {
        adopted.append(launch)
        screen.attach(launch.terminal)
        order.append("adopt")
    }

    func runFailedToStart(_ sink: TerminalRunSink) { failed += 1 }

    func reconcile() async {
        reconciles += 1
        order.append("reconcile")
    }

    func captureForStop(sessionID: UUID) -> UUID? {
        order.append("capture")
        guard let run = adopted.last?.runID else { return nil }
        captured.append(run)
        return run
    }

    func releaseStopCapture(run: UUID) { released.append(run) }
}

/// What the UI was told, in order.
@MainActor
private final class Told {
    private(set) var cards: [UUID] = []
    private(set) var notStarted = 0
    private(set) var failures: [SessionFailure.Kind] = []
    private(set) var failureErrors: [any Error] = []
    var events: [String] = []
    /// A side chat's Close that the rule's retirement could not do (parent, side chat).
    var closeFailed: [(UUID, UUID)] = []

    func failure(_ failure: SessionFailure) {
        failures.append(failure.kind)
        failureErrors.append(failure.error)
        events.append("failure")
    }

    func card(_ id: UUID) {
        cards.append(id)
        events.append("card")
    }

    func none() {
        notStarted += 1
        events.append("notStarted")
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
@MainActor
struct SessionServiceTests {
    private struct Rig {
        let context: RuntimeContext
        let service: SessionService
        let host: FakeHost
        let sinks: FakeSinks
        let told: Told
    }

    private func makeRig(runsIn: SessionLiveFace = .chat, host hasHost: Bool = true, startable: Set<ManagedSession.Provider> = [.claude, .codex],
                         extraEnvironment: [String: String] = [:], claudeVersion: String = "fake 1") async throws -> Rig {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: extraEnvironment, claudeVersion: claudeVersion)
        let host = FakeHost()
        let sinks = FakeSinks()
        let told = Told()
        let service = SessionService(runtime: context.runtime, startableProviders: startable, runsIn: runsIn,
                                     structuredHost: hasHost ? host : nil, terminal: sinks)
        service.failureHandler = { told.failure($0) }
        return Rig(context: context, service: service, host: host, sinks: sinks, told: told)
    }

    private func start(_ rig: Rig, projectID: UUID? = nil) -> Task<Void, Never>? {
        rig.service.startSession(projectID: projectID, launch: NewSessionLaunch(firstMessage: "hello"),
                                 cardCreated: { rig.told.card($0) }, notStarted: { rig.told.none() })
    }

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

    @Test func anApprovedTaskAlwaysUsesTheOwnedTerminalEvenWhenOrdinaryOpeningsUseChat() async throws {
        let rig = try await makeRig(runsIn: .chat, claudeVersion: "2.0.0")
        defer { rig.context.cleanup() }
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
        request.operationID = UUID(); request.name = "Task child"; request.harness = "claude"; request.message = "Inspect"
        #expect(await rig.context.runtime.submitTaskRequest(request).status == "pending")
        let childID = try #require(await rig.context.runtime.openRequestSnapshot().first?.task?.childID)
        await rig.service.approveOpen(requestID: taskID, provider: .claude)?.value
        #expect(rig.host.opened.isEmpty)
        #expect(rig.sinks.requested == 1 && rig.sinks.adopted.first?.sessionID == childID)
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

    @Test func theStructuredStartKeyIsReleasedAtReadyWhateverTheFirstMessageDoes() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let gate = Gate()
        rig.host.script = .readyThenHold(gate)
        let task = start(rig)
        // Ready was told, so the card exists and the next draft of the project may start while the message is still going.
        while rig.told.cards.isEmpty { await Task.yield() }
        #expect(rig.service.transitions.startingKeys.isEmpty)
        #expect(start(rig) != nil)
        gate.open()
        await task?.value
    }

    // MARK: Failures

    @Test func aStructuredStartThatFailsBeforeReadyForgetsItsSessionAndTellsOnce() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failBeforeReady(HostFailure())
        await start(rig)?.value
        let session = try #require(rig.host.newSessions.first?.session)
        #expect(rig.host.forgotten == [session])
        #expect(rig.told.failures == [.startFailed(.claude)] && rig.told.notStarted == 1 && rig.told.cards.isEmpty)
        // The banner comes before the draft is told, and the key is free again.
        #expect(rig.told.events == ["failure", "notStarted"])
        #expect(rig.service.transitions.startingKeys.isEmpty)
    }

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

    @Test func aStructuredStartThatFailsAfterReadyKeepsItsSessionAndOnlyReports() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failAfterReady
        await start(rig)?.value
        #expect(rig.host.forgotten.isEmpty && rig.told.cards.count == 1 && rig.told.notStarted == 0)
        #expect(rig.told.failures == [.startFailed(.claude)])
        #expect(rig.told.events == ["card", "failure"])
    }

    @Test func aStoppingCancellationReportsNothingAndKeepsTheOtherOutcome() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failBeforeReady(HostStopping())
        await start(rig)?.value
        #expect(rig.told.failures.isEmpty)
        #expect(rig.told.notStarted == 1 && rig.host.forgotten.isEmpty)
        #expect(rig.service.transitions.startingKeys.isEmpty)

        // The same in an approved opening.
        rig.host.script = .failBeforeReady(HostStopping())
        await rig.service.approveOpen(requestID: UUID())?.value
        #expect(rig.told.failures.isEmpty && rig.host.forgotten.isEmpty)
    }

    @Test func anApprovedOpeningThatFailedBeforeReadyForgetsItsSessionAndIsABanner() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        rig.host.script = .failBeforeReady(HostFailure())
        await rig.service.approveOpen(requestID: UUID())?.value
        #expect(rig.host.forgotten == [rig.host.opened[0].session])
        #expect(rig.told.failures == [.startFailed(.claude)])
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

    /// What the UI was told during a move, in order.
    private final class MoveLog {
        var events: [String] = []
    }

    private func handOver(_ rig: Rig, _ id: UUID, _ log: MoveLog = MoveLog()) -> Task<Void, Never>? {
        rig.service.handOver(
            sessionID: id, to: .terminal,
            terminalWillStart: { log.events.append("willStart:\($0 == id ? "same" : "card")") },
            shown: { _ in log.events.append("shown") },
            cleared: { log.events.append("cleared") }
        )
    }

    /// Lets the move's task begin and reach the face.
    private func untilTheFaceHasTheMove(_ rig: Rig, _ id: UUID) async {
        while !rig.host.moveBegan.contains(id) { await Task.yield() }
    }

    @Test func aCancelBeforeThePointEndsTheMoveAndTheFaceIsToldItIsOver() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .waits
        let task = handOver(rig, id, log)
        #expect(rig.service.transitions.handovers[id] == Handover(target: .terminal, phase: .waiting))
        // A second move of the same session is refused while one is under way.
        #expect(handOver(rig, id) == nil)

        rig.service.cancelHandover(sessionID: id)
        await task?.value
        #expect(rig.host.cancelled == [id])
        // Nothing moved, nothing failed, nothing was told to the UI; the face is its own again.
        #expect(log.events.isEmpty && rig.told.failures.isEmpty && rig.sinks.requested == 0)
        #expect(rig.host.movesFailed.isEmpty, "the run did not end for a move")
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aCancelAtThePointOfNoReturnDoesNothing() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let gate = Gate()
        var reached: [SessionLiveFace] = []
        rig.service.handoverGate = { _, target in
            reached.append(target)
            await gate.wait()
        }
        rig.host.move = .failsAfterPoint(HostFailure())
        let task = handOver(rig, id)
        await untilTheFaceHasTheMove(rig, id)
        while reached.isEmpty { await Task.yield() }
        #expect(rig.service.transitions.handovers[id]?.phase == .switching)
        rig.service.cancelHandover(sessionID: id)
        #expect(rig.host.cancelled.isEmpty, "Cancel is not offered after the point")
        #expect(rig.service.transitions.handovers[id]?.phase == .switching)
        gate.open()
        await task?.value
        // The run ended for a move that did not happen: the face is told, and the failure is a banner.
        #expect(rig.host.movesFailed == [id] && rig.told.failures == [.handoverFailed])
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aStopEndsAWaitingMove() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .waits
        let task = handOver(rig, id, log)
        let stop = rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in })
        #expect(rig.host.cancelled == [id], "the Stop ended the wait")
        await task?.value
        await stop?.value
        #expect(log.events.isEmpty && !rig.told.failures.contains(.handoverFailed))
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aStopAtThePointOfNoReturnStopsTheTerminalStart() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        let gate = Gate()
        var reached = false
        rig.service.handoverGate = { _, _ in
            reached = true
            await gate.wait()
        }
        rig.host.move = .moves(card: id)
        let task = handOver(rig, id, log)
        while !reached { await Task.yield() }
        let stop = rig.service.stop(sessionID: id, liveRunID: nil, settled: { _ in })
        gate.open()
        await task?.value
        await stop?.value
        // The terminal never started: no look at it, no sink, no run; the Chat run that ended is told it was interrupted.
        #expect(log.events.isEmpty && rig.sinks.requested == 0 && rig.host.continuedInTerminal.isEmpty)
        #expect(rig.host.movesFailed == [id])
        #expect(!rig.told.failures.contains(.handoverFailed), "a move the user ended is not a failure")
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
    }

    @Test func aStopOfTheCardAClearMovedTheRunToStopsTheTerminalStartToo() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID(), card = UUID()
        let log = MoveLog()
        let gate = Gate()
        var reached = false
        rig.service.handoverGate = { _, _ in
            reached = true
            await gate.wait()
        }
        rig.host.move = .moves(card: card)
        let task = handOver(rig, id, log)
        while !reached { await Task.yield() }
        rig.service.transitions.setBusy(card, .stopping)
        gate.open()
        await task?.value
        rig.service.transitions.setBusy(card, nil)
        #expect(log.events.isEmpty && rig.sinks.requested == 0)
        #expect(rig.host.movesFailed == [id] && rig.told.failures.isEmpty)
        #expect(rig.host.finished == [id])
    }

    @Test func aMoveThatSucceedsLooksAtTheTerminalFirstThenResumesTheCardTheRunEndedOn() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        // The card the run ended on is a session the runtime can resume (a `/clear` made it).
        let session = ManagedSession(provider: .claude, providerConversationID: "moved-1", workingDirectory: rig.context.home.path)
        try await rig.context.supervisor.createSession(session)
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .moves(card: session.id)
        await handOver(rig, id, log)?.value
        #expect(log.events == ["willStart:card", "shown"])
        #expect(rig.sinks.adopted.map(\.sessionID) == [session.id])
        #expect(rig.host.continuedInTerminal == [id], "the face notes it on the session the move began on")
        #expect(rig.host.movesFailed.isEmpty && rig.told.failures.isEmpty)
        #expect(rig.host.finished == [id] && rig.service.transitions.handovers[id] == nil)
        _ = await rig.context.runtime.shutdown()
    }

    @Test func aRefusalIsABannerInTheWordsOfTheRefusal() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        for refusal in [HandoverRefusal.requestWaiting, .backgroundWork, .busy] {
            let id = UUID()
            rig.host.move = .refuses(refusal)
            await handOver(rig, id)?.value
            #expect(rig.host.finished.last == id && rig.service.transitions.handovers[id] == nil)
        }
        #expect(rig.told.failures == [.handoverFailed, .handoverFailed, .handoverFailed])
        let words = rig.told.failureErrors.map { ($0 as? HandoverRefusal)?.description }
        #expect(words == [HandoverRefusal.requestWaiting, .backgroundWork, .busy].map(\.description))
        #expect(rig.host.movesFailed.isEmpty, "a refusal comes before the point: no run ended")
        // Any other error is reported as it is.
        rig.host.move = .refuses(HostFailure())
        await handOver(rig, UUID())?.value
        #expect(rig.told.failureErrors.last is HostFailure)
    }

    @Test func aClearDuringTheWaitIsAnInfoNotAFailure() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        let id = UUID()
        let log = MoveLog()
        rig.host.move = .refuses(HandoverRefusal.cleared)
        await handOver(rig, id, log)?.value
        #expect(log.events == ["cleared"] && rig.told.failures.isEmpty)
        #expect(rig.host.finished == [id])
    }

    @Test func theFaceIsToldTheMoveIsOverWhateverTheResult() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        // The terminal cannot start (the runtime does not know the card): the run ended for nothing, the banner says so.
        let id = UUID(), card = UUID()
        rig.host.move = .moves(card: card)
        await handOver(rig, id)?.value
        #expect(rig.told.failures == [.handoverFailed])
        #expect(rig.host.finished == [id] && rig.host.continuedInTerminal.isEmpty)
        #expect(rig.service.transitions.handovers[id] == nil)
    }

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

    @Test func theOtherDirectionIsNotAMove() async throws {
        let rig = try await makeRig()
        defer { rig.context.cleanup() }
        #expect(rig.service.handOver(sessionID: UUID(), to: .chat, terminalWillStart: { _ in }, shown: { _ in }, cleared: {}) == nil)
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

    private func sideChatRig() async throws -> (rig: Rig, parent: UUID, side: UUID) {
        (try await makeRig(), UUID(), UUID())
    }

    @Test func anIdleSideChatThatIsNoLongerOpenIsStoppedAtOnceAndOneThatIsStillOpenIsNot() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.host.settled = [side]
        rig.service.sideChatShown(side, in: parent)
        // Asked while it is the open one: nothing to retire.
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed.isEmpty)
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed == [side])
    }

    @Test func aBusySideChatIsStoppedOnlyOnceItHasSettled() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.service.sideChatShown(side, in: parent)
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed.isEmpty, "a running turn or a waiting card is not cut")
        // Read while still busy: nothing yet, and it keeps waiting.
        await rig.service.sideChatRead(side, in: parent)?.value
        #expect(rig.host.closed.isEmpty)
        rig.host.settled = [side]
        let read = rig.service.sideChatRead(side, in: parent)
        await read?.value
        #expect(rig.host.closed == [side])
        // Done: later reads have nothing to do.
        #expect(rig.service.sideChatRead(side, in: parent) == nil)
    }

    @Test func aSideChatOpenedAgainBeforeItSettledStays() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.service.sideChatShown(side, in: parent)
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        rig.service.sideChatShown(side, in: parent)
        rig.host.settled = [side]
        #expect(rig.service.sideChatRead(side, in: parent) == nil)
        #expect(rig.host.closed.isEmpty)
        // And the flag is gone for good: it is retired again only by being left again.
        rig.service.sideChatShown(nil, in: parent)
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed == [side])
    }

    @Test func theParentsStopRetiresTheOpenSideChatToo() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        let other = UUID()
        rig.host.live = [side, other]
        rig.host.settled = [side, other]
        rig.service.sideChatShown(side, in: parent)
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side, other])
        #expect(Set(rig.host.closed) == [side, other], "the open one is retired as well")
    }

    @Test func aBusySideChatThatTheParentsStopRetiredIsNotSavedByOpeningItAgain() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.service.sideChatShown(side, in: parent)
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed.isEmpty, "not cut while its turn runs")
        // Reopened (or never left): still the parent's stop.
        rig.service.sideChatShown(side, in: parent)
        rig.host.settled = [side]
        await rig.service.sideChatRead(side, in: parent)?.value
        #expect(rig.host.closed == [side])
    }

    @Test func aRunThatEndedInAMoveToTheTerminalIsNotAParentStop() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.live = [side]
        rig.host.settled = [side]
        rig.host.handingOver = [parent]
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        rig.host.handingOver = []
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed == [side])
    }

    @Test func aRunThatMovedOffItsCardByAClearAndEndedInAMoveIsNotAParentStopEither() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        let runCard = UUID()
        rig.host.live = [side]
        rig.host.settled = [side]
        // The side chats were forked from `parent`; after a `/clear` its run is on `runCard`, which is the one being moved.
        rig.host.handingOver = [runCard]
        await rig.service.parentRunEnded(parent, runCard: runCard, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        // The same parent whose run card is not being moved was stopped.
        await rig.service.parentRunEnded(parent, runCard: UUID(), sideChats: [side])
        #expect(rig.host.closed == [side])
    }

    /// Told late, after the face let go of its handover state: a move is still not a stop, while the service's own move is
    /// under way or once the card's terminal run is live.
    @Test func aRunEndToldAfterTheFaceLetGoOfTheMoveIsStillNotAParentStop() async throws {
        let rig = try await makeRig(runsIn: .chat)
        defer { rig.context.cleanup() }
        await rig.service.start(provider: .claude, projectID: nil)?.value
        let card = try #require(rig.sinks.adopted.first?.sessionID)
        let side = UUID()
        rig.host.live = [side]
        rig.host.settled = [side]
        // The terminal runs the card (the move is done): nothing retires.
        await rig.service.parentRunEnded(card, runCard: card, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        let stopTask = rig.service.stop(sessionID: card, liveRunID: nil, settled: { _ in })
        await stopTask?.value
        // The service's move is still under way: nothing retires either.
        rig.service.transitions.setHandover(Handover(target: .terminal, phase: .switching), for: card)
        await rig.service.parentRunEnded(card, runCard: card, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        // No move and no run: a stop.
        rig.service.transitions.setHandover(nil, for: card)
        await rig.service.parentRunEnded(card, runCard: card, sideChats: [side])
        #expect(rig.host.closed == [side])
        _ = await rig.context.runtime.shutdown()
    }

    @Test func aSideChatWithNoLiveRunIsLeftAlone() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        rig.host.settled = [side]
        await rig.service.sideChatLeft(side, in: parent)
        await rig.service.parentRunEnded(parent, runCard: parent, sideChats: [side])
        #expect(rig.host.closed.isEmpty)
        // Nothing was kept for it: when a later run settles, no read ends it.
        rig.host.live = [side]
        #expect(rig.service.sideChatRead(side, in: parent) == nil)
        #expect(rig.host.closed.isEmpty)
    }

    @Test func aRetirementThatCouldNotStopTheSideChatIsToldToTheUI() async throws {
        let (rig, parent, side) = try await sideChatRig()
        defer { rig.context.cleanup() }
        let told = Told()
        rig.service.sideChatCloseFailed = { parent, side, _ in told.closeFailed.append((parent, side)) }
        rig.host.live = [side]
        rig.host.settled = [side]
        rig.host.closeFailure = HostFailure()
        await rig.service.sideChatLeft(side, in: parent)
        #expect(rig.host.closed == [side] && told.closeFailed.count == 1 && told.closeFailed[0] == (parent, side))
        // The user's own Close answers its caller.
        #expect(await rig.service.closeSideChat(side) is HostFailure)
        #expect(told.closeFailed.count == 1)
        rig.host.closeFailure = nil
        #expect(await rig.service.closeSideChat(side) == nil)
    }
}
