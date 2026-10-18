import Darwin
import Foundation

// Development/test fixture, chat mode: behaves like `claude -p --input-format stream-json
// --output-format stream-json --verbose --include-partial-messages --replay-user-messages
// --permission-prompt-tool stdio` without a model. NDJSON user messages and control requests come in on
// stdin; NDJSON goes out on stdout. A user message picks a scenario by its text (ChatScenarios.swift):
// `/scenario <name> [args]`, `/clear`, `/compact`, anything else is a plain streamed answer. Wire shapes:
// ChatWire.swift.
//
// Environment: LOOM_FAKE_CHAT_DELAY_MS (pause between stream events, default 2), LOOM_FAKE_CHAT_CAPABILITIES
// (comma list for `system/init`; `msg_lifecycle_v1` also gates `command_lifecycle`), LOOM_FAKE_CHAT_INIT
// (`silent`, `exit`, `exit-on-resume`), LOOM_FAKE_CHAT_IGNORE_INTERRUPT (`1`),
// CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS / CLAUDE_CODE_SDK_READS_SESSION_STATE (`1`: emit
// `system/session_state_changed`), CLAUDE_CONFIG_DIR (transcripts are written under it unless
// `--no-session-persistence`).
//
// Behavior of the 2.1.300 recordings (S1): nothing is printed until input; `initialize` is answered at once;
// a send is `queued` at accept, and `started` + `system/init` + the `isReplay` echo come when Claude reads
// it. User-message priority:
//   next (or absent)  waits for the whole running tool, then joins the running turn; if the turn ends first
//                     it starts the next turn.
//   later             waits for the turn's end and then starts its own turn (never coalesced).
//   now + origin human  a running Bash moves to the background and the message is read at once, in the same
//                     turn; the task's later completion arrives as a task notification. A stream, or any
//                     other tool, is cut or finished first and the turn ends (aborted_*).
//   now without origin  the running tool finishes, then the turn ends and the message starts the next turn.
// Closing stdin lets the running turn finish (a pending `can_use_tool` fails as a tool error), then exits 0.
// Order as the CLI writes it (S1 t04): a `can_use_tool` comes before its message's `message_delta`/`message_stop`, and
// the turn's `rate_limit_event` right after its first message. With CLAUDE_CONFIG_DIR set, the process keeps a session
// registry entry (`sessions/<pid>.json`, `entrypoint: sdk-cli`, busy while a turn runs) as a stream child does.
// Hooks fire for a stream child too (S1 §D7): with `--settings` naming a hook command, SessionStart, UserPromptSubmit,
// PermissionRequest and Stop run it like the terminal mode does (Stop right after the `result`).

typealias ChatObject = ChatWire.Object

/// How a running turn ends early. Thrown out of every wait inside a scenario.
enum TurnEnd: Error {
    case interrupted
    case abortedByNow
}

struct ChatConfig {
    var sessionID: String
    var resumed: Bool
    var model: String
    var permissionMode: String
    var effort: String?
    var partial: Bool
    var replay: Bool
    var permissionHost: Bool
    var allowBypass: Bool
    var persist: Bool
    var cwd: String
    var configDir: String?
    var capabilities: [String]
    var delayMs: Int
    var emitState: Bool
    var stateHostOnly: Bool
    /// The hook command of `--settings` (Loom's helper), if any.
    var hookHelper: String?
    /// LOOM_FAKE_CHAT_INIT: `silent` never answers `initialize`; `exit` writes one stderr line and exits 1 at once
    /// (a start or resume that fails before Ready); `exit-on-resume` does so only when resumed.
    var initBehavior: String?
    /// LOOM_FAKE_CHAT_IGNORE_INTERRUPT=1: an interrupt is answered but the running turn goes on (a CLI slow to stop).
    var ignoreInterrupt: Bool
    /// The launch layer of permission rules (`--settings` permissions, `--disallowedTools`): never removable live (S9).
    var launchAllow: [String]
    var launchDeny: [String]
    /// `--plugin-dir` folders: their `output-styles/*.md` are listed as `<plugin>:<Name>`.
    var pluginDirs: [String]
    /// LOOM_FAKE_CHAT_USER_RULES: a JSON list of `{behavior, source, rule}` the user's own settings hold (user, project, local
    /// or policy), which `list_permission_rules` shows with their source.
    var userRules: [ChatRuleRow]
    /// LOOM_FAKE_CHAT_FAIL_MODE: a comma list of modes `set_permission_mode` refuses (a request that fails halfway).
    var failModes: Set<String>
    /// LOOM_FAKE_CHAT_FAIL_ASK_RULES=1: `apply_flag_settings` refuses the settings that turn Ask's style on.
    var failAskRules: Bool
    /// LOOM_FAKE_CHAT_RESET_FORGETS_SETTINGS=1: a `conversation_reset` drops the live settings (the unmeasured worst case).
    var resetForgetsSettings: Bool
    /// LOOM_FAKE_CHAT_RESET_ORDER=init-first: a reset writes `system/init` before the SessionStart hook runs (the real CLI
    /// writes the reset, then the hook, then `system/init`; the hook reaches Loom by another road, so either order can arrive).
    var resetInitFirst: Bool
    /// LOOM_FAKE_CHAT_INIT_DELAY_MS: `initialize` is answered after this long (a start that stays in Starting for a while).
    var initDelayMs: Int
    /// LOOM_FAKE_CHAT_CONTROL_DELAY_MS: the mode, settings and rule requests are answered after this long (a window for races).
    var controlDelayMs: Int

