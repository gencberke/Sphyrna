import Foundation

/// Task replies keep the existing control socket's bounded answer size.
enum SessionTaskWireLimits {
    static let replyBytes = 64 * 1024
}

struct SessionTaskWireRequest: Codable, Sendable {
    var version = 5
    var command: String
    var sessionID: UUID
    var runID: UUID
    var generation: UUID
    var credential: String
    var taskID: UUID?
    var targetSessionID: UUID?
    var roundID: UUID?
    var operationID: UUID?
    var nextOperationID: UUID?
    var replyToEventID: UUID?
    var eventIDs: [UUID]?
    var readLeaseID: UUID?
    var kind: SessionTaskReportKind?
    var message: String?
    var name: String?
    var project: String?
    var harness: String?
    var model: String?
    var effort: String?
    var mode: String?
    var after: Int64?
    var limit: Int?
    var revision: Int64?
    var seconds: Double?

    var claim: SessionTaskClaim {
        SessionTaskClaim(sessionID: sessionID, managedRunID: runID, generation: generation, credential: credential)
    }
}

struct SessionTaskWireReply: Codable, Sendable {
    var version: Int
    let status: String
    var detail: String?
    var receipt: SessionTaskReceipt?
    var task: SessionTaskProjection?
    var nativeStatus: SessionTaskNativeStatus?
    var missingReport: Bool?
    var message: String?
    var binding: SessionTaskBinding?

    init(status: String, detail: String? = nil, receipt: SessionTaskReceipt? = nil,
         task: SessionTaskProjection? = nil, nativeStatus: SessionTaskNativeStatus? = nil,
         missingReport: Bool? = nil, message: String? = nil, binding: SessionTaskBinding? = nil) {
        self.version = 5; self.status = status; self.detail = detail; self.receipt = receipt; self.task = task
        self.nativeStatus = nativeStatus; self.missingReport = missingReport; self.message = message; self.binding = binding
    }
}

/// Routes only task-scoped calls. Effects go through the durable coordinator;
/// the runtime remains the sole owner of any provider process.
struct SessionTaskWireRouter: Sendable {
    let coordinator: SessionTaskCoordinator
    let create: @Sendable (SessionTaskWireRequest) async -> SessionTaskWireReply
    let requested: @Sendable (UUID) async -> Void
    let peerSend: @Sendable (SessionTaskWireRequest) async -> SessionTaskWireReply
    let peerInbox: @Sendable (SessionTaskWireRequest) async -> Data
    let peerAck: @Sendable (SessionTaskWireRequest) async -> SessionTaskWireReply
    let readFence: SessionTaskReadFence

