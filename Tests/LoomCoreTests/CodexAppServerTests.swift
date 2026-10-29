import Foundation
import Darwin
import CryptoKit
import Testing
@testable import LoomCore

struct CodexAppServerTests {
    @Test func alreadyReadFrameFencesTaskWriteUntilActorConsumesIt() async throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw CodexAppServerError.closed }
        let transport = try CodexWebSocketTransport(descriptor: descriptors[0], bufferedFrames: [])
        defer { transport.close(); Darwin.close(descriptors[1]) }
        let lease = SessionTaskRunLease()
        transport.setTaskIngress(lease)
        let before = try #require(lease.admit { $0 })
        let payload = Array(#"{"method":"thread/status/changed"}"#.utf8)
        let wire = [UInt8(0x81), UInt8(payload.count)] + payload
        #expect(wire.withUnsafeBytes { Darwin.send(descriptors[1], $0.baseAddress, $0.count, 0) } == wire.count)
        let frames = try await transport.receive()
        #expect(frames.count == 1)
        #expect(lease.admit { _ in true } == nil)
        let sends = CodexTaskWriteCapture()
        let sent = try transport.sendTask(Data("{}".utf8), transaction: { write in
            try lease.withAdmission(revision: before, write)
        }, writeOnce: { _, frame in sends.record(frame.count); return frame.count })
        #expect(!sent && sends.count == 0)
        frames.forEach { $0.finish() }
        let after = try #require(lease.admit { $0 })
        let next = try transport.sendTask(Data("{}".utf8), transaction: { write in
            try lease.withAdmission(revision: after, write)
        }, writeOnce: { _, frame in sends.record(frame.count); return frame.count })
        #expect(next && sends.count == 1)
    }

    @Test func partialReadFrameAlsoFencesTaskWriteUntilComplete() async throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw CodexAppServerError.closed }
        let transport = try CodexWebSocketTransport(descriptor: descriptors[0], bufferedFrames: [])
        defer { transport.close(); Darwin.close(descriptors[1]) }
        let lease = SessionTaskRunLease()
        transport.setTaskIngress(lease)
        let before = try #require(lease.admit { $0 })
        let payload = Array(#"{"method":"thread/status/changed"}"#.utf8)
        let prefix = [UInt8(0x81), UInt8(payload.count)] + Array(payload.prefix(4))
        #expect(prefix.withUnsafeBytes { Darwin.send(descriptors[1], $0.baseAddress, $0.count, 0) } == prefix.count)
        let receive = Task { try await transport.receive() }
        #expect(try await SessionRuntimeTests.waitUntil(2) { transport.readWaitCounts().waiting })
        #expect(lease.admit { _ in true } == nil)
        let sends = CodexTaskWriteCapture()
        let sent = try transport.sendTask(Data("{}".utf8), transaction: { write in
            try lease.withAdmission(revision: before, write)
        }, writeOnce: { _, frame in sends.record(frame.count); return frame.count })
        #expect(!sent && sends.count == 0)
        let rest = Array(payload.dropFirst(4))
        #expect(rest.withUnsafeBytes { Darwin.send(descriptors[1], $0.baseAddress, $0.count, 0) } == rest.count)
        let frames = try await receive.value
        #expect(frames.count == 1)
        frames.forEach { $0.finish() }
        #expect(lease.admit { _ in true } == true)
    }

    @Test func taskFrameBackpressureDefersAndPartialFrameClosesConnection() throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw CodexAppServerError.closed }
        let transport = try CodexWebSocketTransport(descriptor: descriptors[0], bufferedFrames: [])
        defer { transport.close(); Darwin.close(descriptors[1]) }
        let denied = try transport.sendTask(Data("{}".utf8), transaction: { _ in nil })
        #expect(!denied)
        let blocked = try transport.sendTask(Data("{}".utf8), transaction: { try $0() }, writeOnce: { _, _ in 0 })
        #expect(!blocked)
        #expect(throws: CodexAppServerError.self) {
            _ = try transport.sendTask(Data("{}".utf8), transaction: { try $0() }, writeOnce: { _, _ in 1 })
        }
        #expect(throws: CodexAppServerError.self) { try transport.send(Data("{}".utf8)) }
    }

    @Test func taskTurnRequestsPreserveNativeSettingsAndExactIdentity() async throws {
        let (client, peer) = try await CodexSocketPeer.make()
        defer { peer.close() }
        let start = Task { try await client.startTaskTurn(threadID: "owned-thread", text: "task pointer", transaction: { try $0() }, timeout: 2) }
        let startFrame = try await peer.nextFrame()
        let startCall = try JSONDecoder().decode(JSONValue.self, from: Data(startFrame.bytes))
        #expect(startCall["method"] == .string("turn/start"))
        #expect(startCall["params"] == .object([
            "threadId": .string("owned-thread"),
            "input": .array([.object(["type": .string("text"), "text": .string("task pointer"), "text_elements": .array([])])]),
        ]))
        let startID = try #require(startCall["id"])
        try peer.frame(.object(["id": startID, "result": .object(["turn": .object(["id": .string("native-turn")])])]))
        #expect(try await start.value == "native-turn")
        let interrupt = Task { try await client.interruptTaskTurn(threadID: "owned-thread", turnID: "native-turn", timeout: 2) }
        let stopFrame = try await peer.nextFrame()
        let stopCall = try JSONDecoder().decode(JSONValue.self, from: Data(stopFrame.bytes))
        #expect(stopCall["method"] == .string("turn/interrupt"))
        #expect(stopCall["params"] == .object(["threadId": .string("owned-thread"), "turnId": .string("native-turn")]))
        let stopID = try #require(stopCall["id"])
        try peer.frame(.object(["id": stopID, "result": .object([:])]))
        try await interrupt.value
        await client.close()
    }

    @Test func codexIngressFencesUntilItsOrderedConsumerFinishes() async throws {
        let (client, peer) = try await CodexSocketPeer.make()
        defer { peer.close() }
        let supervisor = try ProcessSupervisor()
        let coordinator = CodexSessionCoordinator(client: client, supervisor: supervisor,
                                                   adapter: CodexSessionAdapter(supervisor: supervisor))
        let lease = SessionTaskRunLease()
        await coordinator.fenceTaskEvents(with: lease)
        await client.fenceTaskEvents(with: lease)
        var iterator = client.events.makeAsyncIterator()
        try peer.frame(.object(["method": .string("thread/closed"),
                                "params": .object(["threadId": .string("unmatched")])]))
        let inbound = try #require(await iterator.next())
        #expect(lease.permits { true } == nil)
        await coordinator.consume(inbound)
        #expect(lease.permits { true } == true)
        await client.close()
    }

    @Test func taskInputObservationKeepsOnlyBoundedUserTextDigests() async throws {
        let (client, peer) = try await CodexSocketPeer.make()
        defer { peer.close() }
        let capture = CodexTaskInputCapture()
        await client.observeTaskInputs(capture.add)
        func send(_ item: JSONValue) throws {
            let value: JSONValue = .object(["method": .string("item/started"), "params": .object([
                "threadId": .string("thread"), "turnId": .string("turn"), "item": item,
            ])])
            let data = Array(try JSONEncoder().encode(value))
            let pieces = stride(from: 0, to: data.count, by: 100).map { Array(data[$0..<min($0 + 100, data.count)]) }
            for (index, piece) in pieces.enumerated() {
                try peer.rawFrame(opcode: index == 0 ? 1 : 0, final: index == pieces.count - 1, bytes: piece)
            }
        }
        func user(_ text: String) -> JSONValue {
            .object(["type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string(text), "text_elements": .array([])]),
            ])])
        }
        try send(user("owned pointer"))
        try send(.object(["type": .string("commandExecution"), "command": .string("private fixture")]))
        try send(user(String(repeating: "x", count: SessionTaskLimits.payloadBytes + 1)))
        #expect(try await SessionRuntimeTests.waitUntil { capture.values.count == 2 })
        let values = capture.values
        let first = try #require(values.first), last = try #require(values.last)
        #expect(first.threadID == "thread" && first.turnID == "turn")
        #expect(first.digest == Data(SHA256.hash(data: Data("owned pointer".utf8))))
        #expect(last.digest == nil)
        #expect(first.sequence < last.sequence)
        await client.close()
    }

    @Test func idleSocketsSuspendWithoutPollingAndAsyncWorkStillProgresses() async throws {
        var connections: [(CodexAppServerClient, CodexSocketPeer)] = []
        for _ in 0..<24 { connections.append(try await CodexSocketPeer.make()) }
        defer { for (_, peer) in connections { peer.close() } }
        for (client, _) in connections {
            try await waitUntil { client.readWaitCounts().waiting }
        }
        let counts = connections.map { $0.0.readWaitCounts().wakeups }
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(connections.map { $0.0.readWaitCounts().wakeups } == counts)
        let (client, peer) = connections[0]
        let request = Task { try await client.request(method: "heartbeat", timeout: 1) }
        let id = try await peer.requestID()
        try peer.frame(.object(["id": .number(Double(id)), "result": .string("alive")]))
        #expect(try await request.value == .string("alive"))
        for (client, _) in connections { await client.close() }
        for (client, _) in connections {
            try await waitUntil { await client.requestWorkCounts().deadlines == 0 }
            #expect(!client.readWaitCounts().waiting)
        }
    }

    @Test func completedRequestsCancelTheirDeadlineTasks() async throws {
        let (client, peer) = try await CodexSocketPeer.make()
        defer { peer.close() }
        for index in 0..<20 {
            let request = Task { try await client.request(method: "batch", timeout: 30) }
            let id = try await peer.requestID()
            if index.isMultiple(of: 2) {
                try peer.frame(.object(["id": .number(Double(id)), "result": .bool(true)]))
                #expect(try await request.value == .bool(true))
            } else {
                try peer.frame(.object(["id": .number(Double(id)), "error": .object([
                    "code": .number(-1), "message": .string("expected")])]))
                do { _ = try await request.value; Issue.record("RPC error must throw") }
                catch { #expect(error as? CodexAppServerError == .rpc(code: -1, message: "expected", data: nil)) }
            }
        }
        try await waitUntil { await client.requestWorkCounts().deadlines == 0 }
        #expect(await client.requestWorkCounts().pending == 0)
        await client.close()
    }

    @Test func cancellationTimeoutCloseAndLateResponsesCompleteOnce() async throws {
        let (client, peer) = try await CodexSocketPeer.make()
        defer { peer.close() }
        let cancelled = Task { try await client.request(method: "cancel", timeout: 30) }
        let id = try await peer.requestID()
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("cancel must throw") }
        catch { #expect(error is CancellationError) }
        try peer.frame(.object(["id": .number(Double(id)), "result": .null]))
        try await waitUntil { await client.requestWorkCounts().deadlines == 0 }
        let timeout = Task { try await client.request(method: "deadline", timeout: 0.02) }
        _ = try await peer.requestID()
        do { _ = try await timeout.value; Issue.record("deadline must throw") }
        catch { #expect(error as? CodexAppServerError == .timeout("deadline")) }
        let closed = Task { try await client.request(method: "close", timeout: 30) }
        _ = try await peer.requestID()
        await client.close()
        do { _ = try await closed.value; Issue.record("close must throw") }
        catch { #expect(error as? CodexAppServerError == .closed) }
        try await waitUntil { await client.requestWorkCounts().deadlines == 0 }
        #expect(await client.requestWorkCounts().pending == 0)
        do { _ = try await client.request(method: "after-close"); Issue.record("closed connection must reject") }
        catch { #expect(error as? CodexAppServerError == .closed) }
    }

    @Test func cancellationBeforeRegistrationDoesNotSendOrOwnADeadline() async throws {
        let (client, peer) = try await CodexSocketPeer.make()
        defer { peer.close() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.request(method: "already-cancelled", timeout: 30)
        }
        do { _ = try await task.value; Issue.record("pre-cancelled request must throw") }
        catch { #expect(error is CancellationError) }
        #expect(await client.requestWorkCounts().pending == 0)
        #expect(await client.requestWorkCounts().deadlines == 0)
        #expect(try peer.availableBytes().isEmpty)
        await client.close()
    }

    @Test func fragmentedMessagesPingAndClosePreserveOrderingAndDescriptorOwnership() async throws {
        for _ in 0..<12 {
            let (client, peer) = try await CodexSocketPeer.make()
            let request = Task { try await client.request(method: "fragment", timeout: 1) }
            let id = try await peer.requestID()
            let bytes = try JSONEncoder().encode(JSONValue.object([
                "id": .number(Double(id)), "result": .string("fragmented")]))
            let wakes = client.readWaitCounts().wakeups
            // Stop in the middle of the frame header, and independently wait
            // until the reader consumed it and suspended for the missing byte.
            try peer.write([0x01])
            try await waitUntil {
                let state = client.readWaitCounts()
                return state.waiting && state.wakeups > wakes
            }
            try peer.write([8] + Array(bytes.prefix(8)))
            try peer.rawFrame(opcode: 9, bytes: [65])
            try peer.rawFrame(opcode: 0, bytes: Array(bytes.dropFirst(8)))
            #expect(try await request.value == .string("fragmented"))
            let pong = try await peer.nextFrame()
            #expect(pong.opcode == 10 && pong.bytes == [65])
            let pending = Task { try await client.request(method: "remote-close", timeout: 30) }
            _ = try await peer.requestID()
            try peer.rawFrame(opcode: 8, bytes: [])
            do { _ = try await pending.value; Issue.record("remote close must throw") }
            catch { #expect(error as? CodexAppServerError == .closed) }
            await client.close()
            peer.close()
            try await waitUntil { await client.requestWorkCounts().deadlines == 0 }
            // Allocate reused descriptor numbers while the old source cancellation
            // can still be queued. A late handler must never close these sockets.
            let (replacement, replacementPeer) = try await CodexSocketPeer.make()
            let replacementRequest = Task { try await replacement.request(method: "reuse", timeout: 1) }
            let replacementID = try await replacementPeer.requestID()
            try replacementPeer.frame(.object(["id": .number(Double(replacementID)), "result": .null]))
            #expect(try await replacementRequest.value == .null)
            await replacement.close()
            replacementPeer.close()
        }
    }

    @Test func upgradeBufferedFramesAreConsumedBeforeWaitingForSocketReadiness() async throws {
        let first = Array(try JSONEncoder().encode(JSONValue.object(["method": .string("future/first")])))
        let second = Array(try JSONEncoder().encode(JSONValue.object(["method": .string("future/second")])))
        let buffered = [0x81, UInt8(first.count)] + first + [0x81, UInt8(second.count)] + second
        let (client, peer) = try await CodexSocketPeer.make(bufferedFrames: buffered)
        defer { peer.close() }
        try await waitUntil { await client.latestSequence() == 2 }
        var iterator = client.events.makeAsyncIterator()
        #expect(await iterator.next() == .event(sequence: 1, .unknown(method: "future/first")))
        #expect(await iterator.next() == .event(sequence: 2, .unknown(method: "future/second")))
        try await waitUntil { client.readWaitCounts().waiting }
        #expect(client.readWaitCounts().wakeups == 0)
        await client.close()
    }

    @Test func protocolAndSendFailuresAndReplyCancellationRacesRetireRequests() async throws {
        for oversized in [false, true] {
            let (client, peer) = try await CodexSocketPeer.make()
            let request = Task { try await client.request(method: "invalid", timeout: 30) }
            _ = try await peer.requestID()
            if oversized {
                // A canonical 64-bit payload length of 16 MiB + 1, no body needed.
                try peer.write([0x81, 127, 0, 0, 0, 0, 1, 0, 0, 1])
            } else { try peer.rawFrame(opcode: 2, bytes: []) }
            do { _ = try await request.value; Issue.record("invalid frame must throw") }
            catch { if case .protocolViolation = error as? CodexAppServerError {} else { Issue.record("expected protocol violation") } }
            try await waitUntil { await client.requestWorkCounts().deadlines == 0 }
            await client.close()
            peer.close()
        }
        let (failedClient, failedPeer) = try await CodexSocketPeer.make()
        failedPeer.close()
        do { _ = try await failedClient.request(method: "send-failed", timeout: 30); Issue.record("peer closure must throw") }
        catch {}
        try await waitUntil { await failedClient.requestWorkCounts().deadlines == 0 }
        #expect(await failedClient.requestWorkCounts().pending == 0)
        await failedClient.close()
        for _ in 0..<20 {
            let (client, peer) = try await CodexSocketPeer.make()
            let request = Task { try await client.request(method: "race", timeout: 0.02) }
            let id = try await peer.requestID()
            try peer.frame(.object(["id": .number(Double(id)), "result": .bool(true)]))
            request.cancel()
            do { #expect(try await request.value == .bool(true)) }
            catch { #expect(error is CancellationError || error as? CodexAppServerError == .timeout("race")) }
            await client.close()
            peer.close()
            try await waitUntil { await client.requestWorkCounts().deadlines == 0 }
            #expect(await client.requestWorkCounts().pending == 0)
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("socket/deadline work did not reach its expected suspended/finished state")
        throw CodexAppServerError.timeout("test state")
    }
    @Test func serverResolutionDecodesRoutesAndClearsOnlyItsPendingRequest() async {
        let runID = UUID()
        let binding = CodexRunBinding(sessionID: UUID(), managedRunID: runID,
                                     threadID: "user", workingDirectory: "/tmp/project")
        let router = CodexSessionRouter()
        await router.register(binding)
        let tracker = CodexEventStateTracker(threadID: "user", managedRunID: runID, after: 0)
        let request = CodexServerRequest(id: .number(7), method: "item/commandExecution/requestApproval",
            params: .object([:]), threadID: "user", kind: .commandExecution)
        _ = await tracker.receive(.request(sequence: 1, request), for: runID)
        let resolution = CodexAppServerClient.decodeEvent(method: "serverRequest/resolved",
            params: .object(["threadId": .string("user"), "requestId": .number(7)]))
        #expect(await router.route(.event(sequence: 2, resolution)) == .routed(binding))
        _ = await tracker.receive(.event(sequence: 2, resolution), for: runID)
        #expect(await tracker.status().pendingRequestCount == 0)
        #expect(await tracker.status().activity == .working)
    }

    @Test func resolutionKeepsSiblingRequestsAndRejectsWrongThreadSequenceOrRun() async {
        let runID = UUID(), laterRun = UUID()
        let tracker = CodexEventStateTracker(threadID: "thread", managedRunID: runID, after: 0)
        func request(_ id: JSONValue) -> CodexServerRequest {
            CodexServerRequest(id: id, method: "item/tool/requestUserInput", params: .object([:]), threadID: "thread", kind: .userInput)
        }
        _ = await tracker.receive(.request(sequence: 1, request(.number(7))), for: runID)
        _ = await tracker.receive(.request(sequence: 2, request(.string("7"))), for: runID)
        #expect(await tracker.status().pendingRequestCount == 2)
        #expect(await tracker.receive(.event(sequence: 3, .serverRequestResolved(threadID: "sibling", requestID: .number(7))), for: runID) == .differentThread)
        _ = await tracker.receive(.event(sequence: 4, .serverRequestResolved(threadID: "thread", requestID: .number(999))), for: runID)
        #expect(await tracker.status().pendingRequestCount == 2)
        _ = await tracker.receive(.event(sequence: 5, .serverRequestResolved(threadID: "thread", requestID: .number(7))), for: runID)
        _ = await tracker.receive(.event(sequence: 6, .serverRequestResolved(threadID: "thread", requestID: .number(7))), for: runID)
        #expect(await tracker.status().pendingRequestCount == 1)
        #expect(await tracker.status().activity == .waitingForInput)
        await tracker.beginRun(laterRun, after: 10)
        _ = await tracker.receive(.request(sequence: 11, request(.string("7"))), for: laterRun)
        #expect(await tracker.receive(.event(sequence: 12, .serverRequestResolved(threadID: "thread", requestID: .string("7"))), for: runID) == .staleRun)
        #expect(await tracker.receive(.event(sequence: 9, .serverRequestResolved(threadID: "thread", requestID: .string("7"))), for: laterRun) == .staleSequence)
        #expect(await tracker.status().pendingRequestCount == 1)
        _ = await tracker.receive(.event(sequence: 13, .serverRequestResolved(threadID: "thread", requestID: .string("7"))), for: laterRun)
        #expect(await tracker.status().pendingRequestCount == 0)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.status().lastAssistantMessage == nil)
    }

    @Test func malformedResolutionIDsRemainUnknown() {
        for id: JSONValue in [.null, .bool(true), .array([]), .object([:]), .number(1.25)] {
            #expect(CodexAppServerClient.decodeEvent(method: "serverRequest/resolved",
                params: .object(["threadId": .string("thread"), "requestId": id])) == .unknown(method: "serverRequest/resolved"))
        }
        #expect(CodexAppServerClient.decodeEvent(method: "serverRequest/resolved",
            params: .object(["threadId": .string("thread"), "requestId": .string("7")])) == .serverRequestResolved(threadID: "thread", requestID: .string("7")))
    }

    @Test func cancelledInteractiveReservationRejectsLateIdentity() async throws {
        let matcher = CodexLaunchMatcher()
        let reservation = await matcher.reserveNewLaunch(
            sessionID: UUID(), managedRunID: UUID(), workingDirectory: "/tmp/gate", after: 0
        )
        let waiting = Task { try await matcher.waitForMatch(reservation, timeout: nil) }
        await matcher.cancel(reservation)
        do {
            _ = try await waiting.value
            Issue.record("Cancelled identity wait must not succeed")
        } catch { #expect(error is CodexLaunchMatchingError) }
        let late = await matcher.receive(.event(sequence: 1, .threadStarted(.init(
            id: "late-thread", workingDirectory: "/tmp/gate", originator: nil, source: nil, ephemeral: false
        ))))
        #expect(late == nil)
        let next = await matcher.reserveNewLaunch(
            sessionID: UUID(), managedRunID: UUID(), workingDirectory: "/tmp/gate", after: 1
        )
        #expect(await matcher.receive(.event(sequence: 1, .threadStarted(.init(
            id: "late-thread", workingDirectory: "/tmp/gate", originator: nil, source: nil, ephemeral: false
        )))) == nil)
        await matcher.cancel(next)
    }

    @Test func installedSchemaEventsDecodeWithoutRejectingUnknownFields() throws {
        let started = CodexAppServerClient.decodeEvent(
            method: "thread/started",
            params: try value("""
                {
                  "thread": {
                    "id": "thread-one",
                    "cwd": "/tmp/workspace",
                    "originator": "codex-tui",
                    "source": "cli",
                    "ephemeral": false,
                    "futureField": {"nested": true}
                  }
                }
                """)
        )
        #expect(started == .threadStarted(CodexThreadIdentity(
            id: "thread-one", workingDirectory: "/tmp/workspace",
            originator: "codex-tui", source: "cli", ephemeral: false
        )))

        let status = CodexAppServerClient.decodeEvent(
            method: "thread/status/changed",
            params: try value("""
                {
                  "threadId": "thread-one",
                  "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval", "futureFlag"]
                  }
                }
                """)
        )
        #expect(status == .threadStatusChanged(
            threadID: "thread-one",
            status: .active([.waitingOnApproval, .other("futureFlag")])
        ))

        let completed = CodexAppServerClient.decodeEvent(
            method: "turn/completed",
            params: try value("""
                {
                  "threadId": "thread-one",
                  "turn": {
                    "id": "turn-one",
                    "status": "completed",
                    "items": [
                      {"type": "reasoning", "text": "hidden"},
                      {"type": "agentMessage", "phase": "final_answer", "text": "done"}
                    ]
                  }
                }
                """)
        )
        #expect(completed == .turnCompleted(
            threadID: "thread-one", turnID: "turn-one",
            outcome: .completed, lastAssistantMessage: "done"
        ))
        #expect(CodexAppServerClient.decodeEvent(
            method: "future/event", params: .object(["anything": .bool(true)])
        ) == .unknown(method: "future/event"))
    }

    @Test func reducerSeparatesWorkingApprovalFailureAndOldRunEvents() async {
        let firstRun = UUID(), secondRun = UUID()
        let tracker = CodexEventStateTracker(
            threadID: "thread-one", managedRunID: firstRun, after: 10
        )
        let promptTime = Date(timeIntervalSince1970: 100)
        #expect(await tracker.receive(
            .event(sequence: 11, .turnStarted(
                threadID: "thread-one", turnID: "turn-one"
            )), for: firstRun, receivedAt: promptTime
        ) == .applied)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.status().lastUsedAt == promptTime)

        let request = CodexServerRequest(
            id: .number(7), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string("thread-one")]),
            threadID: "thread-one", kind: .commandExecution
        )
        #expect(await tracker.receive(
            .request(sequence: 12, request), for: firstRun
        ) == .applied)
        #expect(await tracker.status().activity == .waitingForApproval)
        #expect(await tracker.status().pendingRequestCount == 1)

        await tracker.requestResolved(requestSequence: 12)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.status().pendingRequestCount == 0)

        #expect(await tracker.receive(
            .request(sequence: 13, request), for: firstRun
        ) == .applied)

        #expect(await tracker.receive(
            .event(sequence: 14, .error(
                threadID: "thread-one", turnID: "turn-one",
                message: "API unavailable", willRetry: false
            )), for: firstRun
        ) == .applied)
        #expect(await tracker.status().activity == .failed("API unavailable"))
        await tracker.requestResolved(requestSequence: 13)
        #expect(await tracker.status().pendingRequestCount == 0)
        #expect(await tracker.status().activity == .failed("API unavailable"))

        await tracker.beginRun(secondRun, after: 20)
        #expect(await tracker.receive(
            .event(sequence: 19, .turnCompleted(
                threadID: "thread-one", turnID: "old-turn",
                outcome: .completed, lastAssistantMessage: "stale"
            )), for: secondRun
        ) == .staleSequence)
        #expect(await tracker.receive(
            .event(sequence: 21, .unknown(method: "future/event")),
            for: secondRun
        ) == .applied)
        #expect(await tracker.status().activity == .unknown)

        #expect(await tracker.refresh(CodexThreadSnapshot(
            threadID: "thread-one", lastTurnID: "turn-two",
            lastTurnStartedAt: Date(timeIntervalSince1970: 200),
            lastTurnOutcome: .completed, lastAssistantMessage: "hydrated"
        ), after: 22) == .applied)
        #expect(await tracker.status().activity == .turnComplete)
        #expect(await tracker.status().lastAssistantMessage == "hydrated")
    }

    @Test func newTUILaunchesAreSerializedAndMatchedByCwd() async throws {
        let matcher = CodexLaunchMatcher()
        let first = await matcher.reserveNewLaunch(
            sessionID: UUID(), managedRunID: UUID(),
            workingDirectory: "/tmp/one", after: 1
        )
        let secondTask = Task {
            await matcher.reserveNewLaunch(
                sessionID: UUID(), managedRunID: UUID(),
                workingDirectory: "/tmp/two", after: 2
            )
        }
        try await Task.sleep(for: .milliseconds(20))

        await matcher.receive(.event(sequence: 2, .threadStarted(CodexThreadIdentity(
            id: "wrong", workingDirectory: "/tmp/two",
            originator: "codex-tui", source: "cli", ephemeral: false
        ))))
        await matcher.receive(.event(sequence: 3, .threadStarted(CodexThreadIdentity(
            id: "thread-one", workingDirectory: "/tmp/one",
            originator: "codex-tui", source: "cli", ephemeral: false
        ))))
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: first.sessionID, managedRunID: first.managedRunID,
            threadID: "thread-one", workingDirectory: "/tmp/one")))
        #expect(try await matcher.waitForMatch(first) == "thread-one")

        let second = await secondTask.value
        await matcher.receive(.event(sequence: 4, .threadStarted(CodexThreadIdentity(
            id: "thread-two", workingDirectory: "/tmp/two",
            originator: "codex-tui", source: "cli", ephemeral: false
        ))))
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: second.sessionID, managedRunID: second.managedRunID,
            threadID: "thread-two", workingDirectory: "/tmp/two")))
        #expect(try await matcher.waitForMatch(second) == "thread-two")
    }

    @Test func routerMapsNewThreadOnlyWhenItsRunningTUIIsUnambiguous() async {
        let router = CodexSessionRouter()
        let one = CodexRunBinding(
            sessionID: UUID(), managedRunID: UUID(), threadID: "thread-one",
            workingDirectory: "/tmp/shared"
        )
        await router.register(one)
        let newThread = CodexAppServerInbound.event(
            sequence: 5,
            .threadStarted(CodexThreadIdentity(
                id: "thread-new", workingDirectory: "/tmp/shared",
                originator: "loom", source: "vscode", ephemeral: false
            ))
        )
        #expect(await router.route(newThread) == .newConversation(
            previous: one,
            identity: CodexThreadIdentity(
                id: "thread-new", workingDirectory: "/tmp/shared",
                originator: "loom", source: "vscode", ephemeral: false
            )
        ))

        let two = CodexRunBinding(
            sessionID: UUID(), managedRunID: UUID(), threadID: "thread-two",
            workingDirectory: "/tmp/shared"
        )
        await router.register(two)
        guard case let .ambiguous(candidates, threadID) = await router.route(newThread) else {
            Issue.record("Same-cwd /new was guessed instead of reported ambiguous")
            return
        }
        #expect(threadID == "thread-new")
        #expect(Set(candidates.map(\.threadID)) == ["thread-one", "thread-two"])
    }

    @Test func routerUsesReservationBeforeExistingSameCwdBindings() async throws {
        let matcher = CodexLaunchMatcher()
        let router = CodexSessionRouter(launchMatcher: matcher)
        await router.register(CodexRunBinding(
            sessionID: UUID(), managedRunID: UUID(), threadID: "existing",
            workingDirectory: "/tmp/shared"
        ))
        let sessionID = UUID(), runID = UUID()
        let reservation = await matcher.reserveNewLaunch(
            sessionID: sessionID, managedRunID: runID,
            workingDirectory: "/tmp/shared", after: 3
        )
        let decision = await router.route(.event(
            sequence: 4,
            .threadStarted(CodexThreadIdentity(
                id: "new-launch", workingDirectory: "/tmp/shared",
                originator: "loom", source: "vscode", ephemeral: false
            ))
        ))
        #expect(decision == .initialLaunchMatched(CodexRunBinding(
            sessionID: sessionID, managedRunID: runID,
            threadID: "new-launch", workingDirectory: "/tmp/shared"
        ), sequence: 4))
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: reservation.sessionID, managedRunID: reservation.managedRunID,
            threadID: "new-launch", workingDirectory: "/tmp/shared")))
        #expect(try await matcher.waitForMatch(reservation) == "new-launch")
    }

    @Test func knownThreadReplayDoesNotClaimAnotherSameCwdLaunch() async throws {
        let matcher = CodexLaunchMatcher()
        let router = CodexSessionRouter(launchMatcher: matcher)
        let existing = CodexRunBinding(sessionID: UUID(), managedRunID: UUID(),
                                       threadID: "existing", workingDirectory: "/tmp/shared")
        await router.register(existing)
        let reservation = await matcher.reserveNewLaunch(
            sessionID: UUID(), managedRunID: UUID(), workingDirectory: "/tmp/shared", after: 3
        )
        let duplicate = CodexThreadIdentity(id: existing.threadID, workingDirectory: "/tmp/shared",
                                           originator: "codex-tui", source: "cli", ephemeral: false)
        #expect(await router.route(.event(sequence: 4, .threadStarted(duplicate))) == .routed(existing))
        let genuinelyNew = CodexThreadIdentity(id: "new-launch", workingDirectory: "/tmp/shared",
                                              originator: "codex-tui", source: "cli", ephemeral: false)
        #expect(await router.route(.event(sequence: 5, .threadStarted(genuinelyNew))) == .initialLaunchMatched(
            CodexRunBinding(sessionID: reservation.sessionID, managedRunID: reservation.managedRunID,
                            threadID: genuinelyNew.id, workingDirectory: "/tmp/shared"), sequence: 5))
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: reservation.sessionID, managedRunID: reservation.managedRunID,
            threadID: genuinelyNew.id, workingDirectory: "/tmp/shared")))
        #expect(try await matcher.waitForMatch(reservation) == genuinelyNew.id)
    }

    @Test func ephemeralThreadsNeverClaimReservationsBindingsOrAmbiguity() async throws {
        let matcher = CodexLaunchMatcher()
        let router = CodexSessionRouter(launchMatcher: matcher)
        let one = CodexRunBinding(sessionID: UUID(), managedRunID: UUID(),
                                  threadID: "user-thread", workingDirectory: "/tmp/shared")
        await router.register(one)
        let reservation = await matcher.reserveNewLaunch(
            sessionID: UUID(), managedRunID: UUID(), workingDirectory: "/tmp/shared", after: 0
        )
        let helper = CodexAppServerInbound.event(sequence: 1, .threadStarted(CodexThreadIdentity(
            id: "helper", workingDirectory: "/tmp/shared", originator: "private-value",
            source: "exec", ephemeral: true
        )))
        #expect(await router.route(helper) == .unmatched)
        let normal = CodexThreadIdentity(id: "reserved-user", workingDirectory: "/tmp/shared",
                                         originator: "codex-tui", source: "cli", ephemeral: false)
        #expect(await router.route(.event(sequence: 2, .threadStarted(normal))) == .initialLaunchMatched(
            CodexRunBinding(sessionID: reservation.sessionID, managedRunID: reservation.managedRunID,
                            threadID: normal.id, workingDirectory: "/tmp/shared"), sequence: 2))
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: reservation.sessionID, managedRunID: reservation.managedRunID,
            threadID: normal.id, workingDirectory: "/tmp/shared")))
        #expect(try await matcher.waitForMatch(reservation) == normal.id)
        #expect(await router.route(helper) == .unmatched)
        await router.register(CodexRunBinding(sessionID: UUID(), managedRunID: UUID(),
                                            threadID: "second-user", workingDirectory: "/tmp/shared"))
        #expect(await router.route(helper) == .unmatched)
        #expect(await router.route(.event(sequence: 2, .threadStatusChanged(threadID: "helper", status: .idle))) == .unmatched)
        #expect(await router.route(.event(sequence: 3, .threadStatusChanged(threadID: "user-thread", status: .idle))) == .routed(one))
    }

    @Test func anUnidentifiedInitialThreadIsVisibleButCannotBindTheReservation() async throws {
        let matcher = CodexLaunchMatcher()
        let router = CodexSessionRouter(launchMatcher: matcher)
        let reservation = await matcher.reserveNewLaunch(
            sessionID: UUID(), managedRunID: UUID(), workingDirectory: "/tmp/initial", after: 0)
        let helper = CodexThreadIdentity(id: "helper", workingDirectory: "/tmp/initial",
                                        originator: nil, source: nil, ephemeral: true)
        #expect(await router.route(.event(sequence: 1, .threadStarted(helper))) == .unmatched)
        let unknown = CodexThreadIdentity(id: "unknown", workingDirectory: "/tmp/initial",
                                         originator: nil, source: nil)
        guard case let .ambiguous(candidates, threadID) = await router.route(.event(sequence: 2, .threadStarted(unknown))) else {
            Issue.record("Missing metadata authorized an initial identity")
            await matcher.cancel(reservation)
            return
        }
        #expect(threadID == "unknown" && candidates.map(\.managedRunID) == [reservation.managedRunID])
        let normal = CodexThreadIdentity(id: "user", workingDirectory: "/tmp/initial",
                                        originator: "codex-tui", source: "cli", ephemeral: false)
        guard case .initialLaunchMatched = await router.route(.event(sequence: 3, .threadStarted(normal))) else {
            Issue.record("Rejected metadata consumed the reservation")
            await matcher.cancel(reservation)
            return
        }
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: reservation.sessionID, managedRunID: reservation.managedRunID,
            threadID: "user", workingDirectory: "/tmp/shared")))
        #expect(try await matcher.waitForMatch(reservation) == "user")
    }

    @Test func incompleteMetadataNeverAuthorizesIdentityChangeAndDiagnosticsAreBounded() async throws {
        let router = CodexSessionRouter()
        let binding = CodexRunBinding(sessionID: UUID(), managedRunID: UUID(),
                                     threadID: "user", workingDirectory: "/tmp/private-path")
        await router.register(binding)
        let identity = CodexThreadIdentity(id: "unknown", workingDirectory: binding.workingDirectory,
                                          originator: "secret-originator", source: "secret-source")
        #expect(await router.route(.event(sequence: 1, .threadStarted(identity))) == .ambiguous([binding], threadID: "unknown"))
        let diagnostics = await router.diagnostics.snapshot()
        #expect(diagnostics.entries.first?.source == "other")
        #expect(diagnostics.entries.first?.originator == "other")
        #expect(diagnostics.entries.first?.cwdMatch == true)
        let encoded = String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self)
        #expect(!encoded.contains("secret") && !encoded.contains("private-path"))
        for sequence in 2...258 {
            _ = await router.route(.event(sequence: UInt64(sequence), .unknown(method: "private-method")))
        }
        let bounded = await router.diagnostics.snapshot()
        #expect(bounded.entries.count == 256 && bounded.dropped == 2)
        #expect(bounded.entries.last?.event == "unknown")
        #expect(!String(decoding: try JSONEncoder().encode(bounded), as: UTF8.self).contains("private-method"))
    }

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}

