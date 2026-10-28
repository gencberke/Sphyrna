import CryptoKit
import Darwin
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var object: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var array: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}

public enum CodexAppServerError: Error, CustomStringConvertible, Equatable, Sendable {
    case system(operation: String, code: Int32)
    case protocolViolation(String)
    case timeout(String)
    case closed
    case rpc(code: Int?, message: String, data: JSONValue?)

    /// The server answered that it has no such thread: there is no work of
    /// that thread to stop or unsubscribe.
    public var isThreadNotFound: Bool {
        guard case let .rpc(_, message, _) = self else { return false }
        return message.lowercased().contains("not found")
    }

    public var description: String {
        switch self {
        case let .system(operation, code):
            "Codex app-server \(operation): \(String(cString: strerror(code)))"
        case let .protocolViolation(reason): "Codex app-server protocol: \(reason)"
        case let .timeout(operation): "Codex app-server timed out during \(operation)"
        case .closed: "Codex app-server connection closed"
        case let .rpc(code, message, _):
            "Codex app-server RPC\(code.map { " \($0)" } ?? ""): \(message)"
        }
    }
}

public enum CodexThreadActiveFlag: Hashable, Sendable {
    case waitingOnApproval
    case waitingOnUserInput
    case other(String)
}

public enum CodexThreadStatus: Equatable, Sendable {
    case notLoaded
    case idle
    case systemError
    case active(Set<CodexThreadActiveFlag>)
    case unknown(String)
}

public enum CodexTurnOutcome: Equatable, Sendable {
    case completed
    case interrupted
    case failed(String?)
    case unknown(String)
}

public enum CodexApprovalKind: Equatable, Sendable {
    case commandExecution
    case fileChange
    case permissions
    case userInput
    case other(String)
}

public struct CodexThreadIdentity: Equatable, Sendable {
    public let id: String
    public let workingDirectory: String?
    public let originator: String?
    public let source: String?
    public let ephemeral: Bool?

    public init(id: String, workingDirectory: String?, originator: String?, source: String?,
                ephemeral: Bool? = nil) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.originator = originator
        self.source = source
        self.ephemeral = ephemeral
    }
}

public enum CodexAppServerEvent: Equatable, Sendable {
    case threadStarted(CodexThreadIdentity)
    case threadStatusChanged(threadID: String, status: CodexThreadStatus)
    case turnStarted(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turnID: String,
                       outcome: CodexTurnOutcome, lastAssistantMessage: String?)
    case error(threadID: String, turnID: String?, message: String?, willRetry: Bool)
    case threadClosed(threadID: String)
    case serverRequestResolved(threadID: String, requestID: JSONValue)
    case unknown(method: String)
}

public struct CodexServerRequest: Equatable, Sendable {
    public let id: JSONValue
    public let method: String
    public let params: JSONValue
    public let threadID: String?
    public let kind: CodexApprovalKind
}

public enum CodexAppServerInbound: Equatable, Sendable {
    case event(sequence: UInt64, CodexAppServerEvent)
    case request(sequence: UInt64, CodexServerRequest)
}

/// Development measurement hook: called with each inbound frame's JSON-RPC
/// method (nil for responses) and byte count. The product leaves it unset.
public typealias CodexInboundObserver = @Sendable (_ method: String?, _ bytes: Int) -> Void

public struct CodexThreadSnapshot: Equatable, Sendable {
    public let threadID: String
    public let lastTurnID: String?
    public let lastTurnStartedAt: Date?
    public let lastTurnOutcome: CodexTurnOutcome?
    public let lastAssistantMessage: String?
    public let isActive: Bool
    public let isIdle: Bool
    public let status: CodexThreadStatus

    public var hasNoActiveTurn: Bool {
        isIdle || status == .systemError || status == .notLoaded
    }

    public init(
        threadID: String, lastTurnID: String?, lastTurnStartedAt: Date?,
        lastTurnOutcome: CodexTurnOutcome?, lastAssistantMessage: String?,
        isActive: Bool = false, isIdle: Bool = false,
        status: CodexThreadStatus = .unknown("missing")
    ) {
        self.threadID = threadID
        self.lastTurnID = lastTurnID
        self.lastTurnStartedAt = lastTurnStartedAt
        self.lastTurnOutcome = lastTurnOutcome
        self.lastAssistantMessage = lastAssistantMessage
        self.isActive = isActive
        self.isIdle = isIdle
        self.status = status
    }
}

