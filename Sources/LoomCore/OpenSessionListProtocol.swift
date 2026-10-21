import Foundation

// A session asks Sphyrna which other sessions exist (C5a): `"$LOOM_CLI" sessions`. The second request kind on the control
// socket of `open` (OpenSessionProtocol.swift). Read-only: what an agent gets is the directory's summaries (id, title,
// project, state, harness, face, last activity), never a session's content.

enum SessionListLimits {
    static let defaultLimit = SessionQuery.defaultLimit
    static let maximumLimit = SessionQuery.maxLimit
    /// The answer stays under this many bytes of JSON, so it fits the client's 64 KiB read with room to spare.
    static let replyByteBudget = 60_000
}

/// How the wire and the `--json` output write a summary: the same JSON, dates as ISO 8601 (UTC, whole seconds).
enum SessionListCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Version 2 of the control socket's request: it names a `command`. Version 1 is `open` and is unchanged.
struct SessionListWireRequest: Codable, Sendable {
    static let protocolVersion = 2
    static let commandName = "sessions"
    var version = Self.protocolVersion
    var authenticationToken: String
    var sessionID: UUID
    var managedRunID: UUID
    var command = Self.commandName
    var project: String?
    var all: Bool
    var limit: Int?
}

/// A list request that passed the token check.
struct SessionListCall: Sendable {
    let sessionID: UUID
    let managedRunID: UUID
    let project: String?
    let all: Bool
    let limit: Int?
}

/// Sphyrna's answer to `sessions`. The `invalid` and `unavailable` answers of the server itself (a malformed request, a wrong
/// token) arrive in the shape of `OpenSessionReply` and decode here too: `sessions` is then empty.
public struct SessionListReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        /// The request itself is wrong (a rule broken, an unknown project, a requester without a project).
        case invalid
        /// Not a live Sphyrna session, or Sphyrna is quitting.
        case unavailable
    }

    public let status: Status
    public let sessions: [SessionSummary]
    /// The list was cut so the answer fits; narrow it with `--project` or a smaller `--limit`.
    public let truncated: Bool
    public let detail: String?

    public init(status: Status, sessions: [SessionSummary] = [], truncated: Bool = false, detail: String? = nil) {
        self.status = status
        self.sessions = sessions
        self.truncated = truncated
        self.detail = detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        sessions = try container.decodeIfPresent([SessionSummary].self, forKey: .sessions) ?? []
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    public var exitCode: Int32 {
        switch status {
        case .ok: 0
        case .invalid: 2
        case .unavailable: 3
        }
    }

    /// The answer with as many of `sessions` (in their order) as fit the byte budget.
    static func fitting(_ sessions: [SessionSummary]) -> SessionListReply {
        let encoder = SessionListCoding.encoder()
        let empty = SessionListReply(status: .ok, truncated: true)
        var size = (try? encoder.encode(empty).count) ?? 0
        var kept: [SessionSummary] = []
        for summary in sessions {
            let next = ((try? encoder.encode(summary).count) ?? SessionListLimits.replyByteBudget) + 1
            guard size + next <= SessionListLimits.replyByteBudget else {
                return SessionListReply(status: .ok, sessions: kept, truncated: true)
            }
            size += next
            kept.append(summary)
        }
        return SessionListReply(status: .ok, sessions: kept)
    }
}

extension OpenSessionClient {
    /// Sends one `sessions` request and waits for the answer (immediate: nothing waits for the user).
    static func exchange(
        _ request: SessionListWireRequest, socketPath: String,
        connectTimeout: TimeInterval = 2, replyTimeout: TimeInterval = 10
    ) throws -> SessionListReply {
        let data = try JSONEncoder().encode(request)
        let answer = try roundTrip(raw: data, socketPath: socketPath, connectTimeout: connectTimeout,
                                   replyTimeout: replyTimeout)
        guard let reply = try? SessionListCoding.decoder().decode(SessionListReply.self, from: answer) else {
            throw ClaudeHookTransportError.malformedMessage
        }
        return reply
    }
}
