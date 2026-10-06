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
    @Test func denialMetadataCanResolveApprovalWithoutAStopHook() async throws {
        let session = UUID(), run = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: session, managedRunID: run)
        let instant = Date(timeIntervalSince1970: 1_000)
        _ = try await tracker.receive(ClaudeHookEnvelope(sessionID: session, managedRunID: run,
            payload: payload(event: "SessionStart", fields: ["source": "startup"]), sentAt: instant))
        _ = try await tracker.receive(ClaudeHookEnvelope(sessionID: session, managedRunID: run,
            payload: payload(event: "PermissionRequest"), sentAt: instant))
        let generation = await tracker.registryGeneration()
        let issue = await tracker.receiveRegistry(.snapshot(ClaudeRegistrySnapshot(
            sessionID: "provider-session", startedAt: 999_000, status: "idle", statusUpdatedAt: 1_000_010)),
            generation: generation, now: instant.addingTimeInterval(0.02))
        #expect(issue == nil)
        #expect(await tracker.status().activity == .waitingForInput)
    }

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
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        try pipe.fileHandleForWriting.write(contentsOf: input)
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "helper never emits an approval/decision")
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
            fields: ["source": "startup", "session_id": "provider-session"]
        )
        #expect(try await tracker.receive(start, receivedAt: startTime) == .applied(
            ClaudeHookEvent(payload: start.payload)
        ))
        var status = await tracker.status()
        #expect(status.providerSessionID == "provider-session")
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

    @Test func conversationTransitionsRejectLateEventsAndDuplicateStartsKeepWork() async throws {
        let sessionID = UUID(), runID = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: sessionID, managedRunID: runID)
        func event(_ kind: String, id: String, fields: [String: Any] = [:]) throws -> ClaudeHookEnvelope {
            try envelope(sessionID: sessionID, runID: runID, event: kind,
                         fields: fields.merging(["session_id": id]) { _, new in new })
        }
        _ = try await tracker.receive(event("SessionStart", id: "A", fields: ["source": "startup"]))
        _ = try await tracker.receive(event("Stop", id: "A", fields: ["background_tasks": ["task"], "session_crons": ["cron"]]))
        _ = try await tracker.receive(event("SessionStart", id: "B", fields: ["source": "clear"]))
        #expect(await tracker.status().backgroundTaskCount == 0)
        #expect(await tracker.status().scheduledTaskCount == 0)
        _ = try await tracker.receive(event("Stop", id: "B", fields: ["background_tasks": ["B-task"]]))
        _ = try await tracker.receive(event("UserPromptSubmit", id: "B"))
        let current = await tracker.status()
        _ = try await tracker.receive(event("SessionStart", id: "B", fields: ["source": "startup"]))
        #expect(await tracker.status() == current)
        for kind in ["Stop", "PermissionRequest", "UserPromptSubmit", "SessionStart"] {
            _ = try await tracker.receive(event(kind, id: "A", fields: ["source": "clear"]))
            #expect(await tracker.status() == current)
        }
        _ = try await tracker.receive(event("SessionStart", id: "A", fields: ["source": "resume"]))
        #expect(await tracker.status().providerSessionID == "A")
        #expect(await tracker.status().activity == .unknown)
        #expect(await tracker.status().backgroundTaskCount == 0)
    }

    @Test func childAgentPayloadCannotMutateParentStatus() async throws {
        let sessionID = UUID(), runID = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: sessionID, managedRunID: runID)
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "SessionStart"))
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "UserPromptSubmit"))
        let current = await tracker.status()
        for kind in ["Stop", "PermissionRequest", "UserPromptSubmit", "SessionStart"] {
            _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: kind,
                                                  fields: ["agent_id": "child-agent"]))
            #expect(await tracker.status() == current)
        }
    }

    @Test func connectionAcceptanceOrderSurvivesDelayedFirstPayloadAndEOF() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("ordered.sock").path
        let collector = HookEnvelopeCollector()
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: "token", handler: collector.append)
        defer { server.stop() }
        let first = ClaudeHookEnvelope(sessionID: UUID(), managedRunID: UUID(),
                                       payload: try payload(event: "SessionStart", fields: ["session_id": "A"]))
        let second = ClaudeHookEnvelope(sessionID: first.sessionID, managedRunID: first.managedRunID,
                                        payload: try payload(event: "SessionStart", fields: ["session_id": "B", "source": "clear"]))
        let envelopeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        let wire = try JSONSerialization.data(withJSONObject: ["authenticationToken": "token", "envelope": envelopeObject])
        let descriptor = try connectedTestSocket(socket)
        defer { Darwin.close(descriptor) }
        let middle = wire.count / 2
        try writeTestSocket(descriptor, data: Data(wire.prefix(middle)))
        try ClaudeHookClient.send(second, socketPath: socket, authenticationToken: "token")
        #expect(collector.waitForCount(1, timeout: 0.05).isEmpty,
                "A later connection must not overtake a first connection still awaiting payload/EOF")
        try writeTestSocket(descriptor, data: Data(wire.suffix(from: middle)))
        #expect(Darwin.shutdown(descriptor, SHUT_WR) == 0)
        #expect(collector.waitForCount(2, timeout: 1) == [first, second])
    }

    @Test func stalledConnectionHasBoundedReadAndDoesNotBlockSessionEndForever() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("bounded.sock").path
        let collector = HookEnvelopeCollector()
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: "token", handler: collector.append)
        defer { server.stop() }
        let stalled = try connectedTestSocket(socket)
        defer { Darwin.close(stalled) }
        try writeTestSocket(stalled, data: Data("{".utf8))
        let ending = ClaudeHookEnvelope(sessionID: UUID(), managedRunID: UUID(), payload: try payload(event: "SessionEnd"))
        try ClaudeHookClient.send(ending, socketPath: socket, authenticationToken: "token")
        #expect(collector.waitForCount(1, timeout: 2) == [ending])
    }

    private func connectedTestSocket(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClaudeHookTransportError.system(operation: "test socket", code: errno) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw ClaudeHookTransportError.system(operation: "test connect", code: errno)
        }
        return descriptor
    }

    private func writeTestSocket(_ descriptor: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard count > 0 else { throw ClaudeHookTransportError.system(operation: "test send", code: errno) }
            offset += count
        }
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
