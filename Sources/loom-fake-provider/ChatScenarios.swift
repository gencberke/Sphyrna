import Foundation

// Chat-mode scenarios, chosen by the text of a user message: `/scenario <name> [args]`. `/clear` is
// `reset`, `/compact` is `compact`, any other text is a plain streamed `answer`. Every scenario is one turn
// and ends in a `result`. Names:
//   answer                            streamed text deltas
//   thinking                          a thinking block, then text
//   prethink                          Claude 5.1+: two thinking blocks right before a tool_use (Read)
//   read | bash | bash-fail [code] | edit | write   one tool with its result (edit: `structuredPatch`;
//                                     write creates a file: empty `structuredPatch`)
//   subagent [ms] [approval]          an Agent whose messages carry parent_tool_use_id and agent_id, announced by
//                                     task_started (and its own transcript); `approval`: its Bash asks first
//   approval | question | plan        can_use_tool round trips (Bash, AskUserQuestion, ExitPlanMode)
//   approval <variant>                the same round trip for another kind of tool: edit (an Edit, suggestion
//                                     setMode acceptEdits), write (a new file), web (WebFetch), mcp (an MCP tool),
//                                     redirect (a Bash command with `> file`: the CLI asks again every time),
//                                     bare (a Bash command with no description, reason or suggestion), long (a
//                                     twelve-line command)
//   orphan [resolve]                  two Bash requests left waiting across the turn's `result` (the CLI never does
//                                     this; a host must keep a card until its own id is answered or withdrawn, or
//                                     its own tool_use_id finishes: `resolve` finishes the first one's)
//   approvals [n]                     n Bash requests at once (default 3), one assistant message: the cards' counter
//   work [ms]                         three Bash steps over `ms` (default 600): room to interrupt, or to send
//                                     `next`/`later`/`now` messages (a step of a second or more announces itself
//                                     with task_started, so `now` + human origin can move it to the background)
//   result <subtype> [terminal]       ends with that result subtype (success, error_during_execution,
//                                     error_max_turns, error_max_budget_usd, error_max_structured_output_retries)
//   result api_error [status] [category]   an API error as the CLI reports it: assistant.error, then a `result`
//                                     with subtype success, is_error true, terminal_reason api_error
//                                     (default 404 model_not_found)
//   rate-limit [status]               the turn's rate_limit_event status (allowed | allowed_warning | rejected)
//   api-retry [n] [error]             n system/api_retry records (default 2, error `overloaded`), then an answer
//   compact [trigger]                 status compacting, status null, compact_boundary
//   reset [trigger]                   conversation_reset to a new session id, a fresh system/init, and the
//                                     SessionStart hook with source `clear` (the run moves to a new card)
//   unknown                           an unknown record type, an unknown system subtype and keep_alive
//   bigline [MiB]                     a Bash result whose line is about 2x MiB (default 3)
//   file <name> <text>                a Write of <text> to <name> in the work folder, decided by the permission rules
//   run <command>                     a Bash call (`mkdir <d>` and `touch <f>` take effect), decided by the rules
//   web WebFetch|WebSearch            a research call, decided by the rules (ChatPermissions.swift)
//   bg-agent [ms]                     an Agent in the background; its end starts a CLI turn that tries to write its report
//   stream <seconds> <chars/s>        Markdown text deltas at that rate for that time, a short tool call every few seconds
//                                     (ChatStreamScenario.swift; the resource-measurement load)

