import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// One-shot gate a launch can wait on while the test acts.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var waiting = false

    func wait() async {
        guard !opened else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

private func failedReport(_ errors: [String]) -> ShutdownReport {
    ShutdownReport(elapsedSeconds: 0, signals: [], remaining: [], errors: errors,
                   outsideOwnership: [], ownershipGuarantee: "test")
}

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct AppShutdownCoordinatorTests {
    private var productsDirectory: URL {
        Products.directory
    }

    private var childPath: String { productsDirectory.appendingPathComponent("loom-test-child").path }

    private func until(_ seconds: Double = 5, _ detail: @autoclosure () -> String = "",
                       _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("condition not reached in \(seconds)s \(detail())")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func liveRuns(_ supervisor: ProcessSupervisor) async -> Int {
        await supervisor.managedSessions().filter { $0.currentRun != nil }.count
    }

    private func startRun(_ supervisor: ProcessSupervisor, executable: String? = nil) async throws -> UUID {
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        try await supervisor.launch(
            sessionID: sessionID, executable: executable ?? childPath, arguments: ["interactive"],
            environment: LaunchEnvironment.make(
                path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
            )
        )
        return sessionID
    }

    /// The app's configuration: the run starts under a run host in its own
    /// scope, and Quit empties that scope.
    @Test func scopedRunInsideARunHostAndQuitLeavesNoScopeMember() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-quit-scope-\(UUID().uuidString.prefix(8))")
        defer { RunScopeLauncher.removeOwnedBundle(in: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Run hosts are their own TCC-responsible apps; products may live under ~/Documents.
        let child = root.appendingPathComponent("loom-test-child")
        try FileManager.default.copyItem(at: productsDirectory.appendingPathComponent("loom-test-child"), to: child)
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: productsDirectory.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: root.appendingPathComponent("s"))
        )
        _ = try await startRun(supervisor, executable: child.path)
        let members = try await supervisor.liveScopeMembers()
        let host = try #require(members.first { $0.launchdSpawned }, "the run host is a scope member")
        _ = try #require(members.first { !$0.launchdSpawned }, "the child is a scope member")

        let coordinator = AppShutdownCoordinator(shutdown: { await supervisor.shutdown() })
        let report: ShutdownReport = await withCheckedContinuation { continuation in
            coordinator.requestQuit { continuation.resume(returning: $0) }
        }
        #expect(report.succeeded, "\(report)")
        #expect(coordinator.state == .finished)
        #expect(try await supervisor.liveScopeMembers().isEmpty)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while try ProcessTable.snapshot().contains(where: { $0.identity == host.identity && !$0.zombie }),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try !ProcessTable.snapshot().contains { $0.identity == host.identity && !$0.zombie })
    }

    /// Quit while a launch is held after session creation: the late launch is
    /// refused by the stopping supervisor and no process is left behind.
    @Test func quitDuringHeldLaunchLeavesNoProcess() async throws {
        let supervisor = try ProcessSupervisor()
        let gate = Gate()
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let childPath = childPath
        let launch = Task { @MainActor () -> (any Error)? in
            await gate.wait()
            do {
                try await supervisor.launch(
                    sessionID: sessionID, executable: childPath, arguments: ["interactive"],
                    environment: LaunchEnvironment.make(
                        path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
                    )
                )
                return nil
            } catch { return error }
        }
        try await until { gate.waiting }

        let coordinator = AppShutdownCoordinator(shutdown: { await supervisor.shutdown() })
        var report: ShutdownReport?
        coordinator.requestQuit { report = $0 }
        try await until { report != nil }
        gate.open()
        let launchError = await launch.value
        #expect(report?.succeeded == true)
        #expect(coordinator.state == .finished)
        #expect(launchError as? SessionManagementError == .shutdownStarted)
        #expect(await liveRuns(supervisor) == 0)
        #expect(try await supervisor.ownedProcesses().isEmpty)
    }

    @Test func failedQuitReportsFailureAndRetryCanSucceed() async throws {
        let supervisor = try ProcessSupervisor()
        _ = try await startRun(supervisor)
        #expect(await liveRuns(supervisor) == 1)

        let failFirst = LockedCounter()
        let coordinator = AppShutdownCoordinator(shutdown: {
            if failFirst.next() == 1 { return failedReport(["planned failure"]) }
            return await supervisor.shutdown()
        })
        #expect(coordinator.state == .idle)
        var reports: [ShutdownReport] = []
        coordinator.requestQuit { reports.append($0) }
        #expect(coordinator.state == .running)
        try await until { reports.count == 1 }
        #expect(!reports[0].succeeded)
        #expect(coordinator.state == .failed(remaining: 0, errors: ["planned failure"]))
        #expect(await liveRuns(supervisor) == 1, "a failed quit must not claim the run stopped")

        coordinator.requestQuit { reports.append($0) } // Try Again
        try await until { reports.count == 2 }
        #expect(reports[1].succeeded)
        #expect(coordinator.state == .finished)
        #expect(await liveRuns(supervisor) == 0)
    }

    /// AppDelegate uses this production path: optional asynchronous diagnostics
    /// precede a synchronous reply, including rejection and the user's retry.
    @Test(arguments: [false, true])
    func appQuitDeliveryPreservesDiagnosticsAndRepliesOnceInsideNestedLoop(evidenceEnabled: Bool) async {
        let attempts = LockedCounter()
        let diagnostics = LockedCounter()
        let coordinator = AppShutdownCoordinator(shutdown: {
            let attempt = attempts.next()
            return ShutdownReport(elapsedSeconds: 0, signals: [], remaining: [],
                                  errors: attempt == 1 ? ["planned failure"] : [],
                                  outsideOwnership: [], ownershipGuarantee: "fixture")
        })
        let prepare: (@Sendable (ShutdownReport) async -> Void)?
        if evidenceEnabled {
            prepare = { report in
                // Deliberately suspend, as runtime diagnostics collection does.
                try? await Task.sleep(for: .milliseconds(10))
                let expectedErrors = diagnostics.next() == 1 ? ["planned failure"] : []
                #expect(report.errors == expectedErrors)
            }
        } else {
            prepare = nil
        }
        let delivered = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var reports: [ShutdownReport] = []
                    for expectedCount in 1...2 {
                        coordinator.requestQuit(prepareReply: prepare) { report in
                            #expect(diagnostics.count == (evidenceEnabled ? expectedCount : 0))
                            reports.append(report)
                        }
                        // Repeated termination requests while one is preparing
                        // must produce neither a second preparation nor reply.
                        coordinator.requestQuit(prepareReply: prepare) { _ in
                            Issue.record("duplicate quit reply")
                        }
                        let deadline = Date().addingTimeInterval(2)
                        while reports.count < expectedCount, Date() < deadline {
                            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                        }
                        guard reports.count == expectedCount else {
                            continuation.resume(returning: false)
                            return
                        }
                        if expectedCount == 1 {
                            #expect(coordinator.state == .failed(remaining: 0, errors: ["planned failure"]))
                        }
                    }
                    coordinator.requestQuit(prepareReply: prepare) { _ in
                        Issue.record("reply after successful quit")
                    }
                    // Drain scheduled run-loop work to expose extra deliveries.
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    #expect(reports.count == 2)
                    #expect(!reports[0].succeeded && reports[1].succeeded)
                    continuation.resume(returning: true)
                }
            }
        }
        #expect(delivered)
        #expect(attempts.count == 2)
        #expect(diagnostics.count == (evidenceEnabled ? 2 : 0))
        #expect(coordinator.state == .finished)
    }
}
