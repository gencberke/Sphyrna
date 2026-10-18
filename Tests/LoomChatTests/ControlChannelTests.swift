import Foundation
import LoomCore
import Synchronization
import Testing
@testable import LoomChat

/// The request table: ids, answers, timeouts and cancels in both directions, and the capability gate.
@Suite(.timeLimit(.minutes(1)))
struct ControlChannelTests {
    private static func sequentialIDs() -> @Sendable () -> String {
        let counter = Mutex(0)
        return { counter.withLock { $0 += 1; return "req-\($0)" } }
    }

    private func channel(timeout: Duration = .seconds(30)) -> ControlChannel {
        ControlChannel(defaultTimeout: timeout, makeRequestID: Self.sequentialIDs())
    }

    private func json(_ data: Data?) throws -> JSONValue {
        let data = try #require(data)
        return try JSONDecoder().decode(JSONValue.self, from: data.dropLast())
    }

    private func response(_ id: String, _ payload: JSONValue) -> StreamMessage {
        Fixture.message(Fixture.line(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": payload]]))
    }

    // MARK: Host to CLI

    /// `outgoing` is bounded: a writer that cannot keep up (the child stopped reading) makes the next line fail with
    /// `outputFull` instead of piling up, and a request is not left waiting for an answer to a line never sent.
    @Test func aFullOutgoingQueueRefusesTheNextLineVisibly() async throws {
        let channel = ControlChannel(defaultTimeout: .seconds(5), outgoingLimit: 2, makeRequestID: Self.sequentialIDs())
        try await channel.write(Data("a\n".utf8))
        try await channel.write(Data("b\n".utf8))
        await #expect(throws: ControlError.outputFull) { try await channel.write(Data("c\n".utf8)) }
        await #expect(throws: ControlError.outputFull) { try await channel.request(.interrupt(cancelQueued: false)) }
        #expect(await channel.send(.interrupt(cancelQueued: false)) == nil)
        // Once the writer takes a line, there is room again, in order.
        var lines = channel.outgoing.makeAsyncIterator()
        #expect(await lines.next() == Data("a\n".utf8))
        try await channel.write(Data("d\n".utf8))
        #expect(await lines.next() == Data("b\n".utf8))
        #expect(await lines.next() == Data("d\n".utf8))
    }

    /// `system/control_request_progress` (S6: one `started` before a `side_question`'s answer) is a known message, never
    /// drift, and reaches the request's waiter as an event.
    @Test func requestProgressIsKnownAndReachesTheWaiter() async throws {
        let progress = Fixture.message(Fixture.line(["type": "system", "subtype": "control_request_progress",
                                                     "request_id": "req-1", "status": "started"]))
        #expect(progress == .controlProgress(requestID: "req-1", status: "started"))
        var model = TurnModel(source: .live)
        #expect(model.apply(progress).isEmpty)
        #expect(model.unknownRecordCount == 0)

        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        var events = channel.events.makeAsyncIterator()
        let reply = Task { try await channel.request(.sideQuestion("why?")) }
        _ = await lines.next()
        await channel.receive(progress)
        #expect(await events.next() == .progress(requestID: "req-1", status: "started"))
        await channel.receive(response("req-1", ["response": "because", "synthetic": false]))
        #expect(try await reply.value.sideQuestionResponse == "because")
    }

    @Test func aRequestGetsItsAnswerByIdAndAnInterruptReceiptIsTyped() async throws {
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        let reply = Task { try await channel.request(.interrupt(cancelQueued: true)) }
        let sent = try json(await lines.next())
        #expect(sent["request_id"] == "req-1" && sent["request"]?["subtype"] == "interrupt" && sent["request"]?["cancel_queued"] == true)
        await channel.receive(response("req-1", ["still_queued": ["u2"], "cancelled": ["u3", "u4"]]))
        let receipt = try await reply.value.interruptReceipt
        #expect(receipt.cancelled == ["u3", "u4"] && receipt.stillQueued == ["u2"])
    }

    @Test func requestsInFlightAreAnsweredEachByItsOwnId() async throws {
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        let first = Task { try await channel.request(.getContextUsage(.summary)) }
        let one = try json(await lines.next())
        let second = Task { try await channel.request(.setModel("opus")) }
        let two = try json(await lines.next())
        #expect(one["request_id"] == "req-1" && two["request_id"] == "req-2")
        await channel.receive(response("req-2", ["model": "opus"]))
        await channel.receive(response("req-1", ["tokens": 5]))
        let secondPayload = try await second.value.payload
        let firstPayload = try await first.value.payload
        #expect(secondPayload == ["model": "opus"] && firstPayload == ["tokens": 5])
    }

    @Test func anErrorAnswerRejectsTheRequest() async throws {
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        let reply = Task { try await channel.request(.setPermissionMode(.bypassPermissions)) }
        _ = await lines.next()
        await channel.receive(Fixture.message(Fixture.line(["type": "control_response", "response": ["subtype": "error", "request_id": "req-1", "error": "needs the launch flag"]])))
        let result = await reply.result
        #expect(throws: ControlError.rejected(requestID: "req-1", message: "needs the launch flag")) { try result.get() }
    }

    @Test func aRequestThatGetsNoAnswerTimesOutAndTheCLIIsToldToDropIt() async throws {
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        let started = ContinuousClock.now
        let reply = Task { try await channel.request(.getUsage(skipBehaviors: true), timeout: .milliseconds(80)) }
        let result = await reply.result
        #expect(throws: ControlError.timedOut(requestID: "req-1")) { try result.get() }
        #expect(ContinuousClock.now - started >= .milliseconds(70))
        let request = try json(await lines.next())
        #expect(request["request"]?["skip_behaviors"] == true)
        let cancel = try json(await lines.next())
        #expect(cancel == ["type": "control_cancel_request", "request_id": "req-1"])
        // A late answer changes nothing.
        await channel.receive(response("req-1", [:]))
    }

    @Test func cancellingTheCallerCancelsTheRequestBothWays() async throws {
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        let task = Task { try await channel.request(.getContextUsage(.full)) }
        _ = await lines.next()
        task.cancel()
        let result = await task.result
        #expect(throws: ControlError.cancelled(requestID: "req-1")) { try result.get() }
        let cancel = try json(await lines.next())
        #expect(cancel["type"] == "control_cancel_request" && cancel["request_id"] == "req-1")
    }

    @Test func closingFailsEveryRequestInFlight() async throws {
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        let task = Task { try await channel.request(.interrupt(cancelQueued: false)) }
        _ = await lines.next()
        await channel.close()
        let result = await task.result
        #expect(throws: ControlError.closed) { try result.get() }
        await #expect(throws: ControlError.closed) { try await channel.request(.interrupt(cancelQueued: false)) }
        #expect(await lines.next() == nil)
    }

    // MARK: Privacy

    @Test func noResponseKeepsTheAccountWhoeverAskedAndWheneverItArrives() async throws {
        let account: JSONValue = ["email": "user@example.invalid", "organization": "Org", "subscriptionType": "max", "apiProvider": "firstParty"]
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        var model = TurnModel(source: .live)

        // Asked for: get_usage and initialize alike.
        let usage = Task { try await channel.request(.getUsage(skipBehaviors: false)) }
        _ = await lines.next()
        await channel.receive(response("req-1", ["account": account, "five_hour": ["utilization": 0.4]]))
        let usageReply = try await usage.value
        #expect(usageReply.payload["account"] == nil && usageReply.payload["five_hour"]?["utilization"] == 0.4)
        let initialize = Task { try await channel.request(.initialize) }
        _ = await lines.next()
        await channel.receive(response("req-2", ["account": account, "pid": 7, "session_state": "idle"]))
        let ready = try await initialize.value
        model.apply(ready: ready.initializeResponse)
        #expect(ready.payload["account"] == nil && ready.initializeResponse.pid == 7)

        // Late (the request already timed out) and never asked for: the decoder's message carries no account either.
        let slow = Task { try await channel.request(.getContextUsage(.summary), timeout: .milliseconds(30)) }
        _ = await lines.next()
        _ = await slow.result
        var decoder = StreamJSONDecoder()
        let late = Fixture.text(Fixture.line(["type": "control_response", "response": ["subtype": "success", "request_id": "req-3",
                                                                                   "response": ["account": account, "tokens": 3]]]))
        let unsolicited = Fixture.text(Fixture.line(["type": "control_response", "response": ["subtype": "success", "request_id": "cli-77",
                                                                                         "response": ["account": account]]]))
        for frame in decoder.feed(late + unsolicited) {
            guard case let .message(message) = frame, case let .controlResponse(response) = message,
                  case let .success(payload) = response.outcome else { Issue.record("not a success response"); continue }
            #expect(payload["account"] == nil && !payload.serializedString.contains("example.invalid"))
            await channel.receive(message)
            model.apply(message)
        }
        await channel.close()
        var seen = 0
        for await _ in channel.events { seen += 1 }
        #expect(seen == 0 && model.entries.count == 1) // only the start marker
        #expect(!String(describing: model).contains("example.invalid"))
    }

    // MARK: Capabilities

    @Test func aRequestNeedingACapabilityIsRefusedOnlyWhenInitListsOthers() async throws {
        let channel = channel()
        var lines = channel.outgoing.makeAsyncIterator()
        // Nothing known yet: the request goes out.
        let early = Task { try await channel.request(.interrupt(cancelQueued: true)) }
        #expect(try json(await lines.next())["request"]?["cancel_queued"] == true)
        await channel.receive(response("req-1", [:]))
        _ = try await early.value

        await channel.receive(Fixture.message(Fixture.line(["type": "system", "subtype": "init", "capabilities": ["interrupt_receipt_v1"]])))
        #expect(await channel.knownCapabilities == ["interrupt_receipt_v1"])
        let refused = Task { try await channel.request(.interrupt(cancelQueued: true)) }
        let refusal = await refused.result
        #expect(throws: ControlError.unsupported(capability: "interrupt_cancel_queued_v1")) { try refusal.get() }
        // A plain interrupt needs none. Nothing was written for the refused one: the next line is this request.
        let plain = Task { try await channel.request(.interrupt(cancelQueued: false)) }
        let sent = try json(await lines.next())
        #expect(sent["request"] == ["subtype": "interrupt"] && sent["request_id"] == "req-2")
        await channel.receive(response("req-2", [:]))
        _ = try await plain.value

        await channel.receive(Fixture.message(Fixture.initMessage))
        let allowed = Task { try await channel.request(.interrupt(cancelQueued: true)) }
        #expect(try json(await lines.next())["request"]?["cancel_queued"] == true)
        await channel.receive(response("req-3", [:]))
        _ = try await allowed.value
    }

    // MARK: CLI to host

    private func permissionRequest(_ id: String) -> StreamMessage {
        Fixture.message(Fixture.line(["type": "control_request", "request_id": .string(id), "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"], "tool_use_id": "t1"]]))
    }

