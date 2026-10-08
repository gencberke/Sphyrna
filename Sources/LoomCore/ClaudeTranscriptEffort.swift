import Foundation

/// The effort level a Claude conversation last ran at, as Claude records it on each assistant
/// message of the transcript. Claude keeps a level chosen with `/effort` for one process only
/// (`max` can never be saved as the default), so a plain `--resume` falls back to the saved
/// default; the resume passes the recorded level back with `--effort`.
/// Reads only the tail of the transcript and only the `effort` field of assistant records.
public enum ClaudeTranscriptEffort {
    public static let levels: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    static let tailByteCount: UInt64 = 4 << 20

    public static func last(conversationID: String, projectsDirectory: URL) -> String? {
        transcript(conversationID: conversationID, projectsDirectory: projectsDirectory).flatMap(last(in:))
    }

    /// `projects/<folder>/<id>.jsonl`; the folder is Claude's encoding of the working directory,
    /// so it is found by name instead of re-encoding the path.
    static func transcript(conversationID: String, projectsDirectory: URL) -> URL? {
        // Only a plain identifier names a file; never a path.
        guard !conversationID.isEmpty,
              conversationID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" })
        else { return nil }
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return folders.map { $0.appendingPathComponent(conversationID + ".jsonl") }
            .filter { manager.fileExists(atPath: $0.path) }
            .max { modified($0) < modified($1) }
    }

    static func last(in transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > tailByteCount ? size - tailByteCount : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // cut mid-line
        // The newest assistant record that names an effort decides (records without one, such as
        // the synthetic ones an API error leaves, say nothing about it). A level this build does
        // not know means no carry-over, never an older level.
        let key = Array("\"effort\"".utf8)
        for line in lines.reversed() where line.firstRange(of: key) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let effort = object["effort"] as? String else { continue }
            return levels.contains(effort) ? effort : nil
        }
        return nil
    }
}
