import Darwin
import Foundation

// A session asks Loom to open another session (D-40). One request, one answer, on the control
// socket next to the hook socket. This file holds the rules every side shares (limits and input
// validation), the wire shapes, the blocking client the `loom-hook open` command uses, and the
// server. What happens to a request (pending, approval, start) lives in OpenSessionCoordinator.

enum OpenSessionLimits {
    static let messageByteLimit = 64 * 1024
    static let titleLimit = 160
    static let ticketLimit = 40
    static let projectLimit = 4_096
    /// The JSON of a request: the message may grow when its characters are escaped.
    static let wireByteLimit = 512 * 1024
    /// The server answers `pending` after this long and keeps the request.
    static let serverReplyDelay: TimeInterval = 85
    /// The client gives up after this long; it must outlast `serverReplyDelay`.
    static let clientWait: TimeInterval = 90
}

public struct OpenSessionRejection: Error, CustomStringConvertible, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// What an agent asked for, after the rules: the same check runs in the command (before it
/// connects) and in Loom (which trusts nothing it receives).
public struct OpenSessionInput: Equatable, Sendable {
    public let title: String
    public let ticketKey: String?
    public let project: String?
    public let message: String

    public static func validated(
        title: String, ticketKey: String?, project: String?, message: String
    ) throws -> OpenSessionInput {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw OpenSessionRejection("the title is empty") }
        guard trimmedTitle.count <= OpenSessionLimits.titleLimit else {
            throw OpenSessionRejection("the title is longer than \(OpenSessionLimits.titleLimit) characters")
        }
        guard !trimmedTitle.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) else { throw OpenSessionRejection("the title must be a single line") }

        var ticket: String?
        if let raw = ticketKey {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.count <= OpenSessionLimits.ticketLimit,
                  key.unicodeScalars.allSatisfy({ isTicketCharacter($0) }) else {
                throw OpenSessionRejection(
                    "the ticket key must be 1-\(OpenSessionLimits.ticketLimit) letters, digits, '-', '_' or '.'"
                )
            }
            ticket = key
        }

        var projectName: String?
        if let raw = project {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= OpenSessionLimits.projectLimit,
                  !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw OpenSessionRejection("the project is empty or too long")
            }
            projectName = value
        }

        guard !message.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OpenSessionRejection("the message contains a NUL character")
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenSessionRejection("the message is empty")
        }
        guard message.utf8.count <= OpenSessionLimits.messageByteLimit else {
            throw OpenSessionRejection("the message is larger than 64 KiB")
        }
        return OpenSessionInput(title: trimmedTitle, ticketKey: ticket, project: projectName, message: message)
    }

    private static func isTicketCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F, 0x2E: true
        default: false
        }
    }
}

/// Loom's answer. `status` decides the exit code of the command; `line` is what the agent reads.
public struct OpenSessionReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The process was launched with the first message.
        case started
        /// A session for this ticket already exists in the project; nothing was started.
        case exists
        /// Not decided yet; the request stays in Loom and a later approval still opens it.
        case pending
        case denied
        /// The user approved but the session could not be started.
        case failed
        /// The request itself is wrong (rule broken, project unknown, one already waiting).
        case invalid
        /// Not a live Loom session, or Loom is quitting.
        case unavailable
    }

    public let status: Status
    public let sessionID: UUID?
    public let title: String?
    public let running: Bool?
    public let detail: String?

    public init(status: Status, sessionID: UUID? = nil, title: String? = nil,
                running: Bool? = nil, detail: String? = nil) {
        self.status = status
        self.sessionID = sessionID
        self.title = title
        self.running = running
        self.detail = detail
    }

    public var exitCode: Int32 {
        switch status {
        case .started, .exists, .pending: 0
        case .denied, .failed: 1
        case .invalid: 2
        case .unavailable: 3
        }
    }

    public var line: String {
        let quoted = "\"" + (title ?? "").replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let id = sessionID?.uuidString.lowercased() ?? "unknown"
        switch status {
        case .started: return "started \(id) \(quoted)"
        case .exists: return "exists \(id) \(quoted) \(running == true ? "running" : "stopped")"
        case .pending:
            return "pending: approve or deny it in Loom. Nothing has started yet, and the request is kept in memory only: it is lost if Loom quits."
        case .denied: return "denied"
        case .failed: return "error: the session could not be started: \(detail ?? "unknown reason")"
        case .invalid, .unavailable: return "error: \(detail ?? "the request was not accepted")"
        }
    }
}

struct OpenSessionWireRequest: Codable, Sendable {
    static let protocolVersion = 1
    var version = Self.protocolVersion
    var authenticationToken: String
    var sessionID: UUID
    var managedRunID: UUID
    var title: String
    var ticketKey: String?
    var project: String?
    var message: String
}

/// A request that passed the token check.
struct OpenSessionCall: Sendable {
    let sessionID: UUID
    let managedRunID: UUID
    let title: String
    let ticketKey: String?
    let project: String?
    let message: String
}

// MARK: Client (blocking; the command process)

