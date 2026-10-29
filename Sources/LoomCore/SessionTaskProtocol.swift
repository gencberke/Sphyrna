import Foundation

/// Task replies keep the existing control socket's bounded answer size.
enum SessionTaskWireLimits {
    static let replyBytes = 64 * 1024
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
    let version: Int
    let status: String
    let events: [SessionTaskWireEvent]
    let next: Int64?

    init(events: [SessionTaskWireEvent], next: Int64?) {
        version = 5
        status = "ok"
        self.events = events
        self.next = next
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
        var last = try encoder.encode(SessionTaskWirePage(events: [], next: nil))
        guard last.count <= cap else { throw SessionTaskWirePackingError.replyTooSmall }
        for (index, entry) in entries.enumerated() {
            let event = SessionTaskWireEvent(entry)
            let candidate = events + [event]
            let continuation = index + 1 < entries.count ? entry.cursor : next
            let data = try encoder.encode(SessionTaskWirePage(events: candidate, next: continuation))
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
