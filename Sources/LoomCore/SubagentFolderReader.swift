import Darwin
import Foundation

/// One subagent of a session that has no live run, as its folder shows it (V23): the ledger's entry shape, and the
/// `toolUseId` of the Agent call that started it, which joins it to the main transcript.
public struct StoppedSubagent: Equatable, Sendable {
    public var record: SubagentRecord
    public var toolUseID: String?

    public init(record: SubagentRecord, toolUseID: String?) {
        self.record = record
        self.toolUseID = toolUseID
    }
}

/// Lists a stopped session's subagents from the folder Claude keeps them in:
/// `<project folder>/<session id>/subagents/agent-<id>.meta.json`, with `agent-<id>.jsonl` beside it. No hook told Loom about
/// them (no run), so the folder is the only source, and the ledger's shape is the only shape the Agents tab knows: each
/// entry is a finished `SubagentRecord` whose times are the transcript file's (created, last written).
///
/// Bounded: at most `maximumEntries`, the newest first (by the transcript file's last write); only those are read. A meta file
/// that cannot be read, is not a regular file of this user, or is not what Claude writes is skipped. The folder is the
/// session's own `subagents` level: an agent of a workflow, one level deeper, is not listed. A blocking read; callers run it
/// off the main actor.
public enum SubagentFolderReader {
    public static let maximumEntries = 500

    public static func read(folder: URL, limit: Int = maximumEntries) -> [StoppedSubagent] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        struct Candidate {
            var id: String
            var meta: URL
            var transcript: URL
            var transcriptExists: Bool
            var started: Date
            var ended: Date
        }
        let suffix = ".meta.json"
        var candidates: [Candidate] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(suffix) {
            let id = String(name.dropFirst("agent-".count).dropLast(suffix.count))
            guard SubagentMeta.isValidAgentID(id) else { continue }
            let meta = folder.appendingPathComponent(name)
            let transcript = folder.appendingPathComponent("agent-\(id).jsonl")
            let transcriptValues = try? transcript.resourceValues(forKeys: Set(keys))
            let metaValues = try? meta.resourceValues(forKeys: Set(keys))
            let ended = transcriptValues?.contentModificationDate ?? metaValues?.contentModificationDate ?? .distantPast
            let started = min(ended, transcriptValues?.creationDate ?? ended)
            candidates.append(Candidate(id: id, meta: meta, transcript: transcript,
                                        transcriptExists: transcriptValues != nil, started: started, ended: ended))
        }
        candidates.sort { $0.ended != $1.ended ? $0.ended > $1.ended : $0.id < $1.id }
        var entries: [StoppedSubagent] = []
        for candidate in candidates {
            guard entries.count < max(0, limit) else { break }
            guard let (meta, toolUseID) = readMeta(candidate.meta) else { continue }
            let record = SubagentRecord(
                id: candidate.id, agentType: meta.agentType ?? "", description: meta.description,
                isBackground: meta.isBackground ?? false, depth: meta.depth ?? 1,
                startedAt: candidate.started, endedAt: candidate.ended,
                transcriptPath: candidate.transcriptExists ? candidate.transcript.path : nil)
            entries.append(StoppedSubagent(record: record, toolUseID: toolUseID))
        }
        return entries
    }

    private static func readMeta(_ url: URL) -> (SubagentMeta, String?)? {
        guard let descriptor = openOwnRegularFile(url.path) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: SubagentMeta.maximumFileByteCount + 1),
              let meta = SubagentMeta.parse(data) else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let toolUseID = (object?["toolUseId"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 200 ? nil : $0 }
        return (meta, toolUseID)
    }
}
