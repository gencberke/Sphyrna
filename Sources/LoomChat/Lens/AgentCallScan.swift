import Foundation
import LoomCore

/// Which Agent calls of the main session's transcript got a result (V23). A stopped session lists its subagents from their
/// folder (`SubagentFolderReader`); a subagent whose Agent call has no result lies in a turn that ended with it still
/// running, and the list says "Interrupted" for it. The join is the call's `tool_use_id` against the folder's `toolUseId`.
///
/// A read goes backward from the end of the file in pages, as the lens's older-history reads do, and ends when every wanted
/// call has been found with or without its result, at the start of the file, or at the byte bound. A call older than the
/// bound is not judged: the caller says "Done" for it.
public enum AgentCallScan {
    /// The lens's own bound for reading older history.
    public static let defaultByteLimit = TranscriptLens.Limits().olderBytes
    public static let toolNames: Set<String> = ["Agent", "Task"]

    public struct Result: Equatable, Sendable {
        /// The wanted calls found in the transcript.
        public var calls: Set<String> = []
        /// The wanted ids that have a `tool_result`.
        public var answered: Set<String> = []

        /// The wanted calls with no result: the subagents the run ended with.
        public var unanswered: Set<String> { calls.subtracting(answered) }
    }

    public static func scan(file: ClaudeTranscriptFile, wanting wanted: Set<String>, byteLimit: Int = defaultByteLimit,
                            pageBytes: Int = ClaudeTranscriptReader.defaultPageBytes,
                            maximumLineBytes: Int = TranscriptLens.Limits().maximumLineBytes) -> Result {
        var result = Result()
        guard !wanted.isEmpty, let reader = ClaudeTranscriptReader(file: file) else { return result }
        defer { reader.close() }
        let end = reader.historyOffset
        var covered = 0
        while covered < byteLimit, reader.historyOffset > 0, !wanted.isSubset(of: result.calls) {
            let page = reader.readBackward(pageBytes: max(1, min(pageBytes, byteLimit - covered)), maximumLineBytes: maximumLineBytes)
            covered = Int(end - page.startOffset)
            for record in page.records {
                guard let bytes = record.bytes, mentionsToolUse(bytes),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { continue }
                switch StreamMessage(json: value) {
                case let .user(message):
                    guard !message.isSidechain, message.parentToolUseID == nil, message.hasToolResult else { continue }
                    for case let .toolResult(block) in message.content {
                        if let id = block.toolUseID, wanted.contains(id) { result.answered.insert(id) }
                    }
                case let .assistant(message):
                    guard !message.isSidechain, message.parentToolUseID == nil else { continue }
                    for case let .toolUse(call) in message.content where toolNames.contains(call.name) && wanted.contains(call.id) {
                        result.calls.insert(call.id)
                    }
                default:
                    break
                }
            }
            if page.reachedStart { break }
        }
        return result
    }

    /// A cheap test before a line is decoded: only a line that names a tool call or a tool result can matter.
    private static func mentionsToolUse(_ bytes: Data) -> Bool {
        let needle: StaticString = "\"tool_use"
        return bytes.withUnsafeBytes { buffer in
            memmem(buffer.baseAddress, buffer.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
        }
    }
}
