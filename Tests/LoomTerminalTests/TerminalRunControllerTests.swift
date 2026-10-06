import AppKit
import Foundation
@testable import LoomCore
import Testing
@testable import LoomTerminal

private final class ControllerTestBundleAnchor: NSObject {}

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

private struct PlannedFailure: Error {}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalRunControllerTests {
    private var childPath: String {
        Bundle(for: ControllerTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

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

    private func controller(_ supervisor: ProcessSupervisor) -> TerminalRunController {
        TerminalRunController(supervisor: supervisor, executable: childPath,
                              directory: FileManager.default.temporaryDirectory.path)
    }

    @Test(arguments: [2, 20])
    func repeatedRequestsStartAtMostOneRun(requests: Int) async throws {
        let supervisor = try ProcessSupervisor()
        let controller = controller(supervisor)
        var accepted = 0
        for _ in 0..<requests where controller.newTerminal(arguments: ["interactive"]) != nil {
            accepted += 1
        }
        #expect(accepted == 1)
        try await until(5, "state=\(controller.state)") {
            if case .live = controller.state { true } else { false }
        }
        // Requests while live are refused as well.
        #expect(controller.newTerminal(arguments: ["interactive"]) == nil)
        #expect(await liveRuns(supervisor) == 1)
        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report)")
    }

    /// The app's configuration: the run starts under a run host in its own
    /// scope, and Quit empties that scope.
    @Test func scopedTerminalRunsInsideARunHostAndQuitLeavesNoScopeMember() async throws {
        let products = Bundle(for: ControllerTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-term-scope-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Run hosts are their own TCC-responsible apps; products may live under ~/Documents.
        let child = root.appendingPathComponent("loom-test-child")
        try FileManager.default.copyItem(at: products.appendingPathComponent("loom-test-child"), to: child)
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: products.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: root.appendingPathComponent("s"))
        )
        let controller = TerminalRunController(supervisor: supervisor, executable: child.path,
                                               directory: FileManager.default.temporaryDirectory.path)
        #expect(controller.newTerminal(arguments: ["interactive"]) != nil)
        try await until(10, "state=\(controller.state)") { if case .live = controller.state { true } else { false } }

        let members = try await supervisor.liveScopeMembers()
        let host = try #require(members.first { $0.launchdSpawned }, "the run host is a scope member")
        let leader = try #require(members.first { !$0.launchdSpawned }, "the child is a scope member")
        #expect(ProcessTable.resourceCoalition(pid: leader.identity.pid) != ProcessTable.resourceCoalition(pid: getpid()))

        let report: ShutdownReport = await withCheckedContinuation { continuation in
            controller.requestQuit { continuation.resume(returning: $0) }
        }
        #expect(report.succeeded, "\(report)")
        #expect(controller.quitState == .finished)
        #expect(try await supervisor.liveScopeMembers().isEmpty)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while try ProcessTable.snapshot().contains(where: { $0.identity == host.identity && !$0.zombie }),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try !ProcessTable.snapshot().contains { $0.identity == host.identity && !$0.zombie })
    }