private final class CodexTaskInputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexTaskInputObservation] = []
    func add(_ value: CodexTaskInputObservation) { lock.withLock { storage.append(value) } }
    var values: [CodexTaskInputObservation] { lock.withLock { storage } }
}

private final class CodexTaskWriteCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    func record(_ ignored: Int) { lock.withLock { writes += 1 } }
    var count: Int { lock.withLock { writes } }
}

private final class CodexSocketPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var input: [UInt8] = []

    private init(_ descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                       socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    static func make(bufferedFrames: [UInt8] = []) async throws -> (CodexAppServerClient, CodexSocketPeer) {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw CodexAppServerError.system(operation: "test socketpair", code: errno)
        }
        let peer = CodexSocketPeer(sockets[1])
        let client = try await CodexAppServerClient.connectedSocket(descriptor: sockets[0], bufferedFrames: bufferedFrames)
        return (client, peer)
    }

    deinit { close() }
    func close() {
        lock.withLock {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        }
    }

    func availableBytes() throws -> [UInt8] {
        try lock.withLock {
            guard descriptor >= 0 else { throw CodexAppServerError.closed }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if count > 0 { return Array(bytes.prefix(count)) }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return [] }
            if count == 0 { throw CodexAppServerError.closed }
            throw CodexAppServerError.system(operation: "test read", code: errno)
        }
    }

    func frame(_ value: JSONValue) throws {
        try rawFrame(opcode: 1, bytes: Array(JSONEncoder().encode(value)))
    }

    func rawFrame(opcode: UInt8, final: Bool = true, bytes: [UInt8]) throws {
        precondition(bytes.count < 126)
        let frame = [(final ? 0x80 : 0) | opcode, UInt8(bytes.count)] + bytes
        try write(frame)
    }

    func write(_ frame: [UInt8]) throws {
        try lock.withLock {
            guard descriptor >= 0 else { throw CodexAppServerError.closed }
            let count = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            guard count == frame.count else {
                throw CodexAppServerError.system(operation: "test write", code: errno)
            }
        }
    }

    func requestID() async throws -> Int {
        let frame = try await nextFrame()
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(frame.bytes))
        guard case let .number(id) = json.object?["id"] else {
            throw CodexAppServerError.protocolViolation("test expected request id")
        }
        return Int(id)
    }

    func nextFrame() async throws -> (opcode: UInt8, bytes: [UInt8]) {
        for _ in 0..<400 {
            input += try availableBytes()
            if input.count >= 2 {
                var length = Int(input[1] & 0x7f)
                var offset = 2
                if length == 126 {
                    if input.count < 4 { try await Task.sleep(for: .milliseconds(5)); continue }
                    length = Int(input[2]) * 256 + Int(input[3]); offset = 4
                }
                guard length != 127, input[1] & 0x80 != 0 else {
                    throw CodexAppServerError.protocolViolation("test expected masked small client frame")
                }
                if input.count >= offset + 4 + length {
                    let mask = Array(input[offset..<(offset + 4)])
                    let payload = input[(offset + 4)..<(offset + 4 + length)].enumerated()
                        .map { $0.element ^ mask[$0.offset % 4] }
                    let opcode = input[0] & 0x0f
                    input.removeFirst(offset + 4 + length)
                    return (opcode, payload)
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CodexAppServerError.timeout("test client frame")
    }
}
