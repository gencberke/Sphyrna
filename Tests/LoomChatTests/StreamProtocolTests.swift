import Foundation
import LoomCore
import Testing
@testable import LoomChat
@testable import LoomChatTestRigs

/// The wire: NDJSON framing across chunk boundaries and for lines of many MB, unknown types passed through, and the
/// typed messages Loom reads.
@Suite(.timeLimit(.minutes(1)))
struct StreamProtocolTests {
    private func decode(_ chunks: [Data], maximumLineBytes: Int = StreamJSONDecoder.defaultMaximumLineBytes) -> [StreamFrame] {
        var decoder = StreamJSONDecoder(maximumLineBytes: maximumLineBytes)
        var frames: [StreamFrame] = []
        for chunk in chunks { frames += decoder.feed(chunk) }
        return frames + decoder.finish()
    }

    // MARK: Framing

    @Test func linesSplitAtAnyByteBoundaryDecodeTheSame() {
        let input = Fixture.text(Fixture.initMessage) + Fixture.text(Fixture.echo("héllo wörld 日本語", uuid: "u1")) + Fixture.text(Fixture.result())
        let whole = decode([input])
        #expect(whole.count == 3)
        // One byte at a time: every multi-byte character and every line is cut at every possible place.
        let bytes = input.map { Data([$0]) }
        #expect(decode(bytes) == whole)
        // Odd chunk sizes.
        for size in [2, 3, 7, 64, 1000] {
            let chunks = stride(from: 0, to: input.count, by: size).map { input.subdata(in: $0..<min($0 + size, input.count)) }
            #expect(decode(chunks) == whole)
        }
        guard case let .message(.user(user)) = whole[1] else { Issue.record("not a user message"); return }
        #expect(user.text == "héllo wörld 日本語" && user.isReplay && user.uuid == "u1")
    }

    @Test func aLineWithoutANewlineEndsWithTheStream() {
        let frames = decode([Data(Fixture.result().utf8)])
        #expect(frames.count == 1)
        guard case let .message(.result(result)) = frames[0] else { Issue.record("not a result"); return }
        #expect(result.subtype == .success && result.durationMs == 4200)
    }