    @Test func aPermissionRequestWaitsForTheHostAndIsAnsweredOnce() async throws {
        let channel = channel()
        var events = channel.events.makeAsyncIterator()
        var lines = channel.outgoing.makeAsyncIterator()
        await channel.receive(permissionRequest("cli-1"))
        await channel.receive(permissionRequest("cli-2"))
        guard case let .request(first)? = await events.next(), case let .request(second)? = await events.next() else { Issue.record("no events"); return }
        #expect(first.requestID == "cli-1" && second.requestID == "cli-2")
        #expect(await channel.pendingRequests.map(\.requestID) == ["cli-1", "cli-2"])

        let answered = await channel.respond(to: "cli-1", with: .allow(updatedInput: ["command": "ls"]))
        #expect(answered)
        let line = try json(await lines.next())
        #expect(line["type"] == "control_response" && line["response"]?["request_id"] == "cli-1" && line["response"]?["subtype"] == "success")
        #expect(line["response"]?["response"] == ["behavior": "allow", "updatedInput": ["command": "ls"]])
        #expect(await channel.respond(to: "cli-1", with: .deny(message: "again")) == false)
        #expect(await channel.pendingRequests.map(\.requestID) == ["cli-2"])
    }

    @Test func theCLIWithdrawingARequestRemovesItAndSaysSo() async throws {
        let channel = channel()
        var events = channel.events.makeAsyncIterator()
        await channel.receive(permissionRequest("cli-1"))
        _ = await events.next()
        await channel.receive(Fixture.message(Fixture.line(["type": "control_cancel_request", "request_id": "cli-1"])))
        guard case let .cancelled(request)? = await events.next() else { Issue.record("no cancel event"); return }
        #expect(request.requestID == "cli-1")
        #expect(await channel.respond(to: "cli-1", with: .deny(message: "late")) == false)
        #expect(await channel.pendingRequests.isEmpty)
    }

    @Test func aRequestOfAnUnhandledKindIsAnsweredWithAnErrorSoTheCLIDoesNotWait() async throws {
        let channel = channel()
        var events = channel.events.makeAsyncIterator()
        var lines = channel.outgoing.makeAsyncIterator()
        await channel.receive(Fixture.message(Fixture.line(["type": "control_request", "request_id": "cli-9", "request": ["subtype": "elicitation", "message": "?"]])))
        #expect(await events.next() == .unsupported(requestID: "cli-9", subtype: "elicitation"))
        let line = try json(await lines.next())
        #expect(line["response"]?["subtype"] == "error" && line["response"]?["request_id"] == "cli-9")
        #expect(await channel.pendingRequests.isEmpty)
    }
}
