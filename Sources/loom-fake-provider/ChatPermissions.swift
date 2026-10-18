import Foundation

// Chat mode: permission rules, modes and output styles as the 2.1.300 CLI behaves (spikes S9 and S9b), so the Ask mode can be
// tested without a model.
//
//   set_permission_mode   acceptEdits, auto, bypassPermissions, default, dontAsk, plan (`manual` reads as default); answers
//                         {mode} and sends system/status; errors carry `error_code` (invalid_mode, bypass_not_launched,
//                         bypass_disabled).
//   apply_flag_settings   the live layer: a top-level key is replaced as a whole, null removes it, and it is merged with the
//                         launch layer (`--settings`, `--disallowedTools`), which it can never remove. A live deny leaves the
//                         tool in the tool list and refuses the call; a launch deny removes the tool.
//   list_permission_rules {state:{rules:[{behavior, source, rule, description, editability}]}}: Loom's layers are
//                         `flagSettings`; LOOM_FAKE_CHAT_USER_RULES adds rules of the user's own settings with their sources.
//   dontAsk               refuses whatever would ask, with no request to the host (the mode's text); a user's or a flag
//                         allow rule is honoured; read-only Bash is allowed by a classifier that looks at flags.
//   Refusals              tool_result is_error, system/permission_denied{tool_name, tool_use_id, decision_reason_type
//                         mode|rule, message} and an entry in result.permission_denials; the turn still ends in success.
//   Models                Default, opus (all five effort levels), sonnet (low to high), haiku (no effort).
//   Failures on demand    LOOM_FAKE_CHAT_FAIL_MODE (modes `set_permission_mode` refuses), LOOM_FAKE_CHAT_FAIL_ASK_RULES=1 (the
//                         settings with a style fail after the rules went in), LOOM_FAKE_CHAT_RESET_FORGETS_SETTINGS=1,
//                         LOOM_FAKE_CHAT_INIT_DELAY_MS and LOOM_FAKE_CHAT_CONTROL_DELAY_MS (slow answers, for races).
//   Scenarios             `bg-agent [ms]` (an Agent in the background; its end starts a turn that tries to write its report),
//                         `file <name> <text>` (Write in the work folder), `run <command>` (Bash; `mkdir` and `touch` take
//                         effect), `web WebFetch|WebSearch`. Their final text says whether the change was made.

struct ChatRuleRow: Equatable {
    var behavior: String
    var source: String
    var rule: String
}

extension ChatEngine {
    // MARK: Layers

    var livePermissions: ChatObject? { liveSettings["permissions"] as? ChatObject }
    var liveAllow: [String] { livePermissions?["allow"] as? [String] ?? [] }
    var liveDeny: [String] { livePermissions?["deny"] as? [String] ?? [] }

    var outputStyle: String { liveSettings["outputStyle"] as? String ?? "default" }

    var availableOutputStyles: [String] {
        var styles = ["default", "Concise"]
        for directory in config.pluginDirs {
            let url = URL(fileURLWithPath: directory)
            let manifest = try? Data(contentsOf: url.appendingPathComponent(".claude-plugin/plugin.json"))
            guard let plugin = (manifest.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? ChatObject)?["name"] as? String
            else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("output-styles").path)) ?? []
            for file in files.sorted() where file.hasSuffix(".md") {
                let text = (try? String(contentsOf: url.appendingPathComponent("output-styles/" + file), encoding: .utf8)) ?? ""
                let named = text.split(separator: "\n").first { $0.hasPrefix("name:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                styles.append("\(plugin):\(named ?? String(file.dropLast(3)))")
            }
        }
        return styles
    }

    /// Every rule the CLI would list: Loom's launch and live layers, then the user's own.
    func permissionRuleRows() -> [ChatObject] {
        var rows: [ChatRuleRow] = []
        for rule in config.launchAllow + liveAllow { rows.append(ChatRuleRow(behavior: "allow", source: "flagSettings", rule: rule)) }
        for rule in config.launchDeny + liveDeny { rows.append(ChatRuleRow(behavior: "deny", source: "flagSettings", rule: rule)) }
        rows += config.userRules
        return rows.map { row in
            ["behavior": row.behavior, "source": row.source, "rule": row.rule,
             "description": ["prefix": "", "emphasis": row.rule, "suffix": ""] as ChatObject,
             "editability": row.source == "flagSettings" ? "readonly" : "persistent"]
        }
    }

