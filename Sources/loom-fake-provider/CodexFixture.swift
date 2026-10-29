import CryptoKit
import Darwin
import Dispatch
import Foundation

// A tiny stand-in for `codex app-server` (Unix-socket WebSocket, JSON-RPC) and
// for the remote `codex` TUI. No model is involved: turns are timers. Tests
// steer it through prompt text ("work 500", "approve", "fail").

private let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

private func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: Framing

private func sendAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes {
            Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        }
        if count > 0 { offset += count }
        else if count < 0 && errno == EINTR { continue }
        else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(1_000) }
        else { return false }
    }
    return true
}

private func frame(_ opcode: UInt8, _ payload: [UInt8], masked: Bool) -> [UInt8] {
    var bytes: [UInt8] = [0x80 | opcode]
    let flag: UInt8 = masked ? 0x80 : 0
    if payload.count < 126 { bytes.append(flag | UInt8(payload.count)) }
    else if payload.count <= 65_535 { bytes += [flag | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)] }
    else {
        bytes.append(flag | 127)
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((UInt64(payload.count) >> shift) & 0xff)) }
    }
    if masked {
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        bytes += mask
        bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    } else { bytes += payload }
    return bytes
}

/// Parses client (masked) or server (unmasked) frames into text messages.
private struct FrameParser {
    var input: [UInt8] = []
    var closed = false

    mutating func messages() -> [String] {
        var result: [String] = []
        while input.count >= 2 {
            let opcode = input[0] & 0x0f
            let masked = input[1] & 0x80 != 0
            var length = Int(input[1] & 0x7f)
            var offset = 2
            if length == 126 {
                guard input.count >= 4 else { break }
                length = Int(input[2]) << 8 | Int(input[3]); offset = 4
            } else if length == 127 {
                guard input.count >= 10 else { break }
                length = input[2..<10].reduce(0) { ($0 << 8) | Int($1) }; offset = 10
            }
            var mask: [UInt8] = []
            if masked {
                guard input.count >= offset + 4 else { break }
                mask = Array(input[offset..<(offset + 4)]); offset += 4
            }
            guard input.count >= offset + length else { break }
            var payload = Array(input[offset..<(offset + length)])
            if masked { payload = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] } }
            input.removeFirst(offset + length)
            switch opcode {
            case 1: result.append(String(decoding: payload, as: UTF8.self))
            case 8: closed = true
            default: break
            }
        }
        return result
    }
}

private func json(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}

private func encode(_ object: [String: Any]) -> [UInt8] {
    Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
}

// MARK: Server

private struct FakeTurn {
    let id: String
    var status = "inProgress"
    var items: [[String: Any]] = []
    let startedAt = Date().timeIntervalSince1970
}

private struct FakeThread {
    let id: String
    let cwd: String
    var turns: [FakeTurn] = []
    var active = false
    var flags: [String] = []
    var model = "fake-codex-alpha"
    var effort = "low"
    var sandbox = "read-only"
    var approval = "on-request"
    var networkAccess = false
    var writableRoots: [String] = []
    var reviewer = "user"
}

private final class FakeTaskCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, String, String)] = []
    func add(thread: String, turn: String, message: String) {
        lock.withLock { if values.count < 64 { values.append((thread, turn, message)) } }
    }
    func take() -> [(String, String, String)] {
        lock.withLock { let result = values; values.removeAll(); return result }
    }
}

private final class FakeServerConnection {
    let descriptor: Int32
    var parser = FrameParser()
    var upgraded = false
    var handshake: [UInt8] = []
    var resumedThreads: Set<String> = []
    var initializeData: Data?
    var observerMethods: [String] = []
    /// `capabilities.optOutNotificationMethods` from this connection's initialize.
    var optOutMethods: Set<String> = []
    var observerParamsValid = true

    init(_ descriptor: Int32) { self.descriptor = descriptor }

    func send(_ object: [String: Any]) {
        _ = sendAll(descriptor, frame(1, encode(object), masked: false))
    }
}

