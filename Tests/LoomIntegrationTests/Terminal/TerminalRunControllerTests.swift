import AppKit
import Foundation
@testable import LoomCore
import Testing
@testable import LoomTerminal
import LoomTestSupport

private struct PlannedFailure: Error {}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalRunControllerTests {
    private var childPath: String {
        Products.directory
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
        // A launch under a full run's load can take more than 5 s (it did, now and then): the deadline bounds only a failure.
        try await until(30, "state=\(controller.state)") {
            if case .live = controller.state { true } else { false }
        }
        // Requests while live are refused as well.
        #expect(controller.newTerminal(arguments: ["interactive"]) == nil)
        #expect(await liveRuns(supervisor) == 1)
        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report)")
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
        })
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
}
