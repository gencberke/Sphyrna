import Foundation
import LoomCore

public enum ControlError: Error, Equatable, Sendable {
    /// `system/init` lists capabilities and this request's is not among them; nothing was sent.
    case unsupported(capability: String)
    /// No answer within the timeout. The CLI was told to drop the request.
    case timedOut(requestID: String)
    /// The caller's task was cancelled, or the CLI withdrew the request. The CLI was told to drop it.
    case cancelled(requestID: String)
    /// The channel was closed (the process ended) before an answer came.
    case closed
    /// The CLI answered with an error.
    case rejected(requestID: String, message: String)
}

/// The CLI's success answer to a request.
public struct ControlReply: Sendable, Equatable {
    public var requestID: String
    public var payload: JSONValue

    /// For an `interrupt` reply.
    public var interruptReceipt: InterruptReceipt { InterruptReceipt(json: payload) }

    /// For an `initialize` reply (the account is already removed).
    public var initializeResponse: InitializeResponse { InitializeResponse(json: payload) }

    /// For a `cancel_async_message` reply: false when the uuid was not held.
    public var wasCancelled: Bool? { payload["cancelled"]?.bool }

    /// For a `rewind_conversation` reply: the original text of the message, to put back in the composer.
    public var prefillText: String? { payload["prefillText"]?.string }

    /// For a `side_question` reply.
    public var sideQuestionResponse: String? { payload["response"]?.string }
}

/// What the CLI asks of the host.
public enum ControlEvent: Sendable, Equatable {
    /// A request that waits for the host's answer (`respond(to:…)`). The channel never answers a `can_use_tool` itself.
    case request(IncomingControlRequest)
    /// The CLI withdrew a request that was still waiting (`control_cancel_request`); it can no longer be answered.
    case cancelled(IncomingControlRequest)
    /// A request of a kind Loom does not handle. The channel already answered it with an error, so the CLI is not left
    /// waiting.
    case unsupported(requestID: String, subtype: String?)
}

