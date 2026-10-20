import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore

private final class SupervisorTestBundleAnchor: NSObject {}

private actor StopTransitionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor ConcurrentLaunchProbe {
    private(set) var finished = false
    private(set) var error: SessionManagementError?
    func resolve(_ error: SessionManagementError?) {
        self.error = error
        finished = true
    }
}

private actor StopPhaseProbe {
    private(set) var preparations = 0
    private(set) var completions = 0
    private let failureOnce: Bool
    init(failureOnce: Bool = false) { self.failureOnce = failureOnce }
    func prepare() { preparations += 1 }
    func complete() throws {
        completions += 1
        if failureOnce && completions == 1 { throw LoomError.message("completed fail once") }
    }
}

private final class CatalogTransitionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false
    var entered: Bool { condition.withLock { waiting } }
    func hold() {
        condition.lock()
        waiting = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private extension SessionCatalog {
    func holdForTransitionTest(_ gate: CatalogTransitionGate) { gate.hold() }
}

private final class CountingOutputSink: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private let byte: UInt8
    private var storedCount = 0

    init(byte: UInt8) { self.byte = byte }

    func receive(_ data: Data) {
        let count = data.reduce(into: 0) { result, candidate in
            if candidate == byte { result += 1 }
        }
        lock.lock()
        storedCount += count
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }
}