extension ChatEngine {
    func runScenario(_ text: String) throws {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var name = "answer"
        var args: [String] = []
        var prompt = text
        if words.first == "/scenario", words.count > 1 {
            name = words[1]
            args = Array(words.dropFirst(2))
            prompt = "This is a scripted answer streamed in small pieces, as the real CLI streams it."
        } else if words.first == "/clear" {
            name = "reset"
        } else if words.first == "/compact" {
            name = "compact"
        } else {
            prompt = "Fake answer to: " + String(text.prefix(200))
        }
        switch name {
        case "answer":
            try assistantMessage([.text(prompt)])
        case "thinking":
            try assistantMessage([
                .thinking("**Weighing the options**\nThe user wants a short answer, so I will keep it brief."),
                .text("Here is the short answer after thinking."),
            ])
        case "prethink":
            try prethink()
        case "read":
            try read()
            try assistantMessage([.text("The file starts with a title.")])
        case "bash":
            try toolStep(
                id: nextToolID(), name: "Bash", input: ["command": "ls -1", "description": "List files"],
                content: "A.swift\nB.swift", structured: Self.bash(stdout: "A.swift\nB.swift"))
            try assistantMessage([.text("There are two files.")])
        case "bash-fail":
            let code = args.first.flatMap(Int.init) ?? 2
            let message = "Exit code \(code)\nls: missing-dir: No such file or directory"
            try toolStep(
                id: nextToolID(), name: "Bash", input: ["command": "ls missing-dir", "description": "List a folder"],
                content: message, error: true, structured: "Error: " + message)
            try assistantMessage([.text("The folder does not exist.")])
        case "edit":
            try edit()
            try assistantMessage([.text("Updated the constant.")])
        case "write":
            try write()
            try assistantMessage([.text("Created the notes file.")])
        case "subagent":
            try subagent(milliseconds: args.compactMap(Int.init).first ?? 60, approval: args.contains("approval"))
        case "approval":
            try approval(variant: args.first)
        case "orphan":
            try orphan(resolve: args.first == "resolve")
        case "approvals":
            try approvals(count: args.first.flatMap(Int.init) ?? 3)
        case "question":
            try question()
        case "plan":
            try plan()
        case "work":
            try work(milliseconds: args.first.flatMap(Int.init) ?? 600)
        case "result":
            if args.first == "api_error" {
                try apiError(status: args.dropFirst().first.flatMap(Int.init) ?? 404, category: args.dropFirst(2).first ?? "model_not_found")
            } else {
                try resultScenario(subtype: args.first ?? "success", terminal: args.dropFirst().first)
            }
        case "rate-limit":
            try rateLimit(status: args.first ?? "allowed_warning")
        case "api-retry":
            let count = args.first.flatMap(Int.init) ?? 2
            let error = args.dropFirst().first ?? "overloaded"
            for attempt in 1...max(1, count) {
                send(wire.apiRetry(attempt: attempt, maxRetries: max(3, count), delayMs: 500 * attempt,
                                   status: error == "overloaded" ? 529 : 400, error: error))
                try pause(config.delayMs)
            }
            try assistantMessage([.text("The request went through after \(count) retries.")])
        case "compact":
            send(wire.status("compacting"))
            try pause(config.delayMs)
            send(wire.status(nil, compactResult: "success"))
            send(wire.compactBoundary(trigger: args.first ?? "manual", preTokens: 150_000, postTokens: 12_000))
            try assistantMessage([.text("Context compacted.")])
        case "reset":
            reset(trigger: args.first ?? "clear")
        case "unknown":
            for record in wire.unknownRecords() { send(record) }
            try assistantMessage([.text("The unknown records came first.")])
        case "bigline":
            try bigLine(mebibytes: args.first.flatMap(Int.init) ?? 3)
        case "file":
            try fileScenario(args)
        case "run":
            try runScenario(command: args.joined(separator: " "))
        case "web":
            try webScenario(tool: args.first ?? "WebFetch")
        case "bg-agent":
            try backgroundAgentScenario(milliseconds: args.first.flatMap(Int.init) ?? 300)
        case "stream":
            try streamScenario(args)
        default:
            try assistantMessage([.text("Unknown scenario '\(name)'.")])
        }
    }

