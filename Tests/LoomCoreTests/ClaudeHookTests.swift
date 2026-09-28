import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class HookTestBundleAnchor: NSObject {}

private final class HookEnvelopeCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var storage: [ClaudeHookEnvelope] = []

    func append(_ envelope: ClaudeHookEnvelope) {
        condition.lock()
        storage.append(envelope)
        condition.broadcast()
        condition.unlock()
    }

    func waitForCount(_ count: Int, timeout: TimeInterval) -> [ClaudeHookEnvelope] {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while storage.count < count, condition.wait(until: deadline) {}
        return storage
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ClaudeHookTests {
    @Test func authenticatedUnixSocketDeliversOnlyValidMessages() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("events.sock").path
        let collector = HookEnvelopeCollector()
        let server = try ClaudeHookServer(
            socketPath: socketPath, authenticationToken: "correct-token",
            handler: collector.append
        )
        defer { server.stop() }

        var metadata = stat()
        #expect(lstat(socketPath, &metadata) == 0)
        #expect(metadata.st_mode & S_IFMT == S_IFSOCK)
        #expect(metadata.st_mode & 0o777 == 0o600)

        let envelope = ClaudeHookEnvelope(
            sessionID: UUID(), managedRunID: UUID(),
            payload: try payload(event: "SessionStart", fields: ["source": "startup"])
        )
        try ClaudeHookClient.send(
            envelope, socketPath: socketPath, authenticationToken: "wrong-token"
        )
        #expect(collector.waitForCount(1, timeout: 0.05).isEmpty)

        try ClaudeHookClient.send(
            envelope, socketPath: socketPath, authenticationToken: "correct-token"
        )
        #expect(collector.waitForCount(1, timeout: 1) == [envelope])
    }

    @Test func helperForwardsInheritedSessionAndRunIdentity() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("events.sock").path
        let collector = HookEnvelopeCollector()
        let server = try ClaudeHookServer(
            socketPath: socketPath, authenticationToken: "helper-token",
            handler: collector.append
        )
        defer { server.stop() }
        let sessionID = UUID(), runID = UUID()
        let input = try payload(event: "SessionStart", fields: ["source": "startup"])
        let pipe = Pipe()
        let process = Process()
        process.executableURL = Bundle(for: HookTestBundleAnchor.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("loom-hook")
        process.environment = [
            "LOOM_HOOK_SOCKET": socketPath,
            "LOOM_HOOK_TOKEN": "helper-token",
            "LOOM_SESSION_ID": sessionID.uuidString,
            "LOOM_MANAGED_RUN_ID": runID.uuidString,
        ]
        process.standardInput = pipe
        try process.run()
        try pipe.fileHandleForWriting.write(contentsOf: input)
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let received = try #require(collector.waitForCount(1, timeout: 1).first)
        #expect(received.sessionID == sessionID)
        #expect(received.managedRunID == runID)
        #expect(received.payload == input)
    }

    @Test func reducerTracksDocumentedStatesAndRejectsOldRuns() async throws {
        let sessionID = UUID()
        let firstRunID = UUID()
        let secondRunID = UUID()
        let tracker = ClaudeHookStateTracker(
            sessionID: sessionID, managedRunID: firstRunID
        )
        let startTime = Date(timeIntervalSince1970: 100)

        let start = try envelope(
            sessionID: sessionID, runID: firstRunID, event: "SessionStart",
            fields: ["source": "startup", "session_id": "provider-one"]
        )
        #expect(try await tracker.receive(start, receivedAt: startTime) == .applied(
            ClaudeHookEvent(payload: start.payload)
        ))
        var status = await tracker.status()
        #expect(status.providerSessionID == "provider-one")
        #expect(status.activity == .unknown)

        let promptTime = startTime.addingTimeInterval(1)
        let prompt = try envelope(
            sessionID: sessionID, runID: firstRunID,
            event: "UserPromptSubmit"
        )
        _ = try await tracker.receive(prompt, receivedAt: promptTime)
        status = await tracker.status()
        #expect(status.activity == .working)
        #expect(status.lastUsedAt == promptTime)

        let permission = try envelope(
            sessionID: sessionID, runID: firstRunID,
            event: "PermissionRequest", fields: ["tool_name": "Bash"]
        )
        _ = try await tracker.receive(permission)
        #expect(await tracker.status().activity == .waitingForApproval)

        let stop = try envelope(
            sessionID: sessionID, runID: firstRunID, event: "Stop",
            fields: [
                "last_assistant_message": "done",
                "background_tasks": [["id": "task-1"]],
                "session_crons": [["id": "cron-1"], ["id": "cron-2"]],
            ]
        )
        _ = try await tracker.receive(stop)
        status = await tracker.status()
        #expect(status.activity == .turnComplete)
        #expect(status.lastAssistantMessage == "done")
        #expect(status.backgroundTaskCount == 1)
        #expect(status.scheduledTaskCount == 2)

        await tracker.beginRun(secondRunID)
        #expect(try await tracker.receive(stop) == .staleRun)
        #expect(await tracker.status() == ClaudeSessionStatus())

        let unknown = try envelope(
            sessionID: sessionID, runID: secondRunID,
            event: "FutureEvent"
        )
        _ = try await tracker.receive(unknown)
        #expect(await tracker.status().activity == .unknown)
    }

    @Test func parserKeepsFailureAndWaitingInputDistinct() throws {
        let failurePayload = try payload(
            event: "StopFailure",
            fields: [
                "error": "rate_limit",
                "error_details": "429",
                "last_assistant_message": "API Error",
            ]
        )
        let failure = try ClaudeHookEvent(payload: failurePayload)
        #expect(failure.kind == .stopFailure(error: "rate_limit", details: "429"))
        #expect(failure.lastAssistantMessage == "API Error")

        let notification = try ClaudeHookEvent(payload: payload(
            event: "Notification", fields: ["notification_type": "idle_prompt"]
        ))
        #expect(notification.kind == .notification(type: "idle_prompt"))
    }

    private func envelope(sessionID: UUID, runID: UUID, event: String,
                          fields: [String: Any] = [:]) throws -> ClaudeHookEnvelope {
        ClaudeHookEnvelope(
            sessionID: sessionID, managedRunID: runID,
            payload: try payload(event: event, fields: fields)
        )
    }

    private func payload(event: String, fields: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "session_id": "provider-session",
            "hook_event_name": event,
            "cwd": "/tmp/workspace",
            "transcript_path": "/tmp/transcript.jsonl",
        ]
        object.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
