import Foundation
import LoomCore

extension TranscriptLens {
    /// The whole text of a tool's result, for "Show all" on a clipped body. The model keeps a long result as head and tail
    /// and remembers only the line of the call (`ChatEntry.sourceOffset`); the result is written a few lines after it, so
    /// this reads forward from that line, at most `scanLines` lines, until the line that answers `toolUseID`.
    /// Nil when the transcript does not hold it (or it is further than `scanLines` lines away).
    public func fullToolResult(toolUseID: String, from offset: UInt64, scanLines: Int = 400) -> String? {
        let needle = Array("\"tool_use_id\":\"\(toolUseID)\"".utf8)
        let spaced = Array("\"tool_use_id\": \"\(toolUseID)\"".utf8)
        var position = offset
        for _ in 0..<scanLines {
            guard let line = line(at: position, maximumLineBytes: Self.showAllLineBytes) else { return nil }
            defer { position += UInt64(line.count) + 1 }
            guard Self.contains(line, needle) || Self.contains(line, spaced),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
            for block in value["message"]?["content"]?.array ?? [] {
                guard block["type"]?.string == "tool_result", block["tool_use_id"]?.string == toolUseID else { continue }
                if let text = block["content"]?.string { return text }
                let parts = (block["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                return parts.joined(separator: "\n")
            }
        }
        return nil
    }

    /// A line longer than this ends the search (a pasted screenshot between the call and its result).
    static let showAllLineBytes = 32 * 1024 * 1024

    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { buffer in
            needle.withUnsafeBytes { memmem(buffer.baseAddress, buffer.count, $0.baseAddress, $0.count) != nil }
        }
    }
}