/// Typed async client for the installed Codex app-server protocol. The decoder
/// intentionally keeps unrecognized methods and fields instead of failing the
/// stream because the protocol is experimental and grows independently of Loom.
public actor CodexAppServerClient {
    public nonisolated let events: AsyncStream<CodexAppServerInbound>

    private let transport: CodexWebSocketTransport
    private let eventContinuation: AsyncStream<CodexAppServerInbound>.Continuation
    private var readerTask: Task<Void, Never>?
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let deadline: Task<Void, Never>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var deadlineTaskCount = 0
    private let wireDiagnostics: CodexWireDiagnostics?
    private let inboundObserver: CodexInboundObserver?
    private var nextRequestID = 1
    private var sequence: UInt64 = 0
    private var terminalError: (any Error)?
    /// The `userAgent` the server's `initialize` answered with (its name and version); nil until connected.
    public private(set) var serverUserAgent: String?

    private init(
        transport: CodexWebSocketTransport, wireDiagnostics: CodexWireDiagnostics?,
        inboundObserver: CodexInboundObserver? = nil
    ) {
        self.wireDiagnostics = wireDiagnostics
        self.inboundObserver = inboundObserver
        self.transport = transport
        var continuation: AsyncStream<CodexAppServerInbound>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(4_096)) {
            continuation = $0
        }
        eventContinuation = continuation
    }

    /// Notifications the product connection never consumes. Loom reads only
    /// thread/started, thread/status/changed, turn/started, turn/completed, error,
    /// serverRequest/resolved and thread/closed (plus server requests, which are
    /// not notifications and cannot be opted out). Everything here is either a
    /// high-frequency stream or item/hook/realtime/account detail that the
    /// decoder maps to `.unknown`, which the router drops as unmatched. The
    /// list is per connection: the TUI's own connection is unaffected. Names the
    /// server does not know are ignored, so version skew cannot fail initialize.
    public static let productOptOutNotificationMethods: [String] = [
        "item/started", "item/completed",
        "item/agentMessage/delta", "item/plan/delta",
        "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded",
        "item/reasoning/textDelta",
        "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction",
        "item/fileChange/outputDelta", "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress",
        "command/exec/outputDelta", "process/outputDelta",
        "thread/tokenUsage/updated", "turn/diff/updated", "turn/plan/updated",
        "account/rateLimits/updated", "model/safetyBuffering/updated",
        "hook/started", "hook/completed",
        "thread/realtime/itemAdded", "thread/realtime/item/started",
        "thread/realtime/item/transcript/delta", "thread/realtime/item/completed",
        "thread/realtime/transcript/delta", "thread/realtime/transcript/done",
        "thread/realtime/outputAudio/delta",
    ]

    /// `optOutNotificationMethods` defaults to none so diagnostic and probe
    /// connections keep seeing everything the server sends.
    public static func connect(
        socketPath: String, clientName: String = "sphyrna",
        clientVersion: String, timeout: TimeInterval = 5,
        wireDiagnostics: CodexWireDiagnostics? = nil,
        optOutNotificationMethods: [String] = [],
        inboundObserver: CodexInboundObserver? = nil
    ) async throws -> CodexAppServerClient {
        let transport = try await Task.detached {
            try CodexWebSocketTransport(socketPath: socketPath, timeout: timeout)
        }.value
        let client = CodexAppServerClient(
            transport: transport, wireDiagnostics: wireDiagnostics, inboundObserver: inboundObserver)
        await client.startReader()
        do {
            var capabilities: [String: JSONValue] = ["experimentalApi": .bool(true)]
            if !optOutNotificationMethods.isEmpty {
                capabilities["optOutNotificationMethods"] = .array(optOutNotificationMethods.map(JSONValue.string))
            }
            let initialized = try await client.request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string(clientName), "version": .string(clientVersion),
                    ]),
                    "capabilities": .object(capabilities),
                ]), timeout: timeout
            )
            await client.noteServerUserAgent(initialized["userAgent"]?.string)
            try await client.notify(method: "initialized", params: .object([:]))
            return client
        } catch {
            wireDiagnostics?.invalidate("preparation")
            await client.close()
            throw error
        }
    }

    deinit {
        readerTask?.cancel()
        transport.close()
        eventContinuation.finish()
    }

    public func latestSequence() -> UInt64 { sequence }

    private func noteServerUserAgent(_ value: String?) { serverUserAgent = value }

    // MARK: Account reads

    // What a probe asks of a server: who is signed in, the limit windows, the token totals and the model list. Each is a
    // read of the account or the catalog; none starts a thread or a turn or calls a model. The answers stay raw `JSONValue`s,
    // read by `HarnessProbeCodex`.

    /// `account/read`: `{account: null | {type, ...}, requiresOpenaiAuth}`. No token refresh is asked for.
    public func readAccount(timeout: TimeInterval = 5) async throws -> JSONValue {
        try await request(method: "account/read", params: .object([:]), timeout: timeout)
    }

    /// `account/rateLimits/read`: the rate-limit snapshots, without the separate reset-credit lookup (a background read).
    public func readRateLimits(timeout: TimeInterval = 5) async throws -> JSONValue {
        try await request(
            method: "account/rateLimits/read", params: .object(["excludeResetCreditDetails": .bool(true)]), timeout: timeout)
    }

    /// `account/usage/read`, account-wide: `{summary, dailyUsageBuckets}`.
    public func readTokenUsage(timeout: TimeInterval = 5) async throws -> JSONValue {
        try await request(method: "account/usage/read", params: .object([:]), timeout: timeout)
    }

    /// `model/list`: every page, hidden models left out by the server's own default. At most `maxPages` are followed.
    public func listModels(timeout: TimeInterval = 5, maxPages: Int = 10) async throws -> [JSONValue] {
        var models: [JSONValue] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request(method: "model/list", params: .object(params), timeout: timeout)
            guard let data = page["data"]?.array else {
                throw CodexAppServerError.protocolViolation("model list has no data array")
            }
            models += data
            guard let next = page["nextCursor"]?.string, !next.isEmpty else { break }
            cursor = next
        }
        return models
    }

    // Internal socket-pair entry point and lifecycle counters for deterministic
    // transport tests; the public connection still performs the WebSocket upgrade.
    static func connectedSocket(descriptor: Int32, bufferedFrames: [UInt8] = []) async throws -> CodexAppServerClient {
        let client = CodexAppServerClient(
            transport: try CodexWebSocketTransport(descriptor: descriptor, bufferedFrames: bufferedFrames), wireDiagnostics: nil)
        await client.startReader()
        return client
    }

    func requestWorkCounts() -> (pending: Int, deadlines: Int) {
        (pending.count, deadlineTaskCount)
    }

    nonisolated func readWaitCounts() -> (waiting: Bool, wakeups: Int) {
        transport.readWaitCounts()
    }

    public func request(
        method: String, params: JSONValue = .object([:]),
        timeout: TimeInterval = 20
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        let id = nextRequestID
        nextRequestID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                deadlineTaskCount += 1
                let deadline = Task { [weak self] in
                    let expired: Bool
                    do {
                        try await Task.sleep(for: .seconds(max(0.02, timeout)))
                        expired = true
                    } catch { expired = false }
                    await self?.deadlineEnded(id: id, method: method, expired: expired)
                }
                pending[id] = PendingRequest(continuation: continuation, deadline: deadline)
                let transport = self.transport
                Task.detached {
                    do {
                        try transport.send(try JSONEncoder().encode(JSONValue.object([
                            "id": .number(Double(id)),
                            "method": .string(method),
                            "params": params,
                        ])))
                    } catch {
                        await self.failRequest(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failRequest(id: id, error: CancellationError()) }
        }
    }

    public func notify(method: String, params: JSONValue = .object([:])) async throws {
        if let terminalError { throw terminalError }
        let data = try JSONEncoder().encode(JSONValue.object([
            "method": .string(method), "params": params,
        ]))
        let transport = self.transport
        try await Task.detached { try transport.send(data) }.value
    }

    /// Status comes from a history-free `thread/read`; the last turn (id, start,
    /// outcome, last assistant message) from the newest page of `thread/turns/list`,
    /// so a long conversation is never transferred or decoded in full. A thread
    /// without persisted turns reports no last turn; an unknown thread still fails.
    public func readThread(_ threadID: String) async throws -> CodexThreadSnapshot {
        var snapshot = try await readThreadOnce(threadID)
        // The two reads are not atomic. Status and the newest turn disagree only
        // while a turn starts or ends between them, so one retry settles it.
        if snapshot.isActive != (snapshot.lastTurnOutcome == .unknown("inProgress"))
            && snapshot.lastTurnID != nil {
            snapshot = try await readThreadOnce(threadID)
        }
        return snapshot
    }

    private func readThreadOnce(_ threadID: String) async throws -> CodexThreadSnapshot {
        let statusResult = try await request(
            method: "thread/read",
            params: .object(["threadId": .string(threadID), "includeTurns": .bool(false)])
        )
        let thread = statusResult.object?["thread"]?.object ?? [:]
        let lastTurn = try await newestTurn(threadID)
        return CodexThreadSnapshot(
            threadID: thread["id"]?.string ?? threadID,
            lastTurnID: lastTurn?["id"]?.string,
            lastTurnStartedAt: Self.number(lastTurn?["startedAt"])
                .map(Date.init(timeIntervalSince1970:)),
            lastTurnOutcome: lastTurn.map(Self.decodeOutcome),
            lastAssistantMessage: lastTurn.flatMap(Self.lastAssistantMessage),
            isActive: thread["status"]?.object?["type"]?.string == "active",
            isIdle: thread["status"]?.object?["type"]?.string == "idle",
            status: Self.decodeStatus(thread["status"])
        )
    }

    private func newestTurn(_ threadID: String) async throws -> [String: JSONValue]? {
        do {
            let page = try await request(
                method: "thread/turns/list",
                params: .object([
                    "threadId": .string(threadID), "limit": .number(1),
                    "sortDirection": .string("desc"), "itemsView": .string("summary"),
                ])
            )
            return page.object?["data"]?.array?.first?.object
        } catch CodexAppServerError.rpc(let code, let message, _)
            where (code == -32600 && message.contains("not materialized"))
                || (code == -32601 && message.contains("list_turns")) {
            // A newly created TUI thread has no persisted turns yet.
            return nil
        }
    }

    public func backgroundTerminals(threadID: String) async throws -> [String] {
        let result = try await request(
            method: "thread/backgroundTerminals/list",
            params: .object(["threadId": .string(threadID)])
        )
        guard let data = result.object?["data"]?.array else {
            throw CodexAppServerError.protocolViolation(
                "background terminal list has no data array"
            )
        }
        return try data.map { item in
            guard let processID = item.object?["processId"]?.string else {
                throw CodexAppServerError.protocolViolation(
                    "background terminal is missing processId"
                )
            }
            return processID
        }
    }

    public func backgroundTerminalCount(threadID: String) async throws -> Int {
        try await backgroundTerminals(threadID: threadID).count
    }

    /// The server owns remote turns and background commands after the TUI exits.
    /// Keep the PTY alive until the server confirms both have stopped.
    public func stopThreadWork(_ threadID: String) async throws {
        try await Self.stopThreadWork(
            threadID,
            read: { try await self.readThread($0) },
            terminals: { try await self.backgroundTerminals(threadID: $0) },
            interrupt: { threadID, turnID in
                _ = try await self.request(
                    method: "turn/interrupt",
                    params: .object([
                        "threadId": .string(threadID), "turnId": .string(turnID),
                    ])
                )
            },
            terminate: { threadID, processID in
                _ = try await self.request(
                    method: "thread/backgroundTerminals/terminate",
                    params: .object([
                        "threadId": .string(threadID), "processId": .string(processID),
                    ])
                )
            }
        )
    }

    static func stopThreadWork(
        _ threadID: String,
        read: @Sendable (String) async throws -> CodexThreadSnapshot,
        terminals: @Sendable (String) async throws -> [String],
        interrupt: @Sendable (String, String) async throws -> Void,
        terminate: @Sendable (String, String) async throws -> Void
    ) async throws {
        let initial = try await read(threadID)
        guard initial.isActive || initial.hasNoActiveTurn else {
            throw CodexAppServerError.protocolViolation(
                "thread \(threadID) has an unrecognized status"
            )
        }
        if initial.isActive {
            guard let turnID = initial.lastTurnID else {
                throw CodexAppServerError.protocolViolation(
                    "active thread \(threadID) has no turn id"
                )
            }
            do {
                try await interrupt(threadID, turnID)
            } catch {
                // The turn may finish between read and interrupt. Verify below.
                guard try await read(threadID).hasNoActiveTurn else { throw error }
            }
        }
        for processID in try await terminals(threadID) {
            try await terminate(threadID, processID)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let snapshot = try await read(threadID)
            let remainingTerminals = try await terminals(threadID)
            if snapshot.hasNoActiveTurn && remainingTerminals.isEmpty { return }
            try await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw CodexAppServerError.timeout("verifying stopped thread \(threadID)")
    }

    /// Joining is deliberately limited to identity: native TUI settings remain authoritative.
    public func joinThread(_ threadID: String, timeout: TimeInterval = 20) async throws {
        let result = try await request(method: "thread/resume",
            params: .object(["threadId": .string(threadID), "excludeTurns": .bool(true)]), timeout: timeout)
        guard result.object?["thread"]?.object?["id"]?.string == threadID else {
            throw CodexAppServerError.protocolViolation("thread/resume returned a missing or different thread identity")
        }
    }

    /// Inspect the same persisted thread without overwriting its native settings.
    /// Only the two observed safe permission combinations may reach a TUI.
    func resumeThread(_ threadID: String, workingDirectory: String) async throws -> CodexResumeSettings {
        let result = try await request(method: "thread/resume",
            params: .object(["threadId": .string(threadID), "excludeTurns": .bool(true)]))
        let response = result.object ?? [:]
        let thread = response["thread"]?.object ?? [:]
        guard thread["id"]?.string == threadID else {
            throw CodexAppServerError.protocolViolation("thread/resume returned a missing or different thread identity")
        }
        guard let cwd = response["cwd"]?.string, cwd.hasPrefix("/"), workingDirectory.hasPrefix("/"),
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
                == URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CodexAppServerError.protocolViolation("thread/resume returned a different working directory")
        }
        let sandbox = response["sandbox"]?.object ?? [:]
        let mode: HarnessMode
        switch sandbox["type"]?.string {
        case "readOnly": mode = .askBeforeEdits
        case "workspaceWrite" where sandbox["writableRoots"]?.array == []: mode = .acceptEdits
        default: throw CodexAppServerError.protocolViolation("thread/resume returned unverified permissions")
        }
        guard sandbox["networkAccess"]?.bool == false,
              response["approvalPolicy"]?.string == "on-request",
              response["approvalsReviewer"]?.string == "user",
              response["activePermissionProfile"] == nil || response["activePermissionProfile"] == .null,
              response["runtimeWorkspaceRoots"] == nil || response["runtimeWorkspaceRoots"]?.array == [] else {
            throw CodexAppServerError.protocolViolation("thread/resume returned unverified permissions")
        }
        return CodexResumeSettings(model: response["model"]?.string,
                                   effort: response["reasoningEffort"]?.string, mode: mode)
    }

    public func unsubscribe(threadID: String) async throws {
        _ = try await request(
            method: "thread/unsubscribe",
            params: .object(["threadId": .string(threadID)])
        )
    }

    public func respond(id: JSONValue, result: JSONValue) async throws {
        let data = try JSONEncoder().encode(JSONValue.object([
            "id": id, "result": result,
        ]))
        let transport = self.transport
        try await Task.detached { try transport.send(data) }.value
    }

    public func close() {
        readerTask?.cancel()
        readerTask = nil
        transport.close()
        if terminalError == nil { terminalError = CodexAppServerError.closed }
        failAll(CodexAppServerError.closed)
        eventContinuation.finish()
    }

    private func startReader() {
        guard readerTask == nil else { return }
        let transport = self.transport
        readerTask = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    let messages = try await transport.receive()
                    for message in messages { await self?.receive(message) }
                }
            } catch {
                await self?.readerStopped(error)
            }
        }
    }

    private func receive(_ data: Data) async {
        let diagnosticToken = wireDiagnostics?.observe(data)
        if let inboundObserver {
            let head = try? JSONDecoder().decode(JSONValue.self, from: data)
            inboundObserver(head?.object?["method"]?.string, data.count)
        }
        func decoded(_ outcome: String) {
            if let diagnosticToken { wireDiagnostics?.decoded(diagnosticToken, outcome: outcome) }
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let object = value.object else {
                throw CodexAppServerError.protocolViolation("expected JSON object")
            }
            if let id = Self.integer(object["id"]), object["method"] == nil {
                decoded("response")
                guard let request = pending.removeValue(forKey: id) else { return }
                request.deadline.cancel()
                let continuation = request.continuation
                if let error = object["error"]?.object {
                    continuation.resume(throwing: CodexAppServerError.rpc(
                        code: Self.integer(error["code"]),
                        message: error["message"]?.string ?? "unknown error",
                        data: error["data"]
                    ))
                } else {
                    continuation.resume(returning: object["result"] ?? .object([:]))
                }
                return
            }
            guard let method = object["method"]?.string else {
                throw CodexAppServerError.protocolViolation("message has neither response nor method")
            }
            sequence &+= 1
            let params = object["params"] ?? .object([:])
            if let id = object["id"] {
                decoded("request")
                let inbound = CodexAppServerInbound.request(
                    sequence: sequence,
                    CodexServerRequest(
                        id: id, method: method, params: params,
                        threadID: params.object?["threadId"]?.string,
                        kind: Self.requestKind(method)
                    )
                )
                if let diagnosticToken { await wireDiagnostics?.route(inbound, token: diagnosticToken) }
                yieldInbound(inbound)
            } else {
                let event = Self.decodeEvent(method: method, params: params)
                if case .unknown = event { decoded("unknown-event") } else { decoded("event") }
                let inbound = CodexAppServerInbound.event(sequence: sequence, event)
                if let diagnosticToken { await wireDiagnostics?.route(inbound, token: diagnosticToken) }
                yieldInbound(inbound)
            }
        } catch {
            decoded("failed")
            readerStopped(error)
        }
    }

    private func failRequest(id: Int, error: any Error) {
        if let request = pending.removeValue(forKey: id) {
            request.deadline.cancel()
            if case CodexAppServerError.timeout = error { wireDiagnostics?.invalidate("timeout") }
            request.continuation.resume(throwing: error)
        }
    }

    private func deadlineEnded(id: Int, method: String, expired: Bool) {
        deadlineTaskCount -= 1
        if expired { failRequest(id: id, error: CodexAppServerError.timeout(method)) }
    }

    private func yieldInbound(_ inbound: CodexAppServerInbound) {
        if case .dropped = eventContinuation.yield(inbound) {
            wireDiagnostics?.invalidate("stream-drop")
            readerStopped(CodexAppServerError.protocolViolation(
                "event consumer fell more than 4096 messages behind"
            ))
        }
    }

    private func readerStopped(_ error: any Error) {
        guard terminalError == nil else { return }
        wireDiagnostics?.invalidate(error is CodexAppServerError && (error as? CodexAppServerError) == .closed ? "disconnect" : "protocol")
        terminalError = error
        transport.close()
        failAll(error)
        eventContinuation.finish()
    }

    private func failAll(_ error: any Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.deadline.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number) = value, number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case let .number(number) = value else { return nil }
        return number
    }

    static func requestKind(_ method: String) -> CodexApprovalKind {
        switch method {
        case "item/commandExecution/requestApproval": .commandExecution
        case "item/fileChange/requestApproval": .fileChange
        case "item/permissions/requestApproval": .permissions
        case "item/tool/requestUserInput": .userInput
        default: .other(method)
        }
    }

    static func decodeEvent(method: String, params: JSONValue) -> CodexAppServerEvent {
        let object = params.object ?? [:]
        switch method {
        case "thread/started":
            let thread = object["thread"]?.object ?? [:]
            guard let id = thread["id"]?.string else { return .unknown(method: method) }
            return .threadStarted(CodexThreadIdentity(
                id: id, workingDirectory: thread["cwd"]?.string,
                originator: thread["originator"]?.string,
                source: thread["source"]?.string,
                ephemeral: thread["ephemeral"]?.bool
            ))
        case "thread/status/changed":
            guard let threadID = object["threadId"]?.string else {
                return .unknown(method: method)
            }
            return .threadStatusChanged(
                threadID: threadID, status: decodeStatus(object["status"])
            )
        case "turn/started":
            guard let threadID = object["threadId"]?.string,
                  let turnID = object["turn"]?.object?["id"]?.string else {
                return .unknown(method: method)
            }
            return .turnStarted(threadID: threadID, turnID: turnID)
        case "turn/completed":
            guard let threadID = object["threadId"]?.string,
                  let turn = object["turn"]?.object,
                  let turnID = turn["id"]?.string else {
                return .unknown(method: method)
            }
            return .turnCompleted(
                threadID: threadID, turnID: turnID,
                outcome: decodeOutcome(turn),
                lastAssistantMessage: lastAssistantMessage(turn)
            )
        case "error":
            guard let threadID = object["threadId"]?.string else {
                return .unknown(method: method)
            }
            return .error(
                threadID: threadID, turnID: object["turnId"]?.string,
                message: object["error"]?.object?["message"]?.string,
                willRetry: object["willRetry"]?.bool ?? false
            )
        case "serverRequest/resolved":
            guard let threadID = object["threadId"]?.string,
                  let requestID = object["requestId"] else { return .unknown(method: method) }
            switch requestID {
            case .string: break
            case let .number(value) where value.isFinite && value.rounded() == value: break
            default: return .unknown(method: method)
            }
            return .serverRequestResolved(threadID: threadID, requestID: requestID)
        case "thread/closed":
            guard let threadID = object["threadId"]?.string else {
                return .unknown(method: method)
            }
            return .threadClosed(threadID: threadID)
        default:
            return .unknown(method: method)
        }
    }

    private static func decodeStatus(_ value: JSONValue?) -> CodexThreadStatus {
        let object = value?.object ?? [:]
        let type = object["type"]?.string ?? "missing"
        switch type {
        case "notLoaded": return .notLoaded
        case "idle": return .idle
        case "systemError": return .systemError
        case "active":
            let flags: Set<CodexThreadActiveFlag> = Set(
                (object["activeFlags"]?.array ?? []).compactMap { value -> CodexThreadActiveFlag? in
                guard let flag = value.string else { return nil }
                switch flag {
                case "waitingOnApproval": return .waitingOnApproval
                case "waitingOnUserInput": return .waitingOnUserInput
                default: return .other(flag)
                }
            })
            return .active(flags)
        default: return .unknown(type)
        }
    }

    private static func decodeOutcome(_ turn: [String: JSONValue]) -> CodexTurnOutcome {
        let status = turn["status"]?.string ?? "missing"
        let error = turn["error"]?.object?["message"]?.string
        switch status {
        case "completed": return .completed
        case "interrupted": return .interrupted
        case "failed": return .failed(error)
        default: return .unknown(status)
        }
    }

    private static func lastAssistantMessage(_ turn: [String: JSONValue]) -> String? {
        (turn["items"]?.array ?? []).reversed().compactMap { value in
            let item = value.object ?? [:]
            guard item["type"]?.string == "agentMessage" else { return nil }
            return item["text"]?.string
        }.first
    }
}