/// The control half of the stream-json conversation: request ids and the table of requests in flight, both ways.
///
/// - Host to CLI: `request(_:)` assigns an id, queues the line on `outgoing` and waits for the matching
///   `control_response`. It ends with a reply, or `ControlError` on a timeout, a cancelled task, an error answer or a
///   closed channel; the first two also queue a `control_cancel_request` so the CLI drops the work.
/// - CLI to host: `receive(_:)` turns `can_use_tool` and other requests into `events`; the host answers with
///   `respond(to:…)`. A `control_cancel_request` from the CLI removes the waiting request and says so on `events`.
/// - `system/init` capabilities gate the requests that need one.
///
/// The channel does no I/O: the owner feeds it decoded messages (`receive`) and writes every line of `outgoing` to the
/// process's stdin in order.
public actor ControlChannel {
    public nonisolated let outgoing: AsyncStream<Data>
    public nonisolated let events: AsyncStream<ControlEvent>

    private let outgoingContinuation: AsyncStream<Data>.Continuation
    private let eventContinuation: AsyncStream<ControlEvent>.Continuation
    private let defaultTimeout: Duration
    private let makeRequestID: @Sendable () -> String

    private struct Pending {
        let continuation: CheckedContinuation<ControlReply, any Error>
        let subtype: String
        let timer: Task<Void, Never>
    }

    private var pending: [String: Pending] = [:]
    private var waiting: [IncomingControlRequest] = []
    private var capabilities: Set<String>?
    private var isClosed = false

    public init(defaultTimeout: Duration = .seconds(30),
                makeRequestID: @escaping @Sendable () -> String = { "loom-" + UUID().uuidString.lowercased() }) {
        self.defaultTimeout = defaultTimeout
        self.makeRequestID = makeRequestID
        (outgoing, outgoingContinuation) = AsyncStream.makeStream(of: Data.self)
        (events, eventContinuation) = AsyncStream.makeStream(of: ControlEvent.self)
    }

    /// The capabilities the newest `system/init` listed; nil until one did (or when it lists none, which means the CLI
    /// does not say). Only `system/init` counts: the `initialize` answer lists just `ui_surface_v1`, and gating on it
    /// would refuse requests the CLI can do. Before the first turn nothing is refused.
    public var knownCapabilities: Set<String>? { capabilities }

    /// Requests from the CLI that wait for an answer, oldest first.
    public var pendingRequests: [IncomingControlRequest] { waiting }

    // MARK: Host to CLI

    public func request(_ request: OutgoingControlRequest, timeout: Duration? = nil) async throws -> ControlReply {
        if isClosed { throw ControlError.closed }
        if let capability = request.requiredCapability, let capabilities, !capabilities.contains(capability) {
            throw ControlError.unsupported(capability: capability)
        }
        let id = makeRequestID()
        let limit = timeout ?? defaultTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ControlReply, any Error>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    await self?.finish(id, throwing: .timedOut(requestID: id), tellCLI: true)
                }
                pending[id] = Pending(continuation: continuation, subtype: request.subtype, timer: timer)
                outgoingContinuation.yield(ControlWire.requestLine(id: id, request))
            }
        } onCancel: {
            Task { await self.finish(id, throwing: .cancelled(requestID: id), tellCLI: true) }
        }
    }

    /// Sends a request and does not wait for its answer (the answer is ignored). Returns its id.
    @discardableResult
    public func send(_ request: OutgoingControlRequest) -> String? {
        guard !isClosed else { return nil }
        let id = makeRequestID()
        outgoingContinuation.yield(ControlWire.requestLine(id: id, request))
        return id
    }

    // MARK: CLI to host

    /// Routes a decoded message: `system/init` sets the capabilities, `control_*` messages go to the tables. Every
    /// other message is ignored here.
    public func receive(_ message: StreamMessage) {
        switch message {
        case let .systemInit(info):
            if let listed = info.capabilities { capabilities = Set(listed) }
        case let .controlResponse(response):
            switch response.outcome {
            case let .success(payload):
                resolve(response.requestID, with: .success(ControlReply(requestID: response.requestID, payload: payload)))
            case let .error(message):
                resolve(response.requestID, with: .failure(.rejected(requestID: response.requestID, message: message)))
            }
        case let .controlRequest(request):
            switch request.kind {
            case .canUseTool:
                waiting.append(request)
                eventContinuation.yield(.request(request))
            case let .other(subtype, _):
                let name = subtype ?? "unknown"
                outgoingContinuation.yield(ControlWire.errorLine(id: request.requestID, "Loom does not handle \(name) requests"))
                eventContinuation.yield(.unsupported(requestID: request.requestID, subtype: subtype))
            }
        case let .controlCancel(requestID):
            if let index = waiting.firstIndex(where: { $0.requestID == requestID }) {
                eventContinuation.yield(.cancelled(waiting.remove(at: index)))
            } else {
                finish(requestID, throwing: .cancelled(requestID: requestID), tellCLI: false)
            }
        default:
            break
        }
    }

    /// Answers a `can_use_tool` request. False when it is no longer waiting (answered, withdrawn, or the channel closed).
    @discardableResult
    public func respond(to requestID: String, with decision: PermissionDecision) -> Bool {
        answer(requestID, ControlWire.successLine(id: requestID, decision.payload))
    }

    @discardableResult
    public func respond(to requestID: String, success payload: JSONValue) -> Bool {
        answer(requestID, ControlWire.successLine(id: requestID, payload))
    }

    @discardableResult
    public func respond(to requestID: String, error message: String) -> Bool {
        answer(requestID, ControlWire.errorLine(id: requestID, message))
    }

    // MARK: End

    /// The process ended or Loom stopped it: every request in flight fails with `.closed`, waiting requests are
    /// dropped, and `outgoing` and `events` finish.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        for id in Array(pending.keys) { finish(id, throwing: .closed, tellCLI: false) }
        waiting.removeAll()
        outgoingContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: Private

    private func answer(_ requestID: String, _ line: Data) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.requestID == requestID }) else { return false }
        waiting.remove(at: index)
        outgoingContinuation.yield(line)
        return true
    }

    private func resolve(_ id: String, with result: Result<ControlReply, ControlError>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(with: result.mapError { $0 as any Error })
    }

    private func finish(_ id: String, throwing error: ControlError, tellCLI: Bool) {
        guard pending[id] != nil else { return }
        resolve(id, with: .failure(error))
        if tellCLI, !isClosed { outgoingContinuation.yield(ControlWire.cancelLine(id: id)) }
    }
}
