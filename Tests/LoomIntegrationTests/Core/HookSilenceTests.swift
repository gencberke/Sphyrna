import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [ClaudeHookEnvelope] = []
    func append(_ envelope: ClaudeHookEnvelope) { lock.withLock { envelopes.append(envelope) } }
    func count(waiting seconds: Double, for expected: Int) -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, lock.withLock({ envelopes.count }) < expected { usleep(10_000) }
        return lock.withLock { envelopes.count }
    }
}

/// G4 of the cost-and-context rule (goal 3 of D-83): Claude adds a hook's standard output to the model's context for some events
/// (`SessionStart`, `UserPromptSubmit`, ...), and reads a decision from it for others. The helper `loom-hook` prints nothing, on
/// every event and on every way it can fail, so the hooks Sphyrna registers can never put text before the model.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HookSilenceTests {
    private static var events: [(String, [String: Any])] { [
        ("SessionStart", ["source": "startup"]),
        ("UserPromptSubmit", ["prompt": "do the thing"]),
        ("Stop", ["last_assistant_message": "done", "background_tasks": []]),
        ("StopFailure", ["error": "rate_limit", "error_details": "slow down"]),
        ("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"]),
        ("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]]),
        ("SessionEnd", ["reason": "other"]),
        ("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"]),
        ("SubagentStop", ["agent_id": "a1", "agent_type": "Explore", "agent_transcript_path": "/tmp/a1.jsonl"]),
    ] }

    private func payload(_ event: String, _ fields: [String: Any]) throws -> Data {
        var object: [String: Any] = [
            "session_id": "provider-session", "hook_event_name": event, "cwd": "/tmp/workspace",
            "transcript_path": "/tmp/transcript.jsonl",
        ]
        object.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Runs the real helper the way Claude does (no arguments, the event on standard input) and returns what it printed.
    private func run(environment: [String: String], input: Data) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = Products.directory.appendingPathComponent("loom-hook")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let printed = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, printed)
    }

    private func environment(socket: String, token: String) -> [String: String] {
        ["LOOM_HOOK_SOCKET": socket, "LOOM_HOOK_TOKEN": token, "LOOM_SESSION_ID": UUID().uuidString,
         "LOOM_MANAGED_RUN_ID": UUID().uuidString]
    }

    @Test func theHelperPrintsNothingOnAnyOfTheNineEvents() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("events.sock").path
        let received = Received()
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: "silence-token", handler: received.append)
        defer { server.stop() }
        for (event, fields) in Self.events {
            let result = try run(environment: environment(socket: socket, token: "silence-token"),
                                 input: payload(event, fields))
            #expect(result.status == 0, "\(event): exit \(result.status)")
            #expect(result.stdout.isEmpty, "\(event) printed \(result.stdout.count) bytes")
        }
        #expect(received.count(waiting: 2, for: Self.events.count) == Self.events.count, "every event reached the server")
    }

    @Test func theHelperPrintsNothingWhenItFails() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("events.sock").path
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: "right-token", handler: { _ in })
        defer { server.stop() }
        let good = try payload("SessionStart", ["source": "startup"])
        let live = environment(socket: socket, token: "right-token")
        var withoutRun = live; withoutRun["LOOM_MANAGED_RUN_ID"] = nil
        var badSession = live; badSession["LOOM_SESSION_ID"] = "not-a-uuid"
        var failures: [(String, [String: String], Data)] = [
            ("no socket", environment(socket: root.appendingPathComponent("none.sock").path, token: "right-token"), good),
            ("wrong token", environment(socket: socket, token: "wrong-token"), good),
            ("no environment", [:], good),
            ("no run identity", withoutRun, good),
            ("a session identity that is not a UUID", badSession, good),
            ("empty input", live, Data()),
            ("input that is not JSON", live, Data("not json at all".utf8)),
            ("JSON that is no hook payload", live, Data(#"{"hello":"world"}"#.utf8)),
            ("a payload without an event", live, Data(#"{"session_id":"s"}"#.utf8)),
        ]
        for (event, fields) in Self.events {
            // The payload is fine and nothing is listening, for every event.
            failures.append(("\(event) with no socket", environment(socket: root.appendingPathComponent("none.sock").path, token: "t"),
                             try payload(event, fields)))
        }
        for (label, environment, input) in failures {
            let result = try run(environment: environment, input: input)
            #expect(result.status != 0, "\(label): the failure is the exit code, not text")
            #expect(result.stdout.isEmpty, "\(label) printed \(result.stdout.count) bytes")
        }
    }
}