    @Test func aMultiMegabyteLineDecodesAndItsMemoryIsReleased() {
        // About 12 MB of text in one assistant message, delivered in 64 KiB chunks like a pipe would.
        let big = String(repeating: "0123456789abcdef", count: 12 * 1024 * 1024 / 16)
        let data = Fixture.text(Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock(big)]))
            + Fixture.text(Fixture.result())
        var decoder = StreamJSONDecoder()
        var frames: [StreamFrame] = []
        var peak = 0
        for start in stride(from: 0, to: data.count, by: 64 * 1024) {
            frames += decoder.feed(data.subdata(in: start..<min(start + 64 * 1024, data.count)))
            peak = max(peak, decoder.bufferedByteCount)
        }
        #expect(frames.count == 2)
        guard case let .message(.assistant(message)) = frames[0], case let .text(text)? = message.content.first else {
            Issue.record("not an assistant text"); return
        }
        #expect(text.utf8.count == big.utf8.count)
        // The buffer held the one line, and nothing is kept once it was decoded.
        #expect(peak <= big.utf8.count + 4096)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func aLineOverTheLimitIsCountedAndSkippedWithoutBeingBuffered() {
        let limit = 1000
        let huge = String(repeating: "x", count: 5000)
        let input = Fixture.text(Fixture.result()) + Fixture.text(Fixture.assistant(messageID: "m", uuid: "a", blocks: [Fixture.textBlock(huge)]))
            + Fixture.text(Fixture.echo("after", uuid: "u2"))
        var decoder = StreamJSONDecoder(maximumLineBytes: limit)
        var frames: [StreamFrame] = []
        var peak = 0
        for start in stride(from: 0, to: input.count, by: 100) {
            frames += decoder.feed(input.subdata(in: start..<min(start + 100, input.count)))
            peak = max(peak, decoder.bufferedByteCount)
        }
        #expect(frames.count == 3)
        guard case .message(.result) = frames[0], case let .oversized(count, head) = frames[1], case .message(.user) = frames[2] else {
            Issue.record("unexpected frames \(frames)"); return
        }
        #expect(count > 5000 && head.hasPrefix("{"))
        #expect(peak <= limit)
    }

    @Test func notJSONIsMalformedAndTheStreamGoesOn() {
        let frames = decode([Data("this is not json\n[1,2]\n\n   \n".utf8), Fixture.text(Fixture.result())])
        #expect(frames.count == 3)
        guard case .malformed = frames[0], case .malformed = frames[1], case .message(.result) = frames[2] else {
            Issue.record("unexpected frames \(frames)"); return
        }
    }

    // MARK: Unknown passes through

    @Test func unknownTypesAndSubtypesKeepTheirJSON() {
        let future = Fixture.line(["type": "hologram", "payload": ["a": 1]])
        let subtype = Fixture.line(["type": "system", "subtype": "teleported", "where": "mars"])
        let frames = decode([Fixture.text(future) + Fixture.text(subtype)])
        guard case let .message(.unknown(first)) = frames[0], case let .message(.unknown(second)) = frames[1] else {
            Issue.record("unexpected frames \(frames)"); return
        }
        #expect(first.type == "hologram" && first.subtype == nil && first.raw["payload"]?["a"]?.int == 1)
        #expect(second.type == "system" && second.subtype == "teleported" && second.raw["where"]?.string == "mars")
    }

    // MARK: Typed messages

    @Test func systemInitCarriesTheSessionAndItsCapabilities() {
        guard case let .systemInit(info) = Fixture.message(Fixture.initMessage) else { Issue.record("not init"); return }
        #expect(info.sessionID == "s1" && info.model == "claude-opus-5-5" && info.permissionMode == "default")
        #expect(info.slashCommands == ["compact", "review"] && info.skills == ["deploy"] && info.tools == ["Bash", "Read"])
        #expect(info.capabilities == ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"])
        #expect(info.mcpServers == [McpServerStatus(name: "linear", status: "connected")])
        // A CLI that does not list capabilities says nothing, which is not the same as listing none.
        guard case let .systemInit(bare) = Fixture.message(Fixture.line(["type": "system", "subtype": "init"])) else { return }
        #expect(bare.capabilities == nil)
    }

    @Test func resultSubtypesAndTheTerminalReason() {
        for subtype in ["success", "error_during_execution", "error_max_turns", "error_max_budget_usd", "error_max_structured_output_retries", "error_future"] {
            guard case let .result(result) = Fixture.message(Fixture.result(subtype, isError: subtype != "success")) else { Issue.record("no result"); continue }
            #expect(result.subtype.rawValue == subtype && result.isError == (subtype != "success"))
        }
        guard case let .result(aborted) = Fixture.message(Fixture.result(isError: true, terminalReason: "aborted_tools")) else { return }
        #expect(aborted.wasInterrupted && aborted.usage?.contextTokens == 30 && aborted.totalCostUSD == 0.12)
    }

    @Test func statusRetryCompactionRateLimitAndSessionStateAreTyped() {
        guard case let .status(status) = Fixture.message(Fixture.line(["type": "system", "subtype": "status", "status": "compacting"])),
              case let .apiRetry(retry) = Fixture.message(Fixture.line(["type": "system", "subtype": "api_retry", "attempt": 2, "max_retries": 4,
                                                                         "retry_delay_ms": 2000, "error_status": 529, "error": "overloaded"])),
              case let .compactBoundary(boundary) = Fixture.message(Fixture.line(["type": "system", "subtype": "compact_boundary", "uuid": "c1",
                                                                                    "compact_metadata": ["trigger": "auto", "pre_tokens": 180_000, "post_tokens": 42_000]])),
              case let .rateLimit(limit) = Fixture.message(Fixture.line(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed_warning",
                                                                                    "resetsAt": 1_800_000_000, "rateLimitType": "five_hour",
                                                                                    "unifiedWindows": ["five_hour": ["utilization": 0.41, "resetsAt": 1_800_000_000], "seven_day": ["utilization": 0.23, "resetsAt": 1_800_300_000]]]])),
              case let .sessionState(state) = Fixture.message(Fixture.line(["type": "system", "subtype": "session_state_changed", "state": "requires_action"]))
        else { Issue.record("a message was not typed"); return }
        #expect(status.status == "compacting")
        #expect(retry.attempt == 2 && retry.maxRetries == 4 && retry.errorStatus == 529 && retry.error == "overloaded")
        #expect(boundary.trigger == "auto" && boundary.preTokens == 180_000 && boundary.postTokens == 42_000)
        #expect(limit.status == "allowed_warning" && limit.resetsAt == 1_800_000_000 && limit.rateLimitType == "five_hour")
        #expect(limit.windows.count == 2 && limit.utilization == 0.41 && limit.windows["seven_day"]?.resetsAt == 1_800_300_000)
        #expect(state.state == "requires_action")
    }

    @Test func aToolResultKeepsItsStructuredResultAndTheAssistantItsBlocks() {
        let structured: JSONValue = ["stdout": "a\nb", "interrupted": false]
        guard case let .user(user) = Fixture.message(Fixture.toolResult(id: "t1", text: "a\nb", structured: structured)) else { Issue.record("no user"); return }
        #expect(user.hasToolResult && user.toolUseResult == structured && !user.isReplay)
        guard case let .assistant(assistant) = Fixture.message(Fixture.assistant(
            messageID: "m1", uuid: "a1", blocks: [Fixture.thinkingBlock("hm"), Fixture.textBlock("hi"), Fixture.toolUse("t1", "Bash", ["command": "ls"]),
                                                  ["type": "future_block", "x": 1]],
            usage: ["input_tokens": 5, "cache_read_input_tokens": 100, "output_tokens": 7]))
        else { Issue.record("no assistant"); return }
        #expect(assistant.messageID == "m1" && assistant.usage?.contextTokens == 112)
        #expect(assistant.content.count == 4)
        guard case .thinking(_, true) = assistant.content[0], case .text("hi") = assistant.content[1],
              case let .toolUse(use) = assistant.content[2], case .unknown(type: "future_block", _) = assistant.content[3]
        else { Issue.record("blocks \(assistant.content)"); return }
        #expect(use.name == "Bash" && use.input["command"]?.string == "ls")
    }

    @Test func commandLifecycleAndTaskStartedAreTyped() {
        guard case let .commandLifecycle(lifecycle) = Fixture.message(Fixture.line(["type": "command_lifecycle", "command_uuid": "9842ff22", "state": "queued", "uuid": "x", "session_id": "s"])),
              case let .commandLifecycle(future) = Fixture.message(Fixture.line(["type": "command_lifecycle", "command_uuid": "a", "state": "paused"])),
              case let .taskStarted(task) = Fixture.message(Fixture.line(["type": "system", "subtype": "task_started", "task_id": "ae2bb", "tool_use_id": "toolu_1",
                                                                            "task_type": "local_agent", "subagent_type": "general-purpose", "description": "Run sleep"]))
        else { Issue.record("not typed"); return }
        #expect(lifecycle.commandUUID == "9842ff22" && lifecycle.state == .queued)
        #expect(future.state == nil && future.rawState == "paused")
        #expect(task.taskID == "ae2bb" && task.taskType == "local_agent" && task.subagentType == "general-purpose" && task.toolUseID == "toolu_1")
        guard case let .user(user) = Fixture.message(Fixture.line(["type": "user", "isReplay": true, "origin": ["kind": "task-notification"],
                                                                    "message": ["role": "user", "content": "x"]])) else { return }
        #expect(user.originKind == "task-notification" && user.isReplay)
    }

    @Test func partialEventsAreTyped() {
        func event(_ json: JSONValue) -> PartialEvent? {
            guard case let .streamEvent(event) = Fixture.message(Fixture.partial(json)) else { return nil }
            return event.event
        }
        #expect(event(["type": "message_start", "message": ["id": "msg_1", "model": "m"]]) == .messageStart(messageID: "msg_1", model: "m", usage: nil))
        #expect(event(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "t1", "name": "Bash"]])
                == .blockStart(index: 1, block: .toolUse(id: "t1", name: "Bash")))
        #expect(event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "hel"]]) == .blockDelta(index: 0, delta: .text("hel")))
        #expect(event(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "hm"]]) == .blockDelta(index: 0, delta: .thinking("hm")))
        #expect(event(["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"a\""]]) == .blockDelta(index: 2, delta: .inputJSON("{\"a\"")))
        #expect(event(["type": "ping"]) == .ping)
        if case .unknown(type: "future_event", _)? = event(["type": "future_event"]) {} else { Issue.record("unknown event lost") }
    }

    @Test func controlMessagesAreTyped() {
        let permission = Fixture.line(["type": "control_request", "request_id": "q1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "git push"], "tool_use_id": "t9",
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "git push:*"]], "behavior": "allow", "destination": "localSettings"]],
            "decision_reason": "needs approval", "agent_id": "ag1", "mcp_server": ["name": "linear", "source": "user"]]])
        guard case let .controlRequest(request) = Fixture.message(permission), case let .canUseTool(tool) = request.kind else { Issue.record("no can_use_tool"); return }
        #expect(request.requestID == "q1" && tool.toolName == "Bash" && tool.input["command"]?.string == "git push" && tool.toolUseID == "t9")
        #expect(tool.permissionSuggestions.first?.destination == "localSettings" && tool.agentID == "ag1" && tool.mcpServerName == "linear")
        guard case let .controlResponse(ok) = Fixture.message(Fixture.line(["type": "control_response", "response": ["subtype": "success", "request_id": "x", "response": ["still_queued": ["u1"]]]])),
              case let .controlResponse(failed) = Fixture.message(Fixture.line(["type": "control_response", "response": ["subtype": "error", "request_id": "y", "error": "nope"]])),
              case let .controlCancel(id) = Fixture.message(Fixture.line(["type": "control_cancel_request", "request_id": "z"])),
              case .keepAlive = Fixture.message(Fixture.line(["type": "keep_alive"]))
        else { Issue.record("control messages"); return }
        #expect(ok.requestID == "x" && ok.outcome == .success(["still_queued": ["u1"]]))
        #expect(failed.outcome == .error("nope") && id == "z")
    }

    @Test func outgoingLinesHaveTheWireShapes() throws {
        func object(_ data: Data) throws -> JSONValue {
            #expect(data.last == 0x0A)
            return try JSONDecoder().decode(JSONValue.self, from: data.dropLast())
        }
        let interrupt = try object(ControlWire.requestLine(id: "r1", .interrupt(cancelQueued: true)))
        #expect(interrupt == ["type": "control_request", "request_id": "r1", "request": ["subtype": "interrupt", "cancel_queued": true]])
        let mode = try object(ControlWire.requestLine(id: "r2", .setPermissionMode(.plan)))
        #expect(mode["request"] == ["subtype": "set_permission_mode", "mode": "plan"])
        let model = try object(ControlWire.requestLine(id: "r3", .setModel(nil)))
        #expect(model["request"] == ["subtype": "set_model", "model": nil])
        let effort = try object(ControlWire.requestLine(id: "r4", .applyFlagSettings(.effortLevel("high"))))
        #expect(effort["request"] == ["subtype": "apply_flag_settings", "settings": ["effortLevel": "high"]])
        let cancelAsync = try object(ControlWire.requestLine(id: "c1", .cancelAsyncMessage(messageUUID: "u9")))
        #expect(cancelAsync["request"] == ["subtype": "cancel_async_message", "message_uuid": "u9"])
        #expect(try object(ControlWire.requestLine(id: "c2", .initialize))["request"] == ["subtype": "initialize"])
        #expect(try object(ControlWire.requestLine(id: "c3", .rewindConversation(targetMessageUUID: "u1")))["request"]
                == ["subtype": "rewind_conversation", "target_message_uuid": "u1"])
        #expect(try object(ControlWire.requestLine(id: "c4", .rewindFiles(userMessageID: "u1", dryRun: true)))["request"]
                == ["subtype": "rewind_files", "user_message_id": "u1", "dry_run": true])
        #expect(try object(ControlWire.requestLine(id: "c5", .sideQuestion("why?")))["request"] == ["subtype": "side_question", "question": "why?"])
        #expect(try object(ControlWire.requestLine(id: "c6", .backgroundTasks(toolUseID: nil)))["request"] == ["subtype": "background_tasks"])
        let context = try object(ControlWire.requestLine(id: "r5", .getContextUsage(.summary)))
        #expect(context["request"] == ["subtype": "get_context_usage", "detail": "summary"])

        let user = try object(OutgoingUserMessage(uuid: "u1", content: [.text("hi"), .image(mediaType: "image/png", base64: "AAAA")], priority: .next).line())
        #expect(user["type"] == "user" && user["uuid"] == "u1" && user["priority"] == "next" && user["origin"] == ["kind": "human"])
        #expect(user["message"]?["content"]?[1]?["source"]?["media_type"] == "image/png" && user["parent_tool_use_id"]?.isNull == true)

        let allow = try object(ControlWire.successLine(id: "q1", PermissionDecision.allow(
            updatedInput: ["command": "ls"], updatedPermissions: [.setMode(.acceptEdits)], toolUseID: "t1").payload))
        #expect(allow["response"]?["response"]?["behavior"] == "allow" && allow["response"]?["response"]?["updatedPermissions"]?[0]?["type"] == "setMode")
        let deny = PermissionDecision.deny(message: "no", interrupt: true).payload
        #expect(deny == ["behavior": "deny", "message": "no", "interrupt": true])
    }

    @Test func theDefaultLineCapKeepsThePeakWellBelowAGigabyte() {
        // A line is held whole, then copied to be parsed and decoded: about three times its size at the peak.
        #expect(StreamJSONDecoder.defaultMaximumLineBytes == 64 * 1024 * 1024)
        #expect(StreamJSONDecoder().maximumLineBytes == StreamJSONDecoder.defaultMaximumLineBytes)
    }
}
