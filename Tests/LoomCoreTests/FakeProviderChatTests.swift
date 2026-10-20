import Darwin
import Foundation
import Testing

/// A fake-provider process in chat mode (`claude -p --input-format stream-json ...`): the NDJSON a chat
/// engine would read and write, scripted by scenarios. No model, no network, no real Claude.
private final class ChatRig: @unchecked Sendable {
    typealias Record = [String: Any]

    let root: URL
    let sessionID = UUID().uuidString.lowercased()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var records: [Record] = []
    private var sizes: [Int] = []
    private var cursor = 0

    var configDirectory: URL { root.appendingPathComponent("config", isDirectory: true) }

    init(arguments: [String] = [], environment: [String: String] = [:], permissionHost: Bool = true) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-chat-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider")
        var argv = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages",
        ]
        if permissionHost { argv += ["--permission-prompt-tool", "stdio"] }
        process.arguments = argv + (arguments.contains("--resume") ? [] : ["--session-id", sessionID]) + arguments
        process.currentDirectoryURL = root
        var env = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": configDirectory.path, "LOOM_FAKE_CHAT_DELAY_MS": "1"]
        env.merge(environment) { $1 }
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            ingest(data)
        }
        try process.run()
    }

    private func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? Record {
                records.append(object)
                sizes.append(line.count)
            }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
    }

    func send(_ object: Record) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    func user(_ text: String, uuid: String, priority: String? = nil, human: Bool = true) {
        var message: Record = [
            "type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull(), "uuid": uuid,
        ]
        if human { message["origin"] = ["kind": "human"] }
        if let priority { message["priority"] = priority }
        send(message)
    }

    /// The `initialize` exchange: the answer's payload.
    func initialize() async throws -> Record {
        control("init-\(UUID().uuidString)", "initialize")
        let response = try await wait { $0["type"] as? String == "control_response" }
        return (response["response"] as? Record)?["response"] as? Record ?? [:]
    }

    func lifecycle(_ uuid: String) -> [String] {
        all().filter { $0["type"] as? String == "command_lifecycle" && $0["command_uuid"] as? String == uuid }
            .compactMap { $0["state"] as? String }
    }

    func index(where match: (Record) -> Bool) -> Int? { all().firstIndex(where: match) }

    func control(_ id: String, _ subtype: String, _ fields: Record = [:]) {
        var request = fields
        request["subtype"] = subtype
        send(["type": "control_request", "request_id": id, "request": request])
    }

    func answer(_ requestID: String, _ payload: Record) {
        send(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": payload]])
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    func all() -> [Record] { lock.withLock { records } }
    func lineSizes() -> [Int] { lock.withLock { sizes } }

    /// The next record at or after the read position that matches; the position moves past it.
    func wait(timeout: TimeInterval = 15, _ match: (Record) -> Bool) async throws -> Record {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found: Record? = lock.withLock {
                guard let index = records[cursor...].firstIndex(where: match) else { return nil }
                cursor = index + 1
                return records[index]
            }
            if let found { return found }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RigTimeout(tail: all().suffix(3).map { String(describing: $0["type"]) + "/" + String(describing: $0["subtype"]) })
    }

    func waitResult(timeout: TimeInterval = 15) async throws -> Record {
        try await wait(timeout: timeout) { $0["type"] as? String == "result" }
    }

    func waitToolUse(_ name: String) async throws -> Record {
        try await wait { record in
            record["type"] as? String == "assistant"
                && Self.blocks(record).contains { $0["type"] as? String == "tool_use" && $0["name"] as? String == name }
        }
    }

    func waitRequest(_ tool: String) async throws -> Record {
        try await wait {
            $0["type"] as? String == "control_request"
                && ($0["request"] as? Record)?["tool_name"] as? String == tool
        }
    }

    static func blocks(_ record: Record) -> [Record] {
        ((record["message"] as? Record)?["content"] as? [Record]) ?? []
    }

    /// Closes stdin and waits for the process; true when it left with status 0.
    func finish() async -> Bool {
        closeInput()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return !process.isRunning && process.terminationStatus == 0
    }

    func stop() {
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RigTimeout: Error, CustomStringConvertible {
    let tail: [String]
    var description: String { "no matching record in time, last: \(tail)" }
}

private func isType(_ type: String, _ subtype: String? = nil) -> (ChatRig.Record) -> Bool {
    { $0["type"] as? String == type && (subtype == nil || $0["subtype"] as? String == subtype) }
}

private func toolResults(_ records: [ChatRig.Record]) -> [ChatRig.Record] {
    records.filter { $0["type"] as? String == "user" && $0["isReplay"] == nil }
}

private func toolBlock(_ record: ChatRig.Record) -> ChatRig.Record? { ChatRig.blocks(record).first }

private func text(_ record: ChatRig.Record) -> String {
    ChatRig.blocks(record).compactMap { $0["text"] as? String }.joined()
}

private func isUserEcho(_ uuid: String) -> (ChatRig.Record) -> Bool {
    { $0["type"] as? String == "user" && $0["isReplay"] as? Bool == true && $0["uuid"] as? String == uuid }
}

private func isLifecycle(_ uuid: String, _ state: String) -> (ChatRig.Record) -> Bool {
    { $0["type"] as? String == "command_lifecycle" && $0["command_uuid"] as? String == uuid && $0["state"] as? String == state }
}

private func isResponse(_ requestID: String) -> (ChatRig.Record) -> Bool {
    { ($0["response"] as? ChatRig.Record)?["request_id"] as? String == requestID }
}

private func payload(_ response: ChatRig.Record) -> ChatRig.Record {
    (response["response"] as? ChatRig.Record)?["response"] as? ChatRig.Record ?? [:]
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct FakeProviderChatTests {
    // MARK: Start-up, lifecycle, echo, streaming

    @Test func printsNothingUntilInputAnswersInitializeAndRunsAPlainTurnWithItsLifecycle() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.all().isEmpty) // no system/init before the first send

        let start = try await rig.initialize()
        #expect(start["current_permission_mode"] as? String == "default" && start["session_state"] as? String == "idle")
        #expect((start["models"] as? [Any])?.isEmpty == false && (start["commands"] as? [Any])?.isEmpty == false)
        #expect((start["pid"] as? Int ?? 0) > 0)
        #expect(start["capabilities"] as? [String] == ["ui_surface_v1"]) // the ten others come in system/init (S1 Q4)
        #expect((start["account"] as? ChatRig.Record)?["email"] as? String == "user@example.invalid") // fake values

        rig.user("hello there", uuid: "u1")
        let result = try await rig.waitResult()
        _ = try await rig.wait(isLifecycle("u1", "completed"))
        let records = rig.all()
        // queued at accept, then started, init, status requesting, and only then the echo (the "read" signal).
        let order = [
            records.firstIndex(where: isLifecycle("u1", "queued")), records.firstIndex(where: isLifecycle("u1", "started")),
            records.firstIndex { $0["subtype"] as? String == "init" },
            records.firstIndex { $0["status"] as? String == "requesting" },
            records.firstIndex(where: isUserEcho("u1")), records.firstIndex { $0["type"] as? String == "stream_event" },
            records.firstIndex { $0["type"] as? String == "result" }, records.firstIndex(where: isLifecycle("u1", "completed")),
        ]
        let indices = try order.map { try #require($0) }
        #expect(indices == indices.sorted())
        let turnInit = try #require(records.first { $0["subtype"] as? String == "init" })
        #expect(turnInit["session_id"] as? String == rig.sessionID && turnInit["permissionMode"] as? String == "default")
        #expect(turnInit["cwd"] as? String == realPath(rig.root))
        #expect((turnInit["tools"] as? [String])?.contains("Bash") == true && (turnInit["skills"] as? [String])?.isEmpty == false)
        #expect((turnInit["capabilities"] as? [String])?.contains("msg_lifecycle_v1") == true)

        let deltas = records.compactMap { (($0["event"] as? ChatRig.Record)?["delta"] as? ChatRig.Record)?["text"] as? String }
        let assistant = try #require(records.first { $0["type"] as? String == "assistant" })
        #expect(deltas.count > 1 && deltas.joined() == "Fake answer to: hello there" && text(assistant) == deltas.joined())
        #expect(result["subtype"] as? String == "success" && result["is_error"] as? Bool == false)
        #expect(result["result"] as? String == deltas.joined() && result["user_message_uuids"] as? [String] == ["u1"])
        let limit = try #require(records.first { $0["type"] as? String == "rate_limit_event" })
        let info = try #require(limit["rate_limit_info"] as? ChatRig.Record)
        #expect(info["resetsAt"] is Int && (info["unifiedWindows"] as? ChatRig.Record)?["five_hour"] != nil)

        // Every turn starts with its own system/init; the CLI never sends tool_progress.
        rig.user("again", uuid: "u2")
        _ = try await rig.waitResult()
        #expect(rig.all().filter { $0["subtype"] as? String == "init" }.count == 2)
        #expect(!rig.all().contains { $0["type"] as? String == "tool_progress" })
        #expect(await rig.finish())
    }

    @Test func aResumeKeepsItsSessionIDAndAMissingOneFails() async throws {
        let resumed = "22222222-2222-2222-2222-222222222222"
        let rig = try ChatRig(arguments: ["--resume", resumed, "--model", "claude-test", "--permission-mode", "plan"])
        defer { rig.stop() }
        #expect(try await rig.initialize()["current_permission_mode"] as? String == "plan")
        rig.user("hi", uuid: "u1")
        let start = try await rig.wait { $0["subtype"] as? String == "init" }
        #expect(start["session_id"] as? String == resumed)
        #expect(start["model"] as? String == "claude-test" && start["permissionMode"] as? String == "plan")
        #expect(await rig.finish())

        let missing = try ChatRig(arguments: ["--resume", "missing-session"])
        defer { missing.stop() }
        #expect(await missing.finish() == false) // exit status 1, as the real CLI
    }

    // MARK: Thinking and tools

    @Test func thinkingAndToolScenariosEmitTheirSequencesInOneProcess() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }

        // Claude 5.1+: thinking blocks right before a tool_use, one API message.
        rig.user("/scenario prethink", uuid: "u1")
        _ = try await rig.waitResult()
        var records = rig.all()
        let message = records.filter { $0["type"] as? String == "assistant" }
        #expect(message.compactMap { toolBlock($0)?["type"] as? String } == ["thinking", "thinking", "tool_use", "text"])
        let ids = message.prefix(3).compactMap { ($0["message"] as? ChatRig.Record)?["id"] as? String }
        #expect(Set(ids).count == 1) // the three blocks share one message id

        // Edit: a structuredPatch in tool_use_result.
        rig.user("/scenario edit", uuid: "u2")
        _ = try await rig.waitResult()
        records = rig.all()
        let editResult = try #require(toolResults(records).last)
        let patch = try #require(((editResult["tool_use_result"] as? ChatRig.Record)?["structuredPatch"] as? [ChatRig.Record])?.first)
        #expect(patch["oldStart"] as? Int == 1 && (patch["lines"] as? [String])?.contains("+let limit = 2") == true)

        // Write that creates a file: an empty structuredPatch.
        rig.user("/scenario write", uuid: "u2b")
        _ = try await rig.waitResult()
        let created = try #require(toolResults(rig.all()).last?["tool_use_result"] as? ChatRig.Record)
        #expect(created["type"] as? String == "create" && (created["structuredPatch"] as? [Any])?.isEmpty == true)
        #expect(created["originalFile"] is NSNull)

        // Bash success, then Bash failure with an exit code.
        rig.user("/scenario bash", uuid: "u3")
        _ = try await rig.waitResult()
        rig.user("/scenario bash-fail 7", uuid: "u4")
        let failure = try await rig.waitResult()
        #expect(failure["subtype"] as? String == "success") // the turn itself succeeds
        let results = toolResults(rig.all())
        let ok = try #require(toolBlock(results[results.count - 2]))
        let failed = try #require(toolBlock(results[results.count - 1]))
        #expect(ok["is_error"] == nil && ok["content"] as? String == "A.swift\nB.swift")
        #expect(failed["is_error"] as? Bool == true && (failed["content"] as? String)?.hasPrefix("Exit code 7") == true)
        // Every tool_use is answered by a tool_result with its id.
        let uses = rig.all().flatMap(ChatRig.blocks).filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
        let answered = results.compactMap { toolBlock($0)?["tool_use_id"] as? String }
        #expect(uses.count == answered.count && Set(uses) == Set(answered))
        #expect(await rig.finish())
    }

    @Test func aSubagentIsAnnouncedAndItsMessagesCarryItsIdentityAndTheTranscriptIsWritten() async throws {
        let rig = try ChatRig(arguments: ["--forward-subagent-text"])
        defer { rig.stop() }
        rig.user("/scenario subagent 10 approval", uuid: "u1")
        let request = try await rig.waitRequest("Bash")
        let body = try #require(request["request"] as? ChatRig.Record)
        let agentID = try #require(body["agent_id"] as? String)
        rig.answer(request["request_id"] as! String, ["behavior": "allow", "updatedInput": body["input"] as Any])
        _ = try await rig.waitResult()
        let records = rig.all()
        let task = try #require(records.flatMap(ChatRig.blocks).first { $0["name"] as? String == "Agent" })
        let taskID = try #require(task["id"] as? String)
        // The request names the subagent by agent_id; task_started tells who that is.
        let started = try #require(records.first { $0["subtype"] as? String == "task_started" && $0["task_type"] as? String == "local_agent" })
        #expect(started["task_id"] as? String == agentID && started["tool_use_id"] as? String == taskID)
        #expect(started["subagent_type"] as? String == "explorer" && started["description"] as? String == "Map the fake module")
        let inner = records.filter { $0["type"] as? String == "assistant" || $0["type"] as? String == "user" }
            .filter { $0["parent_tool_use_id"] as? String == taskID }
        #expect(inner.count >= 4 && inner.allSatisfy { $0["agent_id"] as? String == agentID && $0["subagent_type"] as? String == "explorer" })
        #expect(inner.contains { toolBlock($0)?["type"] as? String == "tool_result" })
        // No partial stream events for a subagent.
        #expect(!records.contains { $0["type"] as? String == "stream_event" && $0["parent_tool_use_id"] is String })

        let project = rig.configDirectory.appendingPathComponent("projects/" + String(realPath(rig.root).map { $0.isLetter || $0.isNumber ? $0 : "-" }))
        let main = try String(contentsOf: project.appendingPathComponent("\(rig.sessionID).jsonl"), encoding: .utf8)
        let lines = try main.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? ChatRig.Record) }
        // The CLI's queue records come first (S1): the send is enqueued and dequeued, then its `user` record.
        #expect(lines.first?["type"] as? String == "queue-operation" && lines.first?["operation"] as? String == "enqueue")
        let first = lines.first { $0["type"] as? String != "queue-operation" }
        #expect(first?["type"] as? String == "user" && first?["sessionId"] as? String == rig.sessionID)
        #expect(lines.contains { $0["toolUseResult"] != nil }) // transcript spelling of tool_use_result
        let subagents = project.appendingPathComponent("\(rig.sessionID)/subagents")
        let files = try FileManager.default.contentsOfDirectory(atPath: subagents.path)
        let sidechain = try #require(files.first { $0.hasSuffix(".jsonl") })
        #expect(files.contains { $0.hasSuffix(".meta.json") })
        let side = try String(contentsOf: subagents.appendingPathComponent(sidechain), encoding: .utf8)
        #expect(side.contains("\"isSidechain\":true") && side.contains("\"agentId\""))
        #expect(await rig.finish())
    }

    /// R4: without `--forward-subagent-text` the CLI keeps a subagent's text and thinking off the parent's stream; its tool
    /// calls and results are sent either way, and its own transcript has the words either way.
    @Test func aSubagentsTextReachesTheStreamOnlyWithTheForwardFlagAndItsTranscriptHasItEitherWay() async throws {
        for forward in [false, true] {
            let rig = try ChatRig(arguments: forward ? ["--forward-subagent-text"] : [])
            defer { rig.stop() }
            rig.user("/scenario subagent 10 approval", uuid: "u1")
            let request = try await rig.waitRequest("Bash")
            let body = try #require(request["request"] as? ChatRig.Record)
            rig.answer(request["request_id"] as! String, ["behavior": "allow", "updatedInput": body["input"] as Any])
            _ = try await rig.waitResult()
            let records = rig.all()
            let inner = records.filter { $0["type"] as? String == "assistant" || $0["type"] as? String == "user" }
                .filter { $0["parent_tool_use_id"] is String }
            let kinds = Set(inner.flatMap(ChatRig.blocks).compactMap { $0["type"] as? String })
            #expect(kinds.contains("tool_use") && kinds.contains("tool_result"), "forward: \(forward) \(kinds)")
            #expect(kinds.contains("text") == forward, "forward: \(forward) \(kinds)")
            let text = inner.flatMap(ChatRig.blocks).compactMap { $0["text"] as? String }
            #expect(text.contains("Looking at the module.") == forward && text.contains("The module has two services.") == forward)

            let project = rig.configDirectory.appendingPathComponent("projects/" + String(realPath(rig.root).map { $0.isLetter || $0.isNumber ? $0 : "-" }))
            let subagents = project.appendingPathComponent("\(rig.sessionID)/subagents")
            let files = try FileManager.default.contentsOfDirectory(atPath: subagents.path)
            let sidechain = try #require(files.first { $0.hasSuffix(".jsonl") })
            let side = try String(contentsOf: subagents.appendingPathComponent(sidechain), encoding: .utf8)
            #expect(side.contains("Looking at the module.") && side.contains("The module has two services."), "forward: \(forward)")
            #expect(await rig.finish())
        }
    }

    // MARK: Requests

    @Test func anApprovalWaitsForTheAnswerAndFollowsAllowAndDeny() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }

        rig.user("/scenario approval", uuid: "u1")
        let request = try await rig.waitRequest("Bash")
        let body = try #require(request["request"] as? ChatRig.Record)
        #expect(body["subtype"] as? String == "can_use_tool" && body["agent_id"] == nil)
        #expect((body["input"] as? ChatRig.Record)?["command"] as? String == "rm -rf build")
        #expect(body["description"] as? String == "Remove the build folder" && body["decision_reason"] as? String != nil)
        #expect((body["permission_suggestions"] as? [Any])?.isEmpty == false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!rig.all().contains(where: isType("result"))) // the turn waits
        rig.answer(request["request_id"] as! String, ["behavior": "allow", "updatedInput": body["input"] as Any])
        let allowed = try await rig.waitResult()
        #expect(allowed["is_error"] as? Bool == false)
        #expect((allowed["permission_denials"] as? [Any])?.isEmpty == true)
        #expect(toolResults(rig.all()).last.flatMap(toolBlock)?["is_error"] == nil)

        rig.user("/scenario approval", uuid: "u2")
        let second = try await rig.waitRequest("Bash")
        rig.answer(second["request_id"] as! String, ["behavior": "deny", "message": "Not now", "interrupt": false])
        let denied = try await rig.waitResult()
        #expect((denied["permission_denials"] as? [Any])?.count == 1)
        let denial = try #require(toolResults(rig.all()).last.flatMap(toolBlock))
        #expect(denial["is_error"] as? Bool == true && denial["content"] as? String == "Not now")
        #expect(await rig.finish())
    }

    @Test func aQuestionTakesItsAnswersAndAPlanFollowsItsThreeAnswers() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }

        rig.user("/scenario question", uuid: "u1")
        let question = try await rig.waitRequest("AskUserQuestion")
        let body = try #require(question["request"] as? ChatRig.Record)
        #expect(body["requires_user_interaction"] as? Bool == true && body["permission_suggestions"] == nil)
        var input = try #require(body["input"] as? ChatRig.Record)
        #expect((input["questions"] as? [Any])?.count == 2)
        input["answers"] = ["Which database should the app use?": "SQLite", "Which extras do you want?": "Logging, Metrics"]
        rig.answer(question["request_id"] as! String, ["behavior": "allow", "updatedInput": input])
        let answered = try await rig.waitResult()
        #expect((answered["result"] as? String)?.contains("SQLite") == true)
        let structured = try #require(toolResults(rig.all()).last?["tool_use_result"] as? ChatRig.Record)
        #expect((structured["answers"] as? [String: String])?["Which extras do you want?"] == "Logging, Metrics")

        // A plain allow returns to the mode from before the plan.
        rig.user("/scenario plan", uuid: "u2")
        let plan = try await rig.waitRequest("ExitPlanMode")
        let planInput = try #require((plan["request"] as? ChatRig.Record)?["input"] as? ChatRig.Record)
        #expect((planInput["plan"] as? String)?.hasPrefix("# Fake plan") == true && planInput["planFilePath"] is String)
        rig.answer(plan["request_id"] as! String, ["behavior": "allow", "updatedInput": planInput])
        let plain = try await rig.waitResult()
        #expect((plain["result"] as? String)?.contains("default") == true)
        let modes = rig.all().filter { $0["subtype"] as? String == "status" }.compactMap { $0["permissionMode"] as? String }
        #expect(modes == ["plan", "default"])

        // An allow with setMode switches the mode in the same turn.
        rig.user("/scenario plan", uuid: "u3")
        let again = try await rig.waitRequest("ExitPlanMode")
        rig.answer(again["request_id"] as! String, [
            "behavior": "allow", "updatedInput": planInput,
            "updatedPermissions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
        ])
        let done = try await rig.waitResult()
        #expect((done["result"] as? String)?.contains("acceptEdits") == true)
        #expect(rig.all().last { $0["subtype"] as? String == "status" }?["permissionMode"] as? String == "acceptEdits")

        // Keep planning: a denial carries the feedback and the same turn goes on.
        rig.user("/scenario plan", uuid: "u4")
        let kept = try await rig.waitRequest("ExitPlanMode")
        rig.answer(kept["request_id"] as! String, ["behavior": "deny", "message": "Add a rollback step"])
        let stayed = try await rig.waitResult()
        #expect((stayed["result"] as? String)?.contains("plan mode") == true)
        #expect(toolResults(rig.all()).last.flatMap(toolBlock)?["content"] as? String == "Add a rollback step")
        #expect(await rig.finish())
    }

    @Test func closingStdinWhileARequestIsPendingFailsTheToolAndTheTurnFinishes() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }
        rig.user("/scenario approval", uuid: "u1")
        let request = try await rig.waitRequest("Bash")
        #expect(await rig.finish()) // stdin closed with the request pending; the turn ends, exit status 0
        let records = rig.all()
        #expect(!records.contains { $0["type"] as? String == "control_cancel_request" }) // no cancel, unlike interrupt
        let failure = try #require(toolResults(records).last.flatMap(toolBlock))
        #expect(failure["is_error"] as? Bool == true)
        #expect((failure["content"] as? String)?.contains("permission stream closed") == true)
        let result = try #require(records.last { $0["type"] as? String == "result" })
        #expect(result["subtype"] as? String == "success" && result["terminal_reason"] as? String == "completed")
        #expect((result["permission_denials"] as? [Any])?.isEmpty == true && request["request_id"] != nil)
    }

    // MARK: Interrupt and priority

    @Test func interruptWhileARequestIsPendingWithdrawsItBeforeTheAnswerAndTheToolResult() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }
        rig.user("/scenario approval", uuid: "u1")
        let request = try await rig.waitRequest("Bash")
        rig.control("i1", "interrupt")
        let result = try await rig.waitResult()
        let records = rig.all()
        // S1 t09-pending-interrupt: control_cancel_request, then the interrupt's answer, then the tool result, then the result.
        let cancel = try #require(records.firstIndex { $0["type"] as? String == "control_cancel_request" })
        let answer = try #require(records.firstIndex(where: isResponse("i1")))
        let rejection = try #require(records.firstIndex { $0["type"] as? String == "user" && $0["isReplay"] == nil
            && ChatRig.blocks($0).contains { $0["type"] as? String == "tool_result" } })
        let end = try #require(records.firstIndex(where: isType("result")))
        #expect(records[cancel]["request_id"] as? String == request["request_id"] as? String)
        #expect(cancel < answer && answer < rejection && rejection < end)
        #expect(records.filter { $0["type"] as? String == "control_cancel_request" }.count == 1)
        #expect(result["subtype"] as? String == "error_during_execution" && result["terminal_reason"] as? String == "aborted_tools")
        #expect(await rig.finish())
    }

    @Test func interruptWithCancelQueuedAnswersWithTheCancelledSendsBeforeTheResult() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }
        rig.user("/scenario work 3000", uuid: "u1")
        _ = try await rig.waitToolUse("Bash")
        rig.user("second", uuid: "u2", priority: "later")
        rig.user("third", uuid: "u3", priority: "later")
        rig.control("i1", "interrupt", ["cancel_queued": true])
        let response = try await rig.wait(isResponse("i1"))
        let answer = payload(response)
        #expect(Set(answer["cancelled"] as? [String] ?? []) == ["u2", "u3"] && (answer["still_queued"] as? [String])?.isEmpty == true)
        let result = try await rig.waitResult()
        // The answer comes before the result; an interrupt is an error without text.
        let records = rig.all()
        #expect(try #require(records.firstIndex(where: isResponse("i1"))) < (try #require(records.firstIndex { $0["type"] as? String == "result" })))
        #expect(result["subtype"] as? String == "error_during_execution" && result["is_error"] as? Bool == true)
        #expect(result["terminal_reason"] as? String == "aborted_tools" && result["result"] == nil)
        #expect(result["user_message_uuids"] as? [String] == ["u1"])
        _ = try await rig.wait(isLifecycle("u1", "cancelled"))
        #expect(rig.lifecycle("u2") == ["queued", "cancelled"] && rig.lifecycle("u3") == ["queued", "cancelled"])
        // The cancelled sends never start a turn: the next result is the next send's own.
        rig.user("after", uuid: "u4")
        let next = try await rig.waitResult()
        #expect(next["user_message_uuids"] as? [String] == ["u4"])
        #expect(rig.all().filter(isType("result")).count == 2)

        // Without cancel_queued the sends stay queued and run afterwards.
        rig.user("/scenario work 3000", uuid: "u5")
        _ = try await rig.waitToolUse("Bash")
        rig.user("kept", uuid: "u6", priority: "later")
        rig.control("i2", "interrupt")
        let kept = payload(try await rig.wait(isResponse("i2")))
        #expect(kept["still_queued"] as? [String] == ["u6"] && kept["cancelled"] == nil)
        _ = try await rig.waitResult()
        let resumed = try await rig.waitResult()
        #expect(resumed["user_message_uuids"] as? [String] == ["u6"])
        #expect(await rig.finish())
    }

    @Test func cancelAsyncMessageUnsendsOneHeldMessage() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }
        rig.user("/scenario work 3000", uuid: "u1")
        _ = try await rig.waitToolUse("Bash")
        rig.user("held", uuid: "u2", priority: "later")
        _ = try await rig.wait(isLifecycle("u2", "queued"))
        rig.control("c1", "cancel_async_message", ["message_uuid": "u2"])
        #expect(payload(try await rig.wait(isResponse("c1")))["cancelled"] as? Bool == true)
        rig.control("c2", "cancel_async_message", ["message_uuid": "unknown"])
        #expect(payload(try await rig.wait(isResponse("c2")))["cancelled"] as? Bool == false)
        #expect(rig.lifecycle("u2") == ["queued", "cancelled"])
        rig.control("i1", "interrupt")
        _ = try await rig.waitResult()
        #expect(await rig.finish())
    }

    @Test func nextJoinsAfterTheToolLaterWaitsAndNowSplitsByOrigin() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }

        // next: queued at once; read (echo, started) only after the running tool finished, inside the same turn.
        rig.user("/scenario work 900", uuid: "n1")
        _ = try await rig.waitToolUse("Bash")
        rig.user("also this", uuid: "n2", priority: "next")
        let joined = try await rig.waitResult()
        #expect(joined["user_message_uuids"] as? [String] == ["n1", "n2"])
        var records = rig.all()
        let queued = try #require(records.firstIndex(where: isLifecycle("n2", "queued")))
        let firstToolResult = try #require(records.firstIndex { $0["type"] as? String == "user" && toolBlock($0)?["type"] as? String == "tool_result" })
        let read = try #require(records.firstIndex(where: isUserEcho("n2")))
        #expect(queued < firstToolResult && firstToolResult < read)
        #expect(records.contains { $0["type"] as? String == "assistant" && text($0) == "Joined your message: also this" })
        _ = try await rig.wait(isLifecycle("n2", "completed"))

        // later: queued at once, read (echo) only after the first turn ended; then its own turn.
        rig.user("/scenario work 600", uuid: "l1")
        _ = try await rig.waitToolUse("Bash")
        rig.user("then this", uuid: "l2", priority: "later")
        let first = try await rig.waitResult()
        #expect(first["user_message_uuids"] as? [String] == ["l1"] && first["queued_turn_count"] as? Int == 1)
        let second = try await rig.waitResult()
        #expect(second["user_message_uuids"] as? [String] == ["l2"])
        records = rig.all()
        let echo = try #require(records.firstIndex(where: isUserEcho("l2")))
        let firstResult = try #require(records.firstIndex { $0["type"] as? String == "result" && ($0["user_message_uuids"] as? [String]) == ["l1"] })
        #expect(try #require(records.firstIndex(where: isLifecycle("l2", "queued"))) < firstResult && firstResult < echo)

        // now + human origin: the running Bash moves to the background and the message is read in the same turn.
        rig.user("/scenario work 3000", uuid: "x1")
        _ = try await rig.waitToolUse("Bash")
        rig.user("quick one", uuid: "x2", priority: "now")
        let moved = try await rig.waitResult()
        #expect(moved["subtype"] as? String == "success" && moved["user_message_uuids"] as? [String] == ["x1", "x2"])
        records = rig.all()
        let backgrounded = try #require(records.firstIndex { $0["subtype"] as? String == "task_updated" && ($0["patch"] as? ChatRig.Record)?["is_backgrounded"] as? Bool == true })
        let movedResult = try #require(records.firstIndex { ($0["type"] as? String == "user") && (toolBlock($0)?["content"] as? String)?.hasPrefix("Command was moved to the background") == true })
        let readNow = try #require(records.firstIndex(where: isUserEcho("x2")))
        #expect(backgrounded < movedResult && movedResult < readNow)
        // The task finishes later and tells the model: an isReplay user record that is not one of our sends.
        let notice = try #require(records.first { ($0["origin"] as? ChatRig.Record)?["kind"] as? String == "task-notification" })
        #expect(notice["isReplay"] as? Bool == true && (notice["message"] as? ChatRig.Record)?["content"] as? String != nil)
        #expect(records.contains { $0["subtype"] as? String == "task_notification" && $0["status"] as? String == "completed" })

        // now without origin: the tool finishes, then the turn ends and the message starts the next turn.
        rig.user("/scenario work 2400", uuid: "y1")
        _ = try await rig.waitToolUse("Bash")
        rig.user("stop that", uuid: "y2", priority: "now", human: false)
        let aborted = try await rig.waitResult()
        #expect(aborted["subtype"] as? String == "success" && aborted["terminal_reason"] as? String == "aborted_tools")
        #expect(aborted["user_message_uuids"] as? [String] == ["y1"] && aborted["queued_turn_count"] as? Int == 1)
        let ranOn = try await rig.waitResult()
        #expect(ranOn["subtype"] as? String == "success" && ranOn["user_message_uuids"] as? [String] == ["y2"])
        #expect(rig.lifecycle("y1") == ["queued", "started", "cancelled"])
        #expect(await rig.finish())
    }

    @Test func nowWhileTextStreamsCutsTheStreamAndTheMessageStartsTheNextTurn() async throws {
        let rig = try ChatRig(environment: ["LOOM_FAKE_CHAT_DELAY_MS": "80"])
        defer { rig.stop() }
        rig.user("a long streamed answer that takes a while to arrive in pieces", uuid: "s1")
        _ = try await rig.wait { (($0["event"] as? ChatRig.Record)?["delta"] as? ChatRig.Record)?["text"] != nil }
        rig.user("never mind", uuid: "s2", priority: "now")
        let cut = try await rig.waitResult()
        #expect(cut["subtype"] as? String == "success" && cut["terminal_reason"] as? String == "aborted_streaming")
        #expect(cut["user_message_uuids"] as? [String] == ["s1"])
        let partial = try #require(rig.all().first { $0["aborted"] as? Bool == true })
        #expect(!text(partial).isEmpty && cut["result"] as? String == text(partial))
        let next = try await rig.waitResult()
        #expect(next["user_message_uuids"] as? [String] == ["s2"])
        #expect(await rig.finish())
    }

    // MARK: Events and edge records

    @Test func everyResultSubtypeErrorsAndTheStatusEventsAreEmitted() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }
        var seen: [String: String] = [:]
        for (index, subtype) in ["success", "error_during_execution", "error_max_turns", "error_max_budget_usd",
                                 "error_max_structured_output_retries"].enumerated() {
            rig.user("/scenario result \(subtype)", uuid: "r\(index)")
            let result = try await rig.waitResult()
            seen[subtype] = result["subtype"] as? String
            #expect(result["is_error"] as? Bool == (subtype != "success"))
        }
        #expect(Set(seen.values).count == 5 && seen.allSatisfy { $0.key == $0.value })

        // An API error is a success result with is_error, terminal_reason api_error and a category on assistant.error.
        rig.user("/scenario result api_error 404 model_not_found", uuid: "a1")
        let failure = try await rig.waitResult()
        #expect(failure["subtype"] as? String == "success" && failure["is_error"] as? Bool == true)
        #expect(failure["terminal_reason"] as? String == "api_error" && failure["api_error_status"] as? Int == 404)
        let errorMessage = try #require(rig.all().first { $0["error"] as? String == "model_not_found" })
        #expect(errorMessage["type"] as? String == "assistant" && text(errorMessage).contains("model"))

        rig.user("/scenario rate-limit allowed_warning", uuid: "e1")
        let limit = try await rig.wait(isType("rate_limit_event"))
        let info = try #require(limit["rate_limit_info"] as? ChatRig.Record)
        #expect(info["status"] as? String == "allowed_warning" && info["rateLimitType"] as? String == "five_hour")
        #expect((info["unifiedWindows"] as? ChatRig.Record)?["seven_day"] != nil)
        _ = try await rig.waitResult()

        rig.user("/scenario api-retry 2", uuid: "e2")
        _ = try await rig.waitResult()
        let retries = rig.all().filter(isType("system", "api_retry"))
        #expect(retries.compactMap { $0["attempt"] as? Int } == [1, 2] && retries.first?["error"] as? String == "overloaded")

        rig.user("/scenario compact auto", uuid: "e3")
        _ = try await rig.waitResult()
        let sequence = rig.all().filter { $0["subtype"] as? String == "status" && $0["status"] as? String == "compacting"
            || $0["subtype"] as? String == "compact_boundary" }.compactMap { $0["subtype"] as? String }
        #expect(sequence == ["status", "compact_boundary"])
        let boundary = try #require(rig.all().first { $0["subtype"] as? String == "compact_boundary" })
        #expect((boundary["compact_metadata"] as? ChatRig.Record)?["trigger"] as? String == "auto")

        rig.user("/scenario unknown", uuid: "e4")
        _ = try await rig.waitResult()
        #expect(rig.all().contains { $0["type"] as? String == "hologram" })
        #expect(rig.all().contains { $0["subtype"] as? String == "future_event" })

        // A conversation reset as the real CLI writes it: the reset record's id is not a session (it is the record's own uuid);
        // `system/init` and everything after carry the new session id.
        rig.user("/clear", uuid: "e5")
        let reset = try await rig.wait(isType("conversation_reset"))
        let resetID = try #require(reset["new_conversation_id"] as? String)
        #expect(resetID != rig.sessionID && reset["trigger"] as? String == "clear")
        let reinit = try await rig.wait(isType("system", "init"))
        let newID = try #require(reinit["session_id"] as? String)
        #expect(newID != rig.sessionID && newID != resetID)
        let afterReset = try await rig.waitResult()
        #expect(afterReset["session_id"] as? String == newID)
        #expect(await rig.finish())
    }

    @Test func aMultiMegabyteLineArrivesWholeAndTheMinimalControlRequestsAnswer() async throws {
        let rig = try ChatRig(environment: ["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "true"])
        defer { rig.stop() }
        rig.user("/scenario bigline 2", uuid: "b1")
        _ = try await rig.waitResult(timeout: 30)
        #expect((rig.lineSizes().max() ?? 0) > 2 * 1_048_576)
        let big = try #require(toolResults(rig.all()).last.flatMap(toolBlock))
        #expect((big["content"] as? String)?.count ?? 0 > 2 * 1_048_576)

        rig.control("m1", "set_permission_mode", ["mode": "plan"])
        #expect(payload(try await rig.wait(isResponse("m1")))["mode"] as? String == "plan")
        rig.control("m2", "no_such_request")
        let unsupported = try await rig.wait(isResponse("m2"))
        #expect((unsupported["response"] as? ChatRig.Record)?["subtype"] as? String == "error")

        // side_question: progress, then the answer; no turn, no lifecycle.
        let before = rig.all().count
        rig.control("q1", "side_question", ["question": "What is two plus two?"])
        _ = try await rig.wait(isType("system", "control_request_progress"))
        let side = payload(try await rig.wait(isResponse("q1")))
        #expect(side["synthetic"] as? Bool == false && (side["response"] as? String)?.isEmpty == false)
        #expect(rig.all().dropFirst(before).allSatisfy { $0["type"] as? String != "command_lifecycle" && $0["type"] as? String != "result" })

        rig.control("r1", "rewind_files", ["user_message_id": "b1", "dry_run": true])
        let dry = payload(try await rig.wait(isResponse("r1")))
        // A checkpoint exists for the message, and the scenario wrote no file: nothing to rewind.
        #expect(dry["canRewind"] as? Bool == true && (dry["filesChanged"] as? [String])?.isEmpty == true)
        rig.control("r2", "rewind_conversation", ["target_message_uuid": "b1"])
        let rewound = payload(try await rig.wait(isResponse("r2")))
        #expect(rewound["rewound"] as? Bool == true && rewound["prefillText"] as? String == "/scenario bigline 2")
        rig.control("g1", "background_tasks")
        #expect(payload(try await rig.wait(isResponse("g1"))).isEmpty)
        #expect(await rig.finish())
    }

    /// `rewind_files` as S8 saw the CLI (V21): checkpoints per user message from the switch on, only the Write tool's files, a
    /// dry run that changes nothing, a real run that restores them, and the two shapes of "cannot".
    @Test func rewindFilesFollowsTheCheckpointsTheWayTheCliDoes() async throws {
        let rig = try ChatRig(arguments: ["--permission-mode", "bypassPermissions"],
                              environment: ["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "true"])
        defer { rig.stop() }
        let file = rig.root.appendingPathComponent("a.txt")
        rig.user("/scenario file a.txt one", uuid: "u1")
        _ = try await rig.waitResult()
        rig.user("/scenario file a.txt two", uuid: "u2")
        _ = try await rig.waitResult()
        rig.user("/scenario run touch shell.txt", uuid: "u3")
        _ = try await rig.waitResult()
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")

        rig.control("d2", "rewind_files", ["user_message_id": "u2", "dry_run": true])
        let dry = payload(try await rig.wait(isResponse("d2")))
        #expect(dry["canRewind"] as? Bool == true && dry["filesChanged"] as? [String] == [realPath(file)])
        #expect(dry["insertions"] as? Int == 1 && dry["deletions"] as? Int == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")

        // An unknown id has no checkpoint: inside a success for a dry run, an error frame for a real one.
        rig.control("d9", "rewind_files", ["user_message_id": "nope", "dry_run": true])
        let none = payload(try await rig.wait(isResponse("d9")))
        #expect(none["canRewind"] as? Bool == false && none["error"] as? String == "No file checkpoint found for this message.")
        rig.control("r9", "rewind_files", ["user_message_id": "nope"])
        let refused = try await rig.wait(isResponse("r9"))
        let frame = try #require(refused["response"] as? ChatRig.Record)
        #expect(frame["subtype"] as? String == "error" && frame["error"] as? String == "No file checkpoint found for this message.")

        // The real run restores the tracked file to before u2; the file only a shell command made stays.
        rig.control("r2", "rewind_files", ["user_message_id": "u2"])
        let done = payload(try await rig.wait(isResponse("r2")))
        #expect(done["canRewind"] as? Bool == true && done["skippedLinks"] as? Int == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
        // To before u1 the file did not exist.
        rig.control("r1", "rewind_files", ["user_message_id": "u1"])
        _ = try await rig.wait(isResponse("r1"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("shell.txt").path))
        #expect(await rig.finish())
    }

    @Test func rewindFilesIsNotEnabledWithoutTheSwitch() async throws {
        let rig = try ChatRig()
        defer { rig.stop() }
        rig.user("hello", uuid: "u1")
        _ = try await rig.waitResult()
        rig.control("d1", "rewind_files", ["user_message_id": "u1", "dry_run": true])
        let dry = payload(try await rig.wait(isResponse("d1")))
        #expect(dry["canRewind"] as? Bool == false && dry["error"] as? String == "File rewinding is not enabled.")
        rig.control("r1", "rewind_files", ["user_message_id": "u1"])
        let frame = try #require(try await rig.wait(isResponse("r1"))["response"] as? ChatRig.Record)
        #expect(frame["subtype"] as? String == "error" && frame["error"] as? String == "File rewinding is not enabled.")
        #expect(await rig.finish())
    }

    @Test func sessionStateEventsAppearOnlyWhenTheEnvironmentAsksForThem() async throws {
        let plain = try ChatRig()
        defer { plain.stop() }
        plain.user("one", uuid: "u1")
        _ = try await plain.waitResult()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!plain.all().contains(where: isType("system", "session_state_changed")))

        let rig = try ChatRig(environment: ["CLAUDE_CODE_SDK_READS_SESSION_STATE": "1"])
        defer { rig.stop() }
        rig.user("one", uuid: "u1")
        _ = try await rig.wait { $0["state"] as? String == "idle" }
        let records = rig.all()
        let states = records.filter(isType("system", "session_state_changed"))
        // running comes before the lifecycle's queued; idle after completed; the READS variant says host-only.
        #expect(states.compactMap { $0["state"] as? String } == ["running", "idle"])
        #expect(states.allSatisfy { $0["sdk_host_only"] as? Bool == true })
        let queued = try #require(records.firstIndex(where: isLifecycle("u1", "queued")))
        let completed = try #require(records.firstIndex(where: isLifecycle("u1", "completed")))
        #expect(try #require(records.firstIndex(where: isType("system", "session_state_changed"))) < queued)
        #expect(completed < (try #require(records.lastIndex(where: isType("system", "session_state_changed")))))
        #expect(await rig.finish())
    }

    /// D-62: like the CLI, the fake takes a live switch to Full access only when launched with the flag, and refuses it
    /// (and stays in its mode) otherwise.
    @Test func aLiveSwitchToFullAccessNeedsTheLaunchFlag() async throws {
        let with = try ChatRig(arguments: ["--allow-dangerously-skip-permissions"])
        defer { with.stop() }
        with.control("m1", "set_permission_mode", ["mode": "bypassPermissions"])
        #expect(payload(try await with.wait(isResponse("m1")))["mode"] as? String == "bypassPermissions")
        with.control("m2", "set_permission_mode", ["mode": "default"])
        #expect(payload(try await with.wait(isResponse("m2")))["mode"] as? String == "default")

        let without = try ChatRig()
        defer { without.stop() }
        without.control("m1", "set_permission_mode", ["mode": "bypassPermissions"])
        let refused = try await without.wait(isResponse("m1"))
        #expect((refused["response"] as? ChatRig.Record)?["subtype"] as? String == "error")
        without.control("m2", "set_permission_mode", ["mode": "plan"])
        #expect(payload(try await without.wait(isResponse("m2")))["mode"] as? String == "plan")
    }
}