func runCodexServer(socketPath: String, config: [String: String]) -> Never {
    let state = ProcessInfo.processInfo.environment["LOOM_FAKE_STATE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let taskCompletions = FakeTaskCompletions()
    if ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_SERVER_ESCAPE"] != nil, let state {
        // A command the server started that left its session and carries no
        // ownership marker: only the run scope can still attribute it.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("600"), nil]
        defer { arguments.forEach { free($0) } }
        let status = posix_spawn(&pid, "/bin/sleep", nil, &attributes, &arguments, nil)
        posix_spawnattr_destroy(&attributes)
        if status == 0 {
            try? "\(pid)".write(to: state.appendingPathComponent("server-escape.\(getpid())"),
                                atomically: true, encoding: .utf8)
        }
    }
    unlink(socketPath)
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array(socketPath.utf8)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path + [0]) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, Darwin.listen(listener, 8) == 0 else { fail("cannot listen on \(socketPath): \(errno)") }
    guard chmod(socketPath, 0o600) == 0 else { fail("cannot secure socket") }
    var original = stat()
    guard lstat(socketPath, &original) == 0 else { fail("cannot inspect socket") }
    let device = original.st_dev, inode = original.st_ino
    var terminationSources: [DispatchSourceSignal] = []
    if ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_LEAVE_SOCKET"] == nil {
        for number in [SIGHUP, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler {
                var current = stat()
                if lstat(socketPath, &current) == 0, current.st_dev == device, current.st_ino == inode { unlink(socketPath) }
                exit(0)
            }
            source.resume()
            terminationSources.append(source)
        }
    }
    defer { terminationSources.forEach { $0.cancel() } }
    _ = fcntl(listener, F_SETFL, O_NONBLOCK)
    signal(SIGPIPE, SIG_IGN)
    out("FAKE-CODEX-SERVER LISTENING \(socketPath)\r\n")

    var connections: [FakeServerConnection] = []
    var threads: [String: FakeThread] = [:]
    var timers: [(due: Double, action: () -> Void)] = []
    var nextRequestID = 9_000
    var approvals: [Int: (thread: String, turn: String)] = [:]
    var lastResolution: (thread: String, request: Int)?
    var joinAttempts: [String: Int] = [:]
    var prepareFailures = 0
    var completedFailures = 0
    var extraSkillRoots: [String] = []

    func recordStopDiagnostic(_ line: String) {
        guard let state else { return }
        let url = state.appendingPathComponent("codex-joins.log")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func appendState(_ name: String, _ line: String) {
        guard let state else { return }
        let url = state.appendingPathComponent(name)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func recordFullRead(_ threadID: String) { appendState("codex-full-reads.log", threadID) }
    func recordTurnsList(_ params: [String: Any]) {
        appendState("codex-turns-list.log", "limit=\((params["limit"] as? Int).map(String.init) ?? "none") sort=\((params["sortDirection"] as? String) ?? "default")")
    }

    func applyPermissions(_ overrides: [String: String], to thread: inout FakeThread) {
        if let reviewer = overrides["approvals_reviewer"] { thread.reviewer = reviewer.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        if let network = overrides["sandbox_workspace_write.network_access"] { thread.networkAccess = network == "true" }
        if overrides["sandbox_workspace_write.writable_roots"] == "[]" { thread.writableRoots = [] }
    }

    func persist(_ thread: FakeThread) {
        guard let state else { return }
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try? thread.cwd.write(to: state.appendingPathComponent("codex-thread-\(thread.id).cwd"), atomically: true, encoding: .utf8)
        let values: [String: Any] = ["model": thread.model, "effort": thread.effort, "sandbox": thread.sandbox,
            "approval": thread.approval, "networkAccess": thread.networkAccess, "writableRoots": thread.writableRoots,
            "reviewer": thread.reviewer]
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            try? data.write(to: state.appendingPathComponent("codex-thread-\(thread.id).settings"), options: .atomic)
        }
    }

    func known(_ id: String) -> Bool {
        threads[id] != nil || (state.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("codex-thread-\(id).cwd").path) } ?? false)
    }

    func load(_ id: String) -> FakeThread? {
        if let thread = threads[id] { return thread }
        guard let state, let cwd = try? String(contentsOf: state.appendingPathComponent("codex-thread-\(id).cwd"), encoding: .utf8) else { return nil }
        var thread = FakeThread(id: id, cwd: cwd)
        if let data = try? Data(contentsOf: state.appendingPathComponent("codex-thread-\(id).settings")),
           let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            thread.model = (values["model"] as? String) ?? thread.model
            thread.effort = (values["effort"] as? String) ?? thread.effort
            thread.sandbox = (values["sandbox"] as? String) ?? thread.sandbox
            thread.approval = (values["approval"] as? String) ?? thread.approval
            thread.networkAccess = (values["networkAccess"] as? Bool) ?? false
            thread.writableRoots = (values["writableRoots"] as? [String]) ?? []
            thread.reviewer = (values["reviewer"] as? String) ?? "user"
        }
        threads[id] = thread
        return thread
    }

    func broadcast(_ method: String, _ params: [String: Any]) {
        for connection in connections where connection.upgraded {
            if connection.optOutMethods.contains(method) { continue }
            if method.hasPrefix("item/") || method == "thread/tokenUsage/updated",
               let threadID = params["threadId"] as? String,
               !connection.resumedThreads.contains(threadID) { continue }
            if method.hasPrefix("turn/"), let threadID = params["threadId"] as? String,
               !connection.resumedThreads.contains(threadID) { continue }
            connection.send(["method": method, "params": params])
        }
    }

    func status(_ thread: FakeThread) -> [String: Any] {
        thread.active ? ["type": "active", "activeFlags": thread.flags] : ["type": "idle"]
    }

    func announceStatus(_ thread: FakeThread) {
        broadcast("thread/status/changed", ["threadId": thread.id, "status": status(thread)])
    }

    func taskRolloutURL(_ threadID: String) -> URL? {
        guard ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_ROUNDS"] == "1",
              let home = ProcessInfo.processInfo.environment["CODEX_HOME"] else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("sessions/2026/10/29/rollout-2026-10-29T00-00-00-\(threadID).jsonl")
    }

    // Only the explicit task-round fixture writes this synthetic first-turn
    // rollout. Native Codex flushes these records before invoking its tool.
    func writeFirstTaskRollout(_ thread: FakeThread, turnID: String, text: String, clientID: String) {
        guard let file = taskRolloutURL(thread.id),
              ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_ROLLOUT"] != "missing" else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let client = ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_ROLLOUT"] == "wrong-client" ? "wrong" : clientID
            let objects: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": thread.id, "cwd": thread.cwd]],
                ["type": "event_msg", "payload": ["type": "task_started", "turn_id": turnID]],
                ["type": "event_msg", "payload": ["type": "user_message", "client_id": client, "message": text,
                    "images": [], "local_images": [], "audio": [], "local_audio": [], "text_elements": []]],
            ]
            var data = Data()
            for object in objects { data += try JSONSerialization.data(withJSONObject: object); data.append(0x0a) }
            if ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_ROLLOUT"] == "partial" { data.removeLast() }
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* The task helper must refuse when evidence is absent. */ }
    }

    func threadObject(_ thread: FakeThread, includeTurns: Bool) -> [String: Any] {
        var object: [String: Any] = ["id": thread.id, "cwd": thread.cwd, "status": status(thread),
                                     "originator": "codex-tui", "source": "cli", "ephemeral": false]
        if let path = taskRolloutURL(thread.id)?.path { object["path"] = path }
        if includeTurns {
            object["turns"] = thread.turns.map {
                ["id": $0.id, "status": $0.status, "items": $0.items, "startedAt": $0.startedAt] as [String: Any]
            }
        }
        return object
    }

    func resolve(_ requestID: Int) {
        guard let pending = approvals.removeValue(forKey: requestID) else { return }
        lastResolution = (pending.thread, requestID)
        broadcast("serverRequest/resolved", ["threadId": pending.thread, "requestId": requestID])
        if var thread = threads[pending.thread], !approvals.values.contains(where: { $0.thread == pending.thread }) {
            thread.flags = []
            threads[pending.thread] = thread
            announceStatus(thread)
        }
    }

    func complete(_ threadID: String, turnID: String, status: String, message: String) {
        guard var thread = threads[threadID], let index = thread.turns.firstIndex(where: { $0.id == turnID }),
              thread.turns[index].status == "inProgress" else { return }
        for id in approvals.filter({ $0.value.thread == threadID && $0.value.turn == turnID }).keys.sorted() {
            resolve(id)
        }
        thread.turns[index].status = status
        thread.turns[index].items = [["type": "agentMessage", "text": message]]
        thread.active = false
        thread.flags = []
        threads[threadID] = thread
        broadcast("turn/completed", ["threadId": threadID, "turn": [
            "id": turnID, "status": status, "items": [["type": "agentMessage", "text": message]],
        ] as [String: Any]])
        announceStatus(thread)
    }

    func handle(_ connection: FakeServerConnection, _ message: [String: Any]) {
        // A response to a server request (approval decision).
        if let id = message["id"] as? Int, message["method"] == nil, let pending = approvals[id] {
            resolve(id)
            let decision = ((message["result"] as? [String: Any])?["decision"] as? String) ?? "unknown"
            if let state {
                let line = "\(pending.thread) \(decision)\n"
                let url = state.appendingPathComponent("codex-approvals.log")
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (existing + line).write(to: url, atomically: true, encoding: .utf8)
            }
            if !approvals.values.contains(where: { $0.thread == pending.thread && $0.turn == pending.turn }) {
                complete(pending.thread, turnID: pending.turn, status: decision == "accept" ? "completed" : "interrupted",
                         message: decision == "accept" ? "approved" : "declined")
            }
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        let id = message["id"]
        if method == "initialize" {
            connection.initializeData = try? JSONSerialization.data(withJSONObject: params, options: .sortedKeys)
            let capabilities = params["capabilities"] as? [String: Any]
            connection.optOutMethods = Set((capabilities?["optOutNotificationMethods"] as? [String]) ?? [])
        }
        if let data = connection.initializeData, String(decoding: data, as: UTF8.self).contains("loom-observer-diagnosis") {
            connection.observerMethods.append(method)
            if method == "thread/read" || method == "thread/resume" {
                connection.observerParamsValid = connection.observerParamsValid && Set(params.keys) == ["threadId"]
            }
        }
        if let state {
            // Every request a connection makes, in order: a probe's audit that it asked only to read (never a thread or a turn).
            let url = state.appendingPathComponent("codex-methods.log")
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (old + "\(method)\n").write(to: url, atomically: true, encoding: .utf8)
        }
        func reply(_ result: [String: Any]) { if let id { connection.send(["id": id, "result": result]) } }
        func failure(_ code: Int, _ text: String) {
            if let id { connection.send(["id": id, "error": ["code": code, "message": text]]) }
        }
        switch method {
        case "initialize":
            if ProcessInfo.processInfo.environment["LOOM_FAKE_OBSERVER_PREPARATION"] == "timeout" { return }
            reply(["userAgent": "fake-codex-server/0.0.1 (fake)"])
        case "initialized":
            break
        case "skills/extraRoots/set":
            guard let roots = params["extraRoots"] as? [String], roots.allSatisfy({ $0.hasPrefix("/") }) else {
                failure(-32602, "invalid extra skill roots"); return
            }
            extraSkillRoots = roots
            broadcast("skills/changed", [:])
            reply([:])
        case "skills/list":
            let cwds = (params["cwds"] as? [String]) ?? []
            let extras: [[String: Any]] = extraSkillRoots.compactMap { root in
                let path = URL(fileURLWithPath: root).appendingPathComponent("sphyrna/SKILL.md").path
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return ["name": "sphyrna", "description": "fixture", "path": path, "scope": "user",
                        "enabled": ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_SKILL_DISABLED"] == nil]
            }
            let skills = [["name": "native-fixture", "description": "native", "path": "/fixture/native/SKILL.md",
                           "scope": "user", "enabled": true] as [String: Any]] + extras
            reply(["data": cwds.map { ["cwd": $0, "skills": skills, "errors": []] }])
        case "account/read", "account/rateLimits/read", "account/usage/read", "model/list":
            // The reads a probe makes (D-94): fixed answers, no network. LOOM_FAKE_CODEX_PROBE steers them: hang (account/read
            // never answers), signed-out, api-key, limits-error (account/rateLimits/read fails), paged (model/list in two pages).
            let mode = ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_PROBE"] ?? "ok"
            switch method {
            case "account/read":
                if mode == "hang" { return }
                switch mode {
                case "signed-out": reply(["account": NSNull(), "requiresOpenaiAuth": true])
                case "api-key": reply(["account": ["type": "apiKey"], "requiresOpenaiAuth": false])
                default: reply(["account": ["type": "chatgpt", "email": "probe@example.invalid", "planType": "pro"], "requiresOpenaiAuth": true])
                }
            case "account/rateLimits/read":
                if mode == "limits-error" { failure(-32603, "private-provider-error-text"); return }
                let codex: [String: Any] = [
                    "limitId": "codex", "limitName": NSNull(), "planType": "pro",
                    "primary": ["usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1_791_482_400],
                    "secondary": ["usedPercent": 61, "windowDurationMins": 10_080, "resetsAt": 1_791_795_600],
                ]
                let spark: [String: Any] = [
                    "limitId": "codex_spark", "limitName": "Spark", "planType": "pro",
                    "primary": ["usedPercent": 5, "windowDurationMins": 300, "resetsAt": 1_791_482_400], "secondary": NSNull(),
                ]
                reply(["rateLimits": codex, "rateLimitsByLimitId": ["codex": codex, "codex_spark": spark]])
            case "account/usage/read":
                reply(["summary": ["lifetimeTokens": 123_456_789, "peakDailyTokens": 3_400],
                       "dailyUsageBuckets": [["startDate": "2026-10-23", "tokens": 1_200], ["startDate": "2026-10-24", "tokens": 3_400]]])
            default:
                func model(_ slug: String, _ name: String, hidden: Bool = false, isDefault: Bool = false) -> [String: Any] {
                    ["id": slug, "model": slug, "displayName": name, "description": "", "hidden": hidden, "isDefault": isDefault,
                     "defaultReasoningEffort": "medium",
                     "supportedReasoningEfforts": ["low", "medium", "high"].map { ["reasoningEffort": $0, "description": ""] }]
                }
                let alpha = model("fake-codex-alpha", "Fake Codex Alpha", isDefault: true)
                let hidden = model("fake-codex-hidden", "Fake Codex Hidden", hidden: true)
                let beta = model("fake-codex-beta", "Fake Codex Beta")
                if mode == "paged" {
                    if (params["cursor"] as? String) == "page-2" { reply(["data": [beta], "nextCursor": NSNull()]) }
                    else { reply(["data": [alpha, hidden], "nextCursor": "page-2"]) }
                } else {
                    reply(["data": [alpha, hidden, beta], "nextCursor": NSNull()])
                }
            }
        case "thread/start":
            var thread = FakeThread(id: UUID().uuidString.lowercased(), cwd: (params["cwd"] as? String) ?? FileManager.default.currentDirectoryPath)
            if ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_GLOBAL_FULL"] != nil {
                thread.sandbox = "danger-full-access"
                thread.approval = "never"
            }
            if ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_GLOBAL_WIDENED"] != nil {
                thread.reviewer = "auto_review"
                thread.networkAccess = true
                thread.writableRoots = ["/synthetic-outside"]
            }
            applyPermissions(config, to: &thread)
            applyPermissions((params["config"] as? [String: String]) ?? [:], to: &thread)
            thread.model = (params["model"] as? String) ?? thread.model
            thread.effort = ((params["config"] as? [String: Any])?["model_reasoning_effort"] as? String) ?? thread.effort
            thread.sandbox = (params["sandbox"] as? String) ?? thread.sandbox
            thread.approval = (params["approvalPolicy"] as? String) ?? thread.approval
            if thread.sandbox == "read-only" { thread.networkAccess = false; thread.writableRoots = [] }
            threads[thread.id] = thread
            connection.resumedThreads.insert(thread.id)
            persist(thread)
            reply(["thread": threadObject(thread, includeTurns: false)])
            broadcast("thread/started", ["thread": threadObject(thread, includeTurns: false)])
        case "fixture/settings":
            let threadID = (params["threadId"] as? String) ?? ""
            guard var thread = load(threadID) else { failure(-32600, "thread not found: \(threadID)"); return }
            thread.model = (params["model"] as? String) ?? thread.model
            thread.effort = (params["effort"] as? String) ?? thread.effort
            thread.sandbox = (params["sandbox"] as? String) ?? thread.sandbox
            thread.approval = (params["approval"] as? String) ?? thread.approval
            thread.networkAccess = (params["networkAccess"] as? Bool) ?? thread.networkAccess
            thread.writableRoots = (params["writableRoots"] as? [String]) ?? thread.writableRoots
            thread.reviewer = (params["reviewer"] as? String) ?? thread.reviewer
            threads[threadID] = thread
            persist(thread)
            reply([:])
        case "fixture/resolve":
            let threadID = (params["threadId"] as? String) ?? ""
            let mode = (params["mode"] as? String) ?? "first"
            let ids = approvals.filter { $0.value.thread == threadID }.keys.sorted()
            if mode == "duplicate", let lastResolution {
                broadcast("serverRequest/resolved", ["threadId": lastResolution.thread, "requestId": lastResolution.request])
            } else if mode == "wrong-thread", let first = approvals.keys.sorted().first {
                broadcast("serverRequest/resolved", ["threadId": "unowned-thread", "requestId": first])
            } else if mode == "unknown" {
                broadcast("serverRequest/resolved", ["threadId": threadID, "requestId": -1])
            } else if mode == "all" {
                for id in ids { resolve(id) }
            } else if let id = ids.first { resolve(id) }
            // A trailing stream event lets tests observe that the serial
            // coordinator has finished consuming the preceding resolutions.
            broadcast("fixture/resolutionBarrier", [:])
            reply([:])
        case "fixture/endTurn":
            let threadID = (params["threadId"] as? String) ?? ""
            if let turnID = threads[threadID]?.turns.last?.id {
                complete(threadID, turnID: turnID, status: (params["status"] as? String) ?? "interrupted", message: "fixture-end")
            }
            reply([:])
        case "fixture/helper":
            let helper = FakeThread(id: UUID().uuidString.lowercased(), cwd: (params["cwd"] as? String) ?? "")
            var object = threadObject(helper, includeTurns: false)
            object["ephemeral"] = true
            object["source"] = "exec"
            object["originator"] = "private-originator-value"
            broadcast("thread/started", ["thread": object])
            broadcast("thread/status/changed", ["threadId": helper.id, "status": ["type": "systemError"]])
            announceStatus(helper)
            reply([:])
        case "fixture/observerProbe":
            let observers = connections.filter { $0.observerMethods.contains("initialize") }
            let audit: [String: Any] = [
                "twoObservers": observers.count == 2,
                "equalInitialize": observers.count == 2 && observers[0].initializeData == observers[1].initializeData,
                "readOnlyA": observers.first?.observerMethods == ["initialize", "initialized", "thread/read"],
                "resumeOnlyB": observers.last?.observerMethods == ["initialize", "initialized", "thread/resume"],
                "threadIdOnly": observers.allSatisfy { $0.observerParamsValid },
            ]
            if let state { try? JSONSerialization.data(withJSONObject: audit, options: .sortedKeys).write(to: state.appendingPathComponent("observer-audit.json")) }
            let threadID = (params["threadId"] as? String) ?? ""
            let mode = (params["mode"] as? String) ?? "both"
            if mode == "empty" { reply([:]); return }
            if mode != "empty" { broadcast("turn/started", ["threadId": threadID, "turn": ["id": "diagnostic-turn"]]) }
            if mode == "different-turn" {
                for other in connections where other.resumedThreads.contains(threadID) { other.send(["method": "turn/started", "params": ["threadId": threadID, "turn": ["id": "different-turn"]]]) }
            }
            let recipients = mode == "resume-only" ? connections.filter { $0.resumedThreads.contains(threadID) } : mode == "neither" ? [] : connections
            for other in recipients where other.upgraded {
                other.send(["id": 0, "method": "item/commandExecution/requestApproval", "params": [
                    "threadId": threadID, "turnId": "diagnostic-turn", "command": "private-command-canary",
                ]])
            }
            broadcast("private-unknown-method-canary", ["secret": "private-prompt-canary"])
            broadcast("item/commandExecution/requestApproval", ["threadId": "wrong-thread-canary"])
            for other in connections where other.upgraded {
                other.send(["id": 7, "method": "item/commandExecution/requestApproval", "params": ["threadId": "wrong-thread-canary"]])
            }
            broadcast("serverRequest/resolved", ["threadId": threadID, "requestId": 0])
            if mode == "flood" { for _ in 0..<300 { broadcast("private-unknown-method-canary", [:]) } }
            if mode == "disconnect" { for other in connections where other !== connection { other.parser.closed = true; shutdown(other.descriptor, SHUT_RDWR) } }
            reply([:])
        case "thread/resume":
            let threadID = (params["threadId"] as? String) ?? ""
            guard var thread = load(threadID) else { failure(-32600, "thread not found: \(threadID)"); return }
            let isTUI = connection.initializeData.map { String(decoding: $0, as: UTF8.self).contains("fake-codex-tui") } ?? false
            let mode = ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_JOIN"] ?? ""
            if !isTUI {
                joinAttempts[threadID, default: 0] += 1
                if let state {
                    let url = state.appendingPathComponent("codex-joins.log")
                    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    try? (old + "join \(threadID) \(params.keys.sorted().joined(separator: ","))\n").write(to: url, atomically: true, encoding: .utf8)
                }
                if mode == "blank-always" || (mode.hasPrefix("blank") && thread.turns.isEmpty)
                    || (mode == "blank-until-idle" && thread.active) {
                    failure(-32600, "no rollout found for thread \(threadID)"); return
                }
                if mode == "wrong" { reply(["thread": ["id": "wrong-thread"]]); return }
                if mode == "missing" { reply(["thread": [:]]); return }
                if mode == "error" { failure(-32001, "join failed"); return }
            }
            thread.model = (params["model"] as? String) ?? thread.model
            thread.effort = ((params["config"] as? [String: Any])?["model_reasoning_effort"] as? String) ?? thread.effort
            thread.sandbox = (params["sandbox"] as? String) ?? thread.sandbox
            thread.approval = (params["approvalPolicy"] as? String) ?? thread.approval
            threads[threadID] = thread
            persist(thread)
            let finish = {
                if !isTUI && mode == "delay-error" { failure(-32001, "late join failed"); return }
                connection.resumedThreads.insert(threadID)
                if !isTUI, let state {
                    let url = state.appendingPathComponent("codex-joins.log")
                    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    try? (old + "joined \(threadID)\n").write(to: url, atomically: true, encoding: .utf8)
                }
                if !isTUI && mode != "blank-no-replay" {
                    for (requestID, pending) in approvals.sorted(by: { $0.key < $1.key }) where pending.thread == threadID {
                        connection.send(["id": requestID, "method": "item/commandExecution/requestApproval",
                            "params": ["threadId": threadID, "turnId": pending.turn]])
                    }
                }
                if !isTUI && mode == "before-response" {
                    var active = thread
                    let turn = FakeTurn(id: "join-turn")
                    active.turns.append(turn)
                    active.active = true
                    threads[threadID] = active
                    nextRequestID += 1
                    approvals[nextRequestID] = (threadID, turn.id)
                    connection.send(["id": nextRequestID, "method": "item/commandExecution/requestApproval",
                        "params": ["threadId": threadID, "turnId": turn.id]])
                    broadcast("thread/started", ["thread": threadObject(thread, includeTurns: false)])
                }
                let sandboxType: String = switch thread.sandbox {
                case "read-only": "readOnly"
                case "workspace-write": "workspaceWrite"
                case "danger-full-access": "dangerFullAccess"
                default: "futurePolicy"
                }
                reply(["thread": threadObject(thread, includeTurns: false),
                       "cwd": !isTUI && mode == "wrong-cwd" ? "/different-cwd" : thread.cwd,
                       "model": thread.model, "reasoningEffort": thread.effort,
                       "sandbox": ["type": sandboxType, "networkAccess": thread.networkAccess, "writableRoots": thread.writableRoots],
                       "approvalPolicy": thread.approval, "approvalsReviewer": thread.reviewer])
            }
            if !isTUI && (mode.hasPrefix("delay") || mode == "blank-delay") {
                let delay = mode == "blank-delay" ? 1.5 : (Double(mode.dropFirst("delay".count)) ?? 0.3)
                timers.append((monotonic() + delay, finish))
            } else { finish() }
        case "thread/read":
            if ProcessInfo.processInfo.environment["LOOM_FAKE_OBSERVER_PREPARATION"] == "pre-turn" { broadcast("turn/started", ["threadId": (params["threadId"] as? String) ?? "", "turn": ["id": "diagnostic-turn"]]) }
            if ProcessInfo.processInfo.environment["LOOM_FAKE_OBSERVER_PREPARATION"] == "mismatch" { reply(["thread": ["id": "wrong-thread-canary"]]); return }
            let threadID = (params["threadId"] as? String) ?? ""
            guard let thread = load(threadID) else { failure(-32600, "thread not found: \(threadID)"); return }
            if (params["includeTurns"] as? Bool) == true { recordFullRead(threadID) }
            reply(["thread": threadObject(thread, includeTurns: (params["includeTurns"] as? Bool) ?? false)])
        case "thread/turns/list":
            let threadID = (params["threadId"] as? String) ?? ""
            guard let thread = load(threadID) else { failure(-32600, "thread not found: \(threadID)"); return }
            // Mirrors Codex 0.160: a thread without a first user message is not persisted.
            guard !thread.turns.isEmpty else {
                failure(-32600, "thread \(threadID) is not materialized yet; thread/turns/list is unavailable before first user message")
                return
            }
            recordTurnsList(params)
            var page = thread.turns
            if (params["sortDirection"] as? String) != "asc" { page.reverse() }
            if let limit = params["limit"] as? Int { page = Array(page.prefix(limit)) }
            reply(["data": page.map {
                ["id": $0.id, "status": $0.status, "items": $0.items, "startedAt": $0.startedAt, "itemsView": "summary"] as [String: Any]
            }, "nextCursor": NSNull(), "backwardsCursor": NSNull()])
        case "thread/unsubscribe":
            let threadID = (params["threadId"] as? String) ?? ""
            if let state {
                let url = state.appendingPathComponent("codex-joins.log")
                let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (old + "unsubscribe-attempt \(threadID)\n").write(to: url, atomically: true, encoding: .utf8)
            }
            let stopFailure = ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_STOP_FAILURE"]
            if stopFailure == "completed" || (["completed-once", "prepare-completed-once"].contains(stopFailure ?? "") && completedFailures == 0) {
                completedFailures += 1
                failure(-32042, "private-provider-error-text"); return
            }
            if let state {
                let url = state.appendingPathComponent("codex-joins.log")
                let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (old + "unsubscribe \(threadID)\n").write(to: url, atomically: true, encoding: .utf8)
            }
            connection.resumedThreads.remove((params["threadId"] as? String) ?? "")
            reply(["status": "unsubscribed"])
        case "thread/backgroundTerminals/list":
            let stopFailure = ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_STOP_FAILURE"]
            if stopFailure == "prepare" || (["prepare-once", "prepare-completed-once"].contains(stopFailure ?? "") && prepareFailures == 0) {
                prepareFailures += 1
                failure(-32041, "private-provider-error-text"); return
            }
            reply(["data": [] as [Any]])
        case "thread/backgroundTerminals/terminate":
            reply([:])
        case "turn/interrupt":
            let threadID = (params["threadId"] as? String) ?? "", turnID = (params["turnId"] as? String) ?? ""
            recordStopDiagnostic("turn-interrupt \(threadID) \(turnID)")
            complete(threadID, turnID: turnID, status: "interrupted", message: "interrupted")
            reply([:])
        case "turn/start":
            let threadID = (params["threadId"] as? String) ?? ""
            guard var thread = load(threadID) else { failure(-32600, "thread not found: \(threadID)"); return }
            appendState("codex-turn-skill-roots.log", extraSkillRoots.joined(separator: ","))
            appendState("codex-turn-settings.log", "\(threadID) \(thread.sandbox) \(thread.approval)")
            let permissions: [String: Any] = ["reviewer": thread.reviewer, "networkAccess": thread.networkAccess,
                                              "writableRoots": thread.writableRoots]
            if let data = try? JSONSerialization.data(withJSONObject: permissions), let line = String(data: data, encoding: .utf8) {
                appendState("codex-turn-permissions.log", line)
            }
            let text = ((params["input"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            var turn = FakeTurn(id: "turn-\(thread.turns.count + 1)-\(thread.id.prefix(6))")
            let clientID = params["clientUserMessageId"] as? String
            if thread.turns.isEmpty, text.hasPrefix("Sphyrna task:"), let clientID {
                writeFirstTaskRollout(thread, turnID: turn.id, text: text, clientID: clientID)
            }
            turn.items = [["type": "userMessage", "text": text]]
            recordStopDiagnostic("turn-start \(threadID) \(turn.id)")
            thread.turns.append(turn)
            thread.active = true
            threads[threadID] = thread
            if text.hasPrefix("Sphyrna task:"), ProcessInfo.processInfo.environment["LOOM_FAKE_CODEX_DELAY_TASK_RECEIPT"] == "1" {
                timers.append((monotonic() + 0.15, { reply(["turn": ["id": turn.id, "status": "inProgress"]]) }))
            } else { reply(["turn": ["id": turn.id, "status": "inProgress"]]) }
            broadcast("turn/started", ["threadId": threadID, "turn": ["id": turn.id, "status": "inProgress"]])
            announceStatus(thread)
            if ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_ROUNDS"] == "1",
               text.hasPrefix("Sphyrna task:") || text.hasPrefix("/fake-sphyrna-task-create ") {
                broadcast("item/started", ["threadId": threadID, "turnId": turn.id, "item": [
                    "type": "userMessage", "clientId": clientID.map { $0 as Any } ?? NSNull(),
                    "content": [["type": "text", "text": text, "text_elements": []]]
                ]])
                if text.hasPrefix("Sphyrna task:"), thread.turns.count == 1,
                   ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_HOLD_FIRST"] == "1" {
                    return // The test must interrupt this exact still-active turn.
                }
                let turnID = turn.id
                DispatchQueue.global().async {
                    let isCreate = text.hasPrefix("/fake-sphyrna-task-create ")
                    let succeeded = isCreate ? fakeSphyrnaTaskCreate(text) : fakeSphyrnaTaskRound(text)
                    let kind = isCreate ? "CREATE" : "ROUND"
                    taskCompletions.add(thread: threadID, turn: turnID,
                                        message: "FAKE-TASK-\(kind)-\(succeeded ? "OK" : "REFUSED")")
                }
                return
            }
            if text == "/fake-sphyrna-task-probe" {
                complete(threadID, turnID: turn.id, status: "completed",
                         message: fakeSphyrnaTaskProbe() ? "TASK-HELPER-OK" : "TASK-HELPER-REFUSED")
                return
            }
            if text.hasPrefix("stream") {
                // High-frequency streaming a connection may opt out of.
                let count = Int(text.dropFirst("stream".count).trimmingCharacters(in: .whitespaces)) ?? 5
                broadcast("item/started", ["threadId": threadID, "turnId": turn.id, "item": ["type": "agentMessage"]])
                for index in 0..<count {
                    broadcast("item/agentMessage/delta", ["threadId": threadID, "turnId": turn.id, "itemId": "item-1", "delta": "d\(index)"])
                }
                broadcast("thread/tokenUsage/updated", ["threadId": threadID, "turnId": turn.id])
            }
            if text.hasPrefix("approve") || text.hasPrefix("permissions") || text.hasPrefix("input") {
                let isInput = text.hasPrefix("input")
                let method = isInput ? "item/tool/requestUserInput" : text.hasPrefix("permissions")
                    ? "item/permissions/requestApproval" : "item/commandExecution/requestApproval"
                thread.flags = [isInput ? "waitingOnUserInput" : "waitingOnApproval"]
                threads[threadID] = thread
                announceStatus(thread)
                for _ in 0..<(text.hasPrefix("approve two") ? 2 : 1) {
                    nextRequestID += 1
                    let requestID = nextRequestID
                    approvals[requestID] = (threadID, turn.id)
                    // Model the delivery boundary separately from the wire
                    // shape: status is broadcast, but this request can belong
                    // only to the connection that started the turn (the TUI).
                    let recipients = text.hasPrefix("approve tui-only") ? [connection] : connections.filter { $0.resumedThreads.contains(threadID) }
                    for other in recipients where other.upgraded {
                        other.send(["id": requestID, "method": method, "params": [
                            "threadId": threadID, "turnId": turn.id, "command": "touch fixture-file", "cwd": thread.cwd,
                        ] as [String: Any]])
                    }
                }
            } else {
                let delay = text.hasPrefix("work ") ? (Double(text.dropFirst(5)) ?? 300) / 1_000 : 0.05
                let turnID = turn.id
                timers.append((monotonic() + delay, {
                    complete(threadID, turnID: turnID, status: "completed", message: "echo \(text)")
                }))
            }
        default:
            failure(-32601, "method not found: \(method)")
        }
    }

    while true {
        var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
        descriptors += connections.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
        let now = monotonic()
        let wait = timers.map { max(0, $0.due - now) }.min().map { Int32($0 * 1000) + 1 } ?? 200
        poll(&descriptors, nfds_t(descriptors.count), min(wait, 200))
        if descriptors[0].revents & Int16(POLLIN) != 0 {
            while true {
                let fd = Darwin.accept(listener, nil, nil)
                if fd < 0 { break }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                connections.append(FakeServerConnection(fd))
            }
        }
        for (index, connection) in connections.enumerated() where descriptors.indices.contains(index + 1)
            && descriptors[index + 1].revents & Int16(POLLIN | POLLHUP) != 0 {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.recv(connection.descriptor, &buffer, buffer.count, 0)
            if count <= 0 { if count == 0 || (errno != EAGAIN && errno != EINTR) { connection.parser.closed = true }; continue }
            if !connection.upgraded {
                connection.handshake += buffer.prefix(count)
                let separator: [UInt8] = [13, 10, 13, 10]
                guard let end = connection.handshake.indices.first(where: {
                    $0 + 4 <= connection.handshake.count && Array(connection.handshake[$0..<($0 + 4)]) == separator
                }) else { continue }
                let header = String(decoding: connection.handshake.prefix(end), as: UTF8.self)
                let key = header.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("sec-websocket-key:")
                }.map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
                let accept = Data(Insecure.SHA1.hash(data: Data((key + websocketGUID).utf8))).base64EncodedString()
                _ = sendAll(connection.descriptor, Array(
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8
                ))
                connection.upgraded = true
                connection.parser.input = Array(connection.handshake.dropFirst(end + 4))
                connection.handshake = []
            } else {
                connection.parser.input += buffer.prefix(count)
            }
            for text in connection.parser.messages() {
                if let message = json(text) { handle(connection, message) }
            }
        }
        connections.removeAll {
            guard $0.parser.closed else { return false }
            Darwin.close($0.descriptor)
            return true
        }
        let due = timers.filter { $0.due <= monotonic() }
        timers.removeAll { $0.due <= monotonic() }
        for timer in due { timer.action() }
        for (thread, turn, message) in taskCompletions.take() {
            complete(thread, turnID: turn, status: "completed", message: message)
        }
    }
}

// MARK: TUI

private final class FakeCodexClient {
    let descriptor: Int32
    var parser = FrameParser()
    private var nextID = 1

    init?(socketPath: String) {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        _ = sendAll(descriptor, Array("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        var response: [UInt8] = []
        let separator: [UInt8] = [13, 10, 13, 10]
        while true {
            var byte: UInt8 = 0
            guard Darwin.recv(descriptor, &byte, 1, 0) == 1 else { return nil }
            response.append(byte)
            if response.suffix(4) == separator[...] { break }
        }
        guard String(decoding: response, as: UTF8.self).contains(" 101 ") else { return nil }
        signal(SIGPIPE, SIG_IGN)
    }

    func send(_ object: [String: Any]) { _ = sendAll(descriptor, frame(1, encode(object), masked: true)) }

    /// Blocking request; server notifications that arrive meanwhile go to `sink`.
    func request(_ method: String, _ params: [String: Any], sink: ([String: Any]) -> Void) -> [String: Any] {
        let id = nextID
        nextID += 1
        send(["id": id, "method": method, "params": params])
        while true {
            for message in readMessages(timeout: 5_000) {
                if (message["id"] as? Int) == id, message["method"] == nil { return message }
                sink(message)
            }
        }
    }

    func readMessages(timeout: Int32) -> [[String: Any]] {
        var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
        guard poll(&descriptors, 1, timeout) > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if count <= 0 { out("FAKE-CODEX connection to the server was lost\r\n"); exit(1) }
        parser.input += buffer.prefix(count)
        return parser.messages().compactMap(json)
    }
}

func runCodexTUI(socketPath: String, resumeID: String?, workingDirectory: String?, model: String?, effort: String?,
                 sandbox: String?, approval: String?, firstMessage: String?, config: [String: String]) -> Never {
    let environment = ProcessInfo.processInfo.environment
    if resumeID == nil, environment["LOOM_FAKE_CODEX_INPUT_BEFORE_IDENTITY"] != nil {
        out("FAKE-CODEX BEFORE-IDENTITY: type continue (or exit)\r\n")
        guard let answer = readLine(), answer != "exit" else { exit(3) }
    }
    if environment["LOOM_FAKE_CODEX_HANG_AT_START"] != nil {
        // A TUI that never announces a thread: the launch must be undoable.
        out("FAKE-CODEX HANGING\r\n")
        while true { sleep(60) }
    }
    if environment["LOOM_FAKE_CODEX_EXIT_AT_START"] != nil {
        out("Error: fixture TUI failed at start\r\n")
        exit(3)
    }
    guard let client = FakeCodexClient(socketPath: socketPath) else {
        out("FAKE-CODEX cannot connect to \(socketPath)\r\n")
        exit(1)
    }
    var threadID = ""
    var buffered: [[String: Any]] = []
    let sink: ([String: Any]) -> Void = { buffered.append($0) }
    _ = client.request("initialize", ["clientInfo": ["name": "fake-codex-tui", "version": "1"]], sink: sink)
    client.send(["method": "initialized", "params": [:] as [String: Any]])
    // Remote sessions need an explicit working root; local PTY cwd is not transmitted.
    let root = workingDirectory ?? environment["HOME"] ?? FileManager.default.currentDirectoryPath
    guard chdir(root) == 0 else { exit(1) }
    let cwd = FileManager.default.currentDirectoryPath

    func startThread() {
        var params: [String: Any] = ["cwd": cwd]
        if let model { params["model"] = model }
        var settings = config
        if let effort { settings["model_reasoning_effort"] = effort }
        if !settings.isEmpty { params["config"] = settings }
        if let sandbox { params["sandbox"] = sandbox }
        if let approval { params["approvalPolicy"] = approval }
        let reply = client.request("thread/start", params, sink: sink)
        threadID = (((reply["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String) ?? ""
    }

    if let resumeID {
        let reply = client.request("thread/resume", ["threadId": resumeID], sink: sink)
        if let error = reply["error"] as? [String: Any] {
            out("Error: \(error["message"] as? String ?? "resume failed")\r\n")
            exit(1)
        }
        threadID = resumeID
        out("RESUMED-CODEX \(resumeID)\r\n")
    } else {
        startThread()
    }
    out("FAKE-CODEX READY \(threadID) cwd=\(cwd) home=\(environment["CODEX_HOME"] ?? "default")\r\n> ")
    if let firstMessage {
        _ = client.request("turn/start", ["threadId": threadID, "input": [["type": "text", "text": firstMessage]]], sink: sink)
    }

    func show(_ message: [String: Any]) {
        switch message["method"] as? String {
        case "turn/completed":
            let turn = ((message["params"] as? [String: Any])?["turn"] as? [String: Any])
            let text = ((turn?["items"] as? [[String: Any]])?.last?["text"] as? String) ?? ""
            out("CODEX-TURN-DONE \(turn?["status"] as? String ?? "?") \(text)\r\n> ")
        case "item/commandExecution/requestApproval":
            out("CODEX-APPROVAL-REQUESTED\r\n")
        default: break
        }
    }

    var line = ""
    var stdin = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                 pollfd(fd: client.descriptor, events: Int16(POLLIN), revents: 0)]
    while true {
        for message in buffered { show(message) }
        buffered = []
        poll(&stdin, 2, 200)
        if stdin[1].revents & Int16(POLLIN | POLLHUP) != 0 {
            for message in client.readMessages(timeout: 0) { show(message) }
        }
        guard stdin[0].revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { exit(0) }
        if byte != 10 && byte != 13 { line.append(Character(UnicodeScalar(byte))); continue }
        let text = line
        line = ""
        switch text {
        case "": break
        case "/exit": out("bye\r\n"); exit(0)
        case "/resolve-first", "/resolve-all", "/resolve-duplicate", "/resolve-wrong-thread", "/resolve-unknown":
            _ = client.request("fixture/resolve", ["threadId": threadID, "mode": String(text.dropFirst("/resolve-".count))], sink: sink)
            out("RESOLUTION-SENT \(text)\r\n> ")
        case "/interrupt", "/complete":
            _ = client.request("fixture/endTurn", ["threadId": threadID, "status": text == "/interrupt" ? "interrupted" : "completed"], sink: sink)
        case "/settings-safe", "/settings-full", "/settings-unknown", "/settings-network", "/settings-roots", "/settings-never", "/settings-reviewer":
            let sandbox = text == "/settings-full" ? "danger-full-access" : text == "/settings-unknown" ? "future-policy"
                : text == "/settings-roots" ? "workspace-write" : "read-only"
            _ = client.request("fixture/settings", ["threadId": threadID, "model": "fake-codex-beta", "effort": "low",
                "sandbox": sandbox, "approval": text == "/settings-full" || text == "/settings-never" ? "never" : "on-request",
                "networkAccess": text == "/settings-network", "writableRoots": text == "/settings-roots" ? ["/outside"] : [],
                "reviewer": text == "/settings-reviewer" ? "auto" : "user"], sink: sink)
            out("SETTINGS-SAVED \(text)\r\n> ")
        case "/helper":
            _ = client.request("fixture/helper", ["cwd": cwd], sink: sink)
            out("HELPER-SENT\r\n> ")
        case "/new", "/clear":
            startThread()
            out("NEW-THREAD \(threadID)\r\n> ")
        default:
            _ = client.request("turn/start", ["threadId": threadID, "input": [["type": "text", "text": text]]], sink: sink)
        }
    }
}
