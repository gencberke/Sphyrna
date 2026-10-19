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

    /// The complete lines of the transcript's last `tailByteCount` bytes, oldest first.
    static func tailLines(in transcript: URL) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > tailByteCount ? size - tailByteCount : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // cut mid-line
        return lines.map { Data($0) }
    }

    static func last(in transcript: URL) -> String? {
        guard let lines = tailLines(in: transcript) else { return nil }
        // The newest assistant record that names an effort decides (records without one, such as
        // the synthetic ones an API error leaves, say nothing about it). A level this build does
        // not know means no carry-over, never an older level.
        let key = Array("\"effort\"".utf8)
        for line in lines.reversed() where line.firstRange(of: key) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let effort = object["effort"] as? String else { continue }
            return levels.contains(effort) ? effort : nil
        }
        return nil
    }
}

/// The model a Claude conversation last ran on: `message.model` of the newest real assistant record of
/// its transcript (`<synthetic>` records, which an API error or a local command leaves, name no model).
/// Neither face restores the model from the transcript on `--resume` (spike S2), so a resume passes it
/// back with `--model`. The id has no `[1m]` suffix: a session that ran on the 1M window resumes on the
/// plain id. Reads only the tail, as `ClaudeTranscriptEffort` does.
public enum ClaudeTranscriptModel {
    public static func last(conversationID: String, projectsDirectory: URL) -> String? {
        ClaudeTranscriptEffort.transcript(conversationID: conversationID, projectsDirectory: projectsDirectory)
            .flatMap(last(in:))
    }

    static func last(in transcript: URL) -> String? {
        guard let lines = ClaudeTranscriptEffort.tailLines(in: transcript) else { return nil }
        let key = Array("\"model\"".utf8)
        for line in lines.reversed() where line.firstRange(of: key) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty, model != "<synthetic>" else { continue }
            return model
        }
        return nil
    }
}

/// The model Claude starts a session on when nothing is passed: the profile's `settings.json` `model`, else
/// `ANTHROPIC_MODEL` in the launch environment (a user's `opus[1m]` is a default with the 1M window). A resume that passes
/// the transcript's model (`ClaudeTranscriptModel`, whose ids carry no `[1m]`) would drop that window, so it passes none
/// when this default is the model the session ran on.
public enum ClaudeDefaultModel {
    static let settingsByteLimit = 1 << 20
    static let families = ["opus", "sonnet", "haiku"]

    /// The configured default, or nil: a missing, unreadable, oversized or malformed file, or a `model` that is not a
    /// string, means none is configured (the environment is then asked).
    public static func configured(configDirectory: URL, environment: [String: String]) -> String? {
        if let model = fromSettings(configDirectory.appendingPathComponent("settings.json")) { return model }
        return environment["ANTHROPIC_MODEL"].flatMap(normalized)
    }

    private static func fromSettings(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= settingsByteLimit,
              let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? String else { return nil }
        return normalized(model)
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the default stands for the model the transcript names. An alias (`opus`, `sonnet`, `haiku`, with or without
    /// `[1m]`) matches by family: the family word among the id's dash-separated parts. A full id matches by id, `[1m]`
    /// ignored. Any other word (`default`, `opusplan`) matches nothing.
    public static func matches(default configured: String, transcriptModel: String) -> Bool {
        func bare(_ id: String) -> String {
            var value = id.lowercased()
            if value.hasSuffix("[1m]") { value.removeLast(4) }
            return value
        }
        let wanted = bare(configured), ran = bare(transcriptModel)
        if families.contains(wanted) { return ran.split(separator: "-").contains { $0 == wanted } }
        return wanted == ran
    }
}
