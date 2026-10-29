import Foundation

/// A sender-card snapshot; credentials never enter the UI model.
public struct OpenSessionSendRequest: Equatable, Sendable {
    public let targetSessionID: UUID
    public let targetTitle: String
    public let targetHarness: HarnessID
    public let operationID: UUID

    init(targetSessionID: UUID, targetTitle: String, targetHarness: HarnessID, operationID: UUID) {
        self.targetSessionID = targetSessionID; self.targetTitle = targetTitle
        self.targetHarness = targetHarness; self.operationID = operationID
    }
}

struct PeerWireMessage: Codable, Equatable, Sendable {
    let sequence: Int64
    let id: UUID
    let senderID: UUID
    let senderTitle: String
    let createdAt: Date
    let payload: String

    init(_ entry: PeerMailboxEntry) {
        sequence = entry.sequence; id = entry.id; senderID = entry.senderID; senderTitle = entry.senderTitle
        createdAt = entry.createdAt; payload = Data(entry.message.utf8).base64EncodedString()
    }
    var message: String? { Data(base64Encoded: payload).flatMap { String(data: $0, encoding: .utf8) } }
}

struct PeerWirePage: Codable, Equatable, Sendable {
    let version: Int
    let status: String
    let messages: [PeerWireMessage]
    let next: Int64?
    let readLeaseID: UUID?

    init(messages: [PeerWireMessage], next: Int64?, readLeaseID: UUID? = nil) {
        version = 5; status = "ok"; self.messages = messages; self.next = next
        self.readLeaseID = readLeaseID
    }
}

enum PeerWirePacking {
    static func page(_ entries: [PeerMailboxEntry], limit: Int, readLeaseID: UUID? = nil) throws -> (data: Data, ids: [UUID]) {
        guard (1...SessionTaskLimits.pageSize).contains(limit), entries.count <= limit,
              entries.allSatisfy({ $0.sequence > 0 && $0.message.utf8.count <= SessionTaskLimits.payloadBytes }),
              zip(entries, entries.dropFirst()).allSatisfy({ $0.0.sequence < $0.1.sequence }) else {
            throw SessionTaskError.invalidPage
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var packed: [PeerWireMessage] = []
        for entry in entries {
            let candidate = packed + [PeerWireMessage(entry)]
            let cursor = candidate.last?.sequence
            let data = try encoder.encode(PeerWirePage(messages: candidate, next: cursor, readLeaseID: readLeaseID))
            if data.count > SessionTaskWireLimits.replyBytes { break }
            packed = candidate
        }
        guard entries.isEmpty || !packed.isEmpty else { throw SessionTaskError.storage }
        let next = packed.count < entries.count || entries.count == limit ? packed.last?.sequence : nil
        let data = try encoder.encode(PeerWirePage(messages: packed, next: next, readLeaseID: readLeaseID))
        guard data.count <= SessionTaskWireLimits.replyBytes else { throw SessionTaskError.storage }
        return (data, packed.map(\.id))
    }
}
