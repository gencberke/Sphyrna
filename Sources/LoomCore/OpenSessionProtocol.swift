import Darwin
import Foundation

// A session asks Loom to open another session (D-40), or to list the others (C5a). One request, one answer, on the
// control socket next to the hook socket. This file holds the rules every side shares (limits and input
// validation), the wire shapes, the blocking client the `loom-hook open` command uses, and the
// server. What happens to a request (pending, approval, start) lives in OpenSessionCoordinator.

enum OpenSessionLimits {
    static let messageByteLimit = 64 * 1024
    static let titleLimit = 160
    static let projectLimit = 4_096
    /// The JSON of a request: the message may grow when its characters are escaped.
    static let wireByteLimit = 512 * 1024
    /// The server answers `pending` after this long and keeps the request.
    static let serverReplyDelay: TimeInterval = 85
    /// The client gives up after this long; it must outlast `serverReplyDelay`.
    static let clientWait: TimeInterval = 90
    /// What the client reads of an answer.
    static let replyByteLimit = 64 * 1024
}

public struct OpenSessionRejection: Error, CustomStringConvertible, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// What an agent asked for after the shared syntax rules. The server repeats them and also validates the cached model's levels.
public struct OpenSessionInput: Equatable, Sendable {
    public let title: String
    public let project: String?
    public let message: String
    public let harness: HarnessID
    /// The model the agent asked for (`--model`), a safe token; nil leaves it to the CLI.
    public let model: String?
    /// The effort the agent asked for (`--effort`); the server checks it against the cached model catalogue.
    public let effort: String?
    /// The mode the agent asked for (`--mode`); nil takes the user's configured default.
    public let mode: String?

    public static func validated(
        title: String, project: String?, message: String,
        harness: String? = nil, model: String? = nil, effort: String? = nil, mode: String? = nil
    ) throws -> OpenSessionInput {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw OpenSessionRejection("the title is empty") }
        guard trimmedTitle.count <= OpenSessionLimits.titleLimit else {
            throw OpenSessionRejection("the title is longer than \(OpenSessionLimits.titleLimit) characters")
        }
        guard !trimmedTitle.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) else { throw OpenSessionRejection("the title must be a single line") }

        let projectName = try validatedProject(project)

        guard !message.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OpenSessionRejection("the message contains a NUL character")
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenSessionRejection("the message is empty")
        }
        guard message.utf8.count <= OpenSessionLimits.messageByteLimit else {
            throw OpenSessionRejection("the message is larger than 64 KiB")
        }
        let id = HarnessID(harness?.trimmingCharacters(in: .whitespacesAndNewlines) ?? HarnessID.claude.rawValue)
        guard let descriptor = HarnessCatalogue.descriptor(for: id) else { throw OpenSessionRejection("the harness is not known") }
        if let reason = descriptor.comingLaterReason { throw OpenSessionRejection(reason) }
        let chosenModel = try validatedModel(model)
        let chosenEffort = try validatedEffort(effort)
        let chosenMode = try validatedMode(mode, descriptor: descriptor)
        // The helper has no model probe; the server validates the token against its cached model list.
        return OpenSessionInput(
            title: trimmedTitle, project: projectName, message: message,
            harness: id, model: chosenModel, effort: chosenEffort, mode: chosenMode
        )
    }

    /// A `--model` value: a safe token for the CLI, or nil.
    public static func validatedModel(_ model: String?) throws -> String? {
        guard let raw = model else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeLaunchChoices.isSafeToken(value) else {
            throw OpenSessionRejection("the model is not a safe model name")
        }
        return value
    }

    /// An `--effort` value: a shaped token, or nil. Its model-specific validity is checked on the server.
    public static func validatedEffort(_ effort: String?) throws -> String? {
        guard let raw = effort else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HarnessEffort.isToken(value) else { throw OpenSessionRejection("the effort is not a valid level") }
        return value
    }

    /// A `--mode` value: one of the four modes an agent may pick (Q3), or nil. Full access is refused by name, so the agent
    /// reads why instead of guessing.
    public static func validatedMode(_ mode: String?, descriptor: HarnessDescriptor = HarnessCatalogue.descriptor(for: .claude)!) throws -> String? {
        guard let raw = mode else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if HarnessMode.isFullAccessAlias(value) { throw OpenSessionRejection("Full access is never an agent's choice") }
        guard let mode = HarnessMode(rawValue: value), descriptor.agentModes.contains(mode) else {
            throw OpenSessionRejection("the mode is not supported for this harness")
        }
        return value
    }

    /// The choices an opened session starts with, as the catalog records them.
    public var choices: HarnessLaunchChoices {
        HarnessLaunchChoices(harness: harness, model: model, effort: effort, mode: HarnessMode.fromStored(mode))
    }

    /// A `--project` value (name or path) after the rules; nil stays nil. Shared by `open` and `sessions`.
    public static func validatedProject(_ project: String?) throws -> String? {
        guard let raw = project else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= OpenSessionLimits.projectLimit,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OpenSessionRejection("the project is empty or too long")
        }
        return value
    }
}

