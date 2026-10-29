import Foundation

/// Identity and ordering metadata only. A volatile event alone is never a
/// completed app round: its caller must correlate the exact admitted input.
public struct OpenCodeEvent: Equatable, Sendable {
    public let id: String
    public let type: String
    public let sessionID: String?
    public let sequence: Int64?
    public let inboxID: String?
    public let version: Int?

    init(id: String, type: String, sessionID: String?, sequence: Int64?, inboxID: String?, version: Int? = nil) {
        self.id = id; self.type = type; self.sessionID = sessionID
        self.sequence = sequence; self.inboxID = inboxID; self.version = version
    }
}

/// Incremental SSE frames from `/api/event`. Text and tool payloads are never
/// retained after decoding. Disconnect/overflow is not a complete history.
public struct OpenCodeEventDecoder: Sendable {
    public static let frameLimit = 64 * 1024
    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var frameBytes = 0
    private var hasData = false

    public init() {}

    public mutating func feed(_ bytes: Data) throws -> [OpenCodeEvent] {
        guard bytes.count <= 256 * 1024 else { throw OpenCodeError.invalidResponse }
        var events: [OpenCodeEvent] = []
        for byte in bytes {
            frameBytes += 1
            guard frameBytes <= Self.frameLimit else { throw OpenCodeError.invalidResponse }
            if byte != 10 {
                line.append(byte)
                continue
            }
            if line.last == 13 { line.removeLast() }
            if line.isEmpty {
                if hasData {
                    guard events.count < 256 else { throw OpenCodeError.invalidResponse }
                    events.append(try decodeEvent())
                }
                data.removeAll(keepingCapacity: false)
                hasData = false
                frameBytes = 0
            } else if line.starts(with: [100, 97, 116, 97, 58]) {
                var content = line.dropFirst(5)
                if content.first == 32 { content = content.dropFirst() }
                if hasData { data.append(10) }
                data.append(contentsOf: content)
                hasData = true
            }
            line.removeAll(keepingCapacity: true)
        }
        return events
    }

    private struct WireEvent: Decodable {
        struct Payload: Decodable { let sessionID: String?; let inboxID: String? }
        struct Durable: Decodable { let aggregateID: String; let seq: Int64; let version: Int }
        let id: String
        let type: String
        let data: Payload
        let durable: Durable?
    }

    private func decodeEvent() throws -> OpenCodeEvent {
        guard let event = try? JSONDecoder().decode(WireEvent.self, from: Data(data)),
              OpenCodeLaunchProfile.validID(event.id, prefix: "evt_"),
              !event.type.isEmpty, event.type.utf8.count <= 128,
              event.type.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw OpenCodeError.invalidResponse }
        if let id = event.data.sessionID, !OpenCodeLaunchProfile.validID(id, prefix: "ses") {
            throw OpenCodeError.invalidResponse
        }
        if let id = event.data.inboxID, !OpenCodeLaunchProfile.validID(id, prefix: "msg_") {
            throw OpenCodeError.invalidResponse
        }
        if let durable = event.durable {
            guard durable.seq >= 0, durable.version > 0,
                  let sessionID = event.data.sessionID, durable.aggregateID == sessionID else {
                throw OpenCodeError.invalidResponse
            }
        }
        return OpenCodeEvent(id: event.id, type: event.type, sessionID: event.data.sessionID,
                             sequence: event.durable?.seq, inboxID: event.data.inboxID, version: event.durable?.version)
    }
}
