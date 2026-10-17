import Foundation
import LoomCore

/// A message Loom sends to the CLI's stdin:
/// `{"type":"user","message":{"role":"user","content":[…]},"parent_tool_use_id":null,"uuid":…,"priority":…,
/// "origin":{"kind":"human"}}`. The `origin` marks keyboard input as the human's; without it a strict trust gate fails
/// closed. The CLI echoes the message with the same `uuid` (`isReplay`) when `--replay-user-messages` is on.
public struct OutgoingUserMessage: Sendable, Equatable {
    public enum Priority: String, Sendable {
        /// Read in the same turn after the running tool calls finish; cancels nothing.
        case next
        /// Interrupts or moves running work to the background; the composer does not use it.
        case now
        /// Held and sent as a new turn by the CLI's own queue; the composer does not use it.
        case later
    }

    public enum Block: Sendable, Equatable {
        case text(String)
        case image(mediaType: String, base64: String)
    }

    public var uuid: String
    public var content: [Block]
    public var priority: Priority?

    public init(uuid: String = UUID().uuidString.lowercased(), content: [Block], priority: Priority? = .next) {
        self.uuid = uuid
        self.content = content
        self.priority = priority
    }

    public init(uuid: String = UUID().uuidString.lowercased(), text: String, priority: Priority? = .next) {
        self.init(uuid: uuid, content: [.text(text)], priority: priority)
    }

    /// The line to write, with its newline.
    public func line() -> Data {
        let blocks: [JSONValue] = content.map { block in
            switch block {
            case let .text(text):
                ["type": "text", "text": .string(text)]
            case let .image(mediaType, base64):
                ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)]]
            }
        }
        var fields: [String: JSONValue] = [
            "type": "user",
            "message": ["role": "user", "content": .array(blocks)],
            "parent_tool_use_id": nil,
            "uuid": .string(uuid),
            "origin": ["kind": "human"],
        ]
        if let priority { fields["priority"] = .string(priority.rawValue) }
        return ControlWire.line(.object(fields))
    }
}