    private var allowRules: [String] {
        config.launchAllow + liveAllow + config.userRules.filter { $0.behavior == "allow" }.map(\.rule)
    }

    // MARK: Control requests

    func setPermissionMode(id: String, body: ChatObject) {
        let requested = body["mode"] as? String ?? ""
        let mode = requested == "manual" ? "default" : requested
        guard ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"].contains(mode) else {
            send(wire.controlError(
                id, "Invalid permission mode: must be one of acceptEdits, auto, bypassPermissions, default, dontAsk, plan",
                code: "invalid_mode"))
            return
        }
        if config.failModes.contains(mode) {
            send(wire.controlError(id, "The mode could not be changed", code: "fail_mode"))
            return
        }
        if mode == "bypassPermissions", !config.allowBypass {
            let disabled = (livePermissions?["disableBypassPermissionsMode"] as? Bool) == true
            send(wire.controlError(
                id, disabled ? "Bypass permissions mode is disabled by settings"
                    : "The session was not launched with --dangerously-skip-permissions",
                code: disabled ? "bypass_disabled" : "bypass_not_launched"))
            return
        }
        permissionMode = mode
        send(wire.status(nil, permissionMode: mode))
        send(wire.controlSuccess(id, ["mode": mode]))
    }

    func applyFlagSettings(id: String, body: ChatObject) {
        guard let settings = body["settings"] as? ChatObject else {
            send(wire.controlError(id, "apply_flag_settings requires `settings` to be an object"))
            return
        }
        if let style = settings["outputStyle"] as? String, !availableOutputStyles.contains(style) {
            // A style no plugin provides: the CLI does not know it.
            send(wire.controlError(id, "Unknown output style: \(style)", code: "invalid_output_style"))
            return
        }
        for (key, value) in settings {
            if value is NSNull { liveSettings[key] = nil } else { liveSettings[key] = value }
        }
        // A request that fails halfway: the rules are in, the style is not (the answer is an error).
        if config.failAskRules, settings["outputStyle"] is String {
            liveSettings["outputStyle"] = nil
            send(wire.controlError(id, "The settings could not be applied", code: "fail_settings"))
            return
        }
        if let model = settings["model"] as? String { wire.model = model }
        if let effort = settings["effortLevel"] as? String { config.effort = effort }
        if settings["effortLevel"] is NSNull { config.effort = nil }
        // A one-way door: Full access is gone for this process, the mode drops to `default`, and the launch flag no longer helps.
        if (livePermissions?["disableBypassPermissionsMode"] as? Bool) == true {
            config.allowBypass = false
            if permissionMode == "bypassPermissions" {
                permissionMode = "default"
                send(wire.status(nil, permissionMode: "default"))
            }
        }
        send(wire.controlSuccess(id, [:]))
    }

    // MARK: Deciding a tool call

    enum Gate {
        case run
        /// The CLI asks the host (`can_use_tool`).
        case ask
        /// Refused with no request: `reasonType` is `mode` or `rule`.
        case refuse(reasonType: String, message: String)
    }

    private static let editTools: Set<String> = ["Write", "Edit", "NotebookEdit"]

    func subject(of tool: String, _ input: ChatObject) -> String {
        tool == "Bash" ? "Bash with command \(input["command"] as? String ?? "")" : tool
    }

    func gate(tool: String, input: ChatObject) -> Gate {
        let names = subject(of: tool, input)
        if (config.launchDeny + liveDeny).contains(where: { Self.ruleMatches($0, tool: tool, input: input) }) {
            return .refuse(reasonType: "rule", message: "Permission to use \(names) has been denied.")
        }
        let allowed = allowRules.contains { Self.ruleMatches($0, tool: tool, input: input) }
        let readOnly = Self.isReadOnly(tool: tool, input: input)
        switch permissionMode {
        case "bypassPermissions", "auto":
            return .run
        case "dontAsk":
            if allowed || readOnly { return .run }
            return .refuse(reasonType: "mode", message: "Permission to use \(names) has been denied because Claude Code is "
                + "running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools that "
                + "might naturally be used to accomplish this goal. If you believe this capability is essential to complete "
                + "the user's request, STOP and explain to the user what you were trying to do and why you need this "
                + "permission. Let the user decide how to proceed.")
        case "acceptEdits":
            if Self.editTools.contains(tool) || allowed || readOnly { return .run }
            return .ask
        default:
            return allowed || readOnly ? .run : .ask
        }
    }

    /// `Bash(touch:*)` is a prefix rule, `Bash(ls)` an exact one, a bare tool name every call of the tool.
    static func ruleMatches(_ rule: String, tool: String, input: ChatObject) -> Bool {
        let parts = rule.split(separator: "(", maxSplits: 1).map(String.init)
        guard parts.first == tool else { return false }
        guard parts.count == 2, parts[1].hasSuffix(")") else { return true }
        let content = String(parts[1].dropLast())
        guard tool == "Bash", let command = input["command"] as? String else { return false }
        if content.hasSuffix(":*") {
            let prefix = String(content.dropLast(2))
            return command == prefix || command.hasPrefix(prefix + " ")
        }
        return command == content
    }

    static func isReadOnly(tool: String, input: ChatObject) -> Bool {
        switch tool {
        case "Read", "Glob", "Grep": return true
        case "Bash": return isReadOnlyBash(input["command"] as? String ?? "")
        default: return false
        }
    }

    /// The CLI's own read-only classifier, as S9 saw it: plain `ls`, `cat`, `grep`, `git log`, `git status` and the like run;
    /// a redirection, a writer joined with `&&`, `|` or `;`, `sed -i`, `find -delete`, an interpreter, `tee` or an output flag
    /// does not.
    static func isReadOnlyBash(_ command: String) -> Bool {
        guard !command.contains(">"), !command.contains("--output"), !command.contains("$(") else { return false }
        var parts = [command]
        for separator in ["&&", "||", ";", "|"] { parts = parts.flatMap { $0.components(separatedBy: separator) } }
        return parts.allSatisfy { part in
            let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first else { return false }
            switch first {
            case "ls", "cat", "grep", "rg", "head", "tail", "wc", "pwd", "echo", "tree", "which", "stat", "file", "du":
                return true
            case "git":
                return ["log", "status", "diff", "show"].contains(words.dropFirst().first ?? "")
            case "find":
                return !words.contains { ["-delete", "-exec", "-execdir", "-fprint"].contains($0) }
            default:
                return false
            }
        }
    }

    // MARK: A refused call

    /// The CLI's refusal: no request to the host, the call's result is the error, the event says why, and the call is listed
    /// in the turn's `permission_denials`. The turn goes on and ends in success.
    func refuseCall(id: String, tool: String, input: ChatObject, reasonType: String, message: String) {
        send(wire.permissionDenied(tool: tool, toolUseID: id, message: message, reasonType: reasonType))
        denials.append(["tool_name": tool, "tool_use_id": id, "tool_input": input])
        toolResult(id, message, error: true, structured: "Error: " + message, refusal: "permission-rule")
    }

    /// One tool call decided by the rules: it runs (`effect` gives its result), asks the host, or is refused. True when it ran.
    @discardableResult
    func gatedStep(name: String, input: ChatObject, lead: String, effect: (ChatObject) -> (text: String, structured: Any?)) throws -> Bool {
        let id = nextToolID()
        let decision = gate(tool: name, input: input)
        var ask = PermissionAsk.answered([:])
        try assistantMessage([.text(lead), .tool(id: id, name: name, input: input)]) {
            if case .ask = decision {
                ask = requestPermission(tool: name, input: input, toolUseID: id, description: input["description"] as? String,
                                        reason: "This tool needs approval in this mode")
            }
        }
        switch decision {
        case .run:
            break
        case let .refuse(reasonType, message):
            refuseCall(id: id, tool: name, input: input, reasonType: reasonType, message: message)
            try toolBoundary()
            return false
        case .ask:
            let answer = try awaitPermission(ask, toolUseID: id)
            guard answer["behavior"] as? String == "allow" else {
                try deny(id: id, tool: name, input: input, answer: answer)
                return false
            }
        }
        try runTool(id, name: name, milliseconds: 15)
        let result = effect(input)
        toolResult(id, result.text, structured: result.structured)
        try toolBoundary()
        return true
    }

    // MARK: Scenarios

    /// What the model says after a change it tried: made, or (in Ask, by its style) said to be read-only.
    private func report(made: Bool, what: String) -> String {
        if made { return "Done: \(what)." }
        return outputStyle.hasSuffix(":Ask") ? "The change is not made. Ask mode is read-only; leave Ask and I can make it."
            : "Nothing changed: \(what) was not allowed."
    }

    /// `file <name> <text>`: a Write in the work folder.
    func fileScenario(_ args: [String]) throws {
        let name = args.first ?? "made.txt"
        let content = args.dropFirst().joined(separator: " ")
        let path = config.cwd + "/" + name
        let made = try gatedStep(name: "Write", input: ["file_path": path, "content": content], lead: "I'll write \(name).") { input in
            try? (input["content"] as? String ?? "").write(toFile: path, atomically: true, encoding: .utf8)
            return ("File created successfully at: \(path)",
                    ["type": "create", "filePath": path, "content": content, "structuredPatch": [] as [Any],
                     "originalFile": NSNull(), "userModified": false] as ChatObject)
        }
        try assistantMessage([.text(report(made: made, what: "wrote \(name)"))])
    }

    /// `run <command>`: a Bash call; `mkdir <dir>` and `touch <file>` take effect in the work folder.
    func runScenario(command: String) throws {
        let made = try gatedStep(name: "Bash", input: ["command": command, "description": "Run a command"],
                                 lead: "I'll run it.") { input in
            let words = (input["command"] as? String ?? "").split(separator: " ").map(String.init)
            if words.count == 2, words[0] == "mkdir" {
                try? FileManager.default.createDirectory(atPath: config.cwd + "/" + words[1], withIntermediateDirectories: true)
            } else if words.count == 2, words[0] == "touch" {
                FileManager.default.createFile(atPath: config.cwd + "/" + words[1], contents: Data())
            }
            return ("", Self.bash(stdout: ""))
        }
        try assistantMessage([.text(report(made: made, what: "ran the command"))])
    }

    /// `bg-agent [ms]`: an Agent that runs in the background. The turn ends at once; when the agent ends (after `ms`) the CLI
    /// starts a turn by itself (S9b), and in it the model tries to write the agent's report (`fileScenario`).
    func backgroundAgentScenario(milliseconds: Int) throws {
        let tool = nextToolID()
        let agent = "a" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        let run = "run-" + UUID().uuidString.lowercased().prefix(8)
        let description = "Survey the module"
        try assistantMessage([
            .text("I'll start the survey in the background."),
            .tool(id: tool, name: "Agent", input: [
                "description": description, "subagent_type": "explorer", "prompt": "Survey the module.",
                "run_in_background": true,
            ]),
        ])
        send(wire.taskStarted(taskID: agent, runID: run, toolUseID: tool, description: description, type: "local_agent",
                              subagentType: "explorer", prompt: "Survey the module."))
        background.append(BackgroundTask(taskID: agent, runID: run, toolUseID: tool, description: description,
                                         due: Date().addingTimeInterval(Double(milliseconds) / 1_000), isAgent: true))
        send(wire.backgroundTasksChanged(backgroundList()))
        send(wire.taskUpdated(taskID: agent, runID: run, patch: ["is_backgrounded": true]))
        toolResult(tool, "Async agent launched successfully. agentId: \(agent)",
                   structured: ["status": "async_launched", "agentId": agent, "description": description] as ChatObject)
        try toolBoundary()
        try assistantMessage([.text("The survey runs in the background.")])
    }

    /// `web WebFetch|WebSearch`: a research call.
    func webScenario(tool: String) throws {
        let input: ChatObject = tool == "WebSearch" ? ["query": "example domain"] : ["url": "https://example.com", "prompt": "Summarize"]
        let ran = try gatedStep(name: tool, input: input, lead: "Let me look it up.") { _ in
            ("Example Domain: this domain is for use in illustrative examples.", nil)
        }
        try assistantMessage([.text(ran ? "It says: Example Domain." : "I could not look it up: \(tool) was not allowed.")])
    }
}
