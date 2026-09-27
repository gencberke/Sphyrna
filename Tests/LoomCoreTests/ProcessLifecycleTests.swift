import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class TestBundleAnchor: NSObject {}

@Suite(.serialized)
struct ProcessLifecycleTests {
    private var childPath: String {
        Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    private func start(
        _ mode: String, supervisor: ProcessSupervisor,
        parent: [String: String] = [:]
    ) async throws -> ManagedSessionLaunch {
        let sessionID = UUID()
        let directory = FileManager.default.temporaryDirectory.path
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic, workingDirectory: directory
        ))
        let environment = LaunchEnvironment.make(
            parent: parent, path: "/usr/bin:/bin",
            runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        return try await supervisor.launch(
            sessionID: sessionID, executable: childPath, arguments: [mode],
            environment: environment, rows: 31, columns: 97
        )
    }

    private func ready(_ terminal: TerminalEndpoint) async throws -> [String: Any] {
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

    @Test func controllingTerminalAndEnvironment() async throws {
        let supervisor = try ProcessSupervisor()
        let launch = try await start("inspect", supervisor: supervisor, parent: [
            "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "secret",
            "CODEX_HOME": "/wrong", "UNRELATED_TOKEN": "secret",
        ])
        let result = try await ready(launch.terminal)
        #expect(result["pid"] as? Int32 == launch.terminal.pid)
        #expect(result["sid"] as? Int32 == launch.terminal.pid)
        #expect(result["tty"] as? Bool == true)
        #expect(result["rows"] as? Int == 31)
        #expect(result["cols"] as? Int == 97)
        let keys = try #require(result["environmentKeys"] as? [String])
        #expect(!keys.contains { $0.hasPrefix("CLAUDE") || $0.hasPrefix("CODEX")
            || $0 == "UNRELATED_TOKEN" })
        #expect(keys.contains("LOOM_RUN_ID"))
        #expect(keys.contains("LOOM_SESSION_ID"))
        try await launch.terminal.resize(rows: 40, columns: 120)
        #expect((await supervisor.shutdown()).succeeded)
        #expect(try !ProcessTable.snapshot().contains {
            $0.identity.pid == launch.terminal.pid && !$0.zombie
        })
    }

    @Test func escalatesStubbornChild() async throws {
        let supervisor = try ProcessSupervisor()
        _ = try await ready((try await start("stubborn", supervisor: supervisor)).terminal)
        let report = await supervisor.shutdown(graceSeconds: 0.05)
        #expect(report.succeeded)
        #expect(report.signals.contains { $0.signal == SIGKILL })
    }

    @Test func sweepsOtherProcessGroup() async throws {
        let supervisor = try ProcessSupervisor()
        let launch = try await start("group", supervisor: supervisor)
        let result = try await ready(launch.terminal)
        let pid = try #require(result["descendantPID"] as? Int32)
        let records = try await supervisor.ownedProcesses()
        let descendant = try #require(records.first { $0.identity.pid == pid })
        #expect(descendant.sessionID == launch.terminal.pid)
        #expect(descendant.processGroup != launch.terminal.pid)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func findsReparentedMarkedProcess() async throws {
        let supervisor = try ProcessSupervisor()
        let launch = try await start("escape", supervisor: supervisor)
        let result = try await ready(launch.terminal)
        let pid = try #require(result["descendantPID"] as? Int32)
        #expect(ProcessTable.runID(pid: pid) == supervisor.ownershipRunID.uuidString)
        let records = try await supervisor.ownedProcesses()
        #expect(records.contains { $0.identity.pid == pid
            && $0.sessionID != launch.terminal.pid })
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func leavesExternalProcessUntouched() async throws {
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/bin/sleep")
        external.arguments = ["30"]
        try external.run()
        defer { external.terminate(); external.waitUntilExit() }
        let before = try #require(ProcessTable.snapshot().first {
            $0.identity.pid == external.processIdentifier
        })
        let supervisor = try ProcessSupervisor()
        _ = try await ready((try await start("stubborn", supervisor: supervisor)).terminal)
        #expect((await supervisor.shutdown(graceSeconds: 0.03)).succeeded)
        let after = try #require(ProcessTable.snapshot().first {
            $0.identity.pid == external.processIdentifier
        })
        #expect(before.identity == after.identity)
        #expect(external.isRunning)
    }

    @Test func failedExecAndShutdownRejectNewLaunches() async throws {
        let supervisor = try ProcessSupervisor()
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic, workingDirectory: "/tmp"
        ))
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
            sessionID: sessionID
        )
        await #expect(throws: (any Error).self) {
            try await supervisor.launch(
                sessionID: sessionID, executable: "/nonexistent/loom",
                environment: environment
            )
        }
        #expect((await supervisor.shutdown()).succeeded)
        await #expect(throws: (any Error).self) {
            try await supervisor.createSession(ManagedSession(
                provider: .synthetic, workingDirectory: "/tmp"
            ))
        }
    }

    @Test func reusedPIDCannotBeSignaled() throws {
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/bin/sleep")
        external.arguments = ["30"]
        try external.run()
        defer { external.terminate(); external.waitUntilExit() }
        let record = try #require(ProcessTable.snapshot().first {
            $0.identity.pid == external.processIdentifier
        })
        let wrong = ProcessIdentity(
            pid: record.identity.pid,
            startSeconds: record.identity.startSeconds - 1,
            startMicroseconds: record.identity.startMicroseconds
        )
        try ProcessTable.signal(wrong, SIGKILL)
        #expect(external.isRunning)
    }

    @Test func documentsUnobservedAppleEscapeBoundary() async throws {
        let supervisor = try ProcessSupervisor()
        let result = try await ready(
            (try await start("apple-escape", supervisor: supervisor)).terminal
        )
        let pid = try #require(result["descendantPID"] as? Int32)
        let escaped = try #require(ProcessTable.snapshot().first { $0.identity.pid == pid })
        defer { try? ProcessTable.signal(escaped.identity, SIGKILL) }
        // Oracle PID is intentionally NOT registered: this measures a missed snapshot.
        #expect(ProcessTable.runID(pid: pid) == nil)
        let observed = try await supervisor.ownedProcesses()
        #expect(!observed.contains { $0.identity == escaped.identity })
        _ = await supervisor.shutdown()
        #expect(try ProcessTable.snapshot().contains {
            $0.identity == escaped.identity && !$0.zombie
        })
    }

    @Test func recoversRunAfterOwnerSIGKILL() async throws {
        let probePath = URL(fileURLWithPath: childPath).deletingLastPathComponent()
            .appendingPathComponent("loom-probe")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment
        environment["LOOM_PROBE_ROOT"] = root.path
        let probe = Process()
        probe.environment = environment
        probe.executableURL = probePath
        probe.arguments = ["crash-fixture", "escape"]
        let output = Pipe()
        probe.standardOutput = output
        try probe.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        #expect(probe.terminationReason == .uncaughtSignal)
        #expect(probe.terminationStatus == SIGKILL)
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: path)
        let observer = try ProcessSupervisor(
            ledger: OwnershipLedger.load(from: url), ledgerURL: url
        )
        #expect(try await !observer.ownedProcesses().isEmpty)
        let recovery = Process()
        recovery.environment = environment
        recovery.executableURL = probePath
        recovery.arguments = ["recover-stale"]
        try recovery.run()
        recovery.waitUntilExit()
        #expect(recovery.terminationStatus == 0)
        #expect(try await observer.ownedProcesses().isEmpty)
        _ = await observer.shutdown()
        #expect(FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().appendingPathComponent("recovery.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().appendingPathComponent("recovered").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().appendingPathComponent("completed").path
        ))
    }
}