    static func bash(stdout: String) -> ChatObject {
        ["stdout": stdout, "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false]
    }

    func prethink() throws {
        try read(leading: [
            .thinking("**Reading the module**\nI will look at the main file first."),
            .thinking("Opening Main.swift now."),
        ])
        try assistantMessage([.text("Main.swift only holds the entry point.")])
    }

    func read(leading: [Block] = []) throws {
        let path = "/tmp/fake-project/Main.swift"
        let file = "# Fake\nprint(\"hello\")\n"
        try toolStep(
            id: nextToolID(), name: "Read", input: ["file_path": path], leading: leading,
            content: "     1\t# Fake\n     2\tprint(\"hello\")\n",
            structured: ["type": "text", "file": ["filePath": path, "content": file, "numLines": 2, "startLine": 1, "totalLines": 2]])
    }

    func edit() throws {
        let path = "/tmp/fake-project/App.swift"
        try toolStep(
            id: nextToolID(), name: "Edit",
            input: ["file_path": path, "old_string": "let limit = 1", "new_string": "let limit = 2"],
            leading: [.text("I'll raise the limit.")],
            content: "The file \(path) has been updated successfully.",
            structured: [
                "filePath": path, "oldString": "let limit = 1", "newString": "let limit = 2",
                "originalFile": "let limit = 1\nlet name = \"fake\"\n",
                "structuredPatch": [[
                    "oldStart": 1, "oldLines": 2, "newStart": 1, "newLines": 2,
                    "lines": ["-let limit = 1", "+let limit = 2", " let name = \"fake\""],
                ] as ChatObject],
                "userModified": false, "replaceAll": false,
            ])
    }

    /// Write that creates a file: an empty `structuredPatch` and a null `originalFile`.
    func write() throws {
        let path = "/tmp/fake-project/notes.txt"
        try toolStep(
            id: nextToolID(), name: "Write", input: ["file_path": path, "content": "alpha\nbeta\n"],
            content: "File created successfully at: \(path)",
            structured: ["type": "create", "filePath": path, "content": "alpha\nbeta\n", "structuredPatch": [] as [Any],
                         "originalFile": NSNull(), "userModified": false] as ChatObject)
    }

    func subagent(milliseconds: Int, approval: Bool) throws {
        let task = nextToolID()
        let info = AgentInfo(
            id: "a" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16),
            type: "explorer", description: "Map the fake module")
        let run = "run-" + UUID().uuidString.lowercased().prefix(8)
        let prompt = "Map the fake module and report the services."
        transcript.writeMeta(agent: info.id, type: info.type, description: info.description)
        try assistantMessage([
            .text("I'll hand the mapping to a subagent."),
            .tool(id: task, name: "Agent", input: [
                "description": info.description, "subagent_type": info.type, "prompt": prompt, "run_in_background": false,
            ]),
        ])
        subagents[task] = info
        send(wire.taskStarted(
            taskID: info.id, runID: run, toolUseID: task, description: info.description, type: "local_agent",
            subagentType: info.type, prompt: prompt))
        transcript.append(wire.transcriptRecord(
            type: "user", uuid: wire.uuid(), message: ["role": "user", "content": prompt], parentUUID: nil,
            cwd: config.cwd, agentID: info.id), agent: info.id)
        try whileTool(task) {
            try assistantMessage([.text("Looking at the module.")], parent: task)
            let inner = nextToolID()
            let input: ChatObject = ["command": "ls fake-module", "description": "List the module"]
            try assistantMessage([.tool(id: inner, name: "Bash", input: input)], parent: task)
            if approval {
                let answer = try askPermission(
                    tool: "Bash", input: input, toolUseID: inner, description: "List the module",
                    reason: "This command requires approval", agentID: info.id, parent: task)
                if answer["behavior"] as? String != "allow" {
                    try deny(id: inner, tool: "Bash", input: input, answer: answer, parent: task)
                }
            }
            send(wire.taskProgress(
                taskID: info.id, runID: run, toolUseID: task, description: "Running List the module", subagentType: info.type))
            try pause(max(0, milliseconds))
            toolResult(inner, "A.swift\nB.swift", structured: Self.bash(stdout: "A.swift\nB.swift"), parent: task)
            try assistantMessage([.text("The module has two services.")], parent: task)
        }
        let report = "The module has two services: A and B."
        send(wire.taskNotification(taskID: info.id, runID: run, toolUseID: task, status: "completed", summary: report))
        toolResult(task, [["type": "text", "text": report]], structured: [
            "status": "completed", "agentId": info.id, "content": [["type": "text", "text": report]],
            "totalDurationMs": milliseconds, "totalTokens": 1_800, "totalToolUseCount": 1,
        ] as ChatObject)
        subagents[task] = nil
        try toolBoundary()
        try assistantMessage([.text("The subagent found two services.")])
    }