    init(coordinator: SessionTaskCoordinator,
         create: @escaping @Sendable (SessionTaskWireRequest) async -> SessionTaskWireReply = { _ in .init(status: "unavailable") },
         requested: @escaping @Sendable (UUID) async -> Void = { _ in },
         reported: @escaping @Sendable (UUID) async -> Void = { _ in },
         peerSend: @escaping @Sendable (SessionTaskWireRequest) async -> SessionTaskWireReply = { _ in .init(status: "unavailable") },
         peerInbox: @escaping @Sendable (SessionTaskWireRequest) async -> Data = { _ in Data(#"{"version":5,"status":"unavailable"}"#.utf8) },
         peerAck: @escaping @Sendable (SessionTaskWireRequest) async -> SessionTaskWireReply = { _ in .init(status: "unavailable") }) {
        self.coordinator = coordinator; self.create = create; self.requested = requested
        self.peerSend = peerSend; self.peerInbox = peerInbox; self.peerAck = peerAck
        readFence = SessionTaskReadFence { id in Task { await reported(id) } }
    }

    func handle(_ data: Data) async -> Data {
        guard let call = try? JSONDecoder().decode(SessionTaskWireRequest.self, from: data),
              call.version == 5 else { return reply(.init(status: "invalid")) }
        do {
            if call.command == "create" { return reply(await create(call)) }
            if call.command == "peer-send" { return reply(await peerSend(call)) }
            if call.command == "peer-inbox" { return await peerInbox(call) }
            if call.command == "peer-inbox-ack" { return reply(await peerAck(call)) }
            if call.command == "identity" {
                return reply(.init(status: "ok", binding: try await coordinator.identity(for: call.claim)))
            }
            guard let taskID = call.taskID else { throw SessionTaskError.invalidPayload }
            switch call.command {
            case "status":
                let status = try await coordinator.status(taskID: taskID, parent: call.claim)
                return reply(.init(status: "ok", task: status.task, nativeStatus: status.nativeStatus,
                                   missingReport: status.missingReport))
            case "read":
                return try await read(call, taskID: taskID, wait: false)
            case "wait":
                return try await read(call, taskID: taskID, wait: true)
            case "ack":
                guard let ids = call.eventIDs else { throw SessionTaskError.invalidPayload }
                try await coordinator.acknowledgeEvents(taskID: taskID, parent: call.claim, eventIDs: ids)
                if let lease = call.readLeaseID {
                    readFence.acknowledge(lease, taskID: taskID, claim: call.claim, eventIDs: ids)
                }
                return reply(.init(status: "ok"))
            case "input":
                guard let round = call.roundID, let operation = call.operationID else { throw SessionTaskError.invalidPayload }
                let message = try await coordinator.childInput(taskID: taskID, child: call.claim,
                                                               roundID: round, inputOperationID: operation)
                return reply(.init(status: "ok", message: message))
            case "report":
                guard let round = call.roundID, let operation = call.operationID,
                      let kind = call.kind, let message = call.message else { throw SessionTaskError.invalidPayload }
                let receipt = try await coordinator.report(taskID: taskID, child: call.claim, roundID: round,
                    operationID: operation, kind: kind, payload: message)
                readFence.scheduleWake(taskID: taskID)
                return reply(.init(status: "ok", receipt: receipt))
            case "reply":
                guard let operation = call.operationID, let message = call.message else { throw SessionTaskError.invalidPayload }
                let receipt = try await coordinator.requestRound(taskID: taskID, parent: call.claim,
                    operationID: operation, message: message, replyToEventID: call.replyToEventID)
                Task { await requested(taskID) }
                return reply(.init(status: "ok", receipt: receipt))
            case "interrupt":
                guard let round = call.roundID, let operation = call.operationID, let next = call.nextOperationID,
                      let message = call.message else { throw SessionTaskError.invalidPayload }
                let receipt = try await coordinator.interruptAndUpdate(taskID: taskID, parent: call.claim,
                    roundID: round, operationID: operation, nextOperationID: next, message: message)
                Task { await requested(taskID) }
                return reply(.init(status: "ok", receipt: receipt))
            case "stop":
                guard let operation = call.operationID else { throw SessionTaskError.invalidPayload }
                let receipt = try await coordinator.stopChild(taskID: taskID, parent: call.claim, operationID: operation)
                return reply(.init(status: "ok", receipt: receipt))
            default:
                return reply(.init(status: "invalid"))
            }
        } catch let error as SessionTaskError {
            return reply(.init(status: "refused", detail: String(describing: error)))
        } catch {
            return reply(.init(status: "unavailable"))
        }
    }

    private func read(_ call: SessionTaskWireRequest, taskID: UUID, wait: Bool) async throws -> Data {
        // Authenticate before a caller is allowed to hold back a nudge.
        _ = try await coordinator.status(taskID: taskID, parent: call.claim)
        let lease = try readFence.begin(taskID: taskID, claim: call.claim)
        do {
            var revision: Int64?
            if wait {
                guard let last = call.revision, let seconds = call.seconds else { throw SessionTaskError.invalidPayload }
                revision = try await coordinator.wait(taskID: taskID, parent: call.claim,
                                                       afterRevision: last, seconds: seconds)?.revision ?? last
            }
            let page = try await coordinator.eventEntries(taskID: taskID, parent: call.claim,
                after: call.after ?? 0, limit: call.limit ?? SessionTaskLimits.pageSize)
            let result = try SessionTaskWirePacking.page(page.items, next: page.next, revision: revision, readLeaseID: lease)
            readFence.delivered(lease, eventIDs: result.returnedIDs)
            return result.data
        } catch {
            readFence.release(lease)
            throw error
        }
    }

    private func reply(_ value: SessionTaskWireReply) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), data.count <= SessionTaskWireLimits.replyBytes else {
            return Data(#"{"version":5,"status":"unavailable"}"#.utf8)
        }
        return data
    }
}

struct SessionTaskWireEvent: Codable, Equatable, Sendable {
    let cursor: Int64
    let id: UUID
    let roundID: UUID
    let kind: SessionTaskReportKind
    let nativeTurnID: String?
    let execution: SessionTaskExecutionReference?
    let occurredAt: Date
    /// Base64 keeps the worst-case JSON escaping of a valid 16 KiB payload bounded.
    let payload: String