    init(arguments: [String], environment: [String: String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        resumed = value("--resume") != nil
        sessionID = value("--resume") ?? value("--session-id") ?? UUID().uuidString.lowercased()
        model = value("--model") ?? "claude-fake-5-1"
        permissionMode = value("--permission-mode") ?? "default"
        effort = value("--effort")
        partial = arguments.contains("--include-partial-messages")
        replay = arguments.contains("--replay-user-messages")
        permissionHost = value("--permission-prompt-tool") == "stdio"
        allowBypass = arguments.contains("--allow-dangerously-skip-permissions")
        persist = !arguments.contains("--no-session-persistence")
        cwd = FileManager.default.currentDirectoryPath
        configDir = environment["CLAUDE_CONFIG_DIR"]
        capabilities = environment["LOOM_FAKE_CHAT_CAPABILITIES"].map { $0.split(separator: ",").map(String.init) }
            ?? ["interrupt_receipt_v1", "interrupt_cancel_queued_v1", "interrupt_send_now_v1", "msg_lifecycle_v1",
                "request_marker_lists_v1", "sdk_mcp_tools_list_changed", "sdk_mcp_manifests", "mcp_read_resource_v1",
                "mcp_tool_ui_meta_v1", "ui_surface_v1"]
        delayMs = environment["LOOM_FAKE_CHAT_DELAY_MS"].flatMap(Int.init) ?? 2
        let emit = environment["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] == "1"
        let reads = environment["CLAUDE_CODE_SDK_READS_SESSION_STATE"] == "1"
        emitState = emit || reads
        stateHostOnly = reads && !emit
        let settings = value("--settings").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? ChatObject
        let start = ((settings?["hooks"] as? ChatObject)?["SessionStart"] as? [ChatObject])?.first
        hookHelper = ((start?["hooks"] as? [ChatObject])?.first?["command"]) as? String
        initBehavior = environment["LOOM_FAKE_CHAT_INIT"]
        ignoreInterrupt = environment["LOOM_FAKE_CHAT_IGNORE_INTERRUPT"] == "1"
        let permissions = settings?["permissions"] as? ChatObject
        var disallowed: [String] = []
        if let at = arguments.firstIndex(where: { $0 == "--disallowedTools" || $0 == "--disallowed-tools" }) {
            disallowed = Array(arguments[(at + 1)...].prefix { !$0.hasPrefix("--") })
        }
        launchDeny = (permissions?["deny"] as? [String] ?? []) + disallowed
        launchAllow = permissions?["allow"] as? [String] ?? []
        pluginDirs = arguments.indices.filter { arguments[$0] == "--plugin-dir" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
        failModes = Set((environment["LOOM_FAKE_CHAT_FAIL_MODE"] ?? "").split(separator: ",").map(String.init))
        failAskRules = environment["LOOM_FAKE_CHAT_FAIL_ASK_RULES"] == "1"
        resetForgetsSettings = environment["LOOM_FAKE_CHAT_RESET_FORGETS_SETTINGS"] == "1"
        resetInitFirst = environment["LOOM_FAKE_CHAT_RESET_ORDER"] == "init-first"
        initDelayMs = environment["LOOM_FAKE_CHAT_INIT_DELAY_MS"].flatMap(Int.init) ?? 0
        controlDelayMs = environment["LOOM_FAKE_CHAT_CONTROL_DELAY_MS"].flatMap(Int.init) ?? 0
        userRules = (environment["LOOM_FAKE_CHAT_USER_RULES"]
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [ChatObject] ?? []).compactMap { row in
            guard let behavior = row["behavior"] as? String, let source = row["source"] as? String,
                  let rule = row["rule"] as? String else { return nil }
            return ChatRuleRow(behavior: behavior, source: source, rule: rule)
        }
    }
}

/// A user message the host sent.
struct ChatUser {
    var uuid: String
    var content: Any
    var text: String
    var priority: String
    var origin: ChatObject?

    var isHuman: Bool { origin?["kind"] as? String == "human" }
}

enum ChatInbound {
    case user(ChatUser)
    case control(id: String, subtype: String, body: ChatObject)
    case response(id: String, payload: ChatObject)
    case cancel(String)
    case ignored
    case eof
}

/// Lines from stdin, handed from the reader thread to the engine.
final class ChatInbox: @unchecked Sendable {
    enum Item: Sendable {
        case line(Data)
        case eof
    }

    private let condition = NSCondition()
    private var lines: [Data] = []
    private var closed = false

    func push(_ line: Data) {
        condition.lock()
        lines.append(line)
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The next line, `.eof` once input ended and every line was taken, or nil when `timeout` ran out.
    /// A nil timeout waits for as long as it takes.
    func next(timeout: TimeInterval?) -> Item? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while lines.isEmpty, !closed {
            if let deadline {
                if !condition.wait(until: deadline) { break }
            } else {
                condition.wait()
            }
        }
        if !lines.isEmpty { return .line(lines.removeFirst()) }
        return closed ? .eof : nil
    }

    func startReading() {
        Thread.detachNewThread { [self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(0, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if count == 0 { break }
                var start = 0
                for index in 0..<count where buffer[index] == 0x0A {
                    pending.append(contentsOf: buffer[start..<index])
                    if !pending.isEmpty { push(pending) }
                    pending = Data()
                    start = index + 1
                }
                pending.append(contentsOf: buffer[start..<count])
            }
            if !pending.isEmpty { push(pending) }
            close()
        }
    }
}

func chatWrite(_ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = write(1, base + offset, raw.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { usleep(1_000); continue }
                exit(0) // the host went away
            }
            offset += count
        }
    }
}

/// `$CLAUDE_CONFIG_DIR/projects/<cwd with non-alphanumerics as '-'>/<session>.jsonl`, plus a subagent's
/// `<session>/subagents/agent-<id>.{jsonl,meta.json}`, as the terminal mode's `/subagent` writes them.
final class ChatTranscript {
    private let directory: URL?
    private var sessionID: String

    init(config: ChatConfig) {
        sessionID = config.sessionID
        let folder = String(config.cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        directory = config.persist
            ? config.configDir.map { URL(fileURLWithPath: $0).appendingPathComponent("projects/\(folder)", isDirectory: true) }
            : nil
    }

    func switchSession(_ id: String) { sessionID = id }

    func append(_ record: ChatObject, agent: String? = nil) {
        guard let directory else { return }
        let url = agent.map {
            directory.appendingPathComponent("\(sessionID)/subagents/agent-\($0).jsonl")
        } ?? directory.appendingPathComponent("\(sessionID).jsonl")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        let line = ChatWire.line(record)
        line.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }

    func writeMeta(agent: String, type: String, description: String) {
        guard let directory else { return }
        let folder = directory.appendingPathComponent("\(sessionID)/subagents", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta: ChatObject = ["agentType": type, "description": description, "spawnDepth": 1, "requestShape": "foreground"]
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) else { return }
        try? data.write(to: folder.appendingPathComponent("agent-\(agent).meta.json"))
    }
}

/// How the scenario wants the turn's `result` to read, when it is not a plain success.
struct ChatOutcome {
    var subtype = "success"
    var isError = false
    var terminalReason: String? = "completed"
    var apiErrorStatus: Int?
    var text: String?
    var errors: [String] = []
}

/// The tool a turn is running right now. Only a Bash can move to the background.
final class RunningTool {
    let id: String
    let movable: Bool
    let description: String
    let due: Date
    var taskID: String?
    var runID = ""
    var moved = false

    init(id: String, movable: Bool, description: String, due: Date) {
        self.id = id
        self.movable = movable
        self.description = description
        self.due = due
    }
}

struct BackgroundTask {
    var taskID: String
    var runID: String
    var toolUseID: String
    var description: String
    var due: Date
    /// A background subagent (S9b): its end starts a turn in which the model goes on with its report.
    var isAgent = false
}

struct AgentInfo {
    var id: String
    var type: String
    var description: String
}

final class ChatEngine {
    var config: ChatConfig
    var wire: ChatWire
    let inbox = ChatInbox()
    let transcript: ChatTranscript
    var permissionMode: String

    /// Sends accepted and not yet read, in arrival order.
    var unread: [ChatUser] = []
    /// `now` sends that moved a Bash to the background: read at the next boundary.
    var readNow: [ChatUser] = []
    var abortAfterTool = false
    var sentTexts: [String: String] = [:]
    var responses: [String: ChatObject] = [:]
    var pendingIDs: [String] = []
    /// The next `finishTurn` leaves the waiting requests alone (the `orphan` scenario).
    var keepPendingAtEnd = false
    var requestCounter = 0
    var toolCounter = 0

    var sessionBusy = false
    var inputClosed = false
    var running = false
    var currentTool: RunningTool?
    var awaitingPermission = false
    var background: [BackgroundTask] = []
    var interruptedInTool = false
    var turnUUIDs: [String] = []
    var turnStarted = Date()
    var outputTokens = 0
    var denials: [ChatObject] = []
    var finalText = ""
    var outcome = ChatOutcome()
    var rateLimitStatus = "allowed"
    var rateLimitSent = false
    var prePlanMode: String?
    /// The live settings layer of `apply_flag_settings` (S9): a top-level key is replaced as a whole, `null` removes it. It is
    /// merged with the launch layer, never over it.
    var liveSettings: ChatObject = [:]
    /// `permissions.disableBypassPermissionsMode` was set live: Full access is gone for this process (a one-way door).
    var bypassDisabled = false
    var cost = 0.0
    var lastUUID: String?
    var lastAssistantUUID: String?
    /// The Agent tool_use id of a subagent that is running, to its identity.
    var subagents: [String: AgentInfo] = [:]

    let registryStartedAt = Date()
    let slashCommands = ["compact", "clear", "context", "review", "init"]
    let skills = ["fake-skill"]
    var tools: [String] {
        let all = ["Agent", "Bash", "Edit", "Read", "Write", "NotebookEdit", "Glob", "Grep", "WebFetch", "WebSearch",
                   "AskUserQuestion", "ExitPlanMode", "TodoWrite"]
        // Without a permission host the CLI removes the tools that need a person (S1 Q1). A rule given at launch removes a
        // tool from the list; the same rule applied live leaves it there and refuses the call (S9).
        let available = config.permissionHost ? all : all.filter { $0 != "AskUserQuestion" && $0 != "ExitPlanMode" }
        return available.filter { !config.launchDeny.contains($0) }
    }

    init(config: ChatConfig) {
        self.config = config
        wire = ChatWire(session: config.sessionID, model: config.model)
        transcript = ChatTranscript(config: config)
        permissionMode = config.permissionMode
    }

    // MARK: Output

    func send(_ object: ChatObject) { chatWrite(ChatWire.line(object)) }

    func sendInit() {
        send(wire.initMessage(
            permissionMode: permissionMode, cwd: config.cwd, tools: tools, slashCommands: slashCommands, skills: skills,
            capabilities: config.capabilities, effort: config.effort, outputStyle: outputStyle))
    }

    func lifecycle(_ uuid: String, _ state: String) {
        if config.capabilities.contains("msg_lifecycle_v1") { send(wire.commandLifecycle(uuid: uuid, state: state)) }
    }

    func sessionState(_ state: String) {
        if config.emitState { send(wire.sessionState(state, hostOnly: config.stateHostOnly)) }
    }

    func echo(_ message: ChatUser) {
        if config.replay { send(wire.userEcho(uuid: message.uuid, content: message.content, origin: message.origin)) }
    }

    /// Sends a `user` or `assistant` record and writes it to the transcript (a subagent's to its own file).
    func emitMessage(_ object: ChatObject, agent: String? = nil) {
        send(object)
        guard let type = object["type"] as? String, let message = object["message"] as? ChatObject,
              let uuid = object["uuid"] as? String else { return }
        var extra: ChatObject = [:]
        if let structured = object["tool_use_result"] { extra["toolUseResult"] = structured }
        if let kind = (object["tool_result_meta"] as? [ChatObject])?.first?["non_execution_kind"] { extra["toolDenialKind"] = kind }
        transcript.append(wire.transcriptRecord(
            type: type, uuid: uuid, message: message, parentUUID: agent == nil ? lastUUID : nil, cwd: config.cwd,
            agentID: agent, extra: extra), agent: agent)
        if agent == nil { lastUUID = uuid }
        if type == "assistant", agent == nil { lastAssistantUUID = uuid }
    }

    func recordUser(_ message: ChatUser) {
        transcript.append(wire.transcriptRecord(
            type: "user", uuid: message.uuid, message: ["role": "user", "content": message.content],
            parentUUID: lastUUID, cwd: config.cwd, extra: ["permissionMode": permissionMode, "origin": ["kind": "human"]]))
        lastUUID = message.uuid
    }

    /// When each send arrived (the `queued_command` attachment carries it).
    var arrivals: [String: Date] = [:]

    /// The transcript's queue bookkeeping (S1 t07): `enqueue` when a send arrives, `dequeue` when it starts a turn,
    /// `remove` when a running turn absorbed it.
    func recordQueueOperation(_ operation: String, _ fields: ChatObject = [:]) {
        var record: ChatObject = ["type": "queue-operation", "operation": operation, "sessionId": wire.session,
                                  "timestamp": ChatWire.timestamp()]
        record.merge(fields) { _, new in new }
        transcript.append(record)
    }

    /// A send a running turn read at a tool boundary, as the CLI writes it (S1 t07-priority-next and -now): not a `user`
    /// record under the stdin uuid, but an `attachment` of type `queued_command` with a uuid of its own whose
    /// `source_uuid` is the stdin uuid, then a `queue-operation` `remove` with reason `absorbed_mid_turn`.
    func recordAbsorbed(_ message: ChatUser) {
        let uuid = wire.uuid(), delivery = wire.uuid()
        let arrived = ChatWire.timestamp(arrivals[message.uuid] ?? Date())
        transcript.append([
            "type": "attachment", "uuid": uuid, "parentUuid": ChatWire.orNull(lastUUID), "sessionId": wire.session,
            "cwd": config.cwd, "isSidechain": false, "userType": "external", "entrypoint": "sdk-cli",
            "version": "2.1.300-fake", "timestamp": ChatWire.timestamp(),
            "attachment": [
                "type": "queued_command", "prompt": message.text, "source_uuid": message.uuid, "delivery_id": delivery,
                "commandMode": "prompt", "origin": ["kind": "human"], "timestamp": arrived, "humanTurn": true,
            ] as ChatObject,
        ])
        lastUUID = uuid
        recordQueueOperation("remove", ["content": message.text, "reason": "absorbed_mid_turn", "commandUuid": message.uuid,
                                        "deliveryId": delivery])
    }

    /// The turn's one `rate_limit_event`: after its first message, or before the `result` of a turn without one.
    func sendRateLimit() {
        guard !rateLimitSent else { return }
        rateLimitSent = true
        send(wire.rateLimit(
            status: rateLimitStatus, resetsAt: Int(Date().timeIntervalSince1970) + 3_600, type: "five_hour",
            utilization: rateLimitStatus == "allowed" ? 0.41 : rateLimitStatus == "allowed_warning" ? 0.85 : 1.0))
    }

    /// `$CLAUDE_CONFIG_DIR/sessions/<pid>.json` as a stream child writes it: `entrypoint: sdk-cli`.
    func registry(_ status: String) {
        guard let folder = config.configDir else { return }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &process, &length, nil, 0) == 0 else { return }
        let birth = Date(timeIntervalSince1970: Double(process.kp_proc.p_starttime.tv_sec))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let directory = URL(fileURLWithPath: folder).appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let object: ChatObject = [
            "kind": "interactive", "entrypoint": "sdk-cli", "pidDomain": "darwin", "procStart": format.string(from: birth),
            "startedAt": floor(registryStartedAt.timeIntervalSince1970 * 1_000), "sessionId": wire.session,
            "cwd": config.cwd, "status": status,
            "statusUpdatedAt": floor(Date().timeIntervalSince1970 * 1_000),
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: object) else { return }
        let fd = open(directory.appendingPathComponent("\(getpid()).json").path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        bytes.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    /// Sends one hook event through the hook command, like the CLI does (and waits for it).
    func hook(_ event: String, _ fields: ChatObject = [:]) {
        guard let helper = config.hookHelper else { return }
        var payload: ChatObject = ["session_id": wire.session, "hook_event_name": event, "cwd": config.cwd]
        payload.merge(fields) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    // MARK: Input

    func decode(_ item: ChatInbox.Item) -> ChatInbound {
        guard case .line(let data) = item else { return .eof }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? ChatObject,
              let type = object["type"] as? String else { return .ignored }
        switch type {
        case "user":
            let content = (object["message"] as? ChatObject)?["content"] ?? ""
            var text = content as? String ?? ""
            if let blocks = content as? [ChatObject] {
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            let priority = ["later", "now"].contains(object["priority"] as? String ?? "") ? object["priority"] as! String : "next"
            return .user(ChatUser(
                uuid: object["uuid"] as? String ?? wire.uuid(), content: content, text: text, priority: priority,
                origin: object["origin"] as? ChatObject))
        case "control_request":
            guard let id = object["request_id"] as? String else { return .ignored }
            let request = object["request"] as? ChatObject ?? [:]
            return .control(id: id, subtype: request["subtype"] as? String ?? "", body: request)
        case "control_response":
            guard let response = object["response"] as? ChatObject, let id = response["request_id"] as? String else {
                return .ignored
            }
            if response["subtype"] as? String == "success" { return .response(id: id, payload: response["response"] as? ChatObject ?? [:]) }
            return .response(id: id, payload: ["behavior": "deny", "message": response["error"] as? String ?? "Request failed"])
        case "control_cancel_request":
            return (object["request_id"] as? String).map { .cancel($0) } ?? .ignored
        default:
            return .ignored
        }
    }

    /// Takes one inbound item. While a turn runs, this is where an interrupt or a `now` send stops it.
    func handle(_ inbound: ChatInbound) throws {
        switch inbound {
        case .ignored:
            break
        case .user(let message):
            sentTexts[message.uuid] = message.text
            arrivals[message.uuid] = Date()
            recordQueueOperation("enqueue", ["content": message.text])
            if !sessionBusy { sessionBusy = true; sessionState("running") }
            lifecycle(message.uuid, "queued")
            guard running, message.priority == "now" else {
                unread.append(message)
                return
            }
            if let tool = currentTool, !awaitingPermission {
                if message.isHuman, tool.movable, moveToBackground() {
                    readNow.append(message)
                } else {
                    unread.insert(message, at: 0)
                    abortAfterTool = true // the tool finishes first
                }
            } else {
                unread.insert(message, at: 0)
                throw TurnEnd.abortedByNow
            }
        case .control(let id, let subtype, let body):
            try handleControl(id: id, subtype: subtype, body: body)
        case .response(let id, let payload):
            responses[id] = payload
        case .cancel(let id):
            if pendingIDs.contains(id) { responses[id] = ["behavior": "deny", "message": "Cancelled by the host"] }
        case .eof:
            inputClosed = true
        }
    }

    func handleControl(id: String, subtype: String, body: ChatObject) throws {
        switch subtype {
        case "initialize":
            if config.initBehavior == "silent" { return }
            if config.initDelayMs > 0 { usleep(UInt32(config.initDelayMs) * 1_000) }
            send(wire.controlSuccess(id, wire.initializeResponse(
                slashCommands: slashCommands, model: wire.model, permissionMode: permissionMode,
                state: sessionBusy ? "running" : "idle", pid: getpid(),
                // The real answer lists only ui_surface_v1; the ten capabilities come in system/init (S1 Q4).
                capabilities: config.capabilities.filter { $0 == "ui_surface_v1" },
                outputStyle: outputStyle, availableStyles: availableOutputStyles)))
        case "interrupt":
            // A request that waits for the host is withdrawn before the interrupt is answered (S1 t09-pending-interrupt).
            let withdrew = !pendingIDs.isEmpty
            for pending in pendingIDs { send(wire.controlCancel(pending)) }
            pendingIDs = []
            let cancel = (body["cancel_queued"] as? Bool ?? false) && config.capabilities.contains("interrupt_cancel_queued_v1")
            let queued = unread.map(\.uuid)
            if cancel {
                unread.removeAll()
                for uuid in queued { lifecycle(uuid, "cancelled") }
                send(wire.controlSuccess(id, ["still_queued": [] as [String], "cancelled": queued]))
            } else {
                send(wire.controlSuccess(id, ["still_queued": queued]))
            }
            if withdrew { sessionState("running") } // the turn works again, on its way out (t09-pending-interrupt:28)
            if running, !config.ignoreInterrupt { throw TurnEnd.interrupted }
        case "cancel_async_message":
            // Unsends one message the CLI holds and has not read.
            let uuid = body["message_uuid"] as? String
            if let index = unread.firstIndex(where: { $0.uuid == uuid }) {
                lifecycle(unread.remove(at: index).uuid, "cancelled")
                send(wire.controlSuccess(id, ["cancelled": true]))
            } else {
                send(wire.controlSuccess(id, ["cancelled": false]))
            }
        case "set_permission_mode":
            if config.controlDelayMs > 0 { usleep(UInt32(config.controlDelayMs) * 1_000) }
            setPermissionMode(id: id, body: body)
        case "set_model":
            wire.model = (body["model"] as? String).flatMap { $0 == "default" ? nil : $0 } ?? config.model
            send(wire.controlSuccess(id, [:]))
        case "apply_flag_settings":
            if config.controlDelayMs > 0 { usleep(UInt32(config.controlDelayMs) * 1_000) }
            applyFlagSettings(id: id, body: body)
        case "list_permission_rules":
            if config.controlDelayMs > 0 { usleep(UInt32(config.controlDelayMs) * 1_000) }
            send(wire.controlSuccess(id, ["state": ["rules": permissionRuleRows()] as ChatObject]))
        case "background_tasks":
            // The Ctrl+B equivalent: a running Bash goes to the background.
            if running { _ = moveToBackground() }
            send(wire.controlSuccess(id, [:]))
        case "side_question":
            // No lifecycle, no turn, nothing in the transcript.
            send(wire.controlProgress(id))
            send(wire.controlSuccess(id, wire.sideQuestionResponse(body["question"] as? String ?? "")))
        case "rewind_files":
            send(wire.controlSuccess(id, wire.rewindFilesResponse(dryRun: body["dry_run"] as? Bool ?? false)))
        case "rewind_conversation":
            let target = body["target_message_uuid"] as? String ?? ""
            send(wire.controlSuccess(id, wire.rewindConversationResponse(
                target: target, prefill: sentTexts[target] ?? "", preceding: lastAssistantUUID ?? wire.uuid())))
        case "get_usage":
            send(wire.controlSuccess(id, wire.usageResponse()))
        default:
            send(wire.controlError(id, "Unsupported control request: \(subtype)"))
        }
    }

    // MARK: Waiting

    /// The next inbox item. After the end of input nothing more arrives, so it only sleeps.
    func poll(_ timeout: TimeInterval?) -> ChatInbox.Item? {
        if inputClosed {
            if let timeout, timeout > 0 { usleep(UInt32(min(timeout, 0.05) * 1_000_000)) }
            return nil
        }
        return inbox.next(timeout: timeout)
    }

    /// Waits for one input item, for at most `maxWait` (nil: until something arrives), and runs what falls due.
    func serviceOnce(maxWait: TimeInterval?) throws {
        if running { deliverDueBackground() }
        var wait = maxWait
        if let due = background.map(\.due).min() {
            let remaining = max(0, due.timeIntervalSinceNow)
            wait = wait.map { min($0, remaining) } ?? remaining
        }
        if let item = poll(wait) { try handle(decode(item)) }
    }

    /// Waits `milliseconds` and takes whatever arrives meanwhile. With 0, only what already arrived.
    func pause(_ milliseconds: Int) throws {
        if milliseconds <= 0 {
            if running { deliverDueBackground() }
            while let item = poll(0) { try handle(decode(item)) }
            return
        }
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1_000)
        while deadline.timeIntervalSinceNow > 0 { try serviceOnce(maxWait: deadline.timeIntervalSinceNow) }
    }

    // MARK: Background tasks

    func announce(_ tool: RunningTool) {
        guard tool.taskID == nil else { return }
        tool.taskID = "b" + UUID().uuidString.lowercased().prefix(8)
        tool.runID = "run-" + UUID().uuidString.lowercased().prefix(8)
        send(wire.taskStarted(
            taskID: tool.taskID!, runID: tool.runID, toolUseID: tool.id, description: tool.description, type: "local_bash"))
    }

    func backgroundList() -> [ChatObject] {
        background.map {
            ["task_id": $0.taskID, "run_id": $0.runID, "task_type": $0.isAgent ? "local_agent" : "local_bash",
             "description": $0.description]
        }
    }

    /// Moves the running Bash to the background; it is not interrupted and finishes on its own clock.
    @discardableResult
    func moveToBackground() -> Bool {
        guard let tool = currentTool, tool.movable, !tool.moved, !awaitingPermission else { return false }
        announce(tool)
        tool.moved = true
        background.append(BackgroundTask(
            taskID: tool.taskID!, runID: tool.runID, toolUseID: tool.id, description: tool.description, due: tool.due))
        send(wire.backgroundTasksChanged(backgroundList()))
        send(wire.taskUpdated(taskID: tool.taskID!, runID: tool.runID, patch: ["is_backgrounded": true]))
        return true
    }

    /// A background task finished: its events, then the notification told to the model.
    func completeBackground(_ task: BackgroundTask) {
        background.removeAll { $0.taskID == task.taskID }
        let summary = task.isAgent ? "Agent \"\(task.description)\" completed"
            : "Background command \"\(task.description)\" completed (exit code 0)"
        send(wire.taskUpdated(taskID: task.taskID, runID: task.runID, patch: [
            "status": "completed", "end_time": Int(Date().timeIntervalSince1970 * 1_000)]))
        send(wire.taskNotification(
            taskID: task.taskID, runID: task.runID, toolUseID: task.toolUseID, status: "completed", summary: summary))
        send(wire.backgroundTasksChanged(backgroundList()))
        send(wire.taskNotificationUser(
            taskID: task.taskID, toolUseID: task.toolUseID, summary: summary, runID: task.runID))
    }

    func deliverDueBackground() {
        for task in background where task.due <= Date() { completeBackground(task) }
    }

    // MARK: Turns

    func run() -> Never {
        if config.initBehavior == "exit" || (config.initBehavior == "exit-on-resume" && config.resumed) {
            FileHandle.standardError.write(Data("Error: the fake CLI could not start (LOOM_FAKE_CHAT_INIT=exit)\nmore detail\n".utf8))
            exit(1)
        }
        inbox.startReading()
        registry("idle")
        hook("SessionStart", ["source": config.resumed ? "resume" : "startup"])
        while true {
            if !unread.isEmpty {
                runTurn(unread.removeFirst())
                continue
            }
            if let task = background.first(where: { $0.due <= Date() }) {
                runTurn(nil, finished: task)
                continue
            }
            if inputClosed, background.isEmpty { exit(0) }
            try? serviceOnce(maxWait: inputClosed ? 0.05 : nil)
        }
    }

    /// A turn for `first`, or (without one) the turn a finished background task starts by itself.
    func runTurn(_ first: ChatUser?, finished: BackgroundTask? = nil) {
        running = true
        currentTool = nil
        awaitingPermission = false
        abortAfterTool = false
        interruptedInTool = false
        turnUUIDs = first.map { [$0.uuid] } ?? []
        turnStarted = Date()
        outputTokens = 0
        denials = []
        finalText = ""
        outcome = ChatOutcome()
        rateLimitStatus = "allowed"
        rateLimitSent = false
        prePlanMode = nil
        registry("busy")
        if !sessionBusy { sessionBusy = true; sessionState("running") }
        if let first {
            lifecycle(first.uuid, "started")
            hook("UserPromptSubmit", ["prompt_id": first.uuid])
            sendInit()
            send(wire.statusRequesting(turnUUIDs))
            echo(first)
            recordQueueOperation("dequeue")
            recordUser(first)
        } else if let finished {
            completeBackground(finished)
            sendInit()
            send(wire.statusRequesting([]))
        }
        do {
            if let first {
                try runScenario(first.text)
            } else if finished?.isAgent == true {
                // S9b: the model goes on with the agent's report, and tries to write it down.
                try fileScenario(["agent-report.txt", "Survey findings"])
            } else {
                try assistantMessage([.text("The background command finished.")])
            }
            finishTurn(nil)
        } catch let end as TurnEnd {
            finishTurn(end)
        } catch {
            finishTurn(.interrupted)
        }
    }

    func finishTurn(_ end: TurnEnd?) {
        // `orphan` leaves its request waiting across the turn's `result`, which the CLI never does: a host must not
        // retire a card on a result (V18).
        if !keepPendingAtEnd {
            for id in pendingIDs { send(wire.controlCancel(id)) }
            pendingIDs = []
            responses = [:]
        }
        keepPendingAtEnd = false
        let millis = Int(Date().timeIntervalSince(turnStarted) * 1_000)
        cost += 0.0123
        let terminal = interruptedInTool ? "aborted_tools" : "aborted_streaming"
        switch end {
        case nil:
            // A failed API call (not a rate-limit block) has no rate-limit event, and its command is cancelled, not
            // completed (S1 t19-err-badmodel:7-9).
            let failedCall = outcome.terminalReason == "api_error"
            if !failedCall || rateLimitStatus == "rejected" { sendRateLimit() }
            send(wire.result(
                subtype: outcome.subtype, isError: outcome.isError, text: outcome.text ?? finalText, durationMs: millis,
                stopReason: "end_turn", terminalReason: outcome.terminalReason, apiErrorStatus: outcome.apiErrorStatus,
                cost: cost, outputTokens: outputTokens, denials: denials, errors: outcome.errors, userUUIDs: turnUUIDs,
                queued: unread.count))
            for uuid in turnUUIDs { lifecycle(uuid, failedCall ? "cancelled" : "completed") }
            hook("Stop", ["last_assistant_message": "done"])
        case .interrupted?:
            // An interrupt is an error without text; its commands end cancelled.
            if !interruptedInTool { send(wire.userText("[Request interrupted by user]")) }
            send(wire.result(
                subtype: "error_during_execution", isError: true, text: nil, durationMs: millis, stopReason: nil,
                terminalReason: terminal, apiErrorStatus: nil, cost: cost, outputTokens: outputTokens, denials: denials,
                errors: [], userUUIDs: turnUUIDs, queued: unread.count))
            for uuid in turnUUIDs { lifecycle(uuid, "cancelled") }
        case .abortedByNow?:
            // A `now` send ends the turn as a success with the partial text; the message starts the next turn. S1 §0.9
            // says such a result carries `is_error: true` (the t07/t23 recordings show false): the fake sends true, the
            // harder shape, and Loom decides on its own interrupt alone.
            send(wire.result(
                subtype: "success", isError: true, text: finalText, durationMs: millis,
                stopReason: interruptedInTool ? "tool_use" : nil, terminalReason: terminal, apiErrorStatus: nil,
                cost: cost, outputTokens: outputTokens, denials: denials, errors: [], userUUIDs: turnUUIDs,
                queued: unread.count))
            for uuid in turnUUIDs { lifecycle(uuid, "cancelled") }
        }
        running = false
        readNow = []
        registry("idle")
        if unread.isEmpty {
            sessionBusy = false
            sessionState("idle")
        }
    }

    // MARK: Boundaries

    /// A tool boundary: the tool that ran is finished. A `now` send that waited for it ends the turn here;
    /// `next` sends and `now` sends that moved a Bash to the background are read by the running turn.
    func toolBoundary() throws {
        try pause(0)
        if abortAfterTool {
            interruptedInTool = true
            throw TurnEnd.abortedByNow
        }
        let next = unread.filter { $0.priority == "next" }
        let joined = readNow + next
        readNow = []
        guard !joined.isEmpty else { return }
        unread.removeAll { $0.priority == "next" }
        for message in joined {
            turnUUIDs.append(message.uuid)
            echo(message)
            lifecycle(message.uuid, "started")
            send(wire.statusRequesting(turnUUIDs))
            recordAbsorbed(message)
        }
        try assistantMessage([.text("Joined your message: " + joined.map(\.text).joined(separator: " / "))])
    }

    // MARK: Building blocks

    enum Block {
        case text(String)
        case thinking(String)
        case tool(id: String, name: String, input: ChatObject)
    }

    func nextToolID() -> String {
        toolCounter += 1
        return "toolu_fake\(toolCounter)"
    }

    func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= size { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    func agentExtra(_ parent: String?) -> ChatObject {
        parent.flatMap { subagents[$0] }.map { wire.agentFields(id: $0.id, type: $0.type, description: $0.description) } ?? [:]
    }

    /// One API message: its blocks stream as partial events (main thread only, with
    /// `--include-partial-messages`) and each completed block is an `assistant` record. A pause after every
    /// delta lets an interrupt land mid-stream; the text sent so far then becomes an `aborted` message.
    /// `beforeStop` runs after the last block and before `message_delta`/`message_stop`: where the CLI sends a
    /// `can_use_tool` for the message's tool call.
    func assistantMessage(_ blocks: [Block], parent: String? = nil, beforeStop: () -> Void = {}) throws {
        let messageID = "msg_fake" + UUID().uuidString.lowercased().prefix(8)
        let agent = parent.flatMap { subagents[$0]?.id }
        let extra = agentExtra(parent)
        let streaming = config.partial && parent == nil
        func stream(_ event: ChatObject) {
            if streaming { send(wire.streamEvent(event, parent: parent, apiMessageID: messageID)) }
        }
        stream(wire.messageStart(id: messageID))
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            let final: ChatObject
            var weight = 1
            switch block {
            case .text(let text):
                stream(wire.blockStart(index: index, block: ["type": "text", "text": ""]))
                var sent = ""
                do {
                    for piece in chunks(text, size: 10) {
                        sent += piece
                        stream(wire.blockDelta(index: index, delta: ["type": "text_delta", "text": piece]))
                        try pause(config.delayMs)
                    }
                } catch {
                    if parent == nil, !sent.isEmpty {
                        finalText = sent
                        var aborted = extra
                        aborted["aborted"] = true
                        emitMessage(wire.assistant(
                            messageID: messageID, block: ["type": "text", "text": sent], stopReason: nil,
                            outputTokens: max(1, sent.count / 4), parent: parent, extra: aborted))
                    }
                    throw error
                }
                stream(wire.blockStop(index: index))
                final = ["type": "text", "text": text]
                weight = text.count
                if parent == nil { finalText = text }
            case .thinking(let text):
                stream(wire.blockStart(index: index, block: ["type": "thinking", "thinking": "", "signature": ""]))
                for piece in chunks(text, size: 10) {
                    stream(wire.blockDelta(index: index, delta: ["type": "thinking_delta", "thinking": piece]))
                    try pause(config.delayMs)
                }
                stream(wire.blockDelta(index: index, delta: ["type": "signature_delta", "signature": "fake-signature"]))
                stream(wire.blockStop(index: index))
                final = ["type": "thinking", "thinking": text, "signature": "fake-signature"]
                weight = text.count
            case .tool(let id, let name, let input):
                stream(wire.blockStart(index: index, block: ["type": "tool_use", "id": id, "name": name, "input": [:] as ChatObject]))
                let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                for piece in chunks(json, size: max(1, json.count / 3 + 1)) {
                    stream(wire.blockDelta(index: index, delta: ["type": "input_json_delta", "partial_json": piece]))
                    try pause(config.delayMs)
                }
                stream(wire.blockStop(index: index))
                final = ["type": "tool_use", "id": id, "name": name, "input": input]
                weight = json.count
            }
            let tokens = max(1, weight / 4)
            outputTokens += tokens
            var stopReason: String?
            if isLast {
                if case .tool = block { stopReason = "tool_use" } else { stopReason = "end_turn" }
            }
            emitMessage(wire.assistant(
                messageID: messageID, block: final, stopReason: stopReason, outputTokens: tokens, parent: parent,
                extra: extra), agent: agent)
        }
        beforeStop()
        var lastStop = "end_turn"
        if case .tool? = blocks.last { lastStop = "tool_use" }
        stream(wire.messageDelta(stopReason: lastStop, outputTokens: outputTokens))
        stream(wire.messageStop())
        if parent == nil { sendRateLimit() }
    }

    /// `refusal` (`user-rejected`, `permission-rule`) marks a call a permission decision refused, as the CLI does in the
    /// record's `tool_result_meta` (and `toolDenialKind` in the transcript); the text of a deny with a note is the note alone.
    func toolResult(_ id: String, _ content: Any, error: Bool = false, structured: Any? = nil, parent: String? = nil,
                    refusal: String? = nil) {
        var extra = agentExtra(parent)
        if let refusal {
            extra["tool_result_meta"] = [["id": id, "non_execution_kind": refusal,
                                          "permission_decision": ["decision": "reject", "source": "user_reject"] as ChatObject] as ChatObject]
        }
        emitMessage(wire.toolResult(
            toolUseID: id, content: content, isError: error, structured: structured, parent: parent,
            extra: extra), agent: parent.flatMap { subagents[$0]?.id })
    }

    /// An interrupt, a `now` send or a pending request cut a tool short: the CLI answers the tool_use with a
    /// rejection and says why.
    func abortTool(_ id: String, parent: String?, tool: RunningTool?) {
        let first = !interruptedInTool
        interruptedInTool = true
        if let tool, let taskID = tool.taskID, !tool.moved {
            send(wire.taskNotification(
                taskID: taskID, runID: tool.runID, toolUseID: id, status: "stopped", summary: tool.description))
        }
        toolResult(id, "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a "
            + "file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user "
            + "to tell you how to proceed.", error: true, structured: "User rejected tool use", parent: parent,
            refusal: "user-rejected")
        if first { send(wire.userText("[Request interrupted by user for tool use]")) }
    }

    func whileTool<T>(_ id: String, parent: String? = nil, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            abortTool(id, parent: parent, tool: nil)
            throw error
        }
    }

    /// Runs the tool for `milliseconds`, interruptibly. A Bash running a second or more announces itself
    /// (`task_started`). Returns the tool; `moved` says it went to the background instead of finishing.
    @discardableResult
    func runTool(
        _ id: String, name: String = "Bash", description: String = "", milliseconds: Int, parent: String? = nil
    ) throws -> RunningTool {
        let tool = RunningTool(
            id: id, movable: name == "Bash" && parent == nil, description: description,
            due: Date().addingTimeInterval(Double(milliseconds) / 1_000))
        currentTool = tool
        defer { currentTool = nil }
        if tool.movable, milliseconds >= 1_000 { announce(tool) }
        do {
            repeat {
                try serviceOnce(maxWait: max(0, tool.due.timeIntervalSinceNow))
            } while !tool.moved && tool.due > Date()
        } catch {
            abortTool(id, parent: parent, tool: tool)
            throw error
        }
        if let taskID = tool.taskID, !tool.moved {
            send(wire.taskNotification(
                taskID: taskID, runID: tool.runID, toolUseID: id, status: "completed", summary: tool.description))
        }
        return tool
    }

    /// A tool_use (after optional leading blocks of the same message), its run, its result and the boundary.
    func toolStep(
        id: String, name: String, input: ChatObject, milliseconds: Int = 15, leading: [Block] = [],
        content: Any, error: Bool = false, structured: Any? = nil
    ) throws {
        try assistantMessage(leading + [.tool(id: id, name: name, input: input)])
        // The rules refuse what they refuse in every scenario (`dontAsk` with no request to the host, a deny rule), as the CLI
        // does; what would ask the host runs here as it always did, so the older scenarios stay as they were.
        if case let .refuse(reasonType, message) = gate(tool: name, input: input) {
            refuseCall(id: id, tool: name, input: input, reasonType: reasonType, message: message)
            try toolBoundary()
            return
        }
        let tool = try runTool(id, name: name, description: input["description"] as? String ?? name, milliseconds: milliseconds)
        if tool.moved, let taskID = tool.taskID {
            var moved = Self.bash(stdout: "")
            moved["backgroundTaskId"] = taskID
            toolResult(id, "Command was moved to the background (ID: \(taskID)) so that a message that arrived while it "
                + "was running can reach you; it was not interrupted. You will be notified when it completes.", structured: moved)
        } else {
            toolResult(id, content, error: error, structured: structured)
        }
        try toolBoundary()
    }

    /// A permission request on its way: answered already (no permission host), or waiting under its request id.
    enum PermissionAsk {
        case answered(ChatObject)
        case pending(String)
    }

    /// Sends a `can_use_tool` request and waits for the host's answer, interruptibly. Without a permission
    /// host (`--permission-prompt-tool stdio`) the CLI denies on its own, so no request is sent. If input
    /// ends while it waits, the request fails as a tool error and the turn goes on (`failed: true`).
    func askPermission(
        tool: String, input: ChatObject, toolUseID: String, description: String? = nil, suggestions: [ChatObject] = [],
        reason: String? = nil, agentID: String? = nil, requiresInteraction: Bool = false, parent: String? = nil
    ) throws -> ChatObject {
        let ask = requestPermission(
            tool: tool, input: input, toolUseID: toolUseID, description: description, suggestions: suggestions,
            reason: reason, agentID: agentID, requiresInteraction: requiresInteraction)
        return try awaitPermission(ask, toolUseID: toolUseID, parent: parent)
    }

    /// Sends the request only (the CLI sends it before its message's `message_stop`); `awaitPermission` waits.
    func requestPermission(
        tool: String, input: ChatObject, toolUseID: String, description: String? = nil, suggestions: [ChatObject] = [],
        reason: String? = nil, agentID: String? = nil, requiresInteraction: Bool = false
    ) -> PermissionAsk {
        guard config.permissionHost else {
            let message = "Claude requested permissions to use \(tool), but you haven't granted it yet."
            send(wire.permissionDenied(tool: tool, toolUseID: toolUseID, message: message))
            return .answered(["behavior": "deny", "message": message])
        }
        requestCounter += 1
        let id = "fake-req-\(requestCounter)"
        pendingIDs.append(id)
        // The state change comes first, then the request (S1 t08-interrupt-cancelqueued:19-20).
        sessionState("requires_action")
        hook("PermissionRequest", ["tool_name": tool])
        send(wire.canUseTool(
            requestID: id, tool: tool, input: input, toolUseID: toolUseID, description: description,
            suggestions: suggestions, reason: reason, agentID: agentID, requiresInteraction: requiresInteraction))
        return .pending(id)
    }

    func awaitPermission(_ ask: PermissionAsk, toolUseID: String, parent: String? = nil) throws -> ChatObject {
        guard case let .pending(id) = ask else {
            if case let .answered(answer) = ask { return answer }
            return [:]
        }
        awaitingPermission = true
        defer { awaitingPermission = false }
        let payload = try whileTool(toolUseID, parent: parent) { () throws -> ChatObject in
            while responses[id] == nil {
                if inputClosed {
                    responses[id] = [
                        "behavior": "deny", "failed": true,
                        "message": "Tool permission request failed: AbortError: Tool permission stream closed before response received",
                    ]
                    break
                }
                try serviceOnce(maxWait: nil)
            }
            return responses[id] ?? [:]
        }
        responses[id] = nil
        pendingIDs.removeAll { $0 == id }
        sessionState("running")
        return payload
    }
}

func runFakeChat(arguments: [String]) -> Never {
    signal(SIGPIPE, SIG_IGN)
    let config = ChatConfig(arguments: arguments, environment: ProcessInfo.processInfo.environment)
    if config.resumed, config.sessionID.hasPrefix("missing") {
        FileHandle.standardError.write(Data("No conversation found with session ID: \(config.sessionID)\n".utf8))
        exit(1)
    }
    ChatEngine(config: config).run()
}