/// Loom's answer. `status` decides the exit code of the command; `line` is what the agent reads.
public struct OpenSessionReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The process was launched with the first message.
        case started
        /// Not decided yet; the request stays in Loom and a later approval still opens it.
        case pending
        case denied
        /// The user approved but the session could not be started.
        case failed
        /// The request itself is wrong (rule broken, project unknown, one already waiting).
        case invalid
        /// Not a live Sphyrna session, or Sphyrna is quitting.
        case unavailable
    }

    public let status: Status
    public let sessionID: UUID?
    public let title: String?
    public let detail: String?

    public init(status: Status, sessionID: UUID? = nil, title: String? = nil,
                detail: String? = nil) {
        self.status = status
        self.sessionID = sessionID
        self.title = title
        self.detail = detail
    }

    public var exitCode: Int32 {
        switch status {
        case .started, .pending: 0
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
        case .pending:
            return "pending: approve or deny it in Sphyrna. Nothing has started yet, and the request is kept in memory only: it is lost if Sphyrna quits."
        case .denied: return "denied"
        case .failed: return "error: the session could not be started: \(detail ?? "unknown reason")"
        case .invalid, .unavailable: return "error: \(detail ?? "the request was not accepted")"
        }
    }
}

struct OpenSessionWireRequest: Codable, Sendable {
    static let protocolVersion = 1
    /// Older servers reject this version instead of ignoring a non-Claude harness and starting Claude.
    static let harnessProtocolVersion = 4
    var version = Self.protocolVersion
    var authenticationToken: String
    var sessionID: UUID
    var managedRunID: UUID
    var title: String
    var project: String?
    var message: String
    /// Optional so the helpers of 1.7.0 and older still decode: they send none.
    var model: String? = nil
    var effort: String? = nil
    var mode: String? = nil
    /// Older helpers omit this field; the server treats it as Claude.
    var harness: String? = nil {
        didSet { version = Self.version(for: harness) }
    }

    init(authenticationToken: String, sessionID: UUID, managedRunID: UUID, title: String, project: String?,
         message: String, model: String? = nil, effort: String? = nil, mode: String? = nil, harness: String? = nil) {
        version = Self.version(for: harness)
        self.authenticationToken = authenticationToken
        self.sessionID = sessionID
        self.managedRunID = managedRunID
        self.title = title
        self.project = project
        self.message = message
        self.model = model
        self.effort = effort
        self.mode = mode
        self.harness = harness
    }

    static func version(for harness: String?) -> Int {
        guard let harness else { return protocolVersion }
        return HarnessLaunchChoices(harness: HarnessID(harness)).claudeChoices == nil ? harnessProtocolVersion : protocolVersion
    }
}

/// A request that passed the token check.
struct OpenSessionCall: Sendable {
    let sessionID: UUID
    let managedRunID: UUID
    let title: String
    let project: String?
    let message: String
    let model: String?
    let effort: String?
    let mode: String?
    let harness: String?

    init(sessionID: UUID, managedRunID: UUID, title: String, project: String?, message: String,
         model: String? = nil, effort: String? = nil, mode: String? = nil, harness: String? = nil) {
        self.sessionID = sessionID
        self.managedRunID = managedRunID
        self.title = title
        self.project = project
        self.message = message
        self.model = model
        self.effort = effort
        self.mode = mode
        self.harness = harness
    }
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
        let answer = try roundTrip(raw: data, socketPath: socketPath, connectTimeout: connectTimeout,
                                   replyTimeout: replyTimeout)
        guard let reply = try? JSONDecoder().decode(OpenSessionReply.self, from: answer) else {
            throw ClaudeHookTransportError.malformedMessage
        }
        return reply
    }

    /// Sends the bytes, closes the write side and reads the whole answer (at most 64 KiB).
    static func roundTrip(
        raw data: Data, socketPath: String, connectTimeout: TimeInterval, replyTimeout: TimeInterval
    ) throws -> Data {
        let descriptor = try LocalSocket.connect(path: socketPath, timeout: connectTimeout)
        defer { Darwin.close(descriptor) }
        try LocalSocket.writeAll(
            data, to: descriptor, deadline: ProcessInfo.processInfo.systemUptime + 5
        )
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
            throw ClaudeHookTransportError.system(operation: "shutdown", code: errno)
        }
        return try LocalSocket.readToEnd(
            from: descriptor, limit: OpenSessionLimits.replyByteLimit,
            deadline: ProcessInfo.processInfo.systemUptime + replyTimeout
        )
    }
}

// MARK: Server