    init(_ entry: SessionTaskEventEntry) {
        cursor = entry.cursor
        id = entry.event.id
        roundID = entry.event.roundID
        kind = entry.event.kind
        nativeTurnID = entry.event.nativeTurnID
        execution = entry.event.observedExecution
        occurredAt = entry.event.occurredAt
        payload = Data(entry.event.payload.utf8).base64EncodedString()
    }

    var decodedPayload: String? {
        Data(base64Encoded: payload).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct SessionTaskWirePage: Codable, Equatable, Sendable {
    var version: Int
    let status: String
    let events: [SessionTaskWireEvent]
    let next: Int64?
    let revision: Int64?
    let readLeaseID: UUID?

    init(events: [SessionTaskWireEvent], next: Int64?, revision: Int64? = nil, readLeaseID: UUID? = nil) {
        version = 5
        status = "ok"
        self.events = events
        self.next = next
        self.revision = revision
        self.readLeaseID = readLeaseID
    }
}

enum SessionTaskWirePackingError: Error, Equatable { case invalidPage, replyTooSmall }

enum SessionTaskWirePacking {
    struct Result: Sendable {
        let data: Data
        /// These may be acknowledged only after the client actually reads them.
        let returnedIDs: [UUID]
    }

    static func page(_ entries: [SessionTaskEventEntry], next: Int64?,
                     revision: Int64? = nil, readLeaseID: UUID? = nil,
                     budget: Int = SessionTaskWireLimits.replyBytes) throws -> Result {
        guard budget > 0, entries.count <= SessionTaskLimits.pageSize,
              entries.allSatisfy({ $0.cursor > 0 && $0.event.payload.utf8.count <= SessionTaskLimits.payloadBytes }),
              zip(entries, entries.dropFirst()).allSatisfy({ $0.0.cursor < $0.1.cursor }) else {
            throw SessionTaskWirePackingError.invalidPage
        }
        let cap = min(budget, SessionTaskWireLimits.replyBytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var events: [SessionTaskWireEvent] = []
        var last = try encoder.encode(SessionTaskWirePage(events: [], next: nil, revision: revision, readLeaseID: readLeaseID))
        guard last.count <= cap else { throw SessionTaskWirePackingError.replyTooSmall }
        for (index, entry) in entries.enumerated() {
            let event = SessionTaskWireEvent(entry)
            let candidate = events + [event]
            let continuation = index + 1 < entries.count ? entry.cursor : next
            let data = try encoder.encode(SessionTaskWirePage(events: candidate, next: continuation, revision: revision, readLeaseID: readLeaseID))
            guard data.count <= cap else {
                guard !events.isEmpty else { throw SessionTaskWirePackingError.replyTooSmall }
                return Result(data: last, returnedIDs: events.map(\.id))
            }
            events = candidate
            last = data
        }
        return Result(data: last, returnedIDs: events.map(\.id))
    }
}