    @Test func failedLaunchReportsOnceAndCanBeRetried() async throws {
        let supervisor = try ProcessSupervisor()
        var attempts = 0
        let controller = TerminalRunController(events: supervisor.events, launch: { sessionID, arguments, surface in
            attempts += 1
            if attempts == 1 { throw PlannedFailure() }
            try await supervisor.createSession(ManagedSession(
                id: sessionID, provider: .synthetic,
                workingDirectory: FileManager.default.temporaryDirectory.path
            ))
            return try await supervisor.launch(
                sessionID: sessionID, executable: childPath, arguments: arguments,
                environment: LaunchEnvironment.make(
                    path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
                ), outputSink: surface.outputSink
            )
        }, shutdown: { await supervisor.shutdown() })
        var errors: [any Error] = []
        controller.onLaunchError = { errors.append($0) }
        #expect(controller.newTerminal(arguments: ["interactive"]) != nil)
        try await until { if case .ended = controller.state { true } else { false } }
        #expect(errors.count == 1 && errors.first is PlannedFailure)
        #expect(controller.newTerminal(arguments: ["interactive"]) != nil)
        try await until { if case .live = controller.state { true } else { false } }
        #expect(errors.count == 1)
        #expect(await liveRuns(supervisor) == 1)
        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report)")
    }

    /// Quit while a launch is held after session creation: the late launch is
    /// refused by the stopping supervisor and no process is left behind.
    @Test func quitDuringHeldLaunchLeavesNoProcess() async throws {
        let supervisor = try ProcessSupervisor()
        let gate = Gate()
        let controller = TerminalRunController(events: supervisor.events, launch: { sessionID, arguments, surface in
            try await supervisor.createSession(ManagedSession(
                id: sessionID, provider: .synthetic,
                workingDirectory: FileManager.default.temporaryDirectory.path
            ))
            await gate.wait()
            return try await supervisor.launch(
                sessionID: sessionID, executable: childPath, arguments: arguments,
                environment: LaunchEnvironment.make(
                    path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
                ), outputSink: surface.outputSink
            )
        }, shutdown: { await supervisor.shutdown() })
        var launchErrors: [any Error] = []
        controller.onLaunchError = { launchErrors.append($0) }
        #expect(controller.newTerminal(arguments: ["interactive"]) != nil)
        try await until { gate.waiting }

        var report: ShutdownReport?
        controller.requestQuit { report = $0 }
        #expect(controller.newTerminal(arguments: ["interactive"]) == nil)
        try await until { report != nil }
        gate.open()
        try await until { if case .ended = controller.state { true } else { false } }
        #expect(report?.succeeded == true)
        #expect(controller.quitState == .finished)
        #expect(launchErrors.first as? SessionManagementError == .shutdownStarted)
        #expect(await liveRuns(supervisor) == 0)
        #expect(try await supervisor.ownedProcesses().isEmpty)
    }

    @Test func failedQuitKeepsWorkBlockedAndRetryCanSucceed() async throws {
        let supervisor = try ProcessSupervisor()
        let controllerForLaunch = controller(supervisor)
        #expect(controllerForLaunch.newTerminal(arguments: ["interactive"]) != nil)
        try await until { if case .live = controllerForLaunch.state { true } else { false } }

        let failFirst = LockedCounter()
        let controller = TerminalRunController(events: supervisor.events, launch: { _, _, _ in
            throw PlannedFailure()
        }, shutdown: {
            if failFirst.next() == 1 {
                return ShutdownReport(elapsedSeconds: 0, signals: [], remaining: [],
                                      errors: ["planned failure"], outsideOwnership: [],
                                      ownershipGuarantee: "test")
            }
            return await supervisor.shutdown()
        })
        var reports: [ShutdownReport] = []
        controller.requestQuit { reports.append($0) }
        try await until { reports.count == 1 }
        #expect(!reports[0].succeeded)
        #expect(controller.quitState == .failed(remaining: 0, errors: ["planned failure"]))
        #expect(controller.newTerminal(arguments: ["interactive"]) == nil)
        #expect(await liveRuns(supervisor) == 1, "a failed quit must not claim the run stopped")

        controller.requestQuit { reports.append($0) } // Try Again
        try await until { reports.count == 2 }
        #expect(reports[1].succeeded)
        #expect(controller.quitState == .finished)
        #expect(await liveRuns(supervisor) == 0)
    }

    /// AppDelegate uses this production path: optional asynchronous diagnostics
    /// precede a synchronous reply, including rejection and the user's retry.
    @Test(arguments: [false, true])
    func appQuitDeliveryPreservesDiagnosticsAndRepliesOnceInsideNestedLoop(evidenceEnabled: Bool) async {
        let attempts = LockedCounter()
        let diagnostics = LockedCounter()
        let controller = TerminalRunController(events: SessionEventHub(), launch: { _, _, _ in
            throw PlannedFailure()
        }, shutdown: {
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
                        controller.requestQuit(prepareReply: prepare) { report in
                            #expect(diagnostics.count == (evidenceEnabled ? expectedCount : 0))
                            reports.append(report)
                        }
                        // Repeated termination requests while one is preparing
                        // must produce neither a second preparation nor reply.
                        controller.requestQuit(prepareReply: prepare) { _ in
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
                            #expect(controller.quitState == .failed(remaining: 0, errors: ["planned failure"]))
                        }
                    }
                    controller.requestQuit(prepareReply: prepare) { _ in
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
        #expect(controller.quitState == .finished)
    }

    /// Regression for the A-slice hang: AppKit waits for the quit reply in a
    /// nested run loop, possibly inside a main-queue block. The reply must
    /// still arrive there.
    @Test func quitReplyArrivesInsideMainQueueNestedRunLoop() async throws {
        let supervisor = try ProcessSupervisor()
        let controller = controller(supervisor)
        let delivered: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var replied = false
                    controller.requestQuit { _ in replied = true }
                    let deadline = Date().addingTimeInterval(5)
                    while !replied, Date() < deadline {
                        _ = RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
                    }
                    continuation.resume(returning: replied)
                }
            }
        }
        #expect(delivered)
        #expect(controller.quitState == .finished)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}
