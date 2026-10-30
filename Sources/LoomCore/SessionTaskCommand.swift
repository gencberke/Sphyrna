import Foundation

/// The task helper uses a launch-local credential and a bounded one-request
/// connection. It never retries a possibly submitted operation automatically.
public enum SessionTaskCommand {
    public static let usage = """
        usage: "$SPHYRNA_CLI" task <command> --task <id> [options]

          create --name <name> --harness <id> --message -
                                         request an approved new task child
          identity                       identify this live terminal run
          status                         read task and native status
          read [--after <cursor>]        read task events; printed events are acknowledged
          wait --revision <n> [--seconds <n>] [--after <cursor>]
                                         wait up to 60 seconds and read task events
          input --round <id> --operation <id>
                                         child reads the exact accepted round input
          report --round <id> --kind <completed|failed|needsParentInput> --message -
                                         child reports a result; needsParentInput returns promptly
          reply [--reply-to <event-id>] --message -
                                         queue one follow-up to the same child
          interrupt --round <id> [--next-operation <uuid>] --message -
                                         interrupt that exact round and queue an update
          stop                           stop the owned child

        An effect takes an optional --operation <uuid>. If omitted, the helper
        prints a new operation id before sending; reuse it to retry safely.
        Messages are UTF-8 on stdin, at most 16 KiB. Native approvals belong to the user.
        """

