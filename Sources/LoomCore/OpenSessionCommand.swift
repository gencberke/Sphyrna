import Foundation

/// `loom-hook open ...`: how an agent in a Loom session asks Loom to open another one (D-40).
/// It lives here, not in the helper's `main.swift`, so the argument rules and exit codes are tested
/// against a real server without starting a process.
///
/// Exit codes: 0 started or pending; 1 denied (or approved but not started); 2 usage or
/// validation error; 3 Loom unreachable or not inside a Loom session.
public enum OpenSessionCommand {
    public static let usage = """
        usage: "$LOOM_CLI" open --title <title> [--project <name|path>] \
        (--message-file <path> | --message -)

          --title <title>         session title, 1-160 characters
          --ticket <key>          accepted and ignored, so older agent rules keep running; Loom keeps no
                                  tracker keys and does not look up existing sessions
          --project <name|path>   a Loom project by exact name or path (default: this session's project)
          --message-file <path>   file with the first message (UTF-8, at most 64 KiB)
          --message -             read the first message from standard input

        Loom asks the user before anything starts. Result line (one of):
          started <session-id> "<title>"            exit 0
          pending: ...                              exit 0 (not decided within 85 s; the request stays in Loom)
          denied                                    exit 1
          error: <reason>                           exit 1 (approved, not started), 2 (bad request), 3 (Loom unreachable)
        """

    public struct Output {
        public var standardOutput: (String) -> Void
        public var standardError: (String) -> Void

        public init(standardOutput: @escaping (String) -> Void, standardError: @escaping (String) -> Void) {
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    public static func run(
        arguments: [String], environment: [String: String], readStandardInput: () throws -> Data,
        output: Output, replyTimeout: TimeInterval = 90
    ) -> Int32 {
        guard arguments.first == "open" else {
            if arguments.first == "--help" || arguments.first == "-h" || arguments.first == "help" {
                output.standardOutput(usage)
                return 0
            }
            output.standardError("error: unknown command \"\(arguments.first ?? "")\"\n\(usage)")
            return 2
        }
        let parsed: ParsedArguments
        do {
            parsed = try parse(Array(arguments.dropFirst()))
        } catch let rejection as OpenSessionRejection {
            output.standardError("error: \(rejection.reason)\n\(usage)")
            return 2
        } catch {
            output.standardError("error: \(error)")
            return 2
        }
        if parsed.help {
            output.standardOutput(usage)
            return 0
        }

        let message: String
        do { message = try parsed.message(readStandardInput: readStandardInput) }
        catch let rejection as OpenSessionRejection {
            output.standardError("error: \(rejection.reason)")
            return 2
        } catch {
            output.standardError("error: the message could not be read: \(error)")
            return 2
        }
        let input: OpenSessionInput
        do {
            input = try OpenSessionInput.validated(
                title: parsed.title ?? "", project: parsed.project, message: message
            )
        } catch {
            output.standardError("error: \(error)")
            return 2
        }

        guard let socket = environment["LOOM_CONTROL_SOCKET"], !socket.isEmpty,
              let token = environment["LOOM_HOOK_TOKEN"], !token.isEmpty,
              let sessionID = environment["LOOM_SESSION_ID"].flatMap(UUID.init(uuidString:)),
              let runID = environment["LOOM_MANAGED_RUN_ID"].flatMap(UUID.init(uuidString:)) else {
            output.standardOutput("error: not running inside a Loom session (no Loom connection in the environment)")
            return 3
        }
        let reply: OpenSessionReply
        do {
            reply = try OpenSessionClient.exchange(
                OpenSessionWireRequest(
                    authenticationToken: token, sessionID: sessionID, managedRunID: runID,
                    title: input.title, project: input.project, message: input.message
                ),
                socketPath: socket, replyTimeout: replyTimeout
            )
        } catch {
            output.standardOutput("error: Loom could not be reached or did not answer (\(error))")
            return 3
        }
        output.standardOutput(reply.line)
        return reply.exitCode
    }

    // MARK: Arguments

    struct ParsedArguments {
        var title: String?
        var project: String?
        var messageFile: String?
        var messageFromStandardInput = false
        var help = false

        func message(readStandardInput: () throws -> Data) throws -> String {
            let data: Data
            if let messageFile {
                guard let handle = FileHandle(forReadingAtPath: messageFile) else {
                    throw OpenSessionRejection("the message file cannot be read: \(messageFile)")
                }
                defer { try? handle.close() }
                data = try handle.read(upToCount: OpenSessionLimits.messageByteLimit + 1) ?? Data()
            } else {
                data = try readStandardInput()
            }
            guard data.count <= OpenSessionLimits.messageByteLimit else {
                throw OpenSessionRejection("the message is larger than 64 KiB")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw OpenSessionRejection("the message is not valid UTF-8")
            }
            return text
        }
    }

    static func parse(_ arguments: [String]) throws -> ParsedArguments {
        var result = ParsedArguments()
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            var name = arguments[index]
            var inline: String?
            if name.hasPrefix("--"), let equals = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            index += 1
            if name == "--help" || name == "-h" {
                result.help = true
                continue
            }
            guard ["--title", "--ticket", "--project", "--message-file", "--message"].contains(name) else {
                throw OpenSessionRejection("unknown option \"\(name)\"")
            }
            guard seen.insert(name).inserted else {
                throw OpenSessionRejection("\(name) is given more than once")
            }
            let value: String
            if let inline { value = inline }
            else if index < arguments.count { value = arguments[index]; index += 1 }
            else { throw OpenSessionRejection("\(name) needs a value") }
            switch name {
            case "--title": result.title = value
            case "--ticket": break // accepted and ignored (D-69)
            case "--project": result.project = value
            case "--message-file": result.messageFile = value
            default:
                guard value == "-" else {
                    throw OpenSessionRejection(
                        "--message takes only \"-\" (standard input); put the text in a file for --message-file"
                    )
                }
                result.messageFromStandardInput = true
            }
        }
        if result.help { return result }
        guard result.title != nil else { throw OpenSessionRejection("--title is required") }
        switch (result.messageFile != nil, result.messageFromStandardInput) {
        case (false, false): throw OpenSessionRejection("give the first message with --message-file <path> or --message -")
        case (true, true): throw OpenSessionRejection("use either --message-file or --message -, not both")
        default: break
        }
        return result
    }
}
