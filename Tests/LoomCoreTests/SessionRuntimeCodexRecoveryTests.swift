import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// CP5 holistic review SR2: each Codex run owns its server; a stale or moved
/// run never touches another run's server; a dead server never traps a
/// conversation; automatic idle sees the whole run scope.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionRuntimeCodexRecoveryTests {
    typealias Screen = SessionRuntimeTests.Screen

    func threadID(_ context: RuntimeContext, _ sessionID: UUID) async throws -> String? {
        try await context.catalog.session(id: sessionID)?.session.providerConversationID
    }

    func alive(_ context: RuntimeContext, server: UUID?) async -> Bool {
        guard let server else { return false }
        return await context.supervisor.session(id: server)?.currentRun != nil
    }

    /// SR2-P1-1: `/new` moves the run (with its server) to card B. Resuming
    /// the old card A must leave B's server alone.
    @Test(arguments: [false, true])
    func resumingTheOldCardAfterNewKeepsTheMovedRunsServer(scoped: Bool) async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: scoped)
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeCodexTests.launchCodex(context)
        #expect(try await SessionRuntimeTests.waitUntil { try await threadID(context, launch.sessionID) != nil })
        try await screen.send("/new")
        #expect(await screen.contains("NEW-THREAD "))
        #expect(try await SessionRuntimeTests.waitUntil { try await context.catalog.sessions().count == 2 })
        let movedCard = try #require(await context.supervisor.activeSessionID(runID: launch.runID))
        #expect(movedCard != launch.sessionID)
        let bServer = try #require(await context.runtime.codexServerIdentity(forSession: movedCard)?.internalSessionID)

        let screenA = Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: screenA)
        screenA.attach(resumed.terminal)
        #expect(await screenA.contains("RESUMED-CODEX"))
        #expect(await alive(context, server: bServer), "resuming card A stopped the live server of moved card B")
        try await screen.send("b still works")
        #expect(await screen.contains("CODEX-TURN-DONE completed echo b still works", timeout: 5))

        // Both runs stop on their own: B's end never tears down A's server.
        #expect(try await context.runtime.stopConversation(sessionID: movedCard).succeeded)
        let aServer = await context.runtime.codexServerIdentity(forSession: launch.sessionID)?.internalSessionID
        #expect(await alive(context, server: aServer), "the end of B's run tore down A's resumed server")
        try await screenA.send("a still works")
        #expect(await screenA.contains("CODEX-TURN-DONE completed echo a still works", timeout: 5))
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await SessionRuntimeTests.waitUntil(10) { await context.runtime.codexServerState().servers == 0 })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// SR2-P1-2: an ended run not yet reconciled must not tear down the server
    /// of the run that replaced it on the same card. No observer runs, which
    /// fixes the interleaving.
    @Test func staleRecordCannotTearDownTheResumedServer() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false)
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeCodexTests.launchCodex(context)
        #expect(try await SessionRuntimeTests.waitUntil { try await threadID(context, launch.sessionID) != nil })
        try await screen.send("/exit")
        #expect(await SessionRuntimeTests.waitUntil(8) { await context.supervisor.session(id: launch.sessionID)?.currentRun == nil })
        let screenA = Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: screenA)
        screenA.attach(resumed.terminal)
        let server = await context.runtime.codexServerIdentity(forSession: launch.sessionID)?.internalSessionID
        #expect(await alive(context, server: server), "the previous run's reconcile tore down the resumed server")
        try await screenA.send("hello again")
        #expect(await screenA.contains("CODEX-TURN-DONE completed echo hello again", timeout: 5))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// SR2-P1-3: the conversation's own server dies. Stop must succeed on
    /// verified process destruction, empty the scope, and Resume must work.
    @Test(arguments: [false, true])
    func conversationRecoversWithoutQuitAfterItsServerDies(scoped: Bool) async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: scoped)
        defer { context.cleanup() }
        let (launch, _) = try await SessionRuntimeCodexTests.launchCodex(context)
        #expect(try await SessionRuntimeTests.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let serverSession = try #require(await context.runtime.codexServerIdentity(forSession: launch.sessionID)?.internalSessionID)
        let serverPID = try #require(await context.supervisor.session(id: serverSession)?.currentRun?.leader.pid)
        kill(serverPID, SIGKILL)
        #expect(try await SessionRuntimeTests.waitUntil(8) {
            await context.events.snapshot().sessions[launch.sessionID]?.issue?.contains("connection") == true
        })
        if await context.supervisor.session(id: launch.sessionID)?.currentRun != nil {
            let report = try await context.runtime.stopConversation(sessionID: launch.sessionID)
            #expect(report.succeeded, "Stop after server death failed: \(report.errors) \(report.remaining.count) \(String(describing: report.providerStages))")
        }
        #expect(try await SessionRuntimeTests.waitUntil(8) {
            guard await context.runtime.codexServerState().servers == 0 else { return false }
            if !scoped { return true }
            return try await context.supervisor.liveScopeMembers().isEmpty
        })
        #expect(await context.runtime.codexServerState().servers == 0)
        if scoped { #expect(try await context.supervisor.liveScopeMembers().isEmpty) }
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID)
        #expect(resumed.sessionID == launch.sessionID)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// SR2-P1-4: work the conversation forked in its scope blocks automatic
    /// idle; without it idle completes, and only then (the server is gone).
    @Test(arguments: [false, true])
    func automaticIdleSeesTheServersForkedWork(scoped: Bool) async throws {
        let context = try await SessionRuntimeTests.makeContext(
            extraEnvironment: ["LOOM_FAKE_CODEX_SERVER_ESCAPE": "1"], scoped: scoped
        )
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeCodexTests.launchCodex(context)
        #expect(try await SessionRuntimeTests.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let serverSession = try #require(await context.runtime.codexServerIdentity(forSession: launch.sessionID)?.internalSessionID)
        let serverLeader = try #require(await context.supervisor.session(id: serverSession)?.currentRun?.leader)
        let file = context.state.appendingPathComponent("server-escape.\(serverLeader.pid)")
        #expect(await SessionRuntimeTests.waitUntil(5) { FileManager.default.fileExists(atPath: file.path) })
        let pid = try #require(Int32(try String(contentsOf: file, encoding: .utf8)))
        let escape = try #require(try ProcessTable.snapshot().first { $0.identity.pid == pid }?.identity)

        try await screen.send("work 5")
        #expect(await SessionRuntimeTests.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect(await SessionRuntimeTests.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })
        let result = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: Date().addingTimeInterval(4_000)
        )
        guard case let .blocked(reasons) = result else {
            Issue.record("idle was not blocked by the server's forked work: \(result)")
            _ = await context.runtime.shutdown()
            return
        }
        #expect(reasons.contains { if case .nonBaselineDescendants = $0 { true } else { false } })
        #expect(try ProcessTable.snapshot().contains { $0.identity == escape && !$0.zombie })
        #expect(await alive(context, server: serverSession))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [false, true])
    func automaticIdleWithoutForkedWorkCompletesAndEndsTheServer(scoped: Bool) async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: scoped)
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeCodexTests.launchCodex(context)
        #expect(try await SessionRuntimeTests.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let serverSession = try #require(await context.runtime.codexServerIdentity(forSession: launch.sessionID)?.internalSessionID)
        try await screen.send("work 5")
        #expect(await SessionRuntimeTests.waitUntil {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        #expect(await SessionRuntimeTests.waitUntil { await context.runtime.baselineCaptured(sessionID: launch.sessionID) })
        let result = try await context.runtime.lifecycle.evaluateIdle(
            sessionID: launch.sessionID, at: Date().addingTimeInterval(4_000)
        )
        guard case .transitioned = result else {
            Issue.record("idle did not complete: \(result)")
            _ = await context.runtime.shutdown()
            return
        }
        // Idle is published only after the server teardown succeeded: the server's session is gone.
        #expect(await context.supervisor.session(id: serverSession) == nil)
        // The runtime drops its entry for the server in the continuation of the call that began the teardown. The idle
        // stop can be a second caller on the same teardown (the run-end observer begins it too) and return before that
        // continuation has run, as calls waiting on one task resume in no fixed order, so the entry is waited for.
        #expect(await SessionRuntimeTests.waitUntil { await context.runtime.codexServerState().servers == 0 })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// SR2-P2-5: provider error text never reaches the card.
    @Test func providerErrorTextIsNotPublishedVerbatimToTheCard() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_STOP_FAILURE": "prepare"])
        defer { context.cleanup() }
        let (launch, _) = try await SessionRuntimeCodexTests.launchCodex(context)
        #expect(try await SessionRuntimeTests.waitUntil { try await threadID(context, launch.sessionID) != nil })
        let report = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!report.errors.joined().contains("private-provider-error-text"))
        let issue = await context.events.snapshot().sessions[launch.sessionID]?.issue ?? ""
        #expect(!issue.contains("private-provider-error-text"), "raw provider error text on the card: \(issue)")
        try await context.supervisor.registerStopHooks(runID: launch.runID, hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// SR2-P2-10: no socket outlives its server, and a discarded server session
    /// leaves no event state. The started runtime keeps its own task socket in the
    /// same directory (1.8.0), so the server is judged by the sockets it added.
    @Test func teardownRemovesSocketsAndEventState() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        func sockets() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: context.socketDirectory.path)) ?? []).filter { $0.hasSuffix(".sock") })
        }
        let before = sockets()
        let (launch, _) = try await SessionRuntimeCodexTests.launchCodex(context)
        #expect(try await SessionRuntimeTests.waitUntil { try await threadID(context, launch.sessionID) != nil })
        #expect(sockets().subtracting(before).contains { $0.hasPrefix("c-") }, "the server's socket exists while it runs")
        let serverSession = try #require(await context.runtime.codexServerIdentity(forSession: launch.sessionID)?.internalSessionID)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(sockets().subtracting(before).isEmpty, "codex sockets left: \(sockets().subtracting(before))")
        #expect(await context.events.snapshot().sessions[serverSession] == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