    public static func run(arguments: [String], environment: [String: String],
                           readStandardInput: () throws -> Data, output: OpenSessionCommand.Output) -> Int32 {
        let args = arguments.first == "task" ? Array(arguments.dropFirst()) : arguments
        if args.isEmpty || args == ["--help"] || args == ["-h"] || args == ["help"] {
            output.standardOutput(usage)
            return 0
        }
        let command = args[0]
        let allowed = Set(["create", "identity", "status", "read", "wait", "input", "report", "reply", "interrupt", "stop"])
        guard allowed.contains(command) else { output.standardError("error: unknown task command\n\(usage)"); return 2 }
        var values: [String: String] = [:]
        var index = 1
        let fields = Set(["--task", "--round", "--operation", "--next-operation", "--reply-to", "--kind", "--message", "--after", "--limit", "--revision", "--seconds", "--name", "--project", "--harness", "--model", "--effort", "--mode"])
        while index < args.count {
            let flag = args[index]
            guard fields.contains(flag), index + 1 < args.count, values[flag] == nil else {
                output.standardError("error: invalid task arguments"); return 2
            }
            values[flag] = args[index + 1]
            index += 2
        }
        let suppliedTask = values["--task"].flatMap(UUID.init(uuidString:))
        if values["--task"] != nil && suppliedTask == nil { output.standardError("error: invalid --task"); return 2 }
        let taskID = command == "create" ? (suppliedTask ?? UUID()) : suppliedTask
        guard command == "identity" || taskID != nil else {
            output.standardError("error: --task needs a task id"); return 2
        }
        guard let socket = environment["SPHYRNA_TASK_SOCKET"], !socket.isEmpty,
              let secret = environment["SPHYRNA_TASK_TOKEN"], !secret.isEmpty,
              let sessionID = environment["SPHYRNA_TASK_SESSION_ID"].flatMap(UUID.init(uuidString:)),
              let runID = environment["SPHYRNA_TASK_RUN_ID"].flatMap(UUID.init(uuidString:)),
              let generation = environment["SPHYRNA_TASK_GENERATION"].flatMap(UUID.init(uuidString:)) else {
            output.standardError("error: this terminal has no live Sphyrna task connection"); return 3
        }
        var call = SessionTaskWireRequest(command: command, sessionID: sessionID, runID: runID,
                                          generation: generation, credential: secret, taskID: taskID)
        for (flag, assign) in [("--round", 0), ("--operation", 1), ("--reply-to", 2), ("--next-operation", 3)] {
            guard let value = values[flag] else { continue }
            guard let id = UUID(uuidString: value) else { output.standardError("error: invalid \(flag)"); return 2 }
            if assign == 0 { call.roundID = id }
            else if assign == 1 { call.operationID = id }
            else if assign == 2 { call.replyToEventID = id }
            else { call.nextOperationID = id }
        }
        if let raw = values["--after"] { guard let n = Int64(raw), n >= 0 else { output.standardError("error: invalid cursor"); return 2 }; call.after = n }
        if let raw = values["--limit"] { guard let n = Int(raw), (1...SessionTaskLimits.pageSize).contains(n) else { output.standardError("error: invalid limit"); return 2 }; call.limit = n }
        if let raw = values["--revision"] { guard let n = Int64(raw), n >= 0 else { output.standardError("error: invalid revision"); return 2 }; call.revision = n }
        if let raw = values["--seconds"] { guard let n = Double(raw), n > 0, n <= SessionTaskLimits.maxWait, n.isFinite else { output.standardError("error: invalid wait"); return 2 }; call.seconds = n }
        if command == "wait" { call.seconds = call.seconds ?? SessionTaskLimits.maxWait }
        if let kind = values["--kind"] { call.kind = SessionTaskReportKind(rawValue: kind) }
        if command == "create" {
            guard let name = values["--name"], let harness = values["--harness"] else {
                output.standardError("error: create requires --name and --harness"); return 2
            }
            call.name = name; call.harness = harness; call.project = values["--project"]
            call.model = values["--model"]; call.effort = values["--effort"]; call.mode = values["--mode"]
            output.standardOutput("task \(taskID!.uuidString.lowercased())")
        }
        let effect = ["create", "report", "reply", "interrupt", "stop"].contains(command)
        if effect, call.operationID == nil {
            call.operationID = UUID()
            output.standardOutput("operation \(call.operationID!.uuidString.lowercased())")
        }
        if command == "interrupt", call.nextOperationID == nil, values["--operation"] != nil {
            output.standardError("error: retrying an interrupt needs its original --next-operation"); return 2
        }
        if command == "interrupt", call.nextOperationID == nil {
            call.nextOperationID = UUID()
            output.standardOutput("next-operation \(call.nextOperationID!.uuidString.lowercased())")
        }
        if ["create", "report", "reply", "interrupt"].contains(command) {
            guard values["--message"] == "-", let bytes = try? readStandardInput(),
                  let message = String(data: bytes, encoding: .utf8), (try? SessionTaskLimits.text(message)) != nil else {
                output.standardError("error: --message - needs valid UTF-8 input of at most 16 KiB"); return 2
            }
            call.message = message
        }
        if ["input", "report", "interrupt"].contains(command), call.roundID == nil {
            output.standardError("error: --round is required"); return 2
        }
        if command == "input", call.operationID == nil { output.standardError("error: --operation is required"); return 2 }
        if command == "report", call.kind == nil { output.standardError("error: --kind is required"); return 2 }
        if command == "wait", call.revision == nil { output.standardError("error: --revision is required"); return 2 }
        do {
            let answer = try exchange(call, socket: socket, timeout: command == "wait" ? (call.seconds ?? 60) + 5 : 65)
            if command == "read" || command == "wait",
               let page = try? JSONDecoder().decode(SessionTaskWirePage.self, from: answer), page.version == 5, page.status == "ok" {
                var items: [[String: Any]] = []
                for event in page.events {
                    guard let payload = event.decodedPayload else { throw SessionTaskError.invalidPayload }
                    items.append(["cursor": event.cursor, "id": event.id.uuidString.lowercased(),
                                  "round": event.roundID.uuidString.lowercased(), "kind": event.kind.rawValue, "payload": payload])
                }
                let json = try JSONSerialization.data(withJSONObject: ["events": items,
                    "next": page.next.map { $0 as Any } ?? NSNull(), "revision": page.revision.map { $0 as Any } ?? NSNull()],
                    options: [.sortedKeys])
                output.standardOutput(String(decoding: json, as: UTF8.self))
                if !page.events.isEmpty {
                    var ack = call; ack.command = "ack"; ack.eventIDs = page.events.map(\.id)
                    ack.readLeaseID = page.readLeaseID
                    let result = try exchange(ack, socket: socket, timeout: 5)
                    guard let reply = try? JSONDecoder().decode(SessionTaskWireReply.self, from: result), reply.status == "ok" else {
                        output.standardError("error: read acknowledgement was not confirmed"); return 3
                    }
                }
                return 0
            }
            guard let reply = try? JSONDecoder().decode(SessionTaskWireReply.self, from: answer), reply.version == 5 else {
                output.standardError("error: malformed task response"); return 3
            }
            if command == "create", reply.status == "pending" {
                output.standardOutput("pending: approve or deny the task in Sphyrna")
                return 0
            }
            if reply.status == "ok" {
                if let message = reply.message { output.standardOutput(message) }
                else { output.standardOutput(String(decoding: answer, as: UTF8.self)) }
                return 0
            }
            output.standardError("error: \(reply.detail ?? reply.status)")
            return reply.status == "invalid" ? 2 : reply.status == "refused" ? 1 : 3
        } catch {
            output.standardError(SessionChannelSandbox.helperConnectFailure(error, environment: environment)
                ?? "error: Sphyrna task connection did not complete; do not retry an effect with a new operation id")
            return 3
        }
    }

    private static func exchange(_ call: SessionTaskWireRequest, socket: String, timeout: TimeInterval) throws -> Data {
        try OpenSessionClient.roundTrip(raw: JSONEncoder().encode(call), socketPath: socket,
                                        connectTimeout: 2, replyTimeout: timeout)
    }
}
