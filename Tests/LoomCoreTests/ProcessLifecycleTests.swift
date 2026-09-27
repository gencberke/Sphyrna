import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class TestBundleAnchor: NSObject {}

@Suite(.serialized)
@MainActor
struct ProcessLifecycleTests {
    private var childPath: String {
        Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("loom-test-child").path
    }

    private func start(_ mode: String, coordinator: ShutdownCoordinator, parent: [String: String] = [:]) throws -> PTYProcess {
        try coordinator.launch(executable: childPath, arguments: [mode],
            environment: LaunchEnvironment.make(parent: parent, path: "/usr/bin:/bin", runID: coordinator.ledger.runID, sessionID: UUID()),
            directory: FileManager.default.temporaryDirectory.path, rows: 31, columns: 97)
    }

    private func ready(_ child: PTYProcess) throws -> [String: Any] {
        var data = Data()
        let deadline = Date().addingTimeInterval(3)
        repeat {
            data.append(try child.readAvailable())
            if let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
               let json = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] { return object }
            usleep(10_000)
        } while Date() < deadline
        throw LoomError.message("Fixture not ready: \(String(decoding: data, as: UTF8.self))")
    }

    @Test func controllingTerminalAndEnvironment() throws {
        let coordinator = try ShutdownCoordinator()
        defer { _ = coordinator.shutdown() }
        let child = try start("inspect", coordinator: coordinator, parent: [
            "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "secret", "CODEX_HOME": "/wrong", "UNRELATED_TOKEN": "secret",
        ])
        let result = try ready(child)
        #expect(result["pid"] as? Int32 == child.pid)
        #expect(result["sid"] as? Int32 == child.pid)
        #expect(result["tty"] as? Bool == true)
        #expect(result["rows"] as? Int == 31)
        #expect(result["cols"] as? Int == 97)
        let keys = try #require(result["environmentKeys"] as? [String])
        #expect(!keys.contains(where: { $0.hasPrefix("CLAUDE") || $0.hasPrefix("CODEX") || $0 == "UNRELATED_TOKEN" }))
        #expect(keys.contains("LOOM_RUN_ID")); #expect(keys.contains("LOOM_SESSION_ID"))
        try child.resize(rows: 40, columns: 120)
        #expect(coordinator.shutdown().succeeded)
        #expect(child.pollExit() != nil)
    }

    @Test func escalatesStubbornChild() throws {
        let coordinator = try ShutdownCoordinator()
        defer { _ = coordinator.shutdown() }
        _ = try ready(start("stubborn", coordinator: coordinator))
        let report = coordinator.shutdown(graceSeconds: 0.05)
        #expect(report.succeeded)
        #expect(report.signals.contains { $0.signal == SIGKILL })
    }

    @Test func sweepsOtherProcessGroup() throws {
        let coordinator = try ShutdownCoordinator()
        defer { _ = coordinator.shutdown() }
        let child = try start("group", coordinator: coordinator)
        let result = try ready(child)
        let pid = try #require(result["descendantPID"] as? Int32)
        let records = try coordinator.sample()
        let descendant = try #require(records.first { $0.identity.pid == pid })
        #expect(descendant.sessionID == child.pid)
        #expect(descendant.processGroup != child.pid)
        #expect(coordinator.shutdown().succeeded)
    }

    @Test func findsReparentedMarkedProcess() throws {
        let coordinator = try ShutdownCoordinator()
        defer { _ = coordinator.shutdown() }
        let child = try start("escape", coordinator: coordinator)
        let result = try ready(child)
        let pid = try #require(result["descendantPID"] as? Int32)
        #expect(ProcessTable.runID(pid: pid) == coordinator.ledger.runID.uuidString)
        let records = try coordinator.sample()
        #expect(records.contains { $0.identity.pid == pid && $0.sessionID != child.pid })
        #expect(coordinator.shutdown().succeeded)
    }

    @Test func leavesExternalProcessUntouched() throws {
        let external = Process(); external.executableURL = URL(fileURLWithPath: "/bin/sleep"); external.arguments = ["30"]
        try external.run()
        defer { external.terminate(); external.waitUntilExit() }
        let before = try #require(ProcessTable.snapshot().first { $0.identity.pid == external.processIdentifier })
        let coordinator = try ShutdownCoordinator()
        defer { _ = coordinator.shutdown() }
        _ = try ready(start("stubborn", coordinator: coordinator))
        #expect(coordinator.shutdown(graceSeconds: 0.03).succeeded)
        let after = try #require(ProcessTable.snapshot().first { $0.identity.pid == external.processIdentifier })
        #expect(before.identity == after.identity)
        #expect(external.isRunning)
    }

    @Test func failedExecAndShutdownRejectNewLaunches() throws {
        let coordinator = try ShutdownCoordinator()
        let environment = LaunchEnvironment.make(path: "/usr/bin:/bin", runID: coordinator.ledger.runID, sessionID: UUID())
        #expect(throws: (any Error).self) {
            try coordinator.launch(executable: "/nonexistent/loom", environment: environment, directory: "/tmp")
        }
        #expect(coordinator.shutdown().succeeded)
        #expect(throws: (any Error).self) { try start("inspect", coordinator: coordinator) }
    }

    @Test func reusedPIDCannotBeSignaled() throws {
        let external = Process(); external.executableURL = URL(fileURLWithPath: "/bin/sleep"); external.arguments = ["30"]
        try external.run()
        defer { external.terminate(); external.waitUntilExit() }
        let record = try #require(ProcessTable.snapshot().first { $0.identity.pid == external.processIdentifier })
        let wrong = ProcessIdentity(pid: record.identity.pid, startSeconds: record.identity.startSeconds - 1,
                                    startMicroseconds: record.identity.startMicroseconds)
        try ProcessTable.signal(wrong, SIGKILL)
        #expect(external.isRunning)
    }
    @Test func documentsUnobservedAppleEscapeBoundary() throws {
        let coordinator = try ShutdownCoordinator()
        defer { _ = coordinator.shutdown() }
        let result = try ready(start("apple-escape", coordinator: coordinator))
        let pid = try #require(result["descendantPID"] as? Int32)
        let escaped = try #require(ProcessTable.snapshot().first { $0.identity.pid == pid })
        defer { try? ProcessTable.signal(escaped.identity, SIGKILL) }
        // Oracle PID is intentionally NOT registered: this measures a missed snapshot, not a solved guarantee.
        #expect(ProcessTable.runID(pid: pid) == nil)
        let observed = try coordinator.sample()
        #expect(!observed.contains { $0.identity == escaped.identity })
        _ = coordinator.shutdown()
        #expect(try ProcessTable.snapshot().contains { $0.identity == escaped.identity && !$0.zombie })
    }

    @Test func recoversRunAfterOwnerSIGKILL() throws {
        let probePath = URL(fileURLWithPath: childPath).deletingLastPathComponent().appendingPathComponent("loom-probe")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment
        environment["LOOM_PROBE_ROOT"] = root.path
        let probe = Process(); probe.environment = environment; probe.executableURL = probePath; probe.arguments = ["crash-fixture", "escape"]
        let output = Pipe(); probe.standardOutput = output
        try probe.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        #expect(probe.terminationReason == .uncaughtSignal)
        #expect(probe.terminationStatus == SIGKILL)
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: path)
        let coordinator = try ShutdownCoordinator(ledger: OwnershipLedger.load(from: url), ledgerURL: url)
        defer { _ = coordinator.shutdown() }
        let remaining = try coordinator.sample()
        #expect(!remaining.isEmpty)
        let recovery = Process(); recovery.environment = environment; recovery.executableURL = probePath; recovery.arguments = ["recover-stale"]
        try recovery.run(); recovery.waitUntilExit()
        #expect(recovery.terminationStatus == 0)
        #expect(try coordinator.sample().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("recovery.json").path))
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("recovered").path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("completed").path))
    }

}
