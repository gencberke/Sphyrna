import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private extension SessionRuntime {
    func codexSocketForTest(runID: UUID) -> String? { runs[runID]?.server?.socket }
}

private actor RuntimeCodexSetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var installations = 0
    private var released = false
    /// Holds the first conversation's coordinator installation only; every
    /// other conversation installs its own coordinator without waiting.
    func observe(_ phase: SessionRuntime.CodexSetupPhase) async {
        switch phase {
        case .installing:
            installations += 1
            if installations == 1 && !released {
                await withCheckedContinuation { continuation = $0 }
            }
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Uses the existing ownership-sampling test boundary after provider prepare.
/// The pause (the supervisor actor frozen until the test releases it) lets the
/// real fixture TUI submit one late turn before the supervisor signals it; no
/// production timing hook is added.
private final class RuntimeCodexLateTurnGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = ActorFreezeGate()
    private var reached = false
    var hasEntered: Bool { gate.entered }
    func pauseOnce() {
        let first = lock.withLock { if reached { return false }; reached = true; return true }
        guard first else { return }
        gate.hold()
    }
    func release() { gate.release() }
}

/// CP5 C for Codex: the production runtime, the per-conversation app-server managers, the
/// coordinator and adapters, against a fixture app-server and TUI.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionRuntimeCodexTests {
    typealias Screen = SessionRuntimeRig.Screen

    /// A wait that follows a process start (an app-server, a TUI, a run host) in a test that may run beside every other
    /// process-heavy suite: long enough for such a start under that load, still far inside the suite's time limit.
    static let processStartWait: TimeInterval = 30

    static func launchCodex(
        _ context: RuntimeContext, projectID: UUID? = nil
    ) async throws -> (RuntimeLaunch, Screen) {
        let screen = Screen()
        let launch = try await context.runtime.startConversation(
            provider: .codex, projectID: projectID, outputSink: screen
        )
        screen.attach(launch.terminal)
        return (launch, screen)
    }

    static func serverSocket(_ context: RuntimeContext, runID: UUID) async throws -> URL {
        let path = try #require(await context.runtime.codexSocketForTest(runID: runID))
        return URL(fileURLWithPath: path)
    }

    static func project(_ context: RuntimeContext, _ name: String) async throws -> CatalogProject {
        let folder = context.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await context.catalog.addProject(path: folder.path).project
    }

    func threadID(_ context: RuntimeContext, _ sessionID: UUID) async throws -> String? {
        try await context.catalog.session(id: sessionID)?.session.providerConversationID
    }

    func joinLog(_ context: RuntimeContext) -> [String] {
        ((try? String(contentsOf: context.state.appendingPathComponent("codex-joins.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    @Test func bootstrapJoinExcludesTurnsInsteadOfLoadingTheHistory() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains { $0.hasPrefix("joined ") } })
        let joins = joinLog(context).filter { $0.hasPrefix("join ") }
        #expect(joins.count == 1 && joins[0].hasSuffix(" excludeTurns,threadId"))
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func stopAndQuitDoNotRemoveAReplacedSocketPath() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        let path = try await Self.serverSocket(context, runID: launch.runID)
        try FileManager.default.removeItem(at: path)
        try "foreign replacement".write(to: path, atomically: true, encoding: .utf8)
        let stop = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!stop.succeeded)
        #expect((try? String(contentsOf: path, encoding: .utf8)) == "foreign replacement")
        let quit = await context.runtime.shutdown()
        #expect(!quit.succeeded)
        #expect((try? String(contentsOf: path, encoding: .utf8)) == "foreign replacement")
    }

    @Test func anAbnormalServerExitRemovesOnlyItsVerifiedUnboundSocket() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_LEAVE_SOCKET": "1"])
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        let path = try await Self.serverSocket(context, runID: launch.runID)
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [false, true])
    func quitCleansAnAbnormalServerSocketAfterTheTUIStops(active: Bool) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_LEAVE_SOCKET": "1"])
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        try await screen.send(active ? "work 10000" : "work 5")
        if active {
            #expect(await SessionRuntimeRig.waitUntil { await context.events.snapshot().sessions[launch.sessionID]?.status?.activity == .working })
        } else {
            #expect(await screen.contains("CODEX-TURN-DONE completed echo work 5"))
        }
        let path = try await Self.serverSocket(context, runID: launch.runID)
        let result = await context.runtime.shutdown()
        if !result.succeeded { print("Abnormal socket Quit errors: \(result.errors)") }
        #expect(result.succeeded)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(await context.supervisor.runContext(runID: launch.runID) == nil)
    }

    @Test(arguments: ["wrong", "missing", "error"])
    func failedJoinIsVisibleOnlyOnItsOwnCard(mode: String) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": mode])
        defer { context.cleanup() }
        let (first, _) = try await Self.launchCodex(context)
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[first.sessionID]?.issue?.contains("subscription failed") == true
        })
        let firstIssue = await context.events.snapshot().sessions[first.sessionID]?.issue
        let (sibling, _) = try await Self.launchCodex(context)
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.issue?.contains("subscription failed") == true
        })
        #expect(await context.events.snapshot().sessions[first.sessionID]?.issue == firstIssue)
        #expect(joinLog(context).filter { $0.hasPrefix("join ") }.allSatisfy { $0.hasSuffix(" excludeTurns,threadId") })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func requestBeforeJoinResponseAndDuplicateStartedPreservePendingState() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": "before-response"])
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1
        })
        let coordinator = try #require(await context.runtime.codexCoordinator)
        let pending = try #require(await coordinator.pendingRequestSnapshot().pending.first)
        try await coordinator.bindResume(sessionID: launch.sessionID, managedRunID: launch.runID,
            threadID: pending.binding.threadID, workingDirectory: pending.binding.workingDirectory)
        #expect(await coordinator.pendingRequestSnapshot().pending.map(\.id) == [pending.id])
        #expect(joinLog(context).filter { $0.hasPrefix("join ") }.count == 1)
        #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .waitingForApproval)
        try await coordinator.respond(to: pending, result: .object(["decision": .string("accept")]))
        await #expect(throws: CodexAppServerError.self) {
            try await coordinator.respond(to: pending, result: .object(["decision": .string("accept")]))
        }
        #expect((await context.runtime.shutdown()).succeeded)
        let decisions = try String(contentsOf: context.state.appendingPathComponent("codex-approvals.log"), encoding: .utf8)
        #expect(decisions.split(separator: "\n").count == 1)
    }

    @Test(arguments: ["blank", "blank-no-replay", "blank-always"])
    func blankJoinDoesNotBlockTerminalAndRetriesOnlyOnBoundedTransitions(mode: String) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": mode])
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).filter { $0.hasPrefix("join ") }.count == 1 })
        // A retry needs a thread status that changed to active after the last attempt. How many of one turn's
        // statuses fall into an attempt that is still under way depends on timing, so "blank-always" is fed turns
        // (each one idle, then active) until the bound is reached, and not one prompt that must give exactly three.
        let workDone = "CODEX-TURN-DONE completed echo work 5"
        func turnsDone() -> Int { screen.snapshot.components(separatedBy: workDone).count - 1 }
        func joins() -> Int { joinLog(context).filter { $0.hasPrefix("join ") }.count }
        try await screen.send(mode == "blank-always" ? "work 5" : "approve first")
        if mode == "blank" {
            #expect(await SessionRuntimeRig.waitUntil {
                await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1
            })
        } else if mode == "blank-always" {
            var turns = 1
            while turns < 8 {
                #expect(await SessionRuntimeRig.waitUntil(20) { turnsDone() >= turns })
                if joins() >= 3 { break }
                try await screen.send("work 5")
                turns += 1
            }
            #expect(await SessionRuntimeRig.waitUntil(20) {
                await context.events.snapshot().sessions[launch.sessionID]?.issue?.contains("subscription failed (rpc, RPC -32600)") == true
            })
            #expect(joins() == 3)
            // At the bound: another turn does not join again.
            try await screen.send("work 5")
            #expect(await SessionRuntimeRig.waitUntil(20) { turnsDone() >= turns + 1 })
            #expect(joins() == 3)
        } else {
            #expect(await SessionRuntimeRig.waitUntil { joins() >= 2 })
            #expect(await context.runtime.codexCoordinator?.pendingRequestIDs().isEmpty == true)
        }
        #expect(joinLog(context).filter { $0.hasPrefix("join ") }.count <= 3)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func noRolloutDuringActiveTurnRetriesAfterPersistenceAtIdle() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": "blank-until-idle"])
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).filter { $0.hasPrefix("join ") }.count == 1 })
        try await screen.send("work 250")
        #expect(await screen.contains("CODEX-TURN-DONE completed echo work 250"))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains { $0.hasPrefix("joined ") } })
        #expect(joinLog(context).filter { $0.hasPrefix("join ") }.count <= 3)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["stop", "quit", "exit", "idle"])
    func delayedJoinIsDrainedBeforeUnsubscribeAndDoesNotCutSibling(action: String) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": "delay0.3"])
        defer { context.cleanup() }
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        try await siblingScreen.send("approve sibling")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        if action == "stop" {
            #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        } else if action == "exit" {
            try await screen.send("/exit")
            #expect(await SessionRuntimeRig.waitUntil { await context.supervisor.runContext(runID: launch.runID) == nil })
        } else if action == "idle" {
            try await screen.send("work 5")
            #expect(await SessionRuntimeRig.waitUntil {
                await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
            })
            #expect(await SessionRuntimeRig.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })
            let result = try await context.runtime.lifecycle.evaluateIdle(sessionID: launch.sessionID, at: Date().addingTimeInterval(4_000))
            guard case .transitioned = result else { Issue.record("Idle did not transition: \(result)"); return }
        } else { #expect((await context.runtime.shutdown()).succeeded) }
        let lines = joinLog(context)
        let joined = try #require(lines.firstIndex(of: "joined \(thread)"))
        let unsubscribed = try #require(lines.firstIndex(of: "unsubscribe \(thread)"))
        #expect(joined < unsubscribed)
        if action != "quit" {
            #expect(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1)
            #expect((await context.runtime.shutdown()).succeeded)
        }
    }

    @Test(arguments: [("new", "prepare"), ("exit", "prepare"), ("exit", "prepare-once")])
    func failedStopPreparationReleasesCleanupGate(_ scenario: (String, String)) async throws {
        let (action, failure) = scenario
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_STOP_FAILURE": failure])
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(!(try await context.runtime.stopConversation(sessionID: launch.sessionID)).succeeded)
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("unsubscribe \(thread)") })
        try await screen.send(action == "new" ? "/new" : "/exit")
        if action == "new" {
            #expect(try await SessionRuntimeRig.waitUntil { try await context.catalog.sessions().count == 2 })
            try await screen.send("approve new")
            #expect(await SessionRuntimeRig.waitUntil { await context.runtime.codexCoordinator?.pendingRequestIDs().count == 1 })
            try await context.supervisor.registerStopHooks(runID: launch.runID,
                hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
        } else {
            #expect(await screen.contains("bye"))
            if failure == "prepare-once" {
                #expect(await SessionRuntimeRig.waitUntil { await context.supervisor.runContext(runID: launch.runID) == nil })
            } else {
                // The native process exited, but persistent provider failure
                // honestly keeps Stop unverified. The join gate is still drained.
                try await context.supervisor.registerStopHooks(runID: launch.runID,
                    hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
            }
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func lateJoinErrorAfterStopIsNotPublishedToOldOrSiblingCard() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": "delay-error"])
        defer { context.cleanup() }
        let (sibling, _) = try await Self.launchCodex(context)
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.issue?.contains("subscription failed (rpc, RPC -32001)") == true
        })
        let siblingIssue = await context.events.snapshot().sessions[sibling.sessionID]?.issue
        let (launch, _) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("join \(thread) excludeTurns,threadId") })
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.issue == nil)
        #expect(await context.events.snapshot().sessions[sibling.sessionID]?.issue == siblingIssue)
        #expect(joinLog(context).contains("unsubscribe \(thread)"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func replayDuringSuspendedAnswerIsOneTransactionButResolvedIDCanBeReused() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (_, screen) = try await Self.launchCodex(context)
        try await screen.send("approve replay")
        let coordinator = try #require(await context.runtime.codexCoordinator)
        #expect(await SessionRuntimeRig.waitUntil { await coordinator.pendingRequestIDs().count == 1 })
        let first = try #require(await coordinator.pendingRequestSnapshot().pending.first)
        let gate = ResponseGate()
        let writes = ResponseWriteCounter()
        let answer = Task {
            try await coordinator.respond(to: first, result: .object(["decision": .string("accept")])) { _, _ in
                await writes.record()
                await gate.wait()
            }
        }
        #expect(await SessionRuntimeRig.waitUntil { await gate.waiting })
        await coordinator.consume(.request(sequence: first.sequence + 1, first.request))
        let replay = try #require(await coordinator.pendingRequestSnapshot().pending.first)
        #expect(replay.id == first.id)
        await #expect(throws: CodexAppServerError.self) {
            try await coordinator.respond(to: replay, result: .object([:])) { _, _ in await writes.record() }
        }
        await gate.open()
        try await answer.value
        #expect(await writes.count == 1)
        #expect(await coordinator.pendingRequestIDs().isEmpty)
        #expect(await context.supervisor.providerWorkState(sessionID: first.binding.sessionID)?.pendingProviderWorkCount == 0)
        // A replay after our successful write is still the same transaction
        // until the provider's authoritative resolution arrives.
        await coordinator.consume(.request(sequence: first.sequence + 2, first.request))
        #expect(await coordinator.pendingRequestIDs().isEmpty)
        #expect(await writes.count == 1)
        // An authoritative resolution ends the raw-ID transaction. Reuse
        // afterwards must create a genuinely new, answerable occurrence.
        await coordinator.consume(.event(sequence: first.sequence + 3,
            .serverRequestResolved(threadID: first.binding.threadID, requestID: first.request.id)))
        await coordinator.consume(.request(sequence: first.sequence + 4, first.request))
        let reused = try #require(await coordinator.pendingRequestSnapshot().pending.first)
        #expect(reused.id != first.id)
        try await coordinator.respond(to: reused, result: .object([:])) { _, _ in await writes.record() }
        #expect(await writes.count == 2)
        #expect(await coordinator.pendingRequestIDs().isEmpty)
        #expect(await context.supervisor.providerWorkState(sessionID: first.binding.sessionID)?.pendingProviderWorkCount == 0)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func immediateStopCannotReviveAJoinStillInstallingItsBinding() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": "delay0.3"])
        defer { context.cleanup() }
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        try await siblingScreen.send("approve sibling")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let (launch, _) = try await Self.launchCodex(context)
        // No identity, hook, or join-send barrier: this targets the start/Stop race.
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await context.supervisor.runContext(runID: launch.runID) == nil)
        #expect(await context.runtime.codexCoordinator?.pendingRequestSnapshot().pending.allSatisfy {
            $0.binding.managedRunID != launch.runID
        } == true)
        if let thread = try await threadID(context, launch.sessionID) {
            let lines = joinLog(context)
            if let joined = lines.firstIndex(of: "joined \(thread)") {
                let cleanup = try #require(lines.firstIndex(of: "unsubscribe \(thread)"))
                #expect(joined < cleanup)
            }
        }
        #expect(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func timedOutJoinNeverClaimsCleanupAndKeepsSiblingConnectionAlive() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_JOIN": "delay25"])
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("join \(thread) excludeTurns,threadId") })
        let (sibling, _) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, sibling.sessionID) != nil })
        let report = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!report.succeeded)
        #expect(report.providerStages?.first?.outcome == "failed")
        #expect(report.providerStages?.first?.errorCategory == "timeout")
        #expect(await context.supervisor.runContext(runID: sibling.runID) != nil)
        #expect(await SessionRuntimeRig.waitUntil(7) { joinLog(context).contains("joined \(thread)") })
        #expect(!joinLog(context).contains("unsubscribe \(thread)"))
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.issue?.contains("subscription failed (timeout)") == true)
        let coordinator = try #require(await context.runtime.codexCoordinator)
        for _ in 0..<2 {
            await #expect(throws: CodexAppServerError.self) {
                try await coordinator.completeJoinStop(runID: launch.runID, threadID: thread)
            }
        }
        #expect(!joinLog(context).contains("unsubscribe-attempt \(thread)"))
        // Explicit test-only process cleanup does not pretend the observer
        // protocol cleaned its uncertain subscription.
        for run in [launch.runID, sibling.runID] {
            try await context.supervisor.registerStopHooks(runID: run,
                hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["permissions", "input"])
    func terminalResolutionClearsUnsupportedRequestsAndAllowsIdle(kind: String) async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        try await screen.send(kind)
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1
        })
        #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.pendingProviderWorkCount == 1)
        let coordinator = try #require(await context.runtime.codexCoordinator)
        #expect(await coordinator.pendingRequestIDs().count == 1)
        try await screen.send("/resolve-first")
        #expect(await SessionRuntimeRig.waitUntil {
            let view = await context.events.snapshot().sessions[launch.sessionID]
            return view?.userRequests.isEmpty == true && view?.status?.pendingProviderWorkCount == 0
        })
        #expect(await coordinator.pendingRequestIDs().isEmpty)
        #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .working)
        // Resolution does not manufacture turn success. Only the separate turn
        // completion lets the lifecycle stop this otherwise quiet run.
        try await screen.send("/complete")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })
        let outcome = try await context.runtime.lifecycle.evaluateIdle(sessionID: launch.sessionID, at: Date().addingTimeInterval(4_000))
        guard case .transitioned = outcome else {
            Issue.record("Resolved input still blocked idle: \(outcome)")
            _ = await context.runtime.shutdown()
            return
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func resolutionDuplicatesAndInterruptCleanupPreserveOtherThreads() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (first, screen) = try await Self.launchCodex(context)
        let (other, otherScreen) = try await Self.launchCodex(context)
        try await screen.send("approve two")
        try await otherScreen.send("approve sibling")
        #expect(await SessionRuntimeRig.waitUntil {
            let views = await context.events.snapshot().sessions
            return views[first.sessionID]?.userRequests.count == 2 && views[other.sessionID]?.userRequests.count == 1
        })
        for command in ["/resolve-wrong-thread", "/resolve-unknown"] {
            try await screen.send(command)
            #expect(await screen.contains("RESOLUTION-SENT \(command)"))
        }
        try await screen.send("/resolve-first")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[first.sessionID]?.userRequests.count == 1
        })
        let remaining = try #require(await context.events.snapshot().sessions[first.sessionID]?.userRequests.first)
        try await screen.send("/resolve-duplicate")
        #expect(await screen.contains("RESOLUTION-SENT /resolve-duplicate"))
        #expect(await SessionRuntimeRig.waitUntil {
            await context.runtime.codexRoutingDiagnostics().entries.filter { $0.event == "unknown" }.count >= 4
        })
        #expect(await context.events.snapshot().sessions[first.sessionID]?.userRequests.map(\.id) == [remaining.id])
        #expect(await context.supervisor.providerWorkState(sessionID: first.sessionID)?.pendingProviderWorkCount == 1)
        try await screen.send("/interrupt")
        #expect(await SessionRuntimeRig.waitUntil {
            let views = await context.events.snapshot().sessions
            return views[first.sessionID]?.userRequests.isEmpty == true && views[first.sessionID]?.status?.pendingProviderWorkCount == 0
        })
        let views = await context.events.snapshot().sessions
        #expect(views[first.sessionID]?.status?.activity == .failed("interrupted"))
        #expect(views[other.sessionID]?.userRequests.count == 1)
        #expect(views[other.sessionID]?.status?.pendingProviderWorkCount == 1)
        await #expect(throws: SessionRuntimeError.self) {
            try await context.runtime.respond(sessionID: first.sessionID, requestID: remaining.id, decision: .accept)
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func oldRunRequestCannotAnswerReusedProviderIDAfterResume() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        try await screen.send("approve old run")
        let oldCoordinator = try #require(await context.runtime.codexCoordinator)
        #expect(await SessionRuntimeRig.waitUntil { await oldCoordinator.pendingRequestIDs().count == 1 })
        let old = try #require(await oldCoordinator.pendingRequestSnapshot().pending.first)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        let resumedScreen = Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: resumedScreen)
        resumedScreen.attach(resumed.terminal)
        #expect(await resumedScreen.contains("RESUMED-CODEX"))
        try await resumedScreen.send("approve new run")
        let currentCoordinator = try #require(await context.runtime.codexCoordinator)
        #expect(await SessionRuntimeRig.waitUntil { await currentCoordinator.pendingRequestIDs().count == 1 })
        let current = try #require(await currentCoordinator.pendingRequestSnapshot().pending.first)
        #expect(current.request.id == old.request.id)
        #expect(current.id != old.id && current.binding.managedRunID != old.binding.managedRunID)
        await #expect(throws: SessionRuntimeError.self) {
            try await context.runtime.respond(sessionID: launch.sessionID, requestID: old.id.uuidString, decision: .accept)
        }
        await #expect(throws: CodexAppServerError.self) {
            try await currentCoordinator.respond(to: old, result: .object([:]))
        }
        #expect(await currentCoordinator.pendingRequestSnapshot().pending.map(\.id) == [current.id])
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.map(\.id) == [current.id.uuidString]
        })
        #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.pendingProviderWorkCount == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [false, true])
    func failedSuspendedAnswerDuringUnbindOrStopMustThrow(stopping: Bool) async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        try await screen.send("approve me")
        let coordinator = try #require(await context.runtime.codexCoordinator)
        #expect(await SessionRuntimeRig.waitUntil { await coordinator.pendingRequestIDs().count == 1 })
        let pending = try #require(await coordinator.pendingRequestSnapshot().pending.first)
        let gate = ResponseGate()
        let answer = Task {
            try await coordinator.respond(to: pending, result: .object([:])) { _, _ in
                await gate.wait()
                throw CodexAppServerError.closed
            }
        }
        #expect(await SessionRuntimeRig.waitUntil { await gate.waiting })
        if stopping { await coordinator.stop() }
        else { await coordinator.unbind(runID: pending.binding.managedRunID) }
        await gate.open()
        await #expect(throws: CodexAppServerError.closed) { try await answer.value }
        #expect(await coordinator.pendingRequestIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func providerResolutionDuringSuspendedLocalAnswerCannotRemoveSiblingOrResurrectFailure(writeFails: Bool) async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        try await screen.send("approve two")
        let coordinator = try #require(await context.runtime.codexCoordinator)
        #expect(await SessionRuntimeRig.waitUntil { await coordinator.pendingRequestIDs().count == 2 })
        let pending = await coordinator.pendingRequestSnapshot().pending.sorted { $0.sequence < $1.sequence }
        let first = try #require(pending.first), sibling = try #require(pending.last)
        let gate = ResponseGate()
        let answer = Task {
            try await coordinator.respond(to: first, result: .object(["decision": .string("accept")])) { _, _ in
                await gate.wait()
                if writeFails { throw CodexAppServerError.closed }
            }
        }
        #expect(await SessionRuntimeRig.waitUntil { await gate.waiting })
        // A second local click must not launch a second write.
        await #expect(throws: CodexAppServerError.self) {
            try await coordinator.respond(to: first, result: .object([:])) { _, _ in
                Issue.record("Duplicate local answer wrote to the transport")
            }
        }
        try await screen.send("/resolve-first")
        #expect(await SessionRuntimeRig.waitUntil { await coordinator.pendingRequestIDs().count == 1 })
        await gate.open()
        try await answer.value
        #expect(await coordinator.pendingRequestSnapshot().pending.map(\.id) == [sibling.id])
        #expect(await SessionRuntimeRig.waitUntil {
            let view = await context.events.snapshot().sessions[launch.sessionID]
            return view?.userRequests.map(\.id) == [sibling.id.uuidString] && view?.status?.pendingProviderWorkCount == 1
        })
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.first?.failure == nil)
        try await context.runtime.respond(sessionID: launch.sessionID, requestID: sibling.id.uuidString, decision: .accept)
        #expect(await SessionRuntimeRig.waitUntil {
            let view = await context.events.snapshot().sessions[launch.sessionID]
            return view?.userRequests.isEmpty == true && view?.status?.pendingProviderWorkCount == 0
        })
        #expect(await coordinator.pendingRequestIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [1, 2])
    func helperEventsKeepCardsRunOwnersAndStopHooksOnUserThreads(count: Int) async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        var launches: [RuntimeLaunch] = []
        var screens: [Screen] = []
        var threads: [String] = []
        for _ in 0..<count {
            let (launch, screen) = try await Self.launchCodex(context)
            #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
            launches.append(launch); screens.append(screen)
            threads.append(try #require(try await threadID(context, launch.sessionID)))
        }
        try await screens[0].send("/helper")
        #expect(await screens[0].contains("HELPER-SENT"))
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.runtime.codexRoutingDiagnostics().entries.filter { $0.decision == "unmatched" }.count >= 2
        })
        #expect(try await context.catalog.sessions().count == count)
        let snapshot = await context.events.snapshot()
        for (index, launch) in launches.enumerated() {
            #expect(try await threadID(context, launch.sessionID) == threads[index])
            #expect(await context.supervisor.activeSessionID(runID: launch.runID) == launch.sessionID)
            #expect(snapshot.sessions[launch.sessionID]?.identity == .known)
            #expect(snapshot.sessions[launch.sessionID]?.issue == nil)
            let stopped = try await context.runtime.stopConversation(sessionID: launch.sessionID)
            #expect(stopped.succeeded)
            #expect(stopped.providerStages?.map(\.threadID) == [threads[index], threads[index]])
            #expect(stopped.providerStages?.map(\.stage) == ["prepare", "completed"])
        }
        let routing = await context.runtime.codexRoutingDiagnostics()
        // The helper thread came from the first TUI's own server, so only that
        // run is a candidate; a sibling's run is never even considered.
        let helpers = routing.entries.filter { $0.decision == "ignoredEphemeral" }
        let helper = try #require(helpers.first)
        #expect(helper.ephemeral == true && helper.cwdMatch == true)
        #expect(helper.source == "exec" && helper.originator == "other")
        #expect(helpers.flatMap(\.runIDs) == [launches[0].runID])
        let encoded = String(decoding: try JSONEncoder().encode(routing), as: UTF8.self)
        #expect(!encoded.contains("private-originator-value"))
        #expect(!encoded.contains(context.home.path))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: ["completed-once", "completed"])
    func settledJoinUnsubscribeRejectionRetriesOnlyTheCompletedRPC(mode: String) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_STOP_FAILURE": mode])
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("joined \(thread)") })
        try await siblingScreen.send("approve retained sibling")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let coordinator = try #require(await context.runtime.codexCoordinator)
        // Exercise the same prepare/completed protocol independently of the
        // supervisor's retention policy. The real join must settle first.
        try await coordinator.prepareJoinStop(runID: launch.runID, threadID: thread)
        await #expect(throws: CodexAppServerError.self) {
            try await coordinator.completeJoinStop(runID: launch.runID, threadID: thread)
        }
        #expect(joinLog(context).filter { $0 == "unsubscribe-attempt \(thread)" }.count == 1)
        if mode == "completed-once" {
            do { try await coordinator.completeJoinStop(runID: launch.runID, threadID: thread) }
            catch { Issue.record("Authoritative unsubscribe rejection was cached forever: \(error)") }
            #expect(joinLog(context).contains("unsubscribe \(thread)"))
        } else {
            await #expect(throws: CodexAppServerError.self) {
                try await coordinator.completeJoinStop(runID: launch.runID, threadID: thread)
            }
            #expect(!joinLog(context).contains("unsubscribe \(thread)"))
        }
        #expect(joinLog(context).filter { $0 == "unsubscribe-attempt \(thread)" }.count == 2)
        #expect(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1)
        let request = try #require(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.first)
        try await context.runtime.respond(sessionID: sibling.sessionID, requestID: request.id, decision: .accept)
        #expect(await siblingScreen.contains("CODEX-TURN-DONE completed approved"))
        // The persistent-failure test explicitly cleans up fixture processes;
        // it does not claim that the failing subscription barrier succeeded.
        for run in [launch.runID, sibling.runID] {
            try await context.supervisor.registerStopHooks(runID: run,
                hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
        }
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
    }

    @Test func failedPreparationCanRetryItsAuthoritativelyRejectedUnsubscribe() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_STOP_FAILURE": "prepare-completed-once"])
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("joined \(thread)") })
        let failed = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!failed.succeeded)
        #expect(failed.providerStages?.last?.stage == "prepare")
        #expect(failed.signals.isEmpty && !failed.remaining.isEmpty)
        #expect(await context.supervisor.runContext(runID: launch.runID) != nil)
        #expect(await SessionRuntimeRig.waitUntil {
            joinLog(context).contains("unsubscribe-attempt \(thread)")
        })
        let retried = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(retried.succeeded)
        #expect(joinLog(context).filter { $0 == "unsubscribe-attempt \(thread)" }.count >= 2)
        #expect(joinLog(context).contains("unsubscribe \(thread)"))
        try await siblingScreen.send("approve sibling after preparation retry")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.first)
        try await context.runtime.respond(sessionID: sibling.sessionID, requestID: request.id, decision: .accept)
        #expect(await siblingScreen.contains("CODEX-TURN-DONE completed approved"))
        if !retried.succeeded {
            try await context.supervisor.registerStopHooks(runID: launch.runID,
                hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
        }
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
    }

    @Test func repeatedPreparationWaitsOnlyForJoinDrainNotCompletion() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("joined \(thread)") })
        let coordinator = try #require(await context.runtime.codexCoordinator)
        try await coordinator.prepareJoinStop(runID: launch.runID, threadID: thread)
        let returned = ResponseWriteCounter()
        let second = Task {
            try await coordinator.prepareJoinStop(runID: launch.runID, threadID: thread)
            await returned.record()
        }
        #expect(await SessionRuntimeRig.waitUntil(1) { await returned.count == 1 })
        #expect(!joinLog(context).contains("unsubscribe-attempt \(thread)"))
        // Open the completion gate even in the RED run, so no test task leaks.
        try await coordinator.completeJoinStop(runID: launch.runID, threadID: thread)
        try await second.value
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func liveTUIAfterUnknownOwnershipRequiresFreshProviderStopOnRetry() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("joined \(thread)") })
        await context.supervisor.setOwnershipSamplingFailpointForTesting {
            throw LoomError.message("fixture ownership sampling unavailable")
        }
        let first = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!first.succeeded && first.remainingCountVerified == false)
        #expect(first.signals.isEmpty)
        #expect(await launch.terminal.exitStatus() == nil)
        #expect(await context.supervisor.runContext(runID: launch.runID) != nil)
        #expect(!joinLog(context).contains("unsubscribe-attempt \(thread)"))
        try await screen.send("work 60000")
        #expect(await SessionRuntimeRig.waitUntil {
            joinLog(context).contains(where: { $0.hasPrefix("turn-start \(thread) ") })
        })
        let started = try #require(joinLog(context).first(where: { $0.hasPrefix("turn-start \(thread) ") }))
        let turn = try #require(started.split(separator: " ").last).description
        await context.supervisor.setOwnershipSamplingFailpointForTesting(nil)
        let retried = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(retried.succeeded)
        let lines = joinLog(context)
        let interrupted = lines.firstIndex(of: "turn-interrupt \(thread) \(turn)")
        let unsubscribed = lines.firstIndex(of: "unsubscribe \(thread)")
        #expect(interrupted != nil)
        #expect(unsubscribed != nil)
        if let interrupted, let unsubscribed { #expect(interrupted < unsubscribed) }
        #expect(await context.supervisor.runContext(runID: launch.runID) == nil)
        try await siblingScreen.send("approve sibling after live retry")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.first)
        try await context.runtime.respond(sessionID: sibling.sessionID, requestID: request.id, decision: .accept)
        #expect(await siblingScreen.contains("CODEX-TURN-DONE completed approved"))
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.runtime.liveRunCount() == 0)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
    }

    @Test func completedStopsRealLateTurnAfterProducerWasTerminated() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("joined \(thread)") })
        let gate = RuntimeCodexLateTurnGate()
        defer { gate.release() }
        await context.supervisor.setOwnershipSamplingFailpointForTesting { gate.pauseOnce() }
        let stopping = Task { try await context.runtime.stopConversation(sessionID: launch.sessionID) }
        try #require(await SessionRuntimeRig.waitUntil(2) { gate.hasEntered })
        try await screen.send("work 60000")
        try #require(await SessionRuntimeRig.waitUntil(2) {
            joinLog(context).contains(where: { $0.hasPrefix("turn-start \(thread) ") })
        })
        let started = try #require(joinLog(context).first(where: { $0.hasPrefix("turn-start \(thread) ") }))
        let turn = try #require(started.split(separator: " ").last).description
        gate.release()
        let report = try await stopping.value
        #expect(report.succeeded && report.remainingCountVerified == true && report.remaining.isEmpty)
        #expect(await launch.terminal.exitStatus() != nil)
        let lines = joinLog(context)
        let interrupted = lines.firstIndex(of: "turn-interrupt \(thread) \(turn)")
        let unsubscribed = lines.firstIndex(of: "unsubscribe \(thread)")
        #expect(interrupted != nil)
        #expect(unsubscribed != nil)
        if let interrupted, let unsubscribed { #expect(interrupted < unsubscribed) }
        await context.supervisor.setOwnershipSamplingFailpointForTesting(nil)
        try await siblingScreen.send("approve sibling after completed late turn")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.first)
        try await context.runtime.respond(sessionID: sibling.sessionID, requestID: request.id, decision: .accept)
        #expect(await siblingScreen.contains("CODEX-TURN-DONE completed approved"))
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.runtime.liveRunCount() == 0)
    }

    @Test(arguments: ["completed-once", "completed"])
    func completedFailureRetainsRunUntilExplicitStopRetry(mode: String) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_STOP_FAILURE": mode])
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(await SessionRuntimeRig.waitUntil { joinLog(context).contains("joined \(thread)") })
        let first = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!first.succeeded)
        #expect(first.remaining.isEmpty)
        #expect(first.providerStages?.last?.stage == "completed")
        #expect(first.providerStages?.last?.errorCategory == "rpc")
        #expect(await context.supervisor.runContext(runID: launch.runID) != nil)
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun?.id == launch.runID)
        #expect(await context.runtime.liveRunCount() == 2)
        #expect(await context.runtime.codexServerState().servers == 2)
        // Give the real PTY leader-exit callback an opportunity to run. It
        // must not consume fail-once recovery without an explicit user Stop.
        try await Task.sleep(for: .milliseconds(150))
        #expect(joinLog(context).filter { $0 == "unsubscribe-attempt \(thread)" }.count == 1)
        var retried: SessionStopReport?
        do { retried = try await context.runtime.stopConversation(sessionID: launch.sessionID) }
        catch { Issue.record("Completed failure lost its retryable run: \(error)") }
        #expect(joinLog(context).filter { $0 == "unsubscribe-attempt \(thread)" }.count == 2)
        if mode == "completed-once" {
            #expect(retried?.succeeded == true)
            #expect(await context.supervisor.runContext(runID: launch.runID) == nil)
            #expect(await context.runtime.codexServerState().servers == 1)
            #expect(joinLog(context).contains("unsubscribe \(thread)"))
        } else {
            #expect(retried?.succeeded == false)
            #expect(retried?.remaining.isEmpty == true)
            #expect(retried?.providerStages?.last?.errorCategory == "rpc")
            #expect(await context.supervisor.runContext(runID: launch.runID) != nil)
            #expect(await context.runtime.codexServerState().servers == 2)
            #expect(!joinLog(context).contains("unsubscribe \(thread)"))
        }
        try await siblingScreen.send("approve sibling after completion retry")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.first)
        try await context.runtime.respond(sessionID: sibling.sessionID, requestID: request.id, decision: .accept)
        #expect(await siblingScreen.contains("CODEX-TURN-DONE completed approved"))
        // App-wide verified server/PTY destruction is a separate Quit
        // authority; it does not turn a failed per-session RPC into success.
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(await context.runtime.liveRunCount() == 0)
    }

    @Test(arguments: ["prepare", "completed"])
    func stopDiagnosticsSeparateProviderRPCFailureFromProcesses(stage: String) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_STOP_FAILURE": stage])
        defer { context.cleanup() }
        let (launch, _) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        let report = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!report.succeeded)
        let failure = try #require(report.providerStages?.last)
        #expect(failure.stage == stage && failure.outcome == "failed")
        #expect(failure.threadID == thread && failure.errorCategory == "rpc")
        #expect(failure.rpcCode == (stage == "prepare" ? -32041 : -32042))
        if stage == "prepare" {
            #expect(!report.remaining.isEmpty && report.signals.isEmpty)
            #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun?.id == launch.runID)
            try await context.supervisor.registerStopHooks(runID: launch.runID,
                hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
            #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        } else { #expect(report.remaining.isEmpty) }
        let records = await context.supervisor.stopDiagnostics()
        #expect(records.contains { $0.runID == launch.runID && !$0.succeeded && $0.providerStages.last?.stage == stage })
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!encoded.contains("private-provider-error-text"))
        #expect(!report.errors.joined().contains("private-provider-error-text"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func newCodexConversationBindsItsThreadAndKeepsTheServerInternal() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let project = try await Self.project(context, "codex-project")
        let (launch, screen) = try await Self.launchCodex(context, projectID: project.id)
        #expect(await screen.contains("FAKE-CODEX READY"))
        #expect(screen.snapshot.contains("cwd=\(realPath(URL(fileURLWithPath: project.path)))"))

        // The thread the TUI created is the conversation's provider identity.
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let thread = try #require(try await threadID(context, launch.sessionID))
        #expect(screen.snapshot.contains("FAKE-CODEX READY \(thread)"))
        let record = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(record.projectID == project.id)
        #expect(record.session.provider == .codex)

        // The shared server is an internal session: one lease, no catalog card.
        let server = await context.runtime.codexServerState()
        #expect(server.servers == 1)
        #expect(server.internalSessionID != nil)
        #expect(try await context.catalog.sessions().count == 1)
        #expect(await context.supervisor.managedSessions().count == 1)

        // A prompt reaches the provider and its state comes back through the
        // coordinator, not through terminal text.
        try await screen.send("hello codex")
        #expect(await screen.contains("CODEX-TURN-DONE completed echo hello codex"))
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func serverClosesWithTheLastUserRunAndResumeUsesTheSameThread() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (first, firstScreen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, first.sessionID) != nil })
        let thread = try #require(try await threadID(context, first.sessionID))
        try await firstScreen.send("remember codex")
        #expect(await firstScreen.contains("CODEX-TURN-DONE"))
        let serverSession = try #require(await context.runtime.codexServerState().internalSessionID)

        #expect(try await context.runtime.stopConversation(sessionID: first.sessionID).succeeded)
        #expect(try await SessionRuntimeRig.waitUntil {
            let leases = await context.runtime.codexServerState().servers
            let running = await context.supervisor.session(id: serverSession)?.currentRun
            return leases == 0 && running == nil
        })
        #expect(await context.runtime.codexServerState().internalSessionID == nil)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)

        let screen = Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: first.sessionID, outputSink: screen)
        screen.attach(resumed.terminal)
        #expect(await screen.contains("RESUMED-CODEX \(thread)"))
        #expect(resumed.sessionID == first.sessionID)
        #expect(try await context.catalog.sessions().count == 1)
        #expect(try await threadID(context, first.sessionID) == thread)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func resumeOfAMissingThreadIsATypedErrorNotANewThread() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let session = ManagedSession(
            provider: .codex, providerConversationID: "missing-thread", workingDirectory: context.home.path
        )
        try await context.supervisor.createSession(session)
        let screen = Screen()
        do {
            _ = try await context.runtime.resumeConversation(sessionID: session.id, outputSink: screen)
            Issue.record("A missing provider thread must not start another TUI")
        } catch let error as LoomError {
            if case .providerHistoryUnavailable(provider: .codex, conversationID: "missing-thread") = error {} else {
                Issue.record("Expected the typed unavailable-history error; got \(error)")
            }
        }
        let sawIssue = try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[session.id]?.issue?.contains("Provider history unavailable") == true
        }
        if !sawIssue {
            let issue = await context.events.snapshot().sessions[session.id]?.issue
            let live = await context.runtime.liveRunCount()
            let run = await context.supervisor.session(id: session.id)?.currentRun
            print("DEBUG screen=[\(screen.snapshot)] issue=\(String(describing: issue)) live=\(live) run=\(String(describing: run))")
        }
        #expect(sawIssue)
        #expect(!FileManager.default.fileExists(atPath: context.state.appendingPathComponent("codex-tui-arguments.log").path))
        #expect(try await context.catalog.sessions().count == 1)
        #expect(try await threadID(context, session.id) == "missing-thread")
        #expect(try await SessionRuntimeRig.waitUntil { await context.runtime.codexServerState().servers == 0 })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func newInsideTheTUIMovesTheRunToANewConversationInTheSameProject() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let project = try await Self.project(context, "new-project")
        let (launch, screen) = try await Self.launchCodex(context, projectID: project.id)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let oldThread = try #require(try await threadID(context, launch.sessionID))

        try await screen.send("/new")
        #expect(await screen.contains("NEW-THREAD "))
        #expect(try await SessionRuntimeRig.waitUntil { try await context.catalog.sessions().count == 2 })
        let newRecord = try #require(try await context.catalog.sessions().first { $0.session.id != launch.sessionID })
        #expect(newRecord.session.providerConversationID != oldThread)
        #expect(newRecord.projectID == project.id)
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun == nil)
        #expect(await context.supervisor.activeSessionID(runID: launch.runID) == newRecord.session.id)
        #expect(try await context.catalog.runSessionLinks(runID: launch.runID).map(\.sessionID)
            == [launch.sessionID, newRecord.session.id])

        // A request from the new thread belongs to the new card only.
        try await screen.send("approve after new")
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[newRecord.session.id]?.userRequests.count == 1
        })
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.isEmpty ?? true)
        let newRequest = try #require(await context.events.snapshot().sessions[newRecord.session.id]?.userRequests.first)
        await #expect(throws: SessionRuntimeError.self) {
            try await context.runtime.respond(sessionID: launch.sessionID, requestID: newRequest.id, decision: .accept)
        }
        try await context.runtime.respond(sessionID: newRecord.session.id, requestID: newRequest.id, decision: .accept)
        #expect(await screen.contains("CODEX-TURN-DONE completed approved"))

        // The old card cannot stop or feed the new conversation; the lease
        // stays with the run and is released once when the run ends.
        await #expect(throws: SessionRuntimeError.notRunning(launch.sessionID)) {
            _ = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        }
        #expect(await context.runtime.codexServerState().servers == 1)
        #expect(try await context.runtime.stopConversation(sessionID: newRecord.session.id).succeeded)
        #expect(try await SessionRuntimeRig.waitUntil { await context.runtime.codexServerState().servers == 0 })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func concurrentCodexStartsEachGetTheirOwnServerCoordinatorAndApprovalRouting() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let projectA = try await Self.project(context, "concurrent-a")
        let projectB = try await Self.project(context, "concurrent-b")
        let gate = RuntimeCodexSetupGate()
        await context.runtime.observeCodexSetupForTesting { await gate.observe($0) }
        let first = Task { try await Self.launchCodex(context, projectID: projectA.id) }
        #expect(await SessionRuntimeRig.waitUntil { await gate.installations == 1 })
        // A held first setup does not hold up another conversation: nothing is shared.
        let second = Task { try await Self.launchCodex(context, projectID: projectB.id) }
        #expect(await SessionRuntimeRig.waitUntil { await gate.installations == 2 })
        let (b, bScreen) = try await second.value
        await gate.release()
        let (a, aScreen) = try await first.value
        #expect(try await SessionRuntimeRig.waitUntil {
            let a = try await threadID(context, a.sessionID)
            let b = try await threadID(context, b.sessionID)
            return a != nil && b != nil
        })
        let aThread = try #require(try await threadID(context, a.sessionID))
        let bThread = try #require(try await threadID(context, b.sessionID))
        #expect(aThread != bThread)
        #expect(await context.runtime.codexServerState().servers == 2)
        let servers = await context.runtime.codexServerSessionIDs()
        #expect(servers.count == 2 && Set(servers).count == 2)
        let coordinatorA = try #require(await context.runtime.codexCoordinator(forSession: a.sessionID))
        let coordinatorB = try #require(await context.runtime.codexCoordinator(forSession: b.sessionID))
        #expect(coordinatorA !== coordinatorB)
        try await aScreen.send("approve concurrent a")
        try await bScreen.send("approve concurrent b")
        #expect(await SessionRuntimeRig.waitUntil {
            let snapshot = await context.events.snapshot()
            return snapshot.sessions[a.sessionID]?.userRequests.count == 1
                && snapshot.sessions[b.sessionID]?.userRequests.count == 1
        })
        // Each server sees only its own conversation's request.
        #expect(Set(await coordinatorA.pendingRequestSnapshot().pending.map { $0.binding.managedRunID }) == [a.runID])
        #expect(Set(await coordinatorB.pendingRequestSnapshot().pending.map { $0.binding.managedRunID }) == [b.runID])
        for launch in [a, b] {
            if let request = await context.events.snapshot().sessions[launch.sessionID]?.userRequests.first {
                #expect(request.isAnswerable)
                try await context.runtime.respond(sessionID: launch.sessionID, requestID: request.id, decision: .accept)
            } else { Issue.record("Answerable approval missing on concurrent run \(launch.runID)") }
        }
        #expect(await aScreen.contains("CODEX-TURN-DONE completed approved"))
        #expect(await bScreen.contains("CODEX-TURN-DONE completed approved"))
        #expect(try await context.runtime.stopConversation(sessionID: a.sessionID).succeeded)
        try await bScreen.send("sibling survives")
        #expect(await bScreen.contains("CODEX-TURN-DONE completed echo sibling survives"))
        #expect(await context.runtime.codexServerState().servers == 1)
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(await context.runtime.liveRunCount() == 0)
    }

    @Test func quitDuringCodexSetupCannotPublishALateCoordinator() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let gate = RuntimeCodexSetupGate()
        await context.runtime.observeCodexSetupForTesting { await gate.observe($0) }
        let starting = Task { try await Self.launchCodex(context) }
        #expect(await SessionRuntimeRig.waitUntil { await gate.installations == 1 })
        let quitting = Task { await context.runtime.shutdown() }
        // An actor call after starting shutdown confirms its entry guard is
        // set while the held installation has not reached coordinator.start.
        #expect(await SessionRuntimeRig.waitUntil {
            do {
                _ = try await context.runtime.startConversation(provider: .synthetic, projectID: nil)
                return false
            } catch SessionRuntimeError.shuttingDown { return true }
            catch { return false }
        })
        await gate.release()
        let outcome = await starting.result
        if case .success = outcome { Issue.record("Shutdown permitted a late Codex launch") }
        #expect((await quitting.value).succeeded)
        #expect(await context.runtime.codexCoordinator == nil)
        #expect(await context.runtime.codexServerState().servers == 0)
        #expect(await context.runtime.codexServerState().internalSessionID == nil)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(try await context.catalog.sessions().isEmpty)
    }

    @Test func cancellingOneConversationsSetupLeavesTheOtherServerAndApproval() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let projectA = try await Self.project(context, "cancel-a")
        let projectB = try await Self.project(context, "cancel-b")
        let gate = RuntimeCodexSetupGate()
        await context.runtime.observeCodexSetupForTesting { await gate.observe($0) }
        let first = Task { try await Self.launchCodex(context, projectID: projectA.id) }
        #expect(await SessionRuntimeRig.waitUntil { await gate.installations == 1 })
        let (launch, screen) = try await Self.launchCodex(context, projectID: projectB.id)
        first.cancel()
        await gate.release()
        let cancelled = await first.result
        if case .success = cancelled { Issue.record("Cancelled setup launched a conversation") }
        #expect(await gate.installations == 2)
        // The cancelled conversation's own server is gone; only the other remains.
        #expect(try await SessionRuntimeRig.waitUntil { await context.runtime.codexServerState().servers == 1 })
        #expect(await context.runtime.codexServerSessionIDs().count == 1)
        #expect(try await context.catalog.sessions().count == 1)
        try await screen.send("approve surviving setup")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.first)
        try await context.runtime.respond(sessionID: launch.sessionID, requestID: request.id, decision: .accept)
        #expect(await screen.contains("CODEX-TURN-DONE completed approved"))
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
    }

    @Test func eachCodexConversationHasItsOwnServerAndStopClosesOnlyIt() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let projectA = try await Self.project(context, "project-a")
        let projectB = try await Self.project(context, "project-b")
        let (first, firstScreen) = try await Self.launchCodex(context, projectID: projectA.id)
        let (second, secondScreen) = try await Self.launchCodex(context, projectID: projectB.id)
        let firstReady = await firstScreen.contains("FAKE-CODEX READY")
        let secondReady = await secondScreen.contains("FAKE-CODEX READY")
        #expect(firstReady && secondReady)
        #expect(try await SessionRuntimeRig.waitUntil {
            let a = try await threadID(context, first.sessionID)
            let b = try await threadID(context, second.sessionID)
            return a != nil && b != nil
        })
        let firstThread = try await threadID(context, first.sessionID)
        let secondThread = try await threadID(context, second.sessionID)
        #expect(firstThread != secondThread)
        #expect(await context.runtime.codexServerState().servers == 2)
        let servers = await context.runtime.codexServerSessionIDs()
        #expect(servers.count == 2 && Set(servers).count == 2)
        let firstServer = try #require(await context.runtime.codexServerIdentity(forSession: first.sessionID)?.internalSessionID)
        let secondServer = try #require(await context.runtime.codexServerIdentity(forSession: second.sessionID)?.internalSessionID)
        #expect(firstServer != secondServer)

        #expect(try await context.runtime.stopConversation(sessionID: first.sessionID).succeeded)
        // Only A's server is gone; B's server and TUI still work.
        #expect(await context.supervisor.session(id: firstServer) == nil)
        #expect(await context.supervisor.session(id: secondServer)?.currentRun != nil)
        try await secondScreen.send("still alive")
        #expect(await secondScreen.contains("CODEX-TURN-DONE completed echo still alive"))
        #expect(await context.runtime.codexServerState().servers == 1)
        #expect(await context.runtime.codexServerSessionIDs() == [secondServer])

        #expect(try await context.runtime.stopConversation(sessionID: second.sessionID).succeeded)
        // The server's teardown follows the stop; under a loaded machine it lags the call's return.
        #expect(await SessionRuntimeRig.waitUntil(10) { await context.runtime.codexServerState().servers == 0 })
        #expect(await context.runtime.codexServerSessionIDs().isEmpty)
        #expect(await context.supervisor.session(id: secondServer) == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    private func isLive(_ identity: ProcessIdentity) throws -> Bool {
        try ProcessTable.snapshot().contains { $0.identity == identity && !$0.zombie }
    }

    /// OWN-B1: one Codex conversation owns its TUI, its server and everything
    /// either forked. The scoped variant uses real run hosts and an unmarked,
    /// session-leaving command the server started; the shared-server design
    /// could not attribute that command to one conversation.
    @Test(arguments: [false, true])
    func stoppingOneCodexConversationEndsItsOwnTUIServerAndScopeOnly(scoped: Bool) async throws {
        let context = try await SessionRuntimeRig.makeContext(
            extraEnvironment: scoped ? ["LOOM_FAKE_CODEX_SERVER_ESCAPE": "1"] : [:], scoped: scoped
        )
        defer { context.cleanup() }
        let (a, aScreen) = try await Self.launchCodex(context)
        let (b, bScreen) = try await Self.launchCodex(context)
        _ = aScreen
        // Two app-servers, two TUIs and (scoped) their run hosts start beside the rest of a whole-target run: the waits that
        // follow a process start get the time such a start takes there (5 s was not enough once, 21 Oct). A join that
        // fails ends the wait at once with its card's issue, so a real binding failure is still quick and named.
        var joinIssue: String?
        let bound = try await SessionRuntimeRig.waitUntil(Self.processStartWait) {
            for id in [a.sessionID, b.sessionID] {
                if let issue = await context.events.snapshot().sessions[id]?.issue {
                    joinIssue = issue
                    return true
                }
            }
            let x = try await threadID(context, a.sessionID)
            let y = try await threadID(context, b.sessionID)
            return x != nil && y != nil
        }
        try #require(joinIssue == nil, "a Codex join failed: \(joinIssue ?? "")")
        try #require(bound, "the two Codex threads did not bind within \(Self.processStartWait) s")
        let serverA = try #require(await context.runtime.codexServerIdentity(forSession: a.sessionID))
        let serverB = try #require(await context.runtime.codexServerIdentity(forSession: b.sessionID))
        let serverASession = try #require(serverA.internalSessionID)
        let serverBSession = try #require(serverB.internalSessionID)
        let tuiA = try #require(await context.supervisor.session(id: a.sessionID)?.currentRun?.leader)
        let tuiB = try #require(await context.supervisor.session(id: b.sessionID)?.currentRun?.leader)
        let procA = try #require(await context.supervisor.session(id: serverASession)?.currentRun?.leader)
        let procB = try #require(await context.supervisor.session(id: serverBSession)?.currentRun?.leader)
        #expect(procA.pid != procB.pid)
        #expect(Set([tuiA.pid, tuiB.pid, procA.pid, procB.pid]).count == 4)

        var escapeA: ProcessIdentity?, escapeB: ProcessIdentity?
        var scopeA: RunScope?, scopeB: RunScope?
        if scoped {
            scopeA = try #require(serverA.scope)
            scopeB = try #require(serverB.scope)
            #expect(scopeA?.coalitionID != scopeB?.coalitionID)
            // TUI and server of one conversation share its scope; nothing crosses.
            #expect(ProcessTable.resourceCoalition(pid: tuiA.pid) == scopeA?.coalitionID)
            #expect(ProcessTable.resourceCoalition(pid: procA.pid) == scopeA?.coalitionID)
            #expect(ProcessTable.resourceCoalition(pid: tuiB.pid) == scopeB?.coalitionID)
            #expect(ProcessTable.resourceCoalition(pid: procB.pid) == scopeB?.coalitionID)
            func escape(_ server: ProcessIdentity) async throws -> ProcessIdentity? {
                let file = context.state.appendingPathComponent("server-escape.\(server.pid)")
                guard await SessionRuntimeRig.waitUntil(Self.processStartWait, { FileManager.default.fileExists(atPath: file.path) }),
                      let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text) else { return nil }
                return try ProcessTable.snapshot().first { $0.identity.pid == pid }?.identity
            }
            escapeA = try #require(try await escape(procA))
            escapeB = try #require(try await escape(procB))
            #expect(ProcessTable.resourceCoalition(pid: escapeA!.pid) == scopeA?.coalitionID)
            #expect(ProcessTable.runID(pid: escapeA!.pid) == nil) // unmarked: only the scope knows it
        }

        let stopped = try await context.runtime.stopConversation(sessionID: a.sessionID)
        #expect(stopped.succeeded, "\(stopped.errors)")
        #expect(try !isLive(tuiA))
        #expect(try !isLive(procA))
        #expect(await context.supervisor.session(id: serverASession) == nil)
        if scoped, let escapeA, let scopeA {
            #expect(try !isLive(escapeA))
            #expect(try RunScopeTable.members(coalitionID: scopeA.coalitionID).filter { !$0.zombie }.isEmpty)
            #expect(await context.supervisor.ledgerSnapshot().scopes?.count == 1)
        }

        // B is untouched and still routes an approval to its own card.
        #expect(try isLive(tuiB))
        #expect(try isLive(procB))
        if scoped, let escapeB { #expect(try isLive(escapeB)) }
        #expect(await context.runtime.codexServerSessionIDs() == [serverBSession])
        try await bScreen.send("approve after sibling stop")
        try #require(await SessionRuntimeRig.waitUntil(Self.processStartWait) {
            await context.events.snapshot().sessions[b.sessionID]?.userRequests.count == 1
        })
        #expect(await context.events.snapshot().sessions[a.sessionID]?.userRequests.isEmpty ?? true)
        let request = try #require(await context.events.snapshot().sessions[b.sessionID]?.userRequests.first)
        try await context.runtime.respond(sessionID: b.sessionID, requestID: request.id, decision: .accept)
        #expect(await bScreen.contains("CODEX-TURN-DONE completed approved", timeout: Self.processStartWait))

        #expect((await context.runtime.shutdown()).succeeded)
        #expect(try !isLive(tuiB))
        #expect(try !isLive(procB))
        if scoped, let escapeB, let scopeB {
            #expect(try !isLive(escapeB))
            #expect(try RunScopeTable.members(coalitionID: scopeB.coalitionID).filter { !$0.zombie }.isEmpty)
            #expect(await context.supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        }
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
    }

    @Test func approvalRequestReachesTheRightCardAndIsAnsweredOnlyByTheUser() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        let (other, otherScreen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil {
            let a = try await threadID(context, launch.sessionID)
            let b = try await threadID(context, other.sessionID)
            return a != nil && b != nil
        })

        try await screen.send("approve please")
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.first)
        #expect(request.kind == .command)
        #expect(request.summary == "Run: touch fixture-file")
        #expect(request.isAnswerable)
        // Nothing is answered for the user; the other card has no request.
        #expect(await context.events.snapshot().sessions[other.sessionID]?.userRequests.isEmpty ?? true)
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.status?.activity == .waitingForApproval
        })
        #expect(!screen.snapshot.contains("CODEX-TURN-DONE"))

        // The wrong card cannot answer it.
        await #expect(throws: SessionRuntimeError.self) {
            try await context.runtime.respond(sessionID: other.sessionID, requestID: request.id, decision: .accept)
        }
        try await context.runtime.respond(sessionID: launch.sessionID, requestID: request.id, decision: .accept)
        #expect(await screen.contains("CODEX-TURN-DONE completed approved"))
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.isEmpty == true
        })
        // A second answer is refused: the request is no longer pending.
        await #expect(throws: SessionRuntimeError.self) {
            try await context.runtime.respond(sessionID: launch.sessionID, requestID: request.id, decision: .decline)
        }
        let log = try String(contentsOf: context.state.appendingPathComponent("codex-approvals.log"), encoding: .utf8)
        #expect(log.split(separator: "\n").count == 1)
        #expect(log.contains(" accept"))
        _ = otherScreen
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func tuiOnlyApprovalStatusDoesNotInventACardRequestOrAnswer() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        let (sibling, siblingScreen) = try await Self.launchCodex(context)
        try await siblingScreen.send("approve sibling")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.count == 1
        })
        let siblingRequest = try #require(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.first)
        try await screen.send("approve tui-only")
        #expect(await screen.contains("CODEX-APPROVAL-REQUESTED"))
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.status?.activity == .waitingForApproval
        })
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.isEmpty == true)
        let coordinator = try #require(await context.runtime.codexCoordinator(forSession: sibling.sessionID))
        let ownCoordinator = try #require(await context.runtime.codexCoordinator(forSession: launch.sessionID))
        #expect(await coordinator.pendingRequestIDs().count == 1) // sibling only
        #expect(await ownCoordinator.pendingRequestIDs().isEmpty) // TUI-only: nothing invented
        #expect(!FileManager.default.fileExists(atPath: context.state.appendingPathComponent("codex-approvals.log").path))
        await #expect(throws: SessionRuntimeError.self) {
            try await context.runtime.respond(sessionID: launch.sessionID, requestID: siblingRequest.id, decision: .accept)
        }
        // Other-client resolution must not remove the sibling's real request.
        // The fixture resolves it without implying that Loom ever answered it.
        try await screen.send("/resolve-first")
        #expect(await screen.contains("RESOLUTION-SENT /resolve-first"))
        try await screen.send("/complete")
        #expect(await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.status?.activity == .turnComplete
        })
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.isEmpty == true)
        #expect(await context.events.snapshot().sessions[sibling.sessionID]?.userRequests.map(\.id) == [siblingRequest.id])
        #expect(await coordinator.pendingRequestIDs().count == 1)
        #expect(!FileManager.default.fileExists(atPath: context.state.appendingPathComponent("codex-approvals.log").path))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func unsupportedRequestsStayOpenAndUnansweredAsAnHonestError() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        try await screen.send("permissions please")
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.first)
        #expect(!request.isAnswerable)
        await #expect(throws: SessionRuntimeError.self) {
            try await context.runtime.respond(sessionID: launch.sessionID, requestID: request.id, decision: .accept)
        }
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func lostServerConnectionIsShownOnTheCardAndQuitStillSucceeds() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(await screen.contains("FAKE-CODEX READY"))
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let serverSession = try #require(await context.runtime.codexServerState().internalSessionID)
        let serverPID = try #require(await context.supervisor.session(id: serverSession)?.currentRun?.leader.pid)
        kill(serverPID, SIGKILL)

        #expect(try await SessionRuntimeRig.waitUntil(8) {
            await context.events.snapshot().sessions[launch.sessionID]?.issue?.contains("connection") == true
        })
        // The provider terminal is not silently declared healthy or finished.
        #expect(await context.supervisor.session(id: launch.sessionID) != nil)
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
    }

    @Test func quitWhileACodexTurnIsActiveStopsTheTUIAndTheServer() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        try await screen.send("work 20000")
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.status?.activity == .working
        })
        let report = await context.runtime.shutdown()
        #expect(report.succeeded)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(try await context.catalog.runs().allSatisfy { $0.endReason != nil })
    }

    @Test func aTUIThatDiesAtStartUndoesTheLaunchWithoutWaitingForTheTimeout() async throws {
        let context = try await SessionRuntimeRig.makeContext(
            extraEnvironment: ["LOOM_FAKE_CODEX_EXIT_AT_START": "1"]
        )
        defer { context.cleanup() }
        let clock = ContinuousClock()
        var failure: (any Error)?
        let elapsed = await clock.measure {
            do { _ = try await context.runtime.startConversation(provider: .codex, projectID: nil) }
            catch { failure = error }
        }
        #expect(failure != nil)
        // Not the 3 s identity timeout the fixture context uses.
        #expect(elapsed < .seconds(2))
        // The shared server closes with the last (failed) lease too.
        #expect(try await SessionRuntimeRig.waitUntil { await context.supervisor.runningSessionIDs().isEmpty })
        #expect(await context.runtime.liveRunCount() == 0)
        let cards = try await context.catalog.sessions()
        #expect(cards.count == 1)
        #expect(cards.first?.session.providerConversationID == nil)
        #expect(try await SessionRuntimeRig.waitUntil {
            let leases = await context.runtime.codexServerState().servers
            let server = await context.runtime.codexServerState().internalSessionID
            return leases == 0 && server == nil
        })
        #expect(await context.events.snapshot().sessions[cards[0].session.id]?.issue != nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func quitWhileWaitingForACodexIdentityEndsTheStartAndLeavesNoProcess() async throws {
        let context = try await SessionRuntimeRig.makeContext(
            extraEnvironment: ["LOOM_FAKE_CODEX_HANG_AT_START": "1"]
        )
        defer { context.cleanup() }
        async let started: RuntimeLaunch? = try? await context.runtime.startConversation(provider: .codex, projectID: nil)
        // The TUI runs and the runtime is waiting for a thread that never comes.
        #expect(try await SessionRuntimeRig.waitUntil { await context.supervisor.runningSessionIDs().count == 2 })
        let clock = ContinuousClock()
        var report: ShutdownReport?
        let elapsed = await clock.measure { report = await context.runtime.shutdown() }
        #expect(report?.succeeded == true)
        #expect(await started == nil)
        #expect(elapsed < .seconds(2))
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(await context.runtime.liveRunCount() == 0)
        #expect(try await context.catalog.runs().allSatisfy { $0.endReason != nil })
    }

    @Test func aTUIThatNeverReportsAThreadUndoesTheLaunchAfterTheIdentityTimeout() async throws {
        let context = try await SessionRuntimeRig.makeContext(
            extraEnvironment: ["LOOM_FAKE_CODEX_HANG_AT_START": "1"]
        )
        defer { context.cleanup() }
        var failure: (any Error)?
        do { _ = try await context.runtime.startConversation(provider: .codex, projectID: nil) }
        catch { failure = error }
        #expect(failure as? SessionRuntimeError == .providerIdentityTimeout(.codex))
        // The TUI, its lease and the shared server are all gone; the card says why.
        #expect(try await SessionRuntimeRig.waitUntil { await context.supervisor.runningSessionIDs().isEmpty })
        #expect(await context.runtime.liveRunCount() == 0)
        #expect(await context.runtime.codexServerState().servers == 0)
        let cards = try await context.catalog.sessions()
        #expect(cards.count == 1)
        #expect(await context.events.snapshot().sessions[cards[0].session.id]?.issue?
            .contains("identity") == true)
        #expect(try await context.catalog.runs().allSatisfy { $0.endReason != nil })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aFailedAnswerAfterTheServerDiesStaysOnTheRequestAndIsNeverSuccess() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        try await screen.send("approve me")
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.events.snapshot().sessions[launch.sessionID]?.userRequests.count == 1
        })
        let request = try #require(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.first)
        // Keep this fixture TUI alive after the server closes, so this tests a
        // failed answer on a live run rather than runEnded's request clearing.
        let tui = try #require(await context.supervisor.session(id: launch.sessionID)?.currentRun?.leader)
        try ProcessTable.signal(tui, SIGSTOP)
        var tuiSuspended = true
        defer { if tuiSuspended { try? ProcessTable.signal(tui, SIGCONT) } }
        let serverSession = try #require(await context.runtime.codexServerState().internalSessionID)
        let serverPID = try #require(await context.supervisor.session(id: serverSession)?.currentRun?.leader.pid)
        kill(serverPID, SIGKILL)
        #expect(try await SessionRuntimeRig.waitUntil(8) {
            let issue = await context.events.snapshot().sessions[launch.sessionID]?.issue
            let run = await context.supervisor.session(id: launch.sessionID)?.currentRun
            return issue?.contains("connection") == true && run?.leader == tui
        })

        await #expect(throws: (any Error).self) {
            try await context.runtime.respond(sessionID: launch.sessionID, requestID: request.id, decision: .accept)
        }
        // Still open, with the reason; nothing pretends it was answered.
        let after = try #require(await context.events.snapshot().sessions[launch.sessionID]?.userRequests.first)
        #expect(after.id == request.id)
        #expect(after.summary == request.summary)
        #expect(after.failure != nil)
        #expect(!screen.snapshot.contains("CODEX-TURN-DONE"))
        try ProcessTable.signal(tui, SIGCONT)
        tuiSuspended = false
        let shutdown = await context.runtime.shutdown()
        if !shutdown.succeeded {
            let stopFailure = await context.events.snapshot().sessions[launch.sessionID]?.stopFailure
            print("Server-death Quit errors: \(shutdown.errors); concurrent stop: \(String(describing: stopFailure))")
        }
        #expect(shutdown.succeeded)
    }

    @Test func aNewThreadInASharedFolderBelongsToTheTUIWhoseServerSawIt() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let project = try await Self.project(context, "shared-folder")
        let (first, firstScreen) = try await Self.launchCodex(context, projectID: project.id)
        let (second, secondScreen) = try await Self.launchCodex(context, projectID: project.id)
        #expect(try await SessionRuntimeRig.waitUntil {
            let a = try await threadID(context, first.sessionID)
            let b = try await threadID(context, second.sessionID)
            return a != nil && b != nil
        })
        let before = try await context.catalog.sessions().count

        // Two live runs share a folder, but each has its own server, so the
        // `/new` thread is attributed to the TUI that created it with no guess:
        // the first run moves to the new conversation, the second is untouched.
        try await firstScreen.send("/new")
        #expect(await firstScreen.contains("NEW-THREAD "))
        #expect(try await SessionRuntimeRig.waitUntil { try await context.catalog.sessions().count == before + 1 })
        let moved = try #require(try await context.catalog.sessions().first {
            $0.session.id != first.sessionID && $0.session.id != second.sessionID
        })
        #expect(try await SessionRuntimeRig.waitUntil {
            await context.supervisor.activeSessionID(runID: first.runID) == moved.session.id
        })
        let snapshot = await context.events.snapshot()
        #expect(snapshot.sessions[second.sessionID]?.identity == .known)
        #expect(snapshot.sessions[moved.session.id]?.identity != .ambiguous)
        #expect(await context.supervisor.session(id: second.sessionID)?.currentRun?.id == second.runID)
        _ = secondScreen
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func exitInTheCodexTUIEndsTheRunAndReleasesTheLeaseAndServer() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await Self.launchCodex(context)
        #expect(try await SessionRuntimeRig.waitUntil { try await threadID(context, launch.sessionID) != nil })
        try await screen.send("/exit")
        #expect(try await SessionRuntimeRig.waitUntil(8) {
            let state = await context.runtime.codexServerState()
            return await context.supervisor.session(id: launch.sessionID)?.currentRun == nil
                && state.servers == 0 && state.internalSessionID == nil
        })
        #expect(await context.runtime.liveRunCount() == 0)
        #expect(try await context.catalog.runs().first { $0.id == launch.runID }?.endReason == .processExited)
        #expect(await context.events.snapshot().sessions[launch.sessionID]?.stopFailure == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// Regression: the transport's reader used to poll for 250 ms while holding
    /// the lock `send` needs, so every request paid the reader's poll interval
    /// (a Codex stop took seconds). Requests against a live fixture server must
    /// now round-trip in milliseconds.
    @Test func requestsAreNotDelayedByTheReadersPollInterval() async throws {
        let socketDirectory = URL(fileURLWithPath: "/tmp/lq-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let socket = socketDirectory.appendingPathComponent("s.sock").path
        let server = Process()
        server.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider")
        server.arguments = ["app-server", "--listen", "unix://\(socket)"]
        server.standardOutput = FileHandle.nullDevice
        try server.run()
        defer { server.signalForTeardown() }
        var client: CodexAppServerClient?
        let ready = await SessionRuntimeRig.waitUntil(5) {
            client = try? await CodexAppServerClient.connect(socketPath: socket, clientVersion: "test", timeout: 1)
            return client != nil
        }
        #expect(ready)
        let connected = try #require(client)
        _ = try await connected.backgroundTerminalCount(threadID: "warm-up")
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for _ in 0..<20 { _ = try await connected.backgroundTerminalCount(threadID: "thread") }
        }
        await connected.close()
        // Before the fix this took about 20 x 125 ms on average (>2 s).
        #expect(elapsed < .milliseconds(500), "20 round trips took \(elapsed)")
        await server.terminateAndAwaitExit()
    }
}

private actor ResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private actor ResponseWriteCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
