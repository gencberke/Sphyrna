import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct ManagedCodexServerTests {
    @Test func appServerIsTheCataloguedChildRunAndStopKeepsItsSession() async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: true)
        defer { context.cleanup() }
        let sessionID = UUID(), runID = UUID()
        try await context.supervisor.createSession(ManagedSession(id: sessionID, provider: .codex,
                                                                   workingDirectory: context.home.path))
        let scope = try await context.supervisor.openScope()
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let manager = CodexAppServerManager(supervisor: context.supervisor, configuration: .init(
            executable: context.root.appendingPathComponent("bin/loom-fake-provider").path,
            capabilities: .init(version: "fixture", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
            home: context.profile,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path, "LOOM_FAKE_STATE": context.state.path],
            workingDirectory: context.home.path,
            socketPath: context.socketDirectory.appendingPathComponent("managed.sock").path,
            clientVersion: "test", launchChoices: HarnessLaunchChoices(harness: .codex, mode: .askBeforeEdits),
            startupTimeout: 10, scope: scope), managedOwner: .init(sessionID: sessionID, runID: runID))
        do {
            _ = try await manager.start()
            let running = await context.supervisor.session(id: sessionID)
            #expect(running?.provider == .codex)
            #expect(running?.currentRun?.id == runID)
            #expect(await manager.internalSessionID() == nil)
            let report = await manager.stop()
            #expect(report?.sessionID == sessionID && report?.runID == runID && report?.succeeded == true)
            #expect(await context.supervisor.session(id: sessionID)?.currentRun == nil)
            #expect(try await context.catalog.session(id: sessionID) != nil)
        } catch {
            Issue.record("managed app-server fixture failed: \(error)")
            _ = await manager.stop()
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
