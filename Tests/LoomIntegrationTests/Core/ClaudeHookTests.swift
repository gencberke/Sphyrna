import Darwin
import CryptoKit
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

private final class HookEnvelopeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ClaudeHookEnvelope] = []
    var envelopes: [ClaudeHookEnvelope] { lock.withLock { storage } }

    func append(_ envelope: ClaudeHookEnvelope) { lock.withLock { storage.append(envelope) } }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ClaudeHookTests {
    @Test func taskPromptProofContainsOnlyABoundedNonSyntheticDigest() throws {
        let real = try ClaudeHookEvent(payload: payload(event: "UserPromptSubmit", fields: ["prompt": "owned pointer"]))
        #expect(real.taskPromptDigest == Data(SHA256.hash(data: Data("owned pointer".utf8))))
        let oversized = try ClaudeHookEvent(payload: payload(event: "UserPromptSubmit",
            fields: ["prompt": String(repeating: "x", count: SessionTaskLimits.payloadBytes + 1)]))
        #expect(oversized.taskPromptDigest == nil)
        let synthetic = try ClaudeHookEvent(payload: payload(event: "UserPromptSubmit",
            fields: ["prompt": "<task-notification>fixture</task-notification>"]))
        #expect(synthetic.promptIsSynthetic && synthetic.taskPromptDigest == nil)
    }

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

    @Test func authenticatedUnixSocketDeliversOnlyValidMessages() async throws {
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
        // The server refuses a wrong token and says so, so `loom-hook` can leave a trace.
        #expect(throws: ClaudeHookTransportError.rejected) {
            try ClaudeHookClient.send(
                envelope, socketPath: socketPath, authenticationToken: "wrong-token"
            )
        }
        await holds("no envelope from a wrong token", for: .milliseconds(50)) { collector.envelopes.isEmpty }

        try ClaudeHookClient.send(
            envelope, socketPath: socketPath, authenticationToken: "correct-token"
        )
        await waitFor("the envelope", within: .seconds(1)) { !collector.envelopes.isEmpty }
        #expect(collector.envelopes == [envelope])
    }

    @Test func helperForwardsInheritedSessionAndRunIdentity() async throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("events.sock").path
        let collector = HookEnvelopeCollector()
        let server = try ClaudeHookServer(
            socketPath: socketPath, authenticationToken: "helper-token",
            handler: collector.append
        )
        defer { server.stop() }
        let sessionID = UUID(), runID = UUID(), generation = UUID()
        let input = try payload(event: "SessionStart", fields: ["source": "startup"])
        let process = Process()
        process.executableURL = Products.directory.appendingPathComponent("loom-hook")
        process.environment = [
            "LOOM_HOOK_SOCKET": socketPath,
            "LOOM_HOOK_TOKEN": "helper-token",
            "LOOM_SESSION_ID": sessionID.uuidString,
            "LOOM_MANAGED_RUN_ID": runID.uuidString,
            "SPHYRNA_TASK_GENERATION": generation.uuidString,
            "SPHYRNA_TASK_TOKEN": "synthetic-run-secret",
        ]
        let helper = try await runToEnd(process, input: input)

        #expect(helper.status == 0)
        #expect(helper.output.isEmpty, "helper never emits an approval/decision")
        await waitFor("the helper's envelope", within: .seconds(1)) { !collector.envelopes.isEmpty }
        let received = try #require(collector.envelopes.first)
        #expect(received.sessionID == sessionID)
        #expect(received.managedRunID == runID)
        #expect(received.taskGeneration == generation && received.taskCredential == "synthetic-run-secret")
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
        #expect(status.activity == .atPrompt)

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
        #expect(await tracker.status().activity == .atPrompt)
        #expect(await tracker.status().backgroundTaskCount == 0)
    }

    /// A resumed Claude at its prompt is ready, and a prompt typed before its SessionStart hook
    /// arrived is not wiped by that late start (the run is seeded with the conversation's id).
    @Test func resumedConversationIsReadyAndALateStartKeepsTheTurn() async throws {
        let sessionID = UUID(), runID = UUID()
        func event(_ kind: String, fields: [String: Any] = [:]) throws -> ClaudeHookEnvelope {
            try envelope(sessionID: sessionID, runID: runID, event: kind,
                         fields: fields.merging(["session_id": "A"]) { _, new in new })
        }
        let idle = ClaudeHookStateTracker(sessionID: sessionID, managedRunID: runID, providerSessionID: "A")
        _ = try await idle.receive(event("SessionStart", fields: ["source": "resume"]))
        #expect(await idle.status().activity == .atPrompt)
        _ = try await idle.receive(event("UserPromptSubmit"))
        #expect(await idle.status().activity == .working)

        let raced = ClaudeHookStateTracker(sessionID: sessionID, managedRunID: runID, providerSessionID: "A")
        _ = try await raced.receive(event("UserPromptSubmit"))
        #expect(try await raced.receive(event("SessionStart", fields: ["source": "resume"])) != .duplicateSessionStart)
        #expect(await raced.status().activity == .working)
        #expect(await raced.status().providerSessionID == "A")
        #expect(await raced.registryGeneration() != nil)
        // Later duplicates of the start stay ignored; the turn still ends normally.
        #expect(try await raced.receive(event("SessionStart", fields: ["source": "compact"])) == .duplicateSessionStart)
        _ = try await raced.receive(event("Stop"))
        #expect(await raced.status().activity == .turnComplete)
    }

    /// Notification types that say nothing about the turn keep the state; an MCP elicitation
    /// waits for the user.
    @Test func informationalNotificationsKeepTheState() async throws {
        let sessionID = UUID(), runID = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: sessionID, managedRunID: runID)
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "SessionStart"))
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "UserPromptSubmit"))
        let generation = await tracker.registryGeneration()
        for type in ["auth_success", "a_type_from_a_newer_claude"] {
            _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "Notification",
                                                  fields: ["notification_type": type]))
            #expect(await tracker.status().activity == .working)
            #expect(await tracker.registryGeneration() == generation)
        }
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "Notification",
                                              fields: ["notification_type": "elicitation_dialog"]))
        #expect(await tracker.status().activity == .waitingForInput)
        // Answered in the terminal without a prompt hook: the registry check stays open so its
        // "busy" sample can move the card back to Working.
        #expect(await tracker.registryGeneration() != nil)
    }

    /// A prompt typed into a new session before its SessionStart hook arrived is dropped; that
    /// start then cannot claim Claude is idle at its prompt.
    @Test func aPromptDroppedBeforeTheFirstStartKeepsTheStateUnknown() async throws {
        let sessionID = UUID(), runID = UUID()
        func event(_ kind: String, fields: [String: Any] = [:]) throws -> ClaudeHookEnvelope {
            try envelope(sessionID: sessionID, runID: runID, event: kind,
                         fields: fields.merging(["session_id": "Z"]) { _, new in new })
        }
        let tracker = ClaudeHookStateTracker(sessionID: sessionID, managedRunID: runID)
        #expect(try await tracker.receive(event("UserPromptSubmit")) == .wrongConversation)
        _ = try await tracker.receive(event("SessionStart", fields: ["source": "startup"]))
        #expect(await tracker.status().activity == .unknown)
        _ = try await tracker.receive(event("Stop"))
        #expect(await tracker.status().activity == .turnComplete)
        // A later conversation of the same run starts at its prompt again.
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "SessionStart",
                                              fields: ["session_id": "Y", "source": "clear"]))
        #expect(await tracker.status().activity == .atPrompt)
    }

    @Test func childAgentPayloadCannotMutateParentStatus() async throws {
        let sessionID = UUID(), runID = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: sessionID, managedRunID: runID)
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "SessionStart"))
        _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: "UserPromptSubmit"))
        let current = await tracker.status()
        for kind in ["Stop", "UserPromptSubmit", "SessionStart"] {
            _ = try await tracker.receive(envelope(sessionID: sessionID, runID: runID, event: kind,
                                                  fields: ["agent_id": "child-agent"]))
            #expect(await tracker.status() == current)
        }
    }

    @Test func connectionAcceptanceOrderSurvivesDelayedFirstPayloadAndEOF() async throws {
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
        await holds("A later connection must not overtake a first connection still awaiting payload/EOF",
                    for: .milliseconds(50)) { collector.envelopes.isEmpty }
        try writeTestSocket(descriptor, data: Data(wire.suffix(from: middle)))
        #expect(Darwin.shutdown(descriptor, SHUT_WR) == 0)
        await waitFor("both envelopes", within: .seconds(1)) { collector.envelopes.count >= 2 }
        #expect(collector.envelopes == [first, second])
    }

    @Test func stalledConnectionHasBoundedReadAndDoesNotBlockSessionEndForever() async throws {
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
        await waitFor("the session end's envelope", within: .seconds(2)) { !collector.envelopes.isEmpty }
        #expect(collector.envelopes == [ending])
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