private actor StoppedCodexFixture {
    let status: CodexThreadStatus
    private var terminalIDs = ["background-one"]

    init(status: CodexThreadStatus) { self.status = status }

    func read(_ threadID: String) -> CodexThreadSnapshot {
        CodexThreadSnapshot(
            threadID: threadID, lastTurnID: nil, lastTurnStartedAt: nil,
            lastTurnOutcome: nil, lastAssistantMessage: nil, status: status
        )
    }

    func terminals(_ threadID: String) -> [String] { terminalIDs }

    func terminate(_ threadID: String, processID: String) {
        terminalIDs.removeAll { $0 == processID }
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct ProcessSupervisorTests {
    private var childPath: String {
        Bundle(for: SupervisorTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    private func launch(_ mode: String, sessionID: UUID,
                        supervisor: ProcessSupervisor,
                        outputSink: (any TerminalOutputSink)? = nil,
                        provider: ManagedSession.Provider = .synthetic,
                        providerConversationID: String? = nil) async throws -> ManagedSessionLaunch {
        let session = ManagedSession(id: sessionID, provider: provider,
                                     providerConversationID: providerConversationID,
                                     workingDirectory: FileManager.default.temporaryDirectory.path)
        try await supervisor.createSession(session)
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        return try await supervisor.launch(sessionID: sessionID, executable: childPath,
                                           arguments: [mode], environment: environment,
                                           outputSink: outputSink)
    }

    private func ready(terminal: TerminalEndpoint) async throws -> [String: Any] {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            data.append(terminal.readAvailable())
            if let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
               let json = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                return object
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LoomError.message("Fixture not ready: \(String(decoding: data, as: UTF8.self))")
    }

    private func executeCatalogSQL(_ sql: String, at url: URL) throws {
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 1_000)
        try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func scrollbackAllocatesLazilyAndPreservesNewestBytes() {
        let scrollback = TerminalScrollback(capacity: 8)
        #expect(scrollback.allocatedByteCount == 0)
        scrollback.receive(Data("abc".utf8))
        #expect(scrollback.count == 3)
        #expect(scrollback.allocatedByteCount == 8)
        scrollback.receive(Data("defghijk".utf8))
        #expect(String(decoding: scrollback.drain(), as: UTF8.self) == "defghijk")
        #expect(scrollback.count == 0)
    }

    @Test func tenSilentSessionsDoNotPreallocateScrollbackCapacity() async throws {
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger()
        )
        var terminals: [TerminalEndpoint] = []
        for _ in 0..<10 {
            let sessionID = UUID()
            try await supervisor.createSession(ManagedSession(
                id: sessionID, provider: .synthetic,
                workingDirectory: FileManager.default.temporaryDirectory.path
            ))
            let environment = LaunchEnvironment.make(
                path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
                sessionID: sessionID
            )
            terminals.append(try await supervisor.launch(
                sessionID: sessionID, executable: childPath,
                arguments: ["stubborn", "--silent"], environment: environment
            ).terminal)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(terminals.allSatisfy { $0.scrollback?.allocatedByteCount == 0 })
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func managedRunMarkerIsDistinctFromAppOwnershipRun() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let launch = try await launch("inspect", sessionID: sessionID, supervisor: supervisor)
        let result = try await ready(terminal: launch.terminal)
        let pid = try #require(result["pid"] as? Int32)
        let run = try #require(launch.session.currentRun)

        #expect(run.id != supervisor.ownershipRunID)
        #expect(ProcessTable.runID(pid: pid) == supervisor.ownershipRunID.uuidString)
        #expect(ProcessTable.managedRunID(pid: pid) == run.id.uuidString)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func stoppingOneSessionLeavesTheOtherSessionRunning() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let firstID = UUID(), secondID = UUID()
        let firstLaunch = try await launch("escape", sessionID: firstID, supervisor: supervisor)
        let secondLaunch = try await launch("stubborn", sessionID: secondID, supervisor: supervisor)
        let first = try await ready(terminal: firstLaunch.terminal)
        let second = try await ready(terminal: secondLaunch.terminal)
        let firstLeader = try #require(first["pid"] as? Int32)
        let firstDescendant = try #require(first["descendantPID"] as? Int32)
        let secondLeader = try #require(second["pid"] as? Int32)

        let report = try await supervisor.stop(sessionID: firstID, graceSeconds: 0.2)
        #expect(report.succeeded)
        let snapshot = try ProcessTable.snapshot()
        #expect(!snapshot.contains { [firstLeader, firstDescendant].contains($0.identity.pid) && !$0.zombie })
        #expect(snapshot.contains { $0.identity.pid == secondLeader && !$0.zombie })
        #expect(try await supervisor.sample(sessionID: secondID).contains { $0.identity.pid == secondLeader })
        let stoppedSession = await supervisor.session(id: firstID)
        let runningSession = await supervisor.session(id: secondID)
        #expect(stoppedSession?.currentRun == nil)
        #expect(runningSession?.currentRun != nil)

        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func unverifiedProviderStopLeavesRunAlive() async throws {
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger()
        )
        let sessionID = UUID()
        let launch = try await launch(
            "stubborn", sessionID: sessionID, supervisor: supervisor
        )
        _ = try await ready(terminal: launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await supervisor.registerStopHooks(
            runID: runID,
            hooks: ManagedRunStopHooks(
                prepare: { throw LoomError.message("server still active") },
                completed: {}
            )
        )
        let failed = try await supervisor.stop(
            sessionID: sessionID, graceSeconds: 0.2
        )
        #expect(!failed.succeeded)
        #expect(failed.signals.isEmpty)
        #expect(await supervisor.session(id: sessionID)?.currentRun?.id == runID)
        try await supervisor.registerStopHooks(
            runID: runID,
            hooks: ManagedRunStopHooks(prepare: {}, completed: {})
        )
        #expect((try await supervisor.stop(
            sessionID: sessionID, graceSeconds: 0.2
        )).succeeded)
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func unverifiedStopStaysInLatestEventStateUntilAVerifiedStop() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let launch = try await launch("interactive", sessionID: sessionID, supervisor: supervisor)
        let runID = try #require(launch.session.currentRun?.id)
        try await supervisor.registerStopHooks(
            runID: runID,
            hooks: ManagedRunStopHooks(
                prepare: { throw LoomError.message("server still active") },
                completed: {}
            )
        )
        // A consumer that never reads intermediate frames.
        let stream = await supervisor.events.subscribe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!(try await supervisor.stop(sessionID: sessionID, graceSeconds: 0.2)).succeeded)
        var state = try #require(await iterator.next()?.sessions[sessionID])
        #expect(state.runID == runID)
        #expect(state.stopFailure?.contains("Provider prepare failed (providerError)") == true)
        #expect(state.stopFailure?.contains("server still active") == false)

        try await supervisor.registerStopHooks(
            runID: runID, hooks: ManagedRunStopHooks(prepare: {}, completed: {})
        )
        #expect((try await supervisor.stop(sessionID: sessionID, graceSeconds: 0.2)).succeeded)
        state = try #require(await supervisor.events.snapshot().sessions[sessionID])
        #expect(state.runID == nil)
        #expect(state.stopFailure == nil)
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func leaderExitWithUnverifiedStopIsPersistentForEveryConsumer() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let launch = try await launch("interactive", sessionID: sessionID, supervisor: supervisor)
        let runID = try #require(launch.session.currentRun?.id)
        try await supervisor.registerStopHooks(
            runID: runID,
            hooks: ManagedRunStopHooks(
                prepare: { throw LoomError.message("background work still running") },
                completed: {}
            )
        )
        // Ctrl-D ends the interactive fixture: the leader exits by itself.
        _ = try await launch.terminal.write(Data([0x04]))
        var state = await supervisor.events.snapshot().sessions[sessionID]
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while state?.stopFailure == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
            state = await supervisor.events.snapshot().sessions[sessionID]
        }
        #expect(state?.stopFailure?.contains("Provider prepare failed (providerError)") == true)
        #expect(state?.stopFailure?.contains("background work still running") == false)
        #expect(state?.runID == runID)
        // A consumer that subscribes afterwards still sees it.
        let late = await supervisor.events.subscribe()
        var iterator = late.makeAsyncIterator()
        #expect(await iterator.next()?.sessions[sessionID]?.stopFailure != nil)
        try await supervisor.registerStopHooks(
            runID: runID, hooks: ManagedRunStopHooks(prepare: {}, completed: {})
        )
        _ = try await supervisor.stop(sessionID: sessionID, graceSeconds: 0.2)
        #expect(await supervisor.events.snapshot().sessions[sessionID]?.stopFailure == nil)
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func outputAndLeaderExitAreDeliveredWithoutSampling() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let launch = try await launch("quick-exit", sessionID: sessionID, supervisor: supervisor)
        let output = try await ready(terminal: launch.terminal)
        #expect(output["mode"] as? String == "quick-exit")

        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var session = await supervisor.session(id: sessionID)
        while session?.currentRun != nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
            session = await supervisor.session(id: sessionID)
        }
        #expect(session?.currentRun == nil)
        #expect(await supervisor.lastStopReport(sessionID: sessionID)?.succeeded == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func eventReaderDrainsOutputLargerThanOneHandlerBudget() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let launch = try await launch("burst-exit", sessionID: sessionID, supervisor: supervisor)
        let expected = 512 * 1024
        var received = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            let data = launch.terminal.readAvailable()
            received += data.reduce(into: 0) { count, byte in
                if byte == 0x5a { count += 1 }
            }
            if received == expected { break }
            try await Task.sleep(for: .milliseconds(5))
        } while ProcessInfo.processInfo.systemUptime < deadline

        #expect(received == expected)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func hiddenSessionContinuouslyDrainsOutputBeyondScrollbackCapacity() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let sink = CountingOutputSink(byte: 0x59)
        let launch = try await launch("large-burst-exit", sessionID: sessionID,
                                      supervisor: supervisor, outputSink: sink)
        #expect(launch.terminal.scrollback == nil)
        let expected = 8 * 1024 * 1024
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while sink.count < expected, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sink.count == expected)
        while await supervisor.session(id: sessionID)?.currentRun != nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await supervisor.session(id: sessionID)?.currentRun == nil)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func slowEnvironmentCaptureDoesNotBlockTerminalIOOrSupervisorQueries() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let launch = try await launch("stubborn", sessionID: sessionID, supervisor: supervisor)
        _ = try await ready(terminal: launch.terminal)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-slow-environment-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "sleep 0.4\nexport PATH=/usr/bin:/bin\n".write(
            to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
        )
        let parent = [
            "HOME": root.path, "SHELL": "/bin/zsh", "USER": NSUserName(),
            "PATH": "/usr/bin:/bin",
        ]
        let resolution = Task {
            try await supervisor.terminalEnvironment(
                parent: parent, session: [:], testZDOTDIR: root, timeout: 2
            )
        }
        try await Task.sleep(for: .milliseconds(50))

        let started = ProcessInfo.processInfo.systemUptime
        #expect(try await launch.terminal.write(Data([0])) == 1)
        try await launch.terminal.resize(rows: 30, columns: 90)
        _ = launch.terminal.readAvailable()
        #expect(await supervisor.session(id: sessionID) != nil)
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.2)
        #expect(try await resolution.value.environment["PATH"] == "/usr/bin:/bin")
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func naturalExitCleansEscapedDescendantAndAllowsRelaunch() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        let first = try await launch("escape-exit", sessionID: sessionID, supervisor: supervisor)
        let result = try await ready(terminal: first.terminal)
        let descendantPID = try #require(result["descendantPID"] as? Int32)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while await supervisor.session(id: sessionID)?.currentRun != nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!(try ProcessTable.snapshot().contains {
            $0.identity.pid == descendantPID && !$0.zombie
        }))

        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        let second = try await supervisor.launch(
            sessionID: sessionID, executable: childPath,
            arguments: ["stubborn"], environment: environment
        )
        _ = try await ready(terminal: second.terminal)
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func launchRequiresTheMatchingConversationMarker() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let wrong = LaunchEnvironment.make(path: "/usr/bin:/bin",
                                           runID: supervisor.ownershipRunID,
                                           sessionID: UUID())
        do {
            _ = try await supervisor.launch(sessionID: sessionID, executable: childPath,
                                            arguments: ["inspect"], environment: wrong)
            Issue.record("Launch accepted a different session's ownership marker")
        } catch let error as SessionManagementError {
            #expect(error == .invalidOwnershipMarkers(sessionID: sessionID))
        }
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func catalogBackedShutdownRestoresConversationWithoutStartingAProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-supervisor-catalog-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let sessionID = UUID()
        let launch = try await launch("stubborn", sessionID: sessionID, supervisor: supervisor)
        _ = try await ready(terminal: launch.terminal)

        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
        let runs = try await catalog.runs()
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.endedAt != nil)
        #expect(run.endReason == .applicationQuit)
        #expect(run.exitStatus != nil)

        let reopened = try await ProcessSupervisor.restoring(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let restored = await reopened.managedSessions()
        #expect(restored.count == 1)
        #expect(restored.first?.id == sessionID)
        #expect(restored.first?.currentRun == nil)
        #expect((await reopened.shutdown()).succeeded)
    }

    @Test func shutdownDoesNotWaitIndefinitelyForALockedCatalogLaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-supervisor-locked-catalog-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("sessions.sqlite3")
        let catalog = try SessionCatalog(url: databaseURL)
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))

        var lockConnection: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &lockConnection) == SQLITE_OK)
        let connection = try #require(lockConnection)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        let launch = Task {
            try await supervisor.launch(
                sessionID: sessionID, executable: childPath,
                arguments: ["stubborn"], environment: environment
            )
        }
        let publishDeadline = ProcessInfo.processInfo.systemUptime + 1
        while await supervisor.session(id: sessionID)?.currentRun == nil,
              ProcessInfo.processInfo.systemUptime < publishDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await supervisor.session(id: sessionID)?.currentRun != nil)

        let started = ProcessInfo.processInfo.systemUptime
        let report = await supervisor.shutdown(
            graceSeconds: 0.05, pendingOperationGraceSeconds: 0.1
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(elapsed < 1)
        #expect(report.remaining.isEmpty)
        #expect(report.errors.contains { $0.contains("Timed out waiting for pending operations") })

        #expect(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        do {
            _ = try await launch.value
            Issue.record("Launch completed after shutdown began")
        } catch let error as SessionManagementError {
            #expect(error == .shutdownStarted)
        }
        #expect(await supervisor.session(id: sessionID)?.currentRun == nil)
        let runs = try await catalog.runs()
        #expect(runs.count == 1)
        #expect(runs.first?.endReason == .applicationQuit)
    }

    @Test func shutdownStopsTenStubbornSessionsWithinOneSharedSignalWindow() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        var sessionIDs: [UUID] = []
        for _ in 0..<10 {
            let sessionID = UUID()
            sessionIDs.append(sessionID)
            let launch = try await launch("stubborn", sessionID: sessionID, supervisor: supervisor)
            _ = try await ready(terminal: launch.terminal)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let report = await supervisor.shutdown(graceSeconds: 0.2)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(report.succeeded)
        #expect(elapsed < 2.5)
        var perSessionSignalCount = 0
        for sessionID in sessionIDs {
            let sessionReport = await supervisor.lastStopReport(sessionID: sessionID)
            #expect(sessionReport?.succeeded == true)
            perSessionSignalCount += sessionReport?.signals.count ?? 0
        }
        #expect(report.signals.count == perSessionSignalCount)
    }

    @Test func failedCodexThreadStatusesStopBackgroundWorkAndTUI() async throws {
        for status in [CodexThreadStatus.systemError, .notLoaded] {
            let supervisor = try ProcessSupervisor(
                ledger: OwnershipLedger()
            )
            let sessionID = UUID()
            let launch = try await launch(
                "stubborn", sessionID: sessionID, supervisor: supervisor,
                provider: .codex
            )
            _ = try await ready(terminal: launch.terminal)
            let runID = try #require(launch.session.currentRun?.id)
            let fixture = StoppedCodexFixture(status: status)
            try await supervisor.registerStopHooks(
                runID: runID,
                hooks: ManagedRunStopHooks(
                    prepare: {
                        try await CodexAppServerClient.stopThreadWork(
                            "failed-thread",
                            read: { await fixture.read($0) },
                            terminals: { await fixture.terminals($0) },
                            interrupt: { _, _ in
                                throw LoomError.message("Unexpected active turn")
                            },
                            terminate: { await fixture.terminate($0, processID: $1) }
                        )
                    },
                    completed: {}
                )
            )
            let report = try await supervisor.stop(
                sessionID: sessionID, graceSeconds: 0.2
            )
            #expect(report.succeeded)
            #expect(await fixture.terminals("failed-thread").isEmpty)
            #expect(await supervisor.session(id: sessionID)?.currentRun == nil)
            #expect(try !ProcessTable.snapshot().contains {
                $0.identity.pid == launch.terminal.pid && !$0.zombie
            })
        }
    }

    @Test func claudeClearAndResumeMoveOneRunAcrossDurableConversations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-claude-transition-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let launchSessionID = UUID()
        let launch = try await launch(
            "stubborn", sessionID: launchSessionID, supervisor: supervisor,
            provider: .claude
        )
        _ = try await ready(terminal: launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)

        let claude = ClaudeSessionAdapter(supervisor: supervisor)
        let startup = try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID,
            providerSessionID: "claude-one", event: "SessionStart",
            fields: ["source": "startup"]
        )
        _ = try await claude.receive(startup)
        #expect(await supervisor.session(id: launchSessionID)?.providerConversationID
                == "claude-one")

        let promptAt = Date(timeIntervalSince1970: 500)
        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID,
            providerSessionID: "claude-one", event: "UserPromptSubmit"
        ), receivedAt: promptAt)
        #expect(try await catalog.session(id: launchSessionID)?.lastUsedAt == promptAt)

        let clearAt = Date(timeIntervalSince1970: 510)
        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID,
            providerSessionID: "claude-two", event: "SessionStart",
            fields: ["source": "clear"]
        ), receivedAt: clearAt)
        let clearedSessionID = try #require(await supervisor.activeSessionID(runID: runID))
        #expect(clearedSessionID != launchSessionID)
        #expect(await supervisor.session(id: launchSessionID)?.currentRun == nil)
        #expect(await supervisor.session(id: clearedSessionID)?.currentRun?.id == runID)
        #expect(try await catalog.session(id: launchSessionID)?.lifecycle == .idle)
        #expect(try await catalog.session(id: clearedSessionID)?.lifecycle == .active)

        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID,
            providerSessionID: "claude-one", event: "SessionStart",
            fields: ["source": "resume"]
        ), receivedAt: Date(timeIntervalSince1970: 520))
        #expect(await supervisor.activeSessionID(runID: runID) == launchSessionID)
        #expect(await supervisor.session(id: launchSessionID)?.currentRun?.id == runID)
        #expect(await supervisor.session(id: clearedSessionID)?.currentRun == nil)
        #expect((try await catalog.runSessionLinks(runID: runID)).count == 3)
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    /// Feedback 1: the activity time follows a prompt, a finished turn and a /clear or resume
    /// identity change; a view moves only the use date.
    @Test func claudePromptTurnAndIdentityChangesMoveTheActivityTimeButAViewDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-claude-activity-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let launchSessionID = UUID()
        let launch = try await launch("stubborn", sessionID: launchSessionID, supervisor: supervisor, provider: .claude)
        _ = try await ready(terminal: launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        let claude = ClaudeSessionAdapter(supervisor: supervisor)
        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID, providerSessionID: "claude-one",
            event: "SessionStart", fields: ["source": "startup"]
        ), receivedAt: Date(timeIntervalSince1970: 400))
        let lifecycle = SessionLifecycleController(supervisor: supervisor, catalog: catalog)

        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID, providerSessionID: "claude-one",
            event: "UserPromptSubmit"
        ), receivedAt: Date(timeIntervalSince1970: 500))
        #expect(try await catalog.session(id: launchSessionID)?.lastActivityAt == Date(timeIntervalSince1970: 500))

        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID, providerSessionID: "claude-one", event: "Stop"
        ), receivedAt: Date(timeIntervalSince1970: 540))
        let finished = try #require(await catalog.session(id: launchSessionID))
        #expect(finished.lastActivityAt == Date(timeIntervalSince1970: 540), "a finished turn is activity")
        #expect(finished.lastUsedAt == Date(timeIntervalSince1970: 540), "and extends the idle clock")

        try await lifecycle.markViewed(sessionID: launchSessionID, at: Date(timeIntervalSince1970: 9_000))
        let viewed = try #require(await catalog.session(id: launchSessionID))
        #expect(viewed.lastUsedAt == Date(timeIntervalSince1970: 9_000))
        #expect(viewed.lastActivityAt == Date(timeIntervalSince1970: 540), "a view is not activity")

        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID, providerSessionID: "claude-two",
            event: "SessionStart", fields: ["source": "clear"]
        ), receivedAt: Date(timeIntervalSince1970: 9_100))
        let clearedID = try #require(await supervisor.activeSessionID(runID: runID))
        #expect(try await catalog.session(id: clearedID)?.lastActivityAt == Date(timeIntervalSince1970: 9_100))

        _ = try await claude.receive(try claudeEnvelope(
            launchSessionID: launchSessionID, runID: runID, providerSessionID: "claude-one",
            event: "SessionStart", fields: ["source": "resume"]
        ), receivedAt: Date(timeIntervalSince1970: 9_200))
        #expect(try await catalog.session(id: launchSessionID)?.lastActivityAt == Date(timeIntervalSince1970: 9_200),
                "a provider identity change back to an existing session is use of it")
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func pendingResumeReservesDestinationAgainstLaunchAndAnotherAdoption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-adopt-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CatalogTransitionGate()
        defer { gate.release() }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"),
                                        existingRunTransitionFailpoint: { gate.hold() })
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let target = UUID(), source = UUID(), competing = UUID()
        let previous = try await launch("stubborn", sessionID: target, supervisor: supervisor,
                                        provider: .claude, providerConversationID: "A")
        _ = try await ready(terminal: previous.terminal)
        #expect(try await supervisor.stop(sessionID: target, graceSeconds: 0.02).succeeded)
        let live = try await launch("stubborn", sessionID: source, supervisor: supervisor,
                                   provider: .claude, providerConversationID: "B")
        let other = try await launch("stubborn", sessionID: competing, supervisor: supervisor,
                                    provider: .claude, providerConversationID: "C")
        _ = try await ready(terminal: live.terminal)
        _ = try await ready(terminal: other.terminal)
        let run = try #require(live.session.currentRun?.id)
        let otherRun = try #require(other.session.currentRun?.id)
        let adoption = Task { try await supervisor.adoptConversation(runID: run, conversationID: "A", transition: .resume) }
        for _ in 0..<1_000 where !gate.entered { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        let probe = ConcurrentLaunchProbe()
        let environment = LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: target)
        let rejectedLaunch = Task {
            do {
                _ = try await supervisor.launch(sessionID: target, executable: childPath,
                                                 arguments: ["stubborn"], environment: environment)
                await probe.resolve(nil)
            } catch { await probe.resolve(error as? SessionManagementError) }
        }
        for _ in 0..<1_000 {
            let finished = await probe.finished
            let running = await supervisor.session(id: target)?.currentRun != nil
            if finished || running { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await probe.finished)
        #expect(await probe.error == .sessionAlreadyRunning(target))
        #expect(await supervisor.session(id: target)?.currentRun == nil)
        let rejectedAdoption = Task { try await supervisor.adoptConversation(runID: otherRun, conversationID: "A", transition: .resume) }
        gate.release()
        #expect(try await adoption.value == target)
        await rejectedLaunch.value
        await #expect(throws: SessionManagementError.conversationAlreadyRunning(provider: .claude, conversationID: "A")) {
            try await rejectedAdoption.value
        }
        #expect(await supervisor.session(id: target)?.currentRun?.id == run)
        #expect(await supervisor.session(id: source)?.currentRun == nil)
        let links = try await catalog.runSessionLinks(runID: run)
        #expect(links.count == 2)
        #expect(links.filter { $0.unlinkedAt == nil }.map(\.sessionID) == [target])
        #expect(try await supervisor.stop(sessionID: target, graceSeconds: 0.02).succeeded)
        #expect(try await supervisor.stop(sessionID: competing, graceSeconds: 0.02).succeeded)
        let shutdown = await supervisor.shutdown()
        #expect(shutdown.succeeded && shutdown.remaining.isEmpty)
        #expect(await supervisor.runningSessionIDs().isEmpty)
    }

    @Test func failedResumeReleasesDestinationReservationWithoutChangingOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-adopt-target-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"),
                                        existingRunTransitionFailpoint: { throw LoomError.message("transition failpoint") })
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let target = ManagedSession(provider: .claude, providerConversationID: "A", workingDirectory: root.path)
        try await supervisor.createSession(target)
        let source = UUID()
        let live = try await launch("stubborn", sessionID: source, supervisor: supervisor,
                                   provider: .claude, providerConversationID: "B")
        _ = try await ready(terminal: live.terminal)
        let run = try #require(live.session.currentRun?.id)
        await #expect(throws: (any Error).self) {
            try await supervisor.adoptConversation(runID: run, conversationID: "A", transition: .resume)
        }
        #expect(await supervisor.activeSessionID(runID: run) == source)
        #expect(await supervisor.session(id: target.id)?.currentRun == nil)
        #expect(try await catalog.runSessionLinks(runID: run).count == 1)
        let environment = LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: target.id)
        let next = try await supervisor.launch(sessionID: target.id, executable: childPath,
                                               arguments: ["stubborn"], environment: environment)
        _ = try await ready(terminal: next.terminal)
        #expect((await supervisor.shutdown()).succeeded)
        #expect(await supervisor.runningSessionIDs().isEmpty)
    }

    @Test func completedFailurePreservesRunAndConcurrentStopDoesNotConsumeRetry() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let id = UUID()
        let live = try await launch("stubborn", sessionID: id, supervisor: supervisor, provider: .claude, providerConversationID: "A")
        _ = try await ready(terminal: live.terminal)
        let run = try #require(live.session.currentRun?.id)
        let probe = StopPhaseProbe(failureOnce: true), gate = StopTransitionGate()
        try await supervisor.registerStopHooks(runID: run, hooks: ManagedRunStopHooks(
            prepare: { await probe.prepare() }, completed: {
                if await probe.completions == 0 { await gate.wait() }
                try await probe.complete()
            }))
        let first = Task { try await supervisor.stop(sessionID: id, graceSeconds: 0.02) }
        for _ in 0..<1_000 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await gate.entered)
        let second = Task { try await supervisor.stop(sessionID: id, graceSeconds: 0.02) }
        try await Task.sleep(for: .milliseconds(20))
        await gate.release()
        let firstReport = try await first.value, secondReport = try await second.value
        #expect(!firstReport.succeeded && !secondReport.succeeded)
        #expect(firstReport.runID == secondReport.runID)
        #expect(secondReport.providerStages?.last?.outcome == "failed")
        #expect(firstReport.remainingCountVerified == true && firstReport.remaining.isEmpty)
        #expect(await supervisor.session(id: id)?.currentRun?.id == run)
        #expect(await supervisor.session(id: id)?.currentRun?.state == .stopping)
        #expect(await supervisor.runContext(runID: run) != nil)
        // A real PTY exit callback must not silently retry completed().
        for _ in 0..<100 where await live.terminal.exitStatus() == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await live.terminal.exitStatus() != nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.preparations == 1)
        #expect(await probe.completions == 1)
        await #expect(throws: SessionManagementError.runNotFound(run)) {
            try await supervisor.adoptConversation(runID: run, conversationID: "B", transition: .new)
        }
        let retried = try? await supervisor.stop(sessionID: id, graceSeconds: 0.02)
        #expect(retried?.succeeded == true)
        #expect(await probe.preparations == 1)
        #expect(await probe.completions == 2)
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == true)
        #expect(await supervisor.events.snapshot().sessions[id]?.stopFailure == nil)
        #expect(await supervisor.runContext(runID: run) == nil)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// V22 part 2: the CLI writes ids in lower case and a Swift `uuidString` is upper case. A hook that names the id the run's card
    /// already holds, in either case, adopts nothing and moves nothing: no new card, no move of the run.
    @Test(arguments: ["abcdef12-0000-4000-8000-000000000001", "ABCDEF12-0000-4000-8000-000000000001"])
    func aConversationIdThatDiffersOnlyInCaseIsTheSameConversation(hook: String) async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let id = UUID()
        let stored = "abcdef12-0000-4000-8000-000000000001"
        let live = try await launch("stubborn", sessionID: id, supervisor: supervisor,
                                    provider: .claude, providerConversationID: stored)
        _ = try await ready(terminal: live.terminal)
        let run = try #require(live.session.currentRun?.id)
        for transition in [ConversationTransition.new, .resume, .automatic] {
            #expect(try await supervisor.adoptConversation(runID: run, conversationID: hook, transition: transition) == id)
        }
        #expect(await supervisor.session(id: id)?.currentRun?.id == run)
        #expect(await supervisor.session(id: id)?.providerConversationID == stored)
        #expect((await supervisor.shutdown(graceSeconds: 0.02)).succeeded)
    }

    @Test(arguments: [false, true])
    func unknownOwnershipCountPreservesContextUntilVerifiedRetry(quitting: Bool) async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let id = UUID()
        let live = try await launch("stubborn", sessionID: id, supervisor: supervisor)
        _ = try await ready(terminal: live.terminal)
        let run = try #require(live.session.currentRun?.id), probe = StopPhaseProbe()
        try await supervisor.registerStopHooks(runID: run, hooks: ManagedRunStopHooks(
            prepare: { await probe.prepare() }, completed: { try await probe.complete() }))
        await supervisor.setOwnershipSamplingFailpointForTesting { throw LoomError.message("ownership sample failpoint") }
        if quitting {
            let report = await supervisor.shutdown(graceSeconds: 0.02)
            #expect(!report.succeeded && report.remainingCountVerified == false)
        }
        else { #expect(!(try await supervisor.stop(sessionID: id, graceSeconds: 0.02)).succeeded) }
        #expect(await supervisor.lastStopReport(sessionID: id)?.remainingCountVerified == false)
        #expect(await supervisor.runContext(runID: run) != nil)
        #expect(await supervisor.session(id: id)?.currentRun?.id == run)
        #expect(await probe.completions == 0)
        #expect(await supervisor.lastStopReport(sessionID: id)?.signals.isEmpty == true)
        #expect(await live.terminal.exitStatus() == nil)
        await supervisor.setOwnershipSamplingFailpointForTesting(nil)
        if quitting { #expect((await supervisor.shutdown(graceSeconds: 0.02)).succeeded) }
        else {
            let retried = try? await supervisor.stop(sessionID: id, graceSeconds: 0.02)
            #expect(retried?.succeeded == true)
            #expect(await probe.preparations == 2)
            #expect(await probe.completions == 1)
        }
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test(arguments: [false, true])
    func catalogFinishTimeoutRetainsContextUntilExplicitVerifiedRetry(quitting: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-stop-catalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let id = UUID()
        let live = try await launch("stubborn", sessionID: id, supervisor: supervisor)
        _ = try await ready(terminal: live.terminal)
        let run = try #require(live.session.currentRun?.id), probe = StopPhaseProbe(), gate = CatalogTransitionGate()
        defer { gate.release() }
        try await supervisor.registerStopHooks(runID: run, hooks: ManagedRunStopHooks(
            prepare: { await probe.prepare() }, completed: { try await probe.complete() }))
        let hold = Task.detached { await catalog.holdForTransitionTest(gate) }
        for _ in 0..<1_000 where !gate.entered { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        if quitting { #expect(!(await supervisor.shutdown(graceSeconds: 0.02, pendingOperationGraceSeconds: 0.05)).succeeded) }
        else { #expect(!(try await supervisor.stop(sessionID: id, graceSeconds: 0.02)).succeeded) }
        #expect(await supervisor.runContext(runID: run) != nil)
        #expect(await supervisor.session(id: id)?.currentRun?.id == run)
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == false)
        gate.release()
        await hold.value
        for _ in 0..<100 {
            if try await catalog.runs().first(where: { $0.id == run })?.endedAt != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await catalog.runs().first { $0.id == run }?.endedAt != nil)
        // A late successful write alone must not replace the failed Stop report.
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == false)
        if quitting { #expect((await supervisor.shutdown(graceSeconds: 0.02)).succeeded) }
        else {
            #expect((try? await supervisor.stop(sessionID: id, graceSeconds: 0.02))?.succeeded == true)
            #expect(await probe.preparations == 1)
            #expect(await probe.completions == 1)
        }
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == true)
        #expect(await supervisor.runContext(runID: run) == nil)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test(arguments: [false, true])
    func settledCatalogFailureNeedsFreshDurableSuccessBeforeExplicitStopRetry(quitting: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-finish-error-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.sqlite3"), catalog = try SessionCatalog(url: url)
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let id = UUID()
        let live = try await launch("stubborn", sessionID: id, supervisor: supervisor)
        _ = try await ready(terminal: live.terminal)
        let run = try #require(live.session.currentRun?.id), probe = StopPhaseProbe()
        try await supervisor.registerStopHooks(runID: run, hooks: ManagedRunStopHooks(
            prepare: { await probe.prepare() }, completed: { try await probe.complete() }))
        try executeCatalogSQL("CREATE TRIGGER fail_finish BEFORE UPDATE OF ended_at ON runs BEGIN SELECT RAISE(FAIL, 'finish failpoint'); END", at: url)
        if quitting { #expect(!(await supervisor.shutdown(graceSeconds: 0.02)).succeeded) }
        else { #expect(!(try await supervisor.stop(sessionID: id, graceSeconds: 0.02)).succeeded) }
        #expect(await supervisor.runContext(runID: run) != nil)
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == false)
        #expect(try await catalog.runs().first { $0.id == run }?.endedAt == nil)
        try executeCatalogSQL("DROP TRIGGER fail_finish", at: url)
        // Even after failed Quit, Keep Open permits explicit Stop. Verified
        // global destruction must avoid calling the closed provider's hooks.
        #expect((try? await supervisor.stop(sessionID: id, graceSeconds: 0.02))?.succeeded == true)
        #expect(await probe.preparations == (quitting ? 0 : 1))
        #expect(await probe.completions == (quitting ? 0 : 1))
        #expect(try await catalog.runs().first { $0.id == run }?.endedAt != nil)
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == true)
        #expect(await supervisor.runContext(runID: run) == nil)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func quitWaitsForOngoingStopAndRejectsNewStopFinalizers() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let id = UUID()
        let live = try await launch("stubborn", sessionID: id, supervisor: supervisor)
        _ = try await ready(terminal: live.terminal)
        let run = try #require(live.session.currentRun?.id), gate = StopTransitionGate()
        try await supervisor.registerStopHooks(runID: run, hooks: ManagedRunStopHooks(prepare: { await gate.wait() }, completed: {}))
        let stop = Task { try await supervisor.stop(sessionID: id, graceSeconds: 0.02) }
        for _ in 0..<1_000 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await gate.entered)
        let quitTask = Task { await supervisor.shutdown(graceSeconds: 0.02, pendingOperationGraceSeconds: 0.2) }
        // The pre-existing launch admission guard exposes when this fresh
        // supervisor has entered shutdown, without a new product getter.
        var shutdownEntered = false
        for _ in 0..<100 {
            do {
                _ = try await supervisor.launch(sessionID: UUID(), executable: childPath,
                                                 environment: [:])
            } catch let error as SessionManagementError {
                if error == .shutdownStarted { shutdownEntered = true; break }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(shutdownEntered)
        await #expect(throws: SessionManagementError.shutdownStarted) {
            try await supervisor.stop(sessionID: id, graceSeconds: 0.02)
        }
        let quit = await quitTask.value
        #expect(!quit.succeeded && quit.signals.isEmpty)
        #expect(quit.errors.contains { $0.contains("stop") })
        #expect(await supervisor.runContext(runID: run) != nil)
        // Keep Open after a failed Quit must permit an explicit Stop retry.
        let explicitRetry = Task { try await supervisor.stop(sessionID: id, graceSeconds: 0.02) }
        try await Task.sleep(for: .milliseconds(20))
        await gate.release()
        #expect(try await stop.value.succeeded)
        #expect((try? await explicitRetry.value)?.succeeded == true)
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == true)
        #expect(await supervisor.events.snapshot().sessions[id]?.stopFailure == nil)
        #expect((await supervisor.shutdown(graceSeconds: 0.02)).succeeded)
        #expect(await supervisor.runningSessionIDs().isEmpty)
    }

    @Test func unknownCountReportsRejectSuccessAndLegacyShutdownJSONStillDecodes() throws {
        let legacy = Data(#"{"elapsedSeconds":0,"signals":[],"remaining":[],"errors":[],"outsideOwnership":[],"ownershipGuarantee":"legacy"}"#.utf8)
        #expect(try JSONDecoder().decode(ShutdownReport.self, from: legacy).succeeded)
        let unknown = Data(#"{"remainingCountVerified":false,"elapsedSeconds":0,"signals":[],"remaining":[],"errors":[],"outsideOwnership":[],"ownershipGuarantee":"unknown"}"#.utf8)
        #expect(try !JSONDecoder().decode(ShutdownReport.self, from: unknown).succeeded)
        let stop = SessionStopReport(remainingCountVerified: false, sessionID: UUID(), runID: UUID(),
                                    elapsedSeconds: 0, signals: [], remaining: [], errors: [], outsideOwnership: [])
        #expect(!stop.succeeded)
    }

    @Test func adoptionCannotMoveRunAfterStopHasBegun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-adopt-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let id = UUID()
        let launch = try await launch("stubborn", sessionID: id, supervisor: supervisor,
                                      provider: .claude, providerConversationID: "A")
        _ = try await ready(terminal: launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        let gate = StopTransitionGate()
        try await supervisor.registerStopHooks(runID: runID, hooks: ManagedRunStopHooks(
            prepare: { await gate.wait() }, completed: {}
        ))
        let stop = Task { try await supervisor.stop(sessionID: id, graceSeconds: 0.02) }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(1)) }
        await #expect(throws: (any Error).self) {
            try await supervisor.adoptConversation(runID: runID, conversationID: "B", transition: .new)
        }
        await gate.release()
        #expect(try await stop.value.succeeded)
        #expect(await supervisor.managedSessions().allSatisfy { $0.currentRun == nil })
        #expect(await supervisor.events.snapshot().sessions.values.allSatisfy { $0.runID == nil })
        #expect(try await catalog.runs().first { $0.id == runID }?.endedAt != nil)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test(arguments: [false, true])
    func pendingAdoptionSerializesStopAndBoundedShutdown(quitting: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-pending-adopt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let id = UUID()
        let launch = try await launch("stubborn", sessionID: id, supervisor: supervisor,
                                      provider: .claude, providerConversationID: "A")
        _ = try await ready(terminal: launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        let gate = CatalogTransitionGate()
        defer { gate.release() }
        let hold = Task.detached { await catalog.holdForTransitionTest(gate) }
        while !gate.entered { try await Task.sleep(for: .milliseconds(1)) }
        let adoption = Task { try await supervisor.adoptConversation(runID: runID, conversationID: "B", transition: .new) }
        while await supervisor.pendingConversationTransitionCount() == 0 { try await Task.sleep(for: .milliseconds(1)) }
        if quitting {
            let shutdown = await supervisor.shutdown(graceSeconds: 0.02, pendingOperationGraceSeconds: 0.03)
            #expect(!shutdown.succeeded)
            #expect(shutdown.errors.contains { $0.contains("transition") })
            #expect(await supervisor.session(id: id)?.currentRun != nil)
            gate.release()
            await hold.value
            let destination = try await adoption.value
            #expect(await supervisor.session(id: destination)?.currentRun?.id == runID)
            #expect((await supervisor.shutdown(graceSeconds: 0.02)).succeeded)
        } else {
            let stopped = Task { try await supervisor.stop(sessionID: id, graceSeconds: 0.02) }
            while await supervisor.pendingStopCount() == 0 { try await Task.sleep(for: .milliseconds(1)) }
            gate.release()
            await hold.value
            let destination = try await adoption.value
            let report = try await stopped.value
            #expect(report.succeeded)
            #expect(report.sessionID == destination)
        }
        #expect(await supervisor.managedSessions().allSatisfy { $0.currentRun == nil })
        #expect(await supervisor.events.snapshot().sessions.values.allSatisfy { $0.runID == nil })
        #expect(try await catalog.runs().first { $0.id == runID }?.endedAt != nil)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func transitionTimeoutRecordsUnverifiedStopAndRetryCanComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-transition-timeout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let id = UUID()
        let launch = try await launch("stubborn", sessionID: id, supervisor: supervisor,
                                      provider: .claude, providerConversationID: "A")
        _ = try await ready(terminal: launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        let gate = CatalogTransitionGate()
        defer { gate.release() }
        let hold = Task.detached { await catalog.holdForTransitionTest(gate) }
        while !gate.entered { try await Task.sleep(for: .milliseconds(1)) }
        let adoption = Task { try await supervisor.adoptConversation(runID: runID, conversationID: "B", transition: .new) }
        while await supervisor.pendingConversationTransitionCount() == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let report = try await supervisor.stop(sessionID: id, graceSeconds: 0.02)
        #expect(!report.succeeded)
        #expect(report.signals.isEmpty)
        #expect(report.remainingCountVerified == true)
        #expect(await supervisor.lastStopReport(sessionID: id)?.succeeded == false)
        #expect(await supervisor.events.snapshot().sessions[id]?.stopFailure != nil)
        gate.release()
        await hold.value
        let destination = try await adoption.value
        #expect(try await supervisor.stop(sessionID: destination, graceSeconds: 0.02).succeeded)
        #expect(await supervisor.managedSessions().allSatisfy { $0.currentRun == nil })
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func lateClaudeConversationHooksCannotMutateOrReadoptCurrentCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-late-hook-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(), catalog: catalog)
        let id = UUID()
        let run = try await launch("stubborn", sessionID: id, supervisor: supervisor, provider: .claude)
        _ = try await ready(terminal: run.terminal)
        let runID = try #require(run.session.currentRun?.id)
        let adapter = ClaudeSessionAdapter(supervisor: supervisor)
        for (native, source) in [("A", "startup"), ("B", "clear")] {
            _ = try await adapter.receive(try claudeEnvelope(launchSessionID: id, runID: runID,
                providerSessionID: native, event: "SessionStart", fields: ["source": source]))
        }
        let active = try #require(await supervisor.activeSessionID(runID: runID))
        _ = try await adapter.receive(try claudeEnvelope(launchSessionID: id, runID: runID,
            providerSessionID: "B", event: "UserPromptSubmit"))
        let baseline = try #require(try await catalog.session(id: active))
        let status = await adapter.status(sessionID: active)
        for (native, kind, fields) in [
            ("A", "Stop", [:]), ("A", "PermissionRequest", [:]), ("A", "UserPromptSubmit", [:]),
            ("A", "SessionStart", ["source": "clear"]), ("A", "SessionStart", ["source": "startup"]),
            ("B", "Stop", ["agent_id": "child"]), ("B", "SessionStart", ["agent_id": "child", "source": "clear"]),
        ] {
            _ = try await adapter.receive(try claudeEnvelope(launchSessionID: id, runID: runID,
                providerSessionID: native, event: kind, fields: fields), receivedAt: Date().addingTimeInterval(500))
            #expect(await supervisor.activeSessionID(runID: runID) == active)
            #expect(await adapter.status(sessionID: active) == status)
            #expect(try await catalog.session(id: active)?.lastUsedAt == baseline.lastUsedAt)
            #expect(try await catalog.session(id: active)?.session.providerConversationID == "B")
        }
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func lateClaudeEventCannotMutateRelaunchedConversation() async throws {
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger()
        )
        let sessionID = UUID()
        let first = try await launch(
            "stubborn", sessionID: sessionID, supervisor: supervisor,
            provider: .claude, providerConversationID: "claude-one"
        )
        _ = try await ready(terminal: first.terminal)
        let oldRunID = try #require(first.session.currentRun?.id)
        let claude = ClaudeSessionAdapter(supervisor: supervisor)
        let oldPrompt = try claudeEnvelope(
            launchSessionID: sessionID, runID: oldRunID,
            providerSessionID: "claude-one", event: "UserPromptSubmit"
        )
        _ = try await claude.receive(oldPrompt)
        #expect((try await supervisor.stop(sessionID: sessionID, graceSeconds: 0.2)).succeeded)

        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
            sessionID: sessionID
        )
        let second = try await supervisor.launch(
            sessionID: sessionID, executable: childPath,
            arguments: ["stubborn"], environment: environment
        )
        _ = try await ready(terminal: second.terminal)
        let newRunID = try #require(second.session.currentRun?.id)
        #expect(newRunID != oldRunID)
        #expect(try await claude.receive(oldPrompt) == .staleRun)
        #expect(await claude.status(sessionID: sessionID) == ClaudeSessionStatus())
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func codexBindingAndNewThreadPreserveOldConversation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-codex-transition-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let sessionID = UUID()
        let launch = try await launch(
            "stubborn", sessionID: sessionID, supervisor: supervisor,
            provider: .codex
        )
        _ = try await ready(terminal: launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        let codex = CodexSessionAdapter(supervisor: supervisor)
        try await codex.bind(
            sessionID: sessionID, runID: runID, threadID: "thread-one",
            after: 5, at: Date(timeIntervalSince1970: 100)
        )
        let turnTime = Date(timeIntervalSince1970: 110)
        #expect(try await codex.receive(
            .event(sequence: 6, .turnStarted(
                threadID: "thread-one", turnID: "turn-one"
            )), runID: runID, receivedAt: turnTime
        ) == .applied)
        #expect(await codex.status(sessionID: sessionID)?.activity == .working)
        #expect(try await catalog.session(id: sessionID)?.lastUsedAt == turnTime)

        let newSessionID = try await codex.transition(
            runID: runID, to: "thread-two", after: 7,
            at: Date(timeIntervalSince1970: 120)
        )
        #expect(newSessionID != sessionID)
        #expect(await supervisor.activeSessionID(runID: runID) == newSessionID)
        #expect(await supervisor.session(id: sessionID)?.currentRun == nil)
        #expect(await supervisor.session(id: newSessionID)?.currentRun?.id == runID)
        #expect(try await catalog.session(id: sessionID)?.lifecycle == .idle)
        #expect(try await catalog.session(id: newSessionID)?.session.providerConversationID
                == "thread-two")
        #expect(try await codex.receive(
            .event(sequence: 7, .turnCompleted(
                threadID: "thread-one", turnID: "old",
                outcome: .completed, lastAssistantMessage: "stale"
            )), runID: runID
        ) == .staleSequence)
        #expect((try await catalog.runSessionLinks(runID: runID)).count == 2)
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func unexpectedProviderExitArchivesUnknownInsteadOfSuccess() async throws {
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger()
        )
        let sessionID = UUID()
        let claude = ClaudeSessionAdapter(supervisor: supervisor)
        let launch = try await launch(
            "quick-exit", sessionID: sessionID, supervisor: supervisor,
            provider: .claude, providerConversationID: "claude-crash"
        )
        _ = try await ready(terminal: launch.terminal)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while await supervisor.session(id: sessionID)?.currentRun != nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await claude.status(sessionID: sessionID)?.activity == .unknown)
        #expect(await supervisor.lastStopReport(sessionID: sessionID)?.succeeded == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func internalServiceUsesOwnershipWithoutPollutingConversationCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-internal-service-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let service = ManagedSession(
            provider: .synthetic, workingDirectory: root.path
        )
        try await supervisor.createInternalSession(service)
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
            sessionID: service.id
        )
        let launch = try await supervisor.launch(
            sessionID: service.id, executable: childPath,
            arguments: ["stubborn"], environment: environment
        )
        _ = try await ready(terminal: launch.terminal)
        #expect(await supervisor.managedSessions().isEmpty)
        #expect(try await catalog.sessions().isEmpty)
        #expect(try await catalog.runs().isEmpty)
        #expect((try await supervisor.stop(
            sessionID: service.id, graceSeconds: 0.2
        )).succeeded)
        try await supervisor.discardInternalSession(service.id)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func sameProviderConversationCannotBeOpenedTwice() async throws {
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger()
        )
        let firstID = UUID(), duplicateID = UUID()
        let first = try await launch(
            "stubborn", sessionID: firstID, supervisor: supervisor,
            provider: .codex, providerConversationID: "same-thread"
        )
        _ = try await ready(terminal: first.terminal)
        try await supervisor.createSession(ManagedSession(
            id: duplicateID, provider: .codex,
            providerConversationID: "same-thread",
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
            sessionID: duplicateID
        )
        do {
            _ = try await supervisor.launch(
                sessionID: duplicateID, executable: childPath,
                arguments: ["stubborn"], environment: environment
            )
            Issue.record("Duplicate provider conversation was launched")
        } catch let error as SessionManagementError {
            #expect(error == .conversationAlreadyRunning(
                provider: .codex, conversationID: "same-thread"
            ))
        }
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func inTUIResumeCannotClaimAnotherLiveClaudeConversation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-live-resume-conflict-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let firstID = UUID(), secondID = UUID()
        let first = try await launch(
            "stubborn", sessionID: firstID, supervisor: supervisor,
            provider: .claude, providerConversationID: "claude-one"
        )
        let second = try await launch(
            "stubborn", sessionID: secondID, supervisor: supervisor,
            provider: .claude, providerConversationID: "claude-two"
        )
        _ = try await ready(terminal: first.terminal)
        _ = try await ready(terminal: second.terminal)
        let firstRun = try #require(first.session.currentRun?.id)
        let secondRun = try #require(second.session.currentRun?.id)

        let claude = ClaudeSessionAdapter(supervisor: supervisor)
        do {
            _ = try await claude.receive(try claudeEnvelope(
                launchSessionID: secondID, runID: secondRun,
                providerSessionID: "claude-one", event: "SessionStart",
                fields: ["source": "resume"]
            ))
            Issue.record("A live Claude conversation was claimed by a second run")
        } catch let error as SessionManagementError {
            #expect(error == .conversationAlreadyRunning(
                provider: .claude, conversationID: "claude-one"
            ))
        }
        #expect(await supervisor.activeSessionID(runID: firstRun) == firstID)
        #expect(await supervisor.activeSessionID(runID: secondRun) == secondID)
        #expect(await claude.status(sessionID: secondID)?.providerSessionID == nil)
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    private func claudeEnvelope(
        launchSessionID: UUID, runID: UUID, providerSessionID: String,
        event: String, fields: [String: Any] = [:]
    ) throws -> ClaudeHookEnvelope {
        var object: [String: Any] = [
            "session_id": providerSessionID,
            "hook_event_name": event,
            "cwd": FileManager.default.temporaryDirectory.path,
        ]
        object.merge(fields) { _, new in new }
        return ClaudeHookEnvelope(
            sessionID: launchSessionID, managedRunID: runID,
            payload: try JSONSerialization.data(withJSONObject: object)
        )
    }
}
