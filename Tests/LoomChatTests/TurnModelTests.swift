import Foundation
import LoomCore
import Testing
@testable import LoomChat

/// The model fed from the live stream: turns, stable rows, the thinking rule, raw unknown records.
@Suite(.timeLimit(.minutes(1)))
struct TurnModelLiveTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @discardableResult
    private func apply(_ model: inout TurnModel, _ lines: String..., at time: Date? = nil) -> ModelDelta {
        var delta = ModelDelta()
        for line in lines { delta.merge(model.apply(Fixture.message(line), at: time ?? t0)) }
        return delta
    }

    // MARK: A streamed turn

    @Test func aStreamedTurnKeepsOneRowPerBlockAndUpdatesOnlyTheRowThatChanged() {
        var model = TurnModel(source: .live)
        _ = apply(&model, Fixture.initMessage)
        model.appendPendingUser(uuid: "u1", text: "list the files", at: t0)
        #expect(model.prompts.first?.delivery == .pending && model.turns.count == 1 && model.turns[0].isRunning)
        _ = apply(&model, Fixture.echo("list the files", uuid: "u1"))
        #expect(model.prompts.count == 1 && model.prompts[0].delivery == .read)

        _ = apply(&model,
                  Fixture.partial(["type": "message_start", "message": ["id": "msg_1", "model": "m"]]),
                  Fixture.partial(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]),
                  Fixture.partial(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "**Listing** the "]]),
                  Fixture.partial(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "files."]]),
                  Fixture.partial(["type": "content_block_stop", "index": 0]),
                  Fixture.partial(["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]]))
        let textDelta = apply(&model, Fixture.partial(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "I'll "]]))
        // A text delta touches the one text row and nothing else.
        #expect(textDelta.inserted.isEmpty && textDelta.updated == ["msg_1#1"] && !textDelta.turnsChanged)
        _ = apply(&model,
                  Fixture.partial(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "look."]]),
                  Fixture.partial(["type": "content_block_stop", "index": 1]),
                  Fixture.partial(["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "Bash"]]),
                  Fixture.partial(["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"command\":"]]),
                  Fixture.partial(["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "\"ls\"}"]]),
                  Fixture.partial(["type": "content_block_stop", "index": 2]),
                  Fixture.partial(["type": "message_stop"]))
        #expect(model.texts.map(\.text) == ["I'll look."] && model.texts[0].isStreaming == false)
        #expect(model.tools.first?.input["command"]?.string == "ls" && model.tools.first?.status == .running)
        let ids = model.entries.map(\.id)

        // The finished records of the same message land on the same rows.
        let finals = apply(&model,
                           Fixture.assistant(messageID: "msg_1", uuid: "a1", blocks: [Fixture.thinkingBlock("**Listing** the files.")]),
                           Fixture.assistant(messageID: "msg_1", uuid: "a2", blocks: [Fixture.textBlock("I'll look.")]),
                           Fixture.assistant(messageID: "msg_1", uuid: "a3", blocks: [Fixture.toolUse("toolu_1", "Bash", ["command": "ls"])]))
        #expect(model.entries.map(\.id) == ids && finals.inserted.isEmpty)
        #expect(Set(finals.updated) == ["msg_1#0", "msg_1#1", "toolu_1"])

        _ = apply(&model, Fixture.toolResult(id: "toolu_1", text: "a.txt\nb.txt", structured: ["stdout": "a.txt\nb.txt"]))
        #expect(model.tools[0].status == .succeeded && model.tools[0].output?.text == "a.txt\nb.txt")
        #expect(model.turns[0].isRunning)

        let done = apply(&model, Fixture.result(), at: t0.addingTimeInterval(5))
        #expect(done.turnsChanged && model.turns[0].status == .succeeded && model.turns[0].durationMs == 4200)
        #expect(model.entries.allSatisfy { $0.turnID == model.turns[0].id || $0.turnID == "" })
        #expect(model.latestInit?.model == "claude-opus-5-5")
        #expect(model.markers.first == .sessionStart(model: "claude-opus-5-5", permissionMode: "default"))
    }

    // MARK: Turns

    @Test func aSubagentFinishingNeverEndsTheTurnAndAMessageSentWhileWorkingJoinsIt() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "review everything", at: t0)
        _ = apply(&model, Fixture.echo("review everything", uuid: "u1"),
                  Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("agent_1", "Agent", ["description": "Review auth", "subagent_type": "reviewer", "prompt": "Look at auth.py"])]),
                  // The subagent's own messages carry the parent tool-use id.
                  Fixture.assistant(messageID: "s1", uuid: "sa1", blocks: [Fixture.textBlock("Reading auth.py")], parent: "agent_1"),
                  Fixture.assistant(messageID: "s2", uuid: "sa2", blocks: [Fixture.toolUse("sub_t1", "Read", ["file_path": "auth.py"])], parent: "agent_1"),
                  Fixture.toolResult(id: "sub_t1", text: "contents", parent: "agent_1"))
        guard case let .subagent(running)? = model.entry(id: "agent_1")?.body else { Issue.record("no subagent card"); return }
        #expect(running.description == "Review auth" && running.subagentType == "reviewer" && running.status == .running)
        #expect(running.latestProgress == "Reading auth.py")
        #expect(model.entry(id: "m1#0") == nil && model.entry(id: "s1#0")?.thread == .subagent("agent_1"))

        // The user sends another message while Claude works: same turn.
        model.appendPendingUser(uuid: "u2", text: "also check the tests", at: t0.addingTimeInterval(3))
        // The subagent's end is a tool result on the main thread. It does not end the turn.
        _ = apply(&model, Fixture.toolResult(id: "agent_1", text: "Auth looks fine", structured: ["agentId": "ag42"]))
        guard case let .subagent(done)? = model.entry(id: "agent_1")?.body else { return }
        #expect(done.status == .succeeded && done.result?.text == "Auth looks fine" && done.agentID == "ag42")
        #expect(model.turns.count == 1 && model.turns[0].isRunning)
        #expect(model.entry(id: "u2")?.turnID == model.turns[0].id)

        // Only the main thread's result ends it. The next message then starts turn two.
        _ = apply(&model, Fixture.result())
        #expect(model.turns[0].status == .succeeded)
        model.appendPendingUser(uuid: "u3", text: "thanks", at: t0.addingTimeInterval(9))
        #expect(model.turns.count == 2 && model.turns[1].isRunning && model.turns[1].hasUserPrompt)
    }

    @Test func anInterruptedTurnMarksItsUnfinishedWork() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "run the build", at: t0)
        _ = apply(&model,
                  Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("t1", "Bash", ["command": "make"])]),
                  Fixture.result("error_during_execution", isError: true, terminalReason: "aborted_tools"))
        #expect(model.tools[0].status == .interrupted)
        #expect(model.turns[0].status == .interrupted)
        #expect(model.markers.last == .interrupted(afterMs: 4200))
    }

    @Test func aFailedResultFailsTheTurnAndAToolFailureKeepsItsExitCode() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "test", at: t0)
        _ = apply(&model,
                  Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("t1", "Bash", ["command": "npm test"]), Fixture.toolUse("t2", "Bash", ["command": "rm x"])]),
                  Fixture.toolResult(id: "t1", text: "Exit code 2\nFAIL src/a.test.ts", isError: true),
                  Fixture.toolResult(id: "t2", text: "The user doesn't want to proceed with this tool use.", isError: true),
                  Fixture.result("error_max_turns", isError: true))
        #expect(model.tools[0].status == .failed && model.tools[0].exitCode == 2)
        #expect(model.tools[1].status == .denied)
        #expect(model.turns[0].status == .failed("error_max_turns"))
    }

    @Test func editResultsCarryTheirLineCounts() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "edit", at: t0)
        let patch: JSONValue = ["structuredPatch": [["oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 4, "lines": [" keep", "-old", "+new1", "+new2"]]]]
        _ = apply(&model,
                  Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("e1", "Edit", ["file_path": "a.py", "old_string": "old", "new_string": "new1\nnew2"]),
                                                                          Fixture.toolUse("w1", "Write", ["file_path": "b.py", "content": "x\ny\nz\n"])]),
                  Fixture.toolResult(id: "e1", text: "ok", structured: patch),
                  Fixture.toolResult(id: "w1", text: "ok", structured: ["type": "create", "filePath": "b.py", "content": "x\ny\nz\n", "structuredPatch": []]))
        #expect(model.tools[0].changes == LineChanges(added: 2, removed: 1))
        #expect(model.tools[1].changes == LineChanges(added: 3, removed: 0))
    }

    @Test func aMessageSentButNotEchoedIsNotDeliveredWhenTheProcessEnds() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "hello", at: t0)
        #expect(model.pendingUserMessageIDs == ["u1"])
        let delta = model.markNotDelivered(model.pendingUserMessageIDs)
        #expect(delta.updated == ["u1"] && model.prompts[0].delivery == .notDelivered && model.pendingUserMessageIDs.isEmpty)
    }

    // MARK: Delivery (S1)

    @Test func aSentMessageIsQueuedThenReadThenCompleted() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "first", at: t0)
        model.appendPendingUser(uuid: "u2", text: "second", at: t0)
        func lifecycle(_ id: String, _ state: String) -> String {
            Fixture.line(["type": "command_lifecycle", "command_uuid": .string(id), "state": .string(state), "session_id": "s1"])
        }
        apply(&model, lifecycle("u1", "queued"), lifecycle("u2", "queued"))
        #expect(model.prompts.map(\.delivery) == [.queued, .queued])
        apply(&model, lifecycle("u1", "started"), Fixture.echo("first", uuid: "u1"))
        #expect(model.prompts[0].delivery == .read)
        // An interrupt with cancel_queued drops the unread one; the running command's own `cancelled` changes nothing.
        apply(&model, lifecycle("u2", "cancelled"), lifecycle("u1", "cancelled"), lifecycle("u1", "completed"))
        #expect(model.prompts.map(\.delivery) == [.read, .cancelled])
        // A lifecycle line for a command that is not Loom's is ignored.
        #expect(apply(&model, lifecycle("someone-else", "queued")).isEmpty)
        // A message never taken before the process ended is not delivered; one that was queued is too.
        model.appendPendingUser(uuid: "u3", text: "third", at: t0)
        apply(&model, lifecycle("u3", "queued"))
        model.markNotDelivered(model.pendingUserMessageIDs)
        #expect(model.prompts[2].delivery == .notDelivered)
    }

    @Test func aTaskNotificationEchoIsANoticeAndNeverALoomMessage() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "run it", at: t0)
        apply(&model, Fixture.line(["type": "user", "uuid": "n1", "isReplay": true, "origin": ["kind": "task-notification", "producer": "session-task"],
                                    "message": ["role": "user", "content": "<task-notification>\n<status>completed</status>\n<summary>Background command \"sleep\" completed (exit code 0)</summary>\n</task-notification>"]]))
        #expect(model.prompts.count == 1 && model.prompts[0].delivery == .pending)
        #expect(model.markers == [.notice("Background command \"sleep\" completed (exit code 0)")])
    }

    @Test func aSubagentCardLearnsItsAgentAndTypeFromTaskStartedAndARequestIsNamedByAgentID() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "review", at: t0)
        apply(&model,
              Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("agent_1", "Agent", ["description": "Review auth", "prompt": "go"])]),
              Fixture.line(["type": "system", "subtype": "task_started", "task_id": "ae2bb", "tool_use_id": "agent_1", "task_type": "local_agent",
                            "subagent_type": "general-purpose", "description": "Review auth"]),
              Fixture.line(["type": "system", "subtype": "task_started", "task_id": "bp1", "tool_use_id": "sub_t", "task_type": "local_bash", "parent_task_id": "ae2bb"]))
        guard case let .subagent(run)? = model.entry(id: "agent_1")?.body else { Issue.record("no card"); return }
        #expect(run.agentID == "ae2bb" && run.subagentType == "general-purpose")
        // The can_use_tool request of that subagent carries only agent_id; the join gives its name.
        #expect(model.subagentTask(agentID: "ae2bb")?.subagentType == "general-purpose" && model.subagentTask(agentID: "bp1") == nil)
    }

    @Test func aSuccessResultThatIsAnErrorFailsTheTurnAndAnInterruptIsNotAFailure() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "hi", at: t0)
        apply(&model, Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("Not logged in")]),
              Fixture.line(["type": "result", "subtype": "success", "is_error": true, "terminal_reason": "api_error", "api_error_status": 404,
                            "duration_ms": 10, "session_id": "s1"]))
        #expect(model.turns[0].status == .failed("api_error"))
        model.appendPendingUser(uuid: "u2", text: "again", at: t0)
        apply(&model, Fixture.line(["type": "result", "subtype": "error_during_execution", "is_error": true, "terminal_reason": "aborted_tools", "session_id": "s1"]))
        #expect(model.turns[1].status == .interrupted)
    }

    @Test func theInitializeAnswerIsReadyAndDropsTheAccount() async throws {
        let channel = ControlChannel(makeRequestID: { "req-1" })
        var lines = channel.outgoing.makeAsyncIterator()
        let reply = Task { try await channel.request(.initialize) }
        _ = await lines.next()
        await channel.receive(Fixture.message(Fixture.line(["type": "control_response", "response": ["subtype": "success", "request_id": "req-1", "response": [
            "pid": 220, "claude_code_version": "2.1.300", "current_permission_mode": "default", "session_state": "idle", "capabilities": ["ui_surface_v1"],
            "account": ["email": "user@example.invalid", "organization": "Org", "subscriptionType": "max"],
            "models": [["value": "default", "resolvedModel": "claude-opus-5-5", "displayName": "Default", "supportedEffortLevels": ["low", "high"]]],
            "commands": [["name": "review", "description": "Review", "argumentHint": "<x>"]]]]])))
        let answer = try await reply.value
        #expect(answer.payload["account"] == nil && !answer.payload.serializedString.contains("example.invalid"))
        let ready = answer.initializeResponse
        #expect(ready.currentPermissionMode == "default" && ready.sessionState == "idle" && ready.pid == 220)
        #expect(ready.models.first?.supportedEffortLevels == ["low", "high"] && ready.commands.first?.name == "review")
        // `initialize` lists only ui_surface_v1: it must not close the gate that system/init opens.
        #expect(await channel.knownCapabilities == nil)
        var model = TurnModel(source: .live)
        model.apply(ready: ready, at: t0)
        #expect(model.ready?.currentPermissionMode == "default" && model.markers == [.sessionStart(model: nil, permissionMode: "default")])
        apply(&model, Fixture.initMessage)
        #expect(model.markers.count == 1)
    }

    // MARK: Thinking

    @Test func thinkingIsNeverRelabelledAsProseByWhereItSits() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "fix it", at: t0)
        // Claude 5.1+ writes its narrative before a tool call as thinking blocks, two of them back to back.
        _ = apply(&model,
                  Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.thinkingBlock("**Looking at the bug**\nThe parser drops the last line.")]),
                  Fixture.assistant(messageID: "m1", uuid: "a2", blocks: [Fixture.thinkingBlock("I'll read the parser first. Then patch it.")]),
                  Fixture.assistant(messageID: "m1", uuid: "a3", blocks: [Fixture.toolUse("t1", "Read", ["file_path": "parser.py"])]))
        #expect(model.thoughts.count == 2 && model.texts.isEmpty)
        // The live row shows the latest thinking block as its thought line.
        #expect(model.thoughtLine(in: model.turns[0]) == "I'll read the parser first.")
        // After the final answer, nothing about the thinking blocks changes.
        _ = apply(&model, Fixture.assistant(messageID: "m2", uuid: "a4", blocks: [Fixture.textBlock("Fixed.")]), Fixture.result())
        #expect(model.thoughts.count == 2 && model.texts.map(\.text) == ["Fixed."])
    }

    @Test func redactedThinkingIsOneHiddenBlockAndNeverTheThoughtLine() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "x", at: t0)
        _ = apply(&model,
                  Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.thinkingBlock("Checking the cache layer.")]),
                  Fixture.assistant(messageID: "m1", uuid: "a2", blocks: [["type": "redacted_thinking", "data": "xxx"]]))
        #expect(model.thoughts.map(\.isHidden) == [false, true])
        #expect(model.thoughtLine(in: model.turns[0]) == "Checking the cache layer.")
    }

    @Test func theThoughtLineTakesTheBoldHeadingOrTheFirstSentence() {
        #expect(ThoughtLine.extract(from: "**Planning the migration**\n\nFirst I need the schema.") == "Planning the migration")
        #expect(ThoughtLine.extract(from: "## Plan\n- **Read** the schema\n- write it") == "Read")
        #expect(ThoughtLine.extract(from: "The user wants a [fix](http://x.y/z) for the parser. It is broken.") == "The user wants a fix for the parser.")
        #expect(ThoughtLine.extract(from: "- first step is this\n- second") == "first step is this\nsecond")
        #expect(ThoughtLine.extract(from: "a\nb\nc\nd\ne\nf") == "a\nb\nc\nd")
        #expect(ThoughtLine.extract(from: "  \n\n") == nil)
    }

    // MARK: Unknown and oversized

    @Test func unknownRecordsStayRawAndQuietOnesAreNotRows() {
        var model = TurnModel(source: .live)
        _ = apply(&model,
                  Fixture.line(["type": "hologram", "payload": [1, 2, 3]]),
                  Fixture.line(["type": "system", "subtype": "teleported"]),
                  Fixture.line(["type": "system", "subtype": "hook_started"]),
                  Fixture.line(["type": "keep_alive"]),
                  Fixture.line(["type": "system", "subtype": "local_command_output", "content": "Context: 12%"]))
        #expect(model.raws.map(\.type) == ["hologram", "system"] && model.raws[1].subtype == "teleported")
        #expect(model.raws[0].reason == .unknownType && model.raws[0].json.contains("hologram") && !model.raws[0].isTruncated)
        #expect(model.unknownRecordCount == 2)
        #expect(model.markers == [.notice("Context: 12%")])
        #expect(model.turns.isEmpty)
    }

    @Test func anOversizedLineIsAMarkedRowNeverDroppedSilently() {
        var model = TurnModel(source: .live)
        var decoder = StreamJSONDecoder(maximumLineBytes: 1000)
        let big = "{\"type\":\"assistant\",\"message\":{\"content\":\"" + String(repeating: "x", count: 5000) + "\"}}"
        for frame in decoder.feed(Fixture.text(big) + Fixture.text(Fixture.result())) { model.apply(frame) }
        #expect(model.raws.count == 1)
        #expect(model.raws[0].reason == .oversized && model.raws[0].byteCount > 5000 && model.raws[0].type == "assistant")
    }

    @Test func aContextRingInputFollowsTheMainThreadOnly() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "x", at: t0)
        _ = apply(&model,
                  Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("main")], usage: ["input_tokens": 100, "output_tokens": 20]),
                  Fixture.assistant(messageID: "s1", uuid: "a2", blocks: [Fixture.textBlock("sub")], parent: "agent_1", usage: ["input_tokens": 9000]))
        #expect(model.contextUsage?.contextTokens == 120)
        _ = apply(&model, Fixture.line(["type": "system", "subtype": "compact_boundary", "uuid": "c1", "compact_metadata": ["trigger": "auto", "pre_tokens": 180_000, "post_tokens": 42_000]]))
        #expect(model.contextUsage?.contextTokens == 42_000)
        #expect(model.markers == [.compaction(trigger: "auto", preTokens: 180_000, postTokens: 42_000)])
    }
}