enum OpenSessionClient {
    /// Sends one request and waits for the one answer. Throws when Loom cannot be reached or
    /// does not answer in time; nothing is retried (a retry could open a second session).
    static func exchange(
        _ request: OpenSessionWireRequest, socketPath: String,
        connectTimeout: TimeInterval = 2, replyTimeout: TimeInterval = OpenSessionLimits.clientWait
    ) throws -> OpenSessionReply {
        let data = try JSONEncoder().encode(request)
        return try exchange(raw: data, socketPath: socketPath, connectTimeout: connectTimeout,
                            replyTimeout: replyTimeout)
    }

    /// The same exchange for bytes the caller built (tests send what a hostile client could).
    static func exchange(
        raw data: Data, socketPath: String, connectTimeout: TimeInterval = 2,
        replyTimeout: TimeInterval = OpenSessionLimits.clientWait
    ) throws -> OpenSessionReply {
        let descriptor = try LocalSocket.connect(path: socketPath, timeout: connectTimeout)
        defer { Darwin.close(descriptor) }
        try LocalSocket.writeAll(
            data, to: descriptor, deadline: ProcessInfo.processInfo.systemUptime + 5
        )
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
            throw ClaudeHookTransportError.system(operation: "shutdown", code: errno)
        }
        let answer = try LocalSocket.readToEnd(
            from: descriptor, limit: 64 * 1024,
            deadline: ProcessInfo.processInfo.systemUptime + replyTimeout
        )
        guard let reply = try? JSONDecoder().decode(OpenSessionReply.self, from: answer) else {
            throw ClaudeHookTransportError.malformedMessage
        }
        return reply
    }
}

// MARK: Server

/// Accepts control connections on a private local socket. The directory rules, the file mode and
/// the per-run token are the hook server's; unlike it, this one answers on the same connection and
/// can hold it open until the request is decided.
final class OpenSessionControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (OpenSessionCall) async -> OpenSessionReply

    private let socketPath: String
    private let authenticationToken: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "dev.loom.open-session.accept", qos: .utility)
    private let serveQueue = DispatchQueue(
        label: "dev.loom.open-session.serve", qos: .utility, attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var stopped = false
    private var inFlight = 0
    private static let maximumInFlight = 32
    /// Time a client has to send its request after connecting.
    private static let requestDeadline: TimeInterval = 5

    init(socketPath: String, authenticationToken: String, handler: @escaping Handler) throws {
        guard !authenticationToken.isEmpty else {
            throw ClaudeHookTransportError.invalidConfiguration("empty authentication token")
        }
        self.socketPath = socketPath
        self.authenticationToken = authenticationToken
        self.handler = handler
        let descriptor = try LocalSocket.listen(at: socketPath)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptAvailable(descriptor: descriptor) }
        source.setCancelHandler {
            Darwin.close(descriptor)
            unlink(socketPath)
        }
        self.source = source
        source.resume()
    }

    deinit { stop() }

    func stop() {
        let source: DispatchSourceRead? = stateLock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let value = self.source
            self.source = nil
            return value
        }
        source?.cancel()
    }

    private func acceptAvailable(descriptor: Int32) {
        while !stateLock.withLock({ stopped }) {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection >= 0 {
                let admitted = stateLock.withLock {
                    guard inFlight < Self.maximumInFlight else { return false }
                    inFlight += 1
                    return true
                }
                guard admitted, (try? LocalSocket.prepare(connection)) != nil else {
                    if admitted { stateLock.withLock { inFlight -= 1 } }
                    Darwin.close(connection)
                    continue
                }
                serveQueue.async { [self] in serve(connection: connection) }
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func finish(_ connection: Int32, _ reply: OpenSessionReply?) {
        if let reply, let data = try? JSONEncoder().encode(reply) {
            try? LocalSocket.writeAll(
                data, to: connection, deadline: ProcessInfo.processInfo.systemUptime + 2
            )
        }
        Darwin.close(connection)
        stateLock.withLock { inFlight -= 1 }
    }

    private func serve(connection: Int32) {
        let data: Data
        do {
            data = try LocalSocket.readToEnd(
                from: connection, limit: OpenSessionLimits.wireByteLimit,
                deadline: ProcessInfo.processInfo.systemUptime + Self.requestDeadline
            )
        } catch ClaudeHookTransportError.messageTooLarge {
            return finish(connection, OpenSessionReply(status: .invalid, detail: "the request is too large"))
        } catch {
            return finish(connection, nil)
        }
        guard let wire = try? JSONDecoder().decode(OpenSessionWireRequest.self, from: data),
              wire.version == OpenSessionWireRequest.protocolVersion else {
            return finish(connection, OpenSessionReply(status: .invalid, detail: "the request is malformed"))
        }
        guard secureEqual(wire.authenticationToken, authenticationToken) else {
            return finish(connection, OpenSessionReply(
                status: .unavailable, detail: "this process is not part of a live Loom session"
            ))
        }
        let call = OpenSessionCall(
            sessionID: wire.sessionID, managedRunID: wire.managedRunID, title: wire.title,
            ticketKey: wire.ticketKey, project: wire.project, message: wire.message
        )
        let handler = self.handler
        Task.detached(priority: .utility) { [self] in
            finish(connection, await handler(call))
        }
    }
}
