import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore

private final class SupervisorTestBundleAnchor: NSObject {}

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

@Suite(.serialized)
struct ProcessSupervisorTests {
    private var childPath: String {
        Bundle(for: SupervisorTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    private func launch(_ mode: String, sessionID: UUID,
                        supervisor: ProcessSupervisor,
                        outputSink: (any TerminalOutputSink)? = nil) async throws -> ManagedSessionLaunch {
        let session = ManagedSession(id: sessionID, provider: .synthetic,
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
            ledger: OwnershipLedger(coalition: .probe(forceFailure: true))
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
        #expect((await supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    @Test func managedRunMarkerIsDistinctFromAppOwnershipRun() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
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
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
        let firstID = UUID(), secondID = UUID()
        let firstLaunch = try await launch("escape", sessionID: firstID, supervisor: supervisor)
        let secondLaunch = try await launch("stubborn", sessionID: secondID, supervisor: supervisor)
        let first = try await ready(terminal: firstLaunch.terminal)
        let second = try await ready(terminal: secondLaunch.terminal)
        let firstLeader = try #require(first["pid"] as? Int32)
        let firstDescendant = try #require(first["descendantPID"] as? Int32)
        let secondLeader = try #require(second["pid"] as? Int32)

        let report = try await supervisor.stop(sessionID: firstID, graceSeconds: 0.05)
        #expect(report.succeeded)
        let snapshot = try ProcessTable.snapshot()
        #expect(!snapshot.contains { [firstLeader, firstDescendant].contains($0.identity.pid) && !$0.zombie })
        #expect(snapshot.contains { $0.identity.pid == secondLeader && !$0.zombie })
        #expect(try await supervisor.sample(sessionID: secondID).contains { $0.identity.pid == secondLeader })
        let stoppedSession = await supervisor.session(id: firstID)
        let runningSession = await supervisor.session(id: secondID)
        #expect(stoppedSession?.currentRun == nil)
        #expect(runningSession?.currentRun != nil)

        #expect((await supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    @Test func outputAndLeaderExitAreDeliveredWithoutSampling() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
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
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
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
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
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
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
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
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
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
        #expect((await supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    @Test func launchRequiresTheMatchingConversationMarker() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
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
            ledger: OwnershipLedger(coalition: .probe(forceFailure: true)),
            catalog: catalog
        )
        let sessionID = UUID()
        let launch = try await launch("stubborn", sessionID: sessionID, supervisor: supervisor)
        _ = try await ready(terminal: launch.terminal)

        #expect((await supervisor.shutdown(graceSeconds: 0.05)).succeeded)
        let runs = try await catalog.runs()
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.endedAt != nil)
        #expect(run.endReason == .applicationQuit)
        #expect(run.exitStatus != nil)

        let reopened = try await ProcessSupervisor.restoring(
            ledger: OwnershipLedger(coalition: .probe(forceFailure: true)),
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
            ledger: OwnershipLedger(coalition: .probe(forceFailure: true)),
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
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
        var sessionIDs: [UUID] = []
        for _ in 0..<10 {
            let sessionID = UUID()
            sessionIDs.append(sessionID)
            let launch = try await launch("stubborn", sessionID: sessionID, supervisor: supervisor)
            _ = try await ready(terminal: launch.terminal)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let report = await supervisor.shutdown(graceSeconds: 0.05)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(report.succeeded)
        #expect(elapsed < 0.75)
        var perSessionSignalCount = 0
        for sessionID in sessionIDs {
            let sessionReport = await supervisor.lastStopReport(sessionID: sessionID)
            #expect(sessionReport?.succeeded == true)
            perSessionSignalCount += sessionReport?.signals.count ?? 0
        }
        #expect(report.signals.count == perSessionSignalCount)
    }
}
