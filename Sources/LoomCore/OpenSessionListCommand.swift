import Foundation

/// `"$LOOM_CLI" sessions ...`: an agent in a Sphyrna session lists the user's other sessions (C5a). Read-only: the answer
/// holds what the directory knows (id, title, project, state, harness, face, last activity), never a session's content.
extension OpenSessionCommand {
    public static let sessionsUsage = """
        usage: "$SPHYRNA_CLI" sessions [--project <name|path> | --all] [--limit <n>] [--json]

        Lists the user's other Sphyrna sessions, newest activity first, read-only. This session is not listed.

          --project <name|path>   only this Sphyrna project's sessions, by exact name or path
          --all                   every project's sessions, and sessions without a project
          --limit <n>             at most n sessions, 1-100 (default 20)
          --json                  a JSON array instead of the table

        Without --project or --all the list is this session's project; a session that is in no project must say
        --all or --project. The table has a header line, then one line per session, tab-separated:
          id  state  harness  face  last-activity  project  title  opened-by
        state is working, needs-approval, waiting, failed, problem, finished, ready, idle, stale, stopped or unknown;
        harness is claude or codex; face is terminal or chat, "-" when the session is not running; last-activity is
        ISO 8601 in UTC; project is "-" without one; title is in double quotes ("" when it has none); opened-by is the
        requester's id, "-" for a session the user started.
        With --json the keys are id, harness, title, projectID, projectName, state, face, lastActivityAt and openedBy
        (a key is left out when it has no value). Exit codes: 0 listed, 2 bad request, 3 Sphyrna unreachable.
        """

    /// `"$SPHYRNA_CLI" whoami`: this session, its opener and the sessions it opened (FB6-16 part 1).
    public static let whoAmIUsage = """
        usage: "$SPHYRNA_CLI" whoami [--json]

        What this session is, read-only and with no session content: id, state, project and title, its opener (id,
        title and state; "-" when the user started it) and the sessions it opened. `--json` writes one object with
        the keys session, opener and opened, each a session summary as `sessions --json` writes it.
        Exit codes: 0 answered, 2 bad request, 3 Sphyrna unreachable.
        """

    static let sessionsColumns = ["id", "state", "harness", "face", "last-activity", "project", "title", "opened-by"]

    struct SessionsArguments: Equatable {
        var project: String?
        var all = false
        var limit: Int?
        var json = false
        var help = false
    }

