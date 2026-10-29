import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private final class FakeClaudePromptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func receive(_ envelope: ClaudeHookEnvelope) {
        guard let object = try? JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
              object["hook_event_name"] as? String == "UserPromptSubmit",
              let prompt = object["prompt"] as? String else { return }
        lock.withLock { values.append(prompt) }
    }
    var prompts: [String] { lock.withLock { values } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct SessionTaskFakeClaudeTests {
    @Test func fakeClaudeProcessesInitialMessageOnceAndReportsExactPrompts() async throws {
        let root = URL(fileURLWithPath: "/tmp/lf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeClaudePromptCapture()
        let socket = root.appendingPathComponent("hook.sock").path
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: "fixture-token", handler: capture.receive)
        defer { server.stop() }
        let sessionID = UUID(), runID = UUID()
        let supervisor = try ProcessSupervisor()
        try await supervisor.createSession(ManagedSession(id: sessionID, provider: .claude, workingDirectory: root.path))
        let capabilities = ProviderCapabilities(version: "fake 2.1.300", help: "--settings <s> --session-id <id> -n, --name <name>")
        let hooks = ClaudeHookLaunchConfiguration(helperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
            socketPath: socket, authenticationToken: "fixture-token")
        let environment = LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID)
        let profile = try ProviderLaunchProfile.claude(route: .new(sessionID), capabilities: capabilities,
            config: root, environment: environment, hooks: hooks,
            opening: .init(title: "fixture", firstMessage: "first synthetic input"))
        let screen = SessionRuntimeRig.Screen()
        let launch = try await supervisor.launch(sessionID: sessionID,
            executable: RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path,
            arguments: profile.launchArguments(), environment: profile.environment, outputSink: screen, managedRunID: runID)
        screen.attach(launch.terminal)
        #expect(await screen.contains("echo: first synthetic input", timeout: 2))
        try await screen.send("second synthetic input")
        #expect(await screen.contains("echo: second synthetic input"))
        #expect(try await SessionRuntimeRig.waitUntil(2) { capture.prompts.count == 2 })
        #expect(capture.prompts == ["first synthetic input", "second synthetic input"])
        #expect((await supervisor.shutdown()).succeeded)
    }
}