private final class CodexWebSocketTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private let limit = 16 * 1024 * 1024
    private var input: [UInt8] = []
    private var fragments: [UInt8]?
    private var closed = false
    private var readSource: (any DispatchSourceRead)?
    private var readSourceSuspended = true
    private var readWaiter: CheckedContinuation<Void, any Error>?
    private var testReadWakeups: Int?

    init(descriptor: Int32, bufferedFrames: [UInt8]) throws {
        self.descriptor = descriptor
        input = bufferedFrames
        do {
            var enabled: Int32 = 1
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                             socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw CodexAppServerError.system(operation: "socket setup", code: errno)
            }
            testReadWakeups = 0
            installReadSource()
        } catch {
            Darwin.close(descriptor)
            self.descriptor = -1
            throw error
        }
    }

    init(socketPath: String, timeout: TimeInterval) throws {
        var address = sockaddr_un()
        let path = Array(socketPath.utf8)
        guard !path.contains(0), path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CodexAppServerError.protocolViolation("Unix socket path is too long or contains NUL")
        }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexAppServerError.system(operation: "socket", code: errno) }
        do {
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                             socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw CodexAppServerError.system(operation: "SO_NOSIGPIPE", code: errno)
            }
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw CodexAppServerError.system(operation: "fcntl", code: errno)
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: path + [0])
            }
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.02, timeout)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result < 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
                    throw CodexAppServerError.system(operation: "connect", code: errno)
                }
                try wait(for: Int16(POLLOUT), deadline: deadline, operation: "connect")
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                    throw CodexAppServerError.system(operation: "connect status", code: errno)
                }
                guard socketError == 0 else {
                    throw CodexAppServerError.system(operation: "connect", code: socketError)
                }
            }
            try upgrade(deadline: deadline)
            installReadSource()
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit { close() }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        closed = true
        let source = readSource
        readSource = nil
        let waiter = readWaiter
        readWaiter = nil
        if let source {
            if readSourceSuspended { source.resume() }
            source.cancel()
        }
        lock.unlock()
        waiter?.resume(throwing: CodexAppServerError.closed)
        // Once installed, the source's cancel handler exclusively owns close.
        if source == nil, fd >= 0 { Darwin.close(fd) }
    }

    private func installReadSource() {
        let fd = descriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "loom.codex.socket-read"))
        source.setEventHandler { [weak self] in self?.readReady() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
    }

    private func readReady() {
        let waiter: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard !closed, let source = readSource, !readSourceSuspended else { return nil }
            source.suspend()
            readSourceSuspended = true
            if let count = testReadWakeups { testReadWakeups = count + 1 }
            let waiter = readWaiter
            readWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func readWaitCounts() -> (waiting: Bool, wakeups: Int) {
        lock.withLock { (readWaiter != nil, testReadWakeups ?? 0) }
    }

    private func waitForRead() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    guard !closed, let source = readSource else {
                        waiter.resume(throwing: CodexAppServerError.closed)
                        return
                    }
                    precondition(readWaiter == nil, "Only one socket reader is allowed")
                    readWaiter = waiter
                    readSourceSuspended = false
                    source.resume()
                }
            }
        } onCancel: { self.close() }
    }

    func send(_ data: Data) throws {
        guard data.count <= limit else {
            throw CodexAppServerError.protocolViolation("outgoing message exceeds 16 MiB")
        }
        lock.lock()
        defer { lock.unlock() }
        try sendFrameLocked(opcode: 1, payload: Array(data))
    }

    func receive() async throws -> [Data] {
        while true {
            try Task.checkCancellation()
            let messages = try receiveReady()
            if !messages.isEmpty { return messages }
            try await waitForRead()
        }
    }

    private func receiveReady() throws -> [Data] {
        var messages: [Data] = []
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !closed else { throw CodexAppServerError.closed }
        try parseFramesLocked(into: &messages)
        if !messages.isEmpty { return messages }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        if count > 0 {
            guard input.count + count <= limit + 14 else {
                throw CodexAppServerError.protocolViolation("receive buffer exceeds 16 MiB")
            }
            input.append(contentsOf: bytes.prefix(count))
            try parseFramesLocked(into: &messages)
            return messages
        }
        if count == 0 {
            closed = true
            throw CodexAppServerError.closed
        }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return [] }
        throw CodexAppServerError.system(operation: "read", code: errno)
    }

    private func upgrade(deadline: TimeInterval) throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try writeLocked(Array(request.utf8), deadline: deadline)
        let separator: [UInt8] = [13, 10, 13, 10]
        while true {
            if let end = input.indices.first(where: { index in
                index + 4 <= input.count && Array(input[index..<(index + 4)]) == separator
            }) {
                guard let header = String(bytes: input.prefix(end), encoding: .utf8) else {
                    throw CodexAppServerError.protocolViolation("invalid upgrade headers")
                }
                input.removeFirst(end + 4)
                let lines = header.components(separatedBy: "\r\n")
                let status = lines[0].split(separator: " ")
                guard status.count >= 2, status[0] == "HTTP/1.1", status[1] == "101" else {
                    throw CodexAppServerError.protocolViolation(
                        "WebSocket upgrade rejected: \(lines[0])"
                    )
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else {
                        throw CodexAppServerError.protocolViolation("malformed upgrade header")
                    }
                    let name = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                    headers[name] = headers[name].map { $0 + "," + value } ?? value
                }
                let expected = Data(Insecure.SHA1.hash(
                    data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
                )).base64EncodedString()
                let connection = headers["connection", default: ""].lowercased()
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard headers["sec-websocket-accept"] == expected,
                      headers["upgrade"]?.lowercased() == "websocket",
                      connection.contains("upgrade"),
                      headers["sec-websocket-extensions"] == nil,
                      headers["sec-websocket-protocol"] == nil else {
                    throw CodexAppServerError.protocolViolation("invalid WebSocket upgrade response")
                }
                return
            }
            guard input.count < 65_536 else {
                throw CodexAppServerError.protocolViolation("upgrade headers exceed 64 KiB")
            }
            try wait(for: Int16(POLLIN), deadline: deadline, operation: "WebSocket upgrade")
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 { input.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { throw CodexAppServerError.closed }
            else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw CodexAppServerError.system(operation: "upgrade read", code: errno)
            }
        }
    }

    private func parseFramesLocked(into messages: inout [Data]) throws {
        while input.count >= 2 {
            let final = input[0] & 0x80 != 0
            let opcode = input[0] & 0x0f
            guard input[0] & 0x70 == 0, input[1] & 0x80 == 0 else {
                throw CodexAppServerError.protocolViolation("reserved bits or masked server frame")
            }
            var length = UInt64(input[1] & 0x7f)
            var offset = 2
            if length == 126 || length == 127 {
                let byteCount = length == 126 ? 2 : 8
                guard input.count >= offset + byteCount else { return }
                length = input[offset..<(offset + byteCount)].reduce(UInt64(0)) {
                    ($0 << 8) | UInt64($1)
                }
                guard (byteCount == 2 && length >= 126)
                        || (byteCount == 8 && length >= 65_536) else {
                    throw CodexAppServerError.protocolViolation("noncanonical frame length")
                }
                offset += byteCount
            }
            guard length <= limit else {
                throw CodexAppServerError.protocolViolation("frame exceeds 16 MiB")
            }
            if opcode >= 8 && (!final || length > 125) {
                throw CodexAppServerError.protocolViolation("invalid control frame")
            }
            guard input.count >= offset + Int(length) else { return }
            let payload = Array(input[offset..<(offset + Int(length))])
            input.removeFirst(offset + Int(length))
            switch opcode {
            case 0:
                guard fragments != nil else {
                    throw CodexAppServerError.protocolViolation("unexpected continuation")
                }
                guard fragments!.count + payload.count <= limit else {
                    throw CodexAppServerError.protocolViolation("fragmented message exceeds 16 MiB")
                }
                fragments!.append(contentsOf: payload)
                if final {
                    let complete = fragments!
                    fragments = nil
                    try appendText(complete, to: &messages)
                }
            case 1:
                guard fragments == nil else {
                    throw CodexAppServerError.protocolViolation("text frame during fragmented message")
                }
                if final { try appendText(payload, to: &messages) }
                else { fragments = payload }
            case 8:
                guard payload.count != 1 else {
                    throw CodexAppServerError.protocolViolation("invalid close payload")
                }
                try sendFrameLocked(opcode: 8, payload: payload)
                closed = true
                throw CodexAppServerError.closed
            case 9: try sendFrameLocked(opcode: 10, payload: payload)
            case 10: break
            default:
                throw CodexAppServerError.protocolViolation("unsupported opcode \(opcode)")
            }
        }
    }

    private func appendText(_ payload: [UInt8], to messages: inout [Data]) throws {
        guard String(bytes: payload, encoding: .utf8) != nil else {
            throw CodexAppServerError.protocolViolation("text message is not UTF-8")
        }
        messages.append(Data(payload))
    }

    private func sendFrameLocked(opcode: UInt8, payload: [UInt8]) throws {
        guard descriptor >= 0, !closed else { throw CodexAppServerError.closed }
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> shift) & 0xff))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try writeLocked(
            frame, deadline: ProcessInfo.processInfo.systemUptime + 5
        )
    }

    private func writeLocked(_ bytes: [UInt8], deadline: TimeInterval) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset),
                            bytes.count - offset, 0)
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try wait(for: Int16(POLLOUT), deadline: deadline, operation: "write")
            } else {
                throw CodexAppServerError.system(
                    operation: "write", code: count == 0 ? EPIPE : errno
                )
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw CodexAppServerError.timeout("write")
            }
        }
    }

    private func wait(for events: Int16, deadline: TimeInterval,
                      operation: String) throws {
        guard try waitIfReady(for: events, deadline: deadline) else {
            throw CodexAppServerError.timeout(operation)
        }
    }

    private func waitIfReady(for events: Int16, deadline: TimeInterval,
                             on waitDescriptor: Int32? = nil) throws -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: waitDescriptor ?? self.descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 5_000)))
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                    throw CodexAppServerError.system(operation: "poll", code: EBADF)
                }
                return true
            }
            if result == 0 { return false }
            if errno != EINTR {
                throw CodexAppServerError.system(operation: "poll", code: errno)
            }
        }
    }
}