    func approval(variant: String? = nil) throws {
        if let variant, variant != "bash" { return try approvalVariant(variant) }
        let id = nextToolID()
        let input: ChatObject = ["command": "rm -rf build", "description": "Remove the build folder"]
        var ask = PermissionAsk.answered([:])
        try assistantMessage([.text("The build folder is stale, so I'll remove it."), .tool(id: id, name: "Bash", input: input)]) {
            ask = requestPermission(
                tool: "Bash", input: input, toolUseID: id, description: "Remove the build folder",
                suggestions: [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf build"]],
                               "behavior": "allow", "destination": "localSettings"] as ChatObject],
                reason: "This command requires approval")
        }
        let answer = try awaitPermission(ask, toolUseID: id)
        if answer["behavior"] as? String == "allow" {
            try runTool(id, milliseconds: 15)
            toolResult(id, "", structured: Self.bash(stdout: ""))
            try toolBoundary()
            try assistantMessage([.text("The build folder is gone.")])
        } else {
            try deny(id: id, tool: "Bash", input: input, answer: answer)
            try assistantMessage([.text(answer["failed"] as? Bool == true
                ? "The command could not run because the permission request failed."
                : "Understood, I left the build folder alone.")])
        }
    }

    /// One request for another kind of tool (see the scenario list). Allowed, the tool runs and its result follows; denied,
    /// the denial is its result.
    func approvalVariant(_ variant: String) throws {
        let id = nextToolID()
        var name = "Bash"
        var input: ChatObject
        var reason: String? = "This command requires approval"
        var suggestions: [ChatObject] = []
        var lead = "I need to run something first."
        var output = "done"
        var structured: Any? = Self.bash(stdout: "done")
        switch variant {
        case "edit":
            name = "Edit"
            input = ["file_path": "/tmp/fake-project/App.swift", "old_string": "let limit = 1\nlet name = \"fake\"",
                     "new_string": "let limit = 2\nlet name = \"fake\"\nlet retries = 3"]
            reason = "Edits need approval in this mode"
            suggestions = [["type": "setMode", "mode": "acceptEdits", "destination": "session"] as ChatObject]
            lead = "I'll raise the limit."
            output = "The file /tmp/fake-project/App.swift has been updated successfully."
            structured = ["filePath": "/tmp/fake-project/App.swift"] as ChatObject
        case "write":
            name = "Write"
            input = ["file_path": "/tmp/fake-project/notes.txt", "content": "alpha\nbeta\ngamma\n"]
            reason = "Edits need approval in this mode"
            suggestions = [["type": "setMode", "mode": "acceptEdits", "destination": "session"] as ChatObject]
            lead = "I'll write the notes."
            output = "File created successfully at: /tmp/fake-project/notes.txt"
            structured = ["type": "create", "filePath": "/tmp/fake-project/notes.txt"] as ChatObject
        case "web":
            name = "WebFetch"
            input = ["url": "https://example.com/docs/limits", "prompt": "Find the rate limits"]
            reason = "WebFetch needs approval for this domain"
            suggestions = [["type": "addRules", "rules": [["toolName": "WebFetch", "ruleContent": "domain:example.com"] as ChatObject],
                            "behavior": "allow", "destination": "localSettings"] as ChatObject]
            lead = "Let me read the docs."
            output = "The limit is 100 requests a minute."
            structured = nil
        case "mcp":
            name = "mcp__docs__search"
            input = ["query": "webhook signature replay window"]
            reason = "This MCP tool needs approval"
            suggestions = [["type": "addRules", "rules": [["toolName": "mcp__docs__search"] as ChatObject],
                            "behavior": "allow", "destination": "localSettings"] as ChatObject]
            lead = "I'll search the docs server."
            output = "3 results"
            structured = nil
        case "redirect":
            input = ["command": "echo done > out.txt", "description": "Write a marker file"]
            suggestions = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "echo done:*"] as ChatObject],
                            "behavior": "allow", "destination": "localSettings"] as ChatObject]
            lead = "I'll leave a marker."
        case "bare":
            input = ["command": "make release"]
            reason = nil
            lead = "Building the release."
        case "long":
            input = ["command": (1...12).map { "echo step \($0) of the release script && sleep 1" }.joined(separator: "\n"),
                     "description": "Run the release steps"]
            suggestions = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "echo step:*"] as ChatObject],
                            "behavior": "allow", "destination": "localSettings"] as ChatObject]
            lead = "I'll run the release steps."
        default:
            input = ["command": "ls -1", "description": "List files"]
        }
        var ask = PermissionAsk.answered([:])
        try assistantMessage([.text(lead), .tool(id: id, name: name, input: input)]) {
            ask = requestPermission(
                tool: name, input: input, toolUseID: id, description: input["description"] as? String,
                suggestions: suggestions, reason: reason)
        }
        let answer = try awaitPermission(ask, toolUseID: id)
        if answer["behavior"] as? String == "allow" {
            try runTool(id, name: name, milliseconds: 15)
            toolResult(id, output, structured: structured)
            try toolBoundary()
            // What the host sent with its allow, so a test can read it from the stream.
            let granted = (answer["updatedPermissions"] as? [ChatObject]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            }.map { String(decoding: $0, as: UTF8.self) } ?? "none"
            try assistantMessage([.text("That went through. Permissions: \(granted)")])
        } else {
            try deny(id: id, tool: name, input: input, answer: answer)
            try assistantMessage([.text("Understood, I did not do it.")])
        }
    }

    /// Two requests that are never awaited: the turn ends with its `result` while both still wait. With `resolve`, the
    /// first tool call finishes some other way before that (its tool_result arrives).
    func orphan(resolve: Bool) throws {
        let first = nextToolID()
        let second = nextToolID()
        let inputs: [ChatObject] = [["command": "make deploy", "description": "Deploy the build"],
                                    ["command": "make notify", "description": "Tell the team"]]
        try assistantMessage([.text("Deploying."), .tool(id: first, name: "Bash", input: inputs[0]),
                              .tool(id: second, name: "Bash", input: inputs[1])]) {
            _ = requestPermission(tool: "Bash", input: inputs[0], toolUseID: first, description: "Deploy the build",
                                  reason: "This command requires approval")
            _ = requestPermission(tool: "Bash", input: inputs[1], toolUseID: second, description: "Tell the team",
                                  reason: "This command requires approval")
        }
        if resolve { toolResult(first, "Ran somewhere else", structured: Self.bash(stdout: "Ran somewhere else")) }
        keepPendingAtEnd = true
        try assistantMessage([.text("Waiting on you.")])
    }

    /// Several requests at once, from one assistant message: they wait in order of arrival and may be answered in any order.
    func approvals(count: Int) throws {
        let ids = (0..<max(1, count)).map { _ in nextToolID() }
        let inputs: [ChatObject] = ids.indices.map { index in
            ["command": "make step\(index + 1)", "description": "Run build step \(index + 1)"]
        }
        var asks: [PermissionAsk] = []
        var blocks: [Block] = [.text("Three steps need your approval.")]
        for index in ids.indices { blocks.append(.tool(id: ids[index], name: "Bash", input: inputs[index])) }
        try assistantMessage(blocks) {
            for index in ids.indices {
                asks.append(requestPermission(
                    tool: "Bash", input: inputs[index], toolUseID: ids[index], description: "Run build step \(index + 1)",
                    reason: "This command requires approval"))
            }
        }
        var allowed = 0
        for index in ids.indices {
            let answer = try awaitPermission(asks[index], toolUseID: ids[index])
            if answer["behavior"] as? String == "allow" {
                allowed += 1
                try runTool(ids[index], milliseconds: 15)
                toolResult(ids[index], "step \(index + 1) done", structured: Self.bash(stdout: "step \(index + 1) done"))
            } else {
                try deny(id: ids[index], tool: "Bash", input: inputs[index], answer: answer)
            }
        }
        try toolBoundary()
        try assistantMessage([.text("\(allowed) of \(ids.count) steps ran.")])
    }

    /// A denied tool: the tool_result is the denial message, and `interrupt: true` ends the turn.
    func deny(id: String, tool: String, input: ChatObject, answer: ChatObject, parent: String? = nil) throws {
        let message = answer["message"] as? String ?? "The user denied this tool use."
        // A request that failed (input closed) is a tool error, not a denial.
        if answer["failed"] as? Bool != true { denials.append(["tool_name": tool, "tool_use_id": id, "tool_input": input]) }
        toolResult(id, message, error: true, structured: "Error: " + message, parent: parent,
                   refusal: answer["failed"] as? Bool == true ? nil : "permission-rule")
        if answer["interrupt"] as? Bool == true {
            interruptedInTool = true
            throw TurnEnd.interrupted
        }
    }

    func question() throws {
        let id = nextToolID()
        let questions: [ChatObject] = [
            ["question": "Which database should the app use?", "header": "Database", "multiSelect": false,
             "options": [["label": "SQLite", "description": "One file, no server"] as ChatObject,
                         ["label": "Postgres", "description": "A server, more features"] as ChatObject]],
            ["question": "Which extras do you want?", "header": "Extras", "multiSelect": true,
             "options": [["label": "Logging", "description": "Structured logs"] as ChatObject,
                         ["label": "Metrics", "description": "Basic counters"] as ChatObject]],
        ]
        let input: ChatObject = ["questions": questions]
        var ask = PermissionAsk.answered([:])
        try assistantMessage([.tool(id: id, name: "AskUserQuestion", input: input)]) {
            ask = requestPermission(tool: "AskUserQuestion", input: input, toolUseID: id, requiresInteraction: true)
        }
        let answer = try awaitPermission(ask, toolUseID: id)
        if answer["behavior"] as? String == "allow" {
            let answers = (answer["updatedInput"] as? ChatObject)?["answers"] as? [String: String] ?? [:]
            let summary = answers.keys.sorted().map { "\"\($0)\"=\"\(answers[$0] ?? "")\"" }.joined(separator: ", ")
            toolResult(id, "User has answered your questions: \(summary). You can now continue with the user's answers in mind.",
                       structured: ["questions": questions, "answers": answers] as ChatObject)
            try toolBoundary()
            try assistantMessage([.text("You chose: " + answers.keys.sorted().map { answers[$0] ?? "" }.joined(separator: "; "))])
        } else {
            try deny(id: id, tool: "AskUserQuestion", input: input, answer: answer)
            try assistantMessage([.text("I'll decide without your answers.")])
        }
    }

    func plan() throws {
        prePlanMode = permissionMode
        permissionMode = "plan"
        send(wire.status(nil, permissionMode: "plan"))
        let id = nextToolID()
        let path = "/tmp/fake-project/.claude/plans/fake-plan.md"
        let plan = "# Fake plan\n\n1. Read the module.\n2. Change the constant.\n3. Run the tests.\n"
        let input: ChatObject = ["plan": plan, "planFilePath": path] // ASSUMPTION: the CLI injects both
        var ask = PermissionAsk.answered([:])
        try assistantMessage([.text("I have a plan."), .tool(id: id, name: "ExitPlanMode", input: [:])]) {
            ask = requestPermission(tool: "ExitPlanMode", input: input, toolUseID: id, requiresInteraction: true)
        }
        let answer = try awaitPermission(ask, toolUseID: id)
        if answer["behavior"] as? String == "allow" {
            let update = (answer["updatedPermissions"] as? [ChatObject])?.first { $0["type"] as? String == "setMode" }
            // setMode in the answer picks the mode; a plain allow returns to the mode before the plan.
            permissionMode = update?["mode"] as? String ?? prePlanMode ?? "default"
            send(wire.status(nil, permissionMode: permissionMode))
            toolResult(id, "User has approved your plan. You can now start coding.",
                       structured: ["plan": plan, "isAgent": false, "filePath": path] as ChatObject)
            try toolBoundary()
            try assistantMessage([.text("Implementing the plan in \(permissionMode) mode.")])
        } else {
            try deny(id: id, tool: "ExitPlanMode", input: input, answer: answer)
            try assistantMessage([.text("Staying in plan mode.")])
        }
    }

    func work(milliseconds: Int) throws {
        try assistantMessage([.text("Starting the work.")])
        for step in 1...3 {
            try toolStep(
                id: nextToolID(), name: "Bash", input: ["command": "make step\(step)", "description": "Step \(step)"],
                milliseconds: max(1, milliseconds / 3), content: "step \(step) done",
                structured: Self.bash(stdout: "step \(step) done"))
        }
        try assistantMessage([.text("All three steps finished.")])
    }

    func resultScenario(subtype: String, terminal: String?) throws {
        try assistantMessage([.text("This turn ends with \(subtype).")])
        if subtype == "success" {
            outcome.terminalReason = terminal ?? "completed"
            return
        }
        let defaults = ["error_max_turns": "max_turns", "error_max_budget_usd": "budget_exhausted"]
        outcome = ChatOutcome(
            subtype: subtype, isError: true, terminalReason: terminal ?? defaults[subtype], text: "",
            errors: ["Fake \(subtype)"])
    }

    func rateLimit(status: String) throws {
        rateLimitStatus = status
        if status == "rejected" {
            // ASSUMPTION: a blocked turn reports like any API error (S1 could not provoke it).
            try apiError(status: 429, category: "rate_limit")
            return
        }
        try assistantMessage([.text("The limit event follows the first message.")])
    }

    func apiError(status: Int, category: String) throws {
        let texts = [
            "model_not_found": "There's an issue with the selected model. It may not exist or you may not have access to it.",
            "authentication_failed": "Not logged in · Please run /login",
            "rate_limit": "You've hit your limit.",
        ]
        let text = texts[category] ?? "The API request failed (\(category))."
        emitMessage(wire.apiErrorAssistant(text: text, category: category, status: status))
        finalText = text
        outcome = ChatOutcome(
            subtype: "success", isError: true, terminalReason: "api_error", apiErrorStatus: status, text: text)
    }

    /// A conversation reset as the real CLI 2.1.300 writes it (v2 fix round B, F1): `conversation_reset` first, whose
    /// `new_conversation_id` is the record's own uuid and NOT the new session (the transcript is written under the id that
    /// follows); then the SessionStart hook with source `clear` and `system/init`, both under the new session id.
    func reset(trigger: String) {
        let newID = UUID().uuidString.lowercased()
        send(wire.conversationReset(newID: UUID().uuidString.lowercased(), trigger: trigger))
        wire.session = newID
        transcript.switchSession(newID)
        lastUUID = nil
        // Not measured on the real CLI: whether live settings (rules, style) survive a reset. The worst case on demand.
        if config.resetForgetsSettings { liveSettings = [:] }
        if config.resetInitFirst {
            sendInit()
            hook("SessionStart", ["source": "clear"])
        } else {
            hook("SessionStart", ["source": "clear"])
            sendInit()
        }
        outcome.text = ""
    }

    func bigLine(mebibytes: Int) throws {
        let line = String(repeating: "bulk output line 0123456789 abcdefghijklmnopqrstuvwxyz\n", count: 19_100) // 1 MiB
        let output = String(repeating: line, count: max(1, mebibytes))
        try toolStep(
            id: nextToolID(), name: "Bash", input: ["command": "cat big.log", "description": "Print the log"],
            content: output, structured: Self.bash(stdout: output))
        try assistantMessage([.text("The log was big.")])
    }
}
