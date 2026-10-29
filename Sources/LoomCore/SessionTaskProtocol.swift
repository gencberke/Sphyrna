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
    var roundID: UUID?
    var operationID: UUID?
    var nextOperationID: UUID?
    var replyToEventID: UUID?
    var eventIDs: [UUID]?
    var kind: SessionTaskReportKind?
    var message: String?
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

    init(status: String, detail: String? = nil, receipt: SessionTaskReceipt? = nil,
         task: SessionTaskProjection? = nil, nativeStatus: SessionTaskNativeStatus? = nil,
         missingReport: Bool? = nil, message: String? = nil) {
        self.version = 5; self.status = status; self.detail = detail; self.receipt = receipt; self.task = task
        self.nativeStatus = nativeStatus; self.missingReport = missingReport; self.message = message
    }
}

/// Routes only task-scoped calls. Effects go through the durable coordinator;
/// the runtime remains the sole owner of any provider process.
struct SessionTaskWireRouter: Sendable {
    let coordinator: SessionTaskCoordinator
    let requested: @Sendable (UUID) async -> Void
    let reported: @Sendable (UUID) async -> Void

    init(coordinator: SessionTaskCoordinator,
         requested: @escaping @Sendable (UUID) async -> Void = { _ in },
         reported: @escaping @Sendable (UUID) async -> Void = { _ in }) {
        self.coordinator = coordinator; self.requested = requested; self.reported = reported
    }

    func handle(_ data: Data) async -> Data {
        guard let call = try? JSONDecoder().decode(SessionTaskWireRequest.self, from: data),
              call.version == 5, let taskID = call.taskID else { return reply(.init(status: "invalid")) }
        do {
            switch call.command {
            case "status":
                let status = try await coordinator.status(taskID: taskID, parent: call.claim)
                return reply(.init(status: "ok", task: status.task, nativeStatus: status.nativeStatus,
                                   missingReport: status.missingReport))
            case "read":
                let page = try await coordinator.eventEntries(taskID: taskID, parent: call.claim,
                    after: call.after ?? 0, limit: call.limit ?? SessionTaskLimits.pageSize)
                return try SessionTaskWirePacking.page(page.items, next: page.next).data
            case "wait":
                guard let revision = call.revision, let seconds = call.seconds else { throw SessionTaskError.invalidPayload }
                let changed = try await coordinator.wait(taskID: taskID, parent: call.claim,
                                                          afterRevision: revision, seconds: seconds)
                let page = try await coordinator.eventEntries(taskID: taskID, parent: call.claim,
                    after: call.after ?? 0, limit: call.limit ?? SessionTaskLimits.pageSize)
                return try SessionTaskWirePacking.page(page.items, next: page.next,
                                                       revision: changed?.revision ?? revision).data
            case "ack":
                guard let ids = call.eventIDs else { throw SessionTaskError.invalidPayload }
                try await coordinator.acknowledgeEvents(taskID: taskID, parent: call.claim, eventIDs: ids)
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
                Task { await reported(taskID) }
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

    init(events: [SessionTaskWireEvent], next: Int64?, revision: Int64? = nil) {
        version = 5
        status = "ok"
        self.events = events
        self.next = next
        self.revision = revision
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
                     revision: Int64? = nil, budget: Int = SessionTaskWireLimits.replyBytes) throws -> Result {
        guard budget > 0, entries.count <= SessionTaskLimits.pageSize,
              entries.allSatisfy({ $0.cursor > 0 && $0.event.payload.utf8.count <= SessionTaskLimits.payloadBytes }),
              zip(entries, entries.dropFirst()).allSatisfy({ $0.0.cursor < $0.1.cursor }) else {
            throw SessionTaskWirePackingError.invalidPage
        }
        let cap = min(budget, SessionTaskWireLimits.replyBytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var events: [SessionTaskWireEvent] = []
        var last = try encoder.encode(SessionTaskWirePage(events: [], next: nil, revision: revision))
        guard last.count <= cap else { throw SessionTaskWirePackingError.replyTooSmall }
        for (index, entry) in entries.enumerated() {
            let event = SessionTaskWireEvent(entry)
            let candidate = events + [event]
            let continuation = index + 1 < entries.count ? entry.cursor : next
            let data = try encoder.encode(SessionTaskWirePage(events: candidate, next: continuation, revision: revision))
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
