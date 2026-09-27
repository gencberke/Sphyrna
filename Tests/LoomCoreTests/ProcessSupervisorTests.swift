import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class SupervisorTestBundleAnchor: NSObject {}

@Suite(.serialized)
struct ProcessSupervisorTests {
    private var childPath: String {
        Bundle(for: SupervisorTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    private func launch(_ mode: String, sessionID: UUID,
                        supervisor: ProcessSupervisor) async throws -> ManagedSession {
        let session = ManagedSession(id: sessionID, provider: .synthetic,
                                     workingDirectory: FileManager.default.temporaryDirectory.path)
        try await supervisor.createSession(session)
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        return try await supervisor.launch(sessionID: sessionID, executable: childPath,
                                           arguments: [mode], environment: environment)
    }

    private func ready(sessionID: UUID, supervisor: ProcessSupervisor) async throws -> [String: Any] {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            data.append(try await supervisor.readAvailable(sessionID: sessionID))
            if let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
               let json = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                return object
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LoomError.message("Fixture not ready: \(String(decoding: data, as: UTF8.self))")
    }

    @Test func managedRunMarkerIsDistinctFromAppOwnershipRun() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
        let sessionID = UUID()
        let session = try await launch("inspect", sessionID: sessionID, supervisor: supervisor)
        let result = try await ready(sessionID: sessionID, supervisor: supervisor)
        let pid = try #require(result["pid"] as? Int32)
        let run = try #require(session.currentRun)

        #expect(run.id != supervisor.ownershipRunID)
        #expect(ProcessTable.runID(pid: pid) == supervisor.ownershipRunID.uuidString)
        #expect(ProcessTable.managedRunID(pid: pid) == run.id.uuidString)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func stoppingOneSessionLeavesTheOtherSessionRunning() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
        let firstID = UUID(), secondID = UUID()
        _ = try await launch("escape", sessionID: firstID, supervisor: supervisor)
        _ = try await launch("stubborn", sessionID: secondID, supervisor: supervisor)
        let first = try await ready(sessionID: firstID, supervisor: supervisor)
        let second = try await ready(sessionID: secondID, supervisor: supervisor)
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
        _ = try await launch("quick-exit", sessionID: sessionID, supervisor: supervisor)
        let output = try await ready(sessionID: sessionID, supervisor: supervisor)
        #expect(output["mode"] as? String == "quick-exit")

        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var run = await supervisor.session(id: sessionID)?.currentRun
        while run?.exitStatus == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
            run = await supervisor.session(id: sessionID)?.currentRun
        }
        #expect(run?.state == .exited)
        #expect(run?.exitStatus == 7 << 8)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func eventReaderDrainsOutputLargerThanOneHandlerBudget() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger(coalition: .probe(forceFailure: true)))
        let sessionID = UUID()
        _ = try await launch("burst-exit", sessionID: sessionID, supervisor: supervisor)
        let expected = 512 * 1024
        var received = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            let data = try await supervisor.readAvailable(sessionID: sessionID)
            received += data.reduce(into: 0) { count, byte in
                if byte == 0x5a { count += 1 }
            }
            if received == expected { break }
            try await Task.sleep(for: .milliseconds(5))
        } while ProcessInfo.processInfo.systemUptime < deadline

        #expect(received == expected)
        #expect((await supervisor.shutdown()).succeeded)
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
        _ = try await launch("stubborn", sessionID: sessionID, supervisor: supervisor)
        _ = try await ready(sessionID: sessionID, supervisor: supervisor)

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
}