    static func parseSessions(_ arguments: [String]) throws -> SessionsArguments {
        var result = SessionsArguments()
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
            guard ["--project", "--all", "--limit", "--json"].contains(name) else {
                throw OpenSessionRejection(name.hasPrefix("-") ? "unknown option \"\(name)\"" : "unexpected argument \"\(name)\"")
            }
            guard seen.insert(name).inserted else { throw OpenSessionRejection("\(name) is given more than once") }
            if name == "--all" || name == "--json" {
                guard inline == nil else { throw OpenSessionRejection("\(name) takes no value") }
                if name == "--all" { result.all = true } else { result.json = true }
                continue
            }
            let value: String
            if let inline { value = inline }
            else if index < arguments.count { value = arguments[index]; index += 1 }
            else { throw OpenSessionRejection("\(name) needs a value") }
            if name == "--project" {
                result.project = value
            } else {
                guard let limit = Int(value.trimmingCharacters(in: .whitespaces)),
                      (1...SessionListLimits.maximumLimit).contains(limit) else {
                    throw OpenSessionRejection("--limit must be a whole number from 1 to \(SessionListLimits.maximumLimit)")
                }
                result.limit = limit
            }
        }
        if result.help { return result }
        if result.all, result.project != nil { throw OpenSessionRejection("use either --project or --all, not both") }
        result.project = try OpenSessionInput.validatedProject(result.project)
        return result
    }

    static func runSessions(arguments: [String], environment: [String: String], output: Output) -> Int32 {
        let parsed: SessionsArguments
        do { parsed = try parseSessions(arguments) }
        catch let rejection as OpenSessionRejection {
            output.standardError("error: \(rejection.reason)\n\(sessionsUsage)")
            return 2
        } catch {
            output.standardError("error: \(error)")
            return 2
        }
        if parsed.help {
            output.standardOutput(sessionsUsage)
            return 0
        }
        guard let connection = Connection(environment: environment) else {
            output.standardOutput(Connection.missing)
            return 3
        }
        let reply: SessionListReply
        do {
            reply = try OpenSessionClient.exchange(
                SessionListWireRequest(
                    authenticationToken: connection.token, sessionID: connection.sessionID,
                    managedRunID: connection.runID, project: parsed.project, all: parsed.all, limit: parsed.limit
                ),
                socketPath: connection.socketPath
            )
        } catch {
            output.standardOutput("error: Sphyrna could not be reached or did not answer (\(error))")
            return 3
        }
        guard reply.status == .ok else {
            output.standardOutput("error: \(reply.detail ?? "the request was not accepted")")
            return reply.exitCode
        }
        if parsed.json {
            guard let data = try? SessionListCoding.encoder().encode(reply.sessions) else {
                output.standardOutput("error: the list could not be written")
                return 3
            }
            output.standardOutput(String(decoding: data, as: UTF8.self))
        } else {
            output.standardOutput(table(reply.sessions))
        }
        if reply.truncated {
            output.standardError("note: the list was cut at \(reply.sessions.count) sessions to fit one answer; narrow it with --project or a smaller --limit")
        }
        return 0
    }

    /// The header line and one line per session. Tabs and line breaks inside a project name or title become spaces.
    static func table(_ sessions: [SessionSummary]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let rows = sessions.map { session in
            [
                session.id.uuidString.lowercased(), session.state.rawValue, session.harness.rawValue,
                session.face?.rawValue ?? "-", formatter.string(from: session.lastActivityAt),
                session.projectName.map(singleLine) ?? "-", quoted(session.title ?? ""),
                session.openedBy?.uuidString.lowercased() ?? "-",
            ].joined(separator: "\t")
        }
        return ([sessionsColumns.joined(separator: "\t")] + rows).joined(separator: "\n")
    }

    static func runWhoAmI(arguments: [String], environment: [String: String], output: Output) -> Int32 {
        var json = false
        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "--help", "-h":
                output.standardOutput(whoAmIUsage)
                return 0
            default:
                output.standardError("error: unknown option \"\(argument)\"\n\(whoAmIUsage)")
                return 2
            }
        }
        guard let connection = Connection(environment: environment) else {
            output.standardOutput(Connection.missing)
            return 3
        }
        let reply: WhoAmIReply
        do {
            reply = try OpenSessionClient.exchange(
                WhoAmIWireRequest(
                    authenticationToken: connection.token, sessionID: connection.sessionID,
                    managedRunID: connection.runID
                ),
                socketPath: connection.socketPath
            )
        } catch {
            output.standardOutput("error: Sphyrna could not be reached or did not answer (\(error))")
            return 3
        }
        guard reply.status == .ok, let who = reply.who else {
            output.standardOutput("error: \(reply.detail ?? "the request was not accepted")")
            return reply.exitCode
        }
        if json {
            guard let data = try? SessionListCoding.encoder().encode(who) else {
                output.standardOutput("error: the answer could not be written")
                return 3
            }
            output.standardOutput(String(decoding: data, as: UTF8.self))
        } else {
            output.standardOutput(whoAmITable(who))
        }
        return 0
    }

    /// Key lines for this session, then one line per session it opened.
    static func whoAmITable(_ who: SessionWhoAmI) -> String {
        func line(_ summary: SessionSummary) -> String {
            "\(summary.id.uuidString.lowercased()) \(summary.state.rawValue) \(quoted(summary.title ?? ""))"
        }
        let own = who.session
        var lines = [
            "id: \(own.id.uuidString.lowercased())",
            "state: \(own.state.rawValue)",
            "project: \(own.projectName.map(singleLine) ?? "-")",
            "title: \(quoted(own.title ?? ""))",
            "opened-by: \(who.opener.map(line) ?? "-")",
        ]
        if who.opened.isEmpty {
            lines.append("opened: none")
        } else {
            lines += who.opened.map { "opened: " + line($0) }
        }
        return lines.joined(separator: "\n")
    }

    private static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
    }

    private static func quoted(_ text: String) -> String {
        "\"" + singleLine(text).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