/// Accepts control connections on a private local socket. The directory rules, the file mode and
/// the per-run token are the hook server's; unlike it, this one answers on the same connection and
/// can hold it open until the request is decided.
final class OpenSessionControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (OpenSessionCall) async -> OpenSessionReply
    typealias SessionsHandler = @Sendable (SessionListCall) async -> SessionListReply
    typealias WhoAmIHandler = @Sendable (WhoAmICall) async -> WhoAmIReply

    private let socketPath: String
    private let authenticationToken: String
    private let handler: Handler
    private let sessionsHandler: SessionsHandler?
    private let whoAmIHandler: WhoAmIHandler?
    // A session is waiting on this answer, so the queues do not run at utility priority: in a process that
    // is CPU-bound at higher priority (the full test target) utility work waited more than 10 s for a CPU.
    private let acceptQueue = DispatchQueue(label: "dev.loom.open-session.accept", qos: .userInitiated)
    private let serveQueue = DispatchQueue(
        label: "dev.loom.open-session.serve", qos: .userInitiated, attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var stopped = false
    private var inFlight = 0
    private static let maximumInFlight = 32
    /// Time a client has to send its request after connecting.
    private static let requestDeadline: TimeInterval = 5

    init(socketPath: String, authenticationToken: String, sessions: SessionsHandler? = nil,
         whoAmI: WhoAmIHandler? = nil, handler: @escaping Handler) throws {
        guard !authenticationToken.isEmpty else {
            throw ClaudeHookTransportError.invalidConfiguration("empty authentication token")
        }
        self.socketPath = socketPath
        self.authenticationToken = authenticationToken
        self.handler = handler
        sessionsHandler = sessions
        whoAmIHandler = whoAmI
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
        finish(connection, encoded: reply.flatMap { try? JSONEncoder().encode($0) })
    }

    private func finish(_ connection: Int32, _ reply: SessionListReply) {
        finish(connection, encoded: try? SessionListCoding.encoder().encode(reply))
    }

    private func finish(_ connection: Int32, _ reply: WhoAmIReply) {
        finish(connection, encoded: try? SessionListCoding.encoder().encode(reply))
    }

    private func finish(_ connection: Int32, encoded: Data?) {
        if let data = encoded {
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
        // Version 1 is Claude `open` (what older helpers send); 2 carries `sessions`, 3 `whoami`, 4 a non-Claude `open`.
        guard let wire = try? JSONDecoder().decode(OpenSessionWireRequest.self, from: data),
              [OpenSessionWireRequest.protocolVersion, OpenSessionWireRequest.harnessProtocolVersion].contains(wire.version) else {
            if let list = try? JSONDecoder().decode(SessionListWireRequest.self, from: data),
               list.version == SessionListWireRequest.protocolVersion,
               list.command == SessionListWireRequest.commandName {
                return serve(connection: connection, list: list)
            }
            if let who = try? JSONDecoder().decode(WhoAmIWireRequest.self, from: data),
               who.version == WhoAmIWireRequest.protocolVersion,
               who.command == WhoAmIWireRequest.commandName {
                return serve(connection: connection, who: who)
            }
            return finish(connection, OpenSessionReply(status: .invalid, detail: "the request is malformed"))
        }
        guard secureEqual(wire.authenticationToken, authenticationToken) else {
            return finish(connection, OpenSessionReply(
                status: .unavailable, detail: "this process is not part of a live Sphyrna session"
            ))
        }
        guard wire.version == OpenSessionWireRequest.version(for: wire.harness) else {
            return finish(connection, OpenSessionReply(status: .invalid, detail: "the harness requires a newer open protocol"))
        }
        let call = OpenSessionCall(
            sessionID: wire.sessionID, managedRunID: wire.managedRunID, title: wire.title,
            project: wire.project, message: wire.message,
            model: wire.model, effort: wire.effort, mode: wire.mode, harness: wire.harness
        )
        let handler = self.handler
        Task.detached(priority: .userInitiated) { [self] in
            finish(connection, await handler(call))
        }
    }

    private func serve(connection: Int32, list: SessionListWireRequest) {
        guard secureEqual(list.authenticationToken, authenticationToken) else {
            return finish(connection, SessionListReply(
                status: .unavailable, detail: "this process is not part of a live Sphyrna session"
            ))
        }
        guard let handler = sessionsHandler else {
            return finish(connection, SessionListReply(
                status: .unavailable, detail: "this Sphyrna does not list sessions"
            ))
        }
        let call = SessionListCall(
            sessionID: list.sessionID, managedRunID: list.managedRunID, project: list.project,
            all: list.all, limit: list.limit
        )
        Task.detached(priority: .userInitiated) { [self] in
            finish(connection, await handler(call))
        }
    }

    private func serve(connection: Int32, who: WhoAmIWireRequest) {
        guard secureEqual(who.authenticationToken, authenticationToken) else {
            return finish(connection, WhoAmIReply(
                status: .unavailable, detail: "this process is not part of a live Sphyrna session"
            ))
        }
        guard let handler = whoAmIHandler else {
            return finish(connection, WhoAmIReply(
                status: .unavailable, detail: "this Sphyrna does not know its sessions"
            ))
        }
        let call = WhoAmICall(sessionID: who.sessionID, managedRunID: who.managedRunID)
        Task.detached(priority: .userInitiated) { [self] in
            finish(connection, await handler(call))
        }
    }
}
