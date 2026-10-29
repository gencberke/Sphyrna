import Darwin
import Foundation

public enum SendMessageCommand {
    public static let usage = """
        usage: "$SPHYRNA_CLI" send <session-id> --message-file <path> [--operation <uuid>]
               "$SPHYRNA_CLI" inbox [--peek] [--after <cursor>] [--limit <n>]

        Each send needs the user's approval. The UTF-8 message may be at most 16 KiB.
        Reuse the printed operation id when retrying an uncertain send. `inbox` reads only
        this session's messages; --peek leaves them unread.
        """

    public static func run(arguments: [String], environment: [String: String], output: OpenSessionCommand.Output) -> Int32 {
        guard let command = arguments.first, command == "send" || command == "inbox" else {
            output.standardError("error: unknown message command"); return 2
        }
        if arguments.count == 2 && ["--help", "-h"].contains(arguments[1]) { output.standardOutput(usage); return 0 }
        guard let socket = environment["SPHYRNA_TASK_SOCKET"], !socket.isEmpty,
              let secret = environment["SPHYRNA_TASK_TOKEN"], !secret.isEmpty,
              let sessionID = environment["SPHYRNA_TASK_SESSION_ID"].flatMap(UUID.init(uuidString:)),
              let runID = environment["SPHYRNA_TASK_RUN_ID"].flatMap(UUID.init(uuidString:)),
              let generation = environment["SPHYRNA_TASK_GENERATION"].flatMap(UUID.init(uuidString:)) else {
            output.standardError("error: this terminal has no live Sphyrna message connection"); return 3
        }
        var call = SessionTaskWireRequest(command: command == "send" ? "peer-send" : "peer-inbox",
            sessionID: sessionID, runID: runID, generation: generation, credential: secret)
        var peek = false, path: String?, target: UUID?, operation: UUID?, after: Int64 = 0, limit = SessionTaskLimits.pageSize
        var i = 1
        if command == "send" {
            guard arguments.count > 1, let id = UUID(uuidString: arguments[1]) else {
                output.standardError("error: send needs a session id"); return 2
            }
            target = id; i = 2
        }
        var seen: Set<String> = []
        while i < arguments.count {
            let flag = arguments[i]; i += 1
            guard seen.insert(flag).inserted else { output.standardError("error: repeated option"); return 2 }
            if command == "inbox" && flag == "--peek" { peek = true; continue }
            guard i < arguments.count else { output.standardError("error: option needs a value"); return 2 }
            let value = arguments[i]; i += 1
            switch (command, flag) {
            case ("send", "--message-file"): path = value
            case ("send", "--operation"):
                guard let id = UUID(uuidString: value) else { output.standardError("error: invalid operation"); return 2 }; operation = id
            case ("inbox", "--after"):
                guard let n = Int64(value), n >= 0 else { output.standardError("error: invalid cursor"); return 2 }; after = n
            case ("inbox", "--limit"):
                guard let n = Int(value), (1...SessionTaskLimits.pageSize).contains(n) else {
                    output.standardError("error: invalid limit"); return 2
                }; limit = n
            default: output.standardError("error: invalid message option"); return 2
            }
        }
        if command == "send" {
            guard let path else {
                output.standardError("error: --message-file must name a readable file"); return 2
            }
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { output.standardError("error: --message-file must name a readable file"); return 2 }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                close(descriptor); output.standardError("error: --message-file must name a readable regular file"); return 2
            }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var bytes = Data()
            do {
                while bytes.count <= SessionTaskLimits.payloadBytes {
                    guard let chunk = try file.read(upToCount: SessionTaskLimits.payloadBytes + 1 - bytes.count), !chunk.isEmpty else { break }
                    bytes.append(chunk)
                }
            } catch { output.standardError("error: --message-file could not be read"); return 2 }
            guard
                  let message = String(data: bytes, encoding: .utf8), (try? SessionTaskLimits.text(message)) != nil else {
                output.standardError("error: message must be valid UTF-8 and at most 16 KiB"); return 2
            }
            let id = operation ?? UUID()
            output.standardOutput("operation \(id.uuidString.lowercased())")
            call.operationID = id; call.targetSessionID = target; call.message = message
        } else { call.after = after; call.limit = limit }
        do {
            let answer = try exchange(call, socket: socket, timeout: command == "send" ? 90 : 8)
            if command == "inbox", let page = try? JSONDecoder().decode(PeerWirePage.self, from: answer),
               page.version == 5, page.status == "ok" {
                var values: [[String: Any]] = []
                for entry in page.messages {
                    guard let message = entry.message else { throw SessionTaskError.invalidPayload }
                    values.append(["cursor": entry.sequence, "id": entry.id.uuidString.lowercased(),
                                   "sender": entry.senderID.uuidString.lowercased(), "senderTitle": entry.senderTitle,
                                   "message": message])
                }
                let json = try JSONSerialization.data(withJSONObject: ["messages": values,
                    "next": page.next.map { $0 as Any } ?? NSNull()], options: [.sortedKeys])
                output.standardOutput(String(decoding: json, as: UTF8.self))
                if !peek && !page.messages.isEmpty {
                    var ack = call; ack.command = "peer-inbox-ack"; ack.eventIDs = page.messages.map(\.id)
                    ack.readLeaseID = page.readLeaseID
                    let data = try exchange(ack, socket: socket, timeout: 5)
                    guard let reply = try? JSONDecoder().decode(SessionTaskWireReply.self, from: data), reply.status == "ok" else {
                        output.standardError("error: inbox acknowledgement was not confirmed"); return 3
                    }
                }
                return 0
            }
            guard let reply = try? JSONDecoder().decode(SessionTaskWireReply.self, from: answer), reply.version == 5 else {
                output.standardError("error: malformed message response"); return 3
            }
            switch reply.status {
            case "pending", "sent": output.standardOutput(reply.status); return 0
            case "denied", "failed": output.standardOutput(reply.status); return 1
            case "invalid": output.standardError("error: \(reply.detail ?? "invalid message")"); return 2
            default: output.standardError("error: \(reply.detail ?? "message connection unavailable")"); return 3
            }
        } catch {
            output.standardError("error: Sphyrna did not answer; reuse the same operation id")
            return 3
        }
    }

    private static func exchange(_ call: SessionTaskWireRequest, socket: String, timeout: TimeInterval) throws -> Data {
        try OpenSessionClient.roundTrip(raw: JSONEncoder().encode(call), socketPath: socket,
                                        connectTimeout: 2, replyTimeout: timeout)
    }
}
