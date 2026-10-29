import Darwin
import Foundation

/// Only text that Codex recorded as a person or assistant message. Tool and reasoning items are not messages.
public struct CodexRolloutMessage: Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let role: Role
    public let text: String
}

public enum CodexRolloutText {
    public static func message(in line: Data) -> CodexRolloutMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return message(in: object)
    }

    public static func message(in object: [String: Any]) -> CodexRolloutMessage? {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message",
              let roleText = payload["role"] as? String,
              let blocks = payload["content"] as? [[String: Any]] else { return nil }
        let role: CodexRolloutMessage.Role
        let contentType: String
        switch roleText {
        case "user": role = .user; contentType = "input_text"
        case "assistant":
            // Missing phase is the legacy format. A new or malformed phase is not known transcript text yet.
            if let phase = payload["phase"], !(phase is NSNull) {
                guard let value = phase as? String,
                      ["commentary", "partial_answer", "final_answer"].contains(value) else { return nil }
            }
            role = .assistant; contentType = "output_text"
        default: return nil
        }
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == contentType else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CodexRolloutMessage(role: role, text: text)
    }
}

/// Reads whole lines backward in bounded pages, including when an oversized or unfinished line spans a page.
public final class CodexRolloutReader: TranscriptReader, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var cursor: UInt64
    private var bytesReadValue = 0
    private var skippedLongLineValue = false
    public var bytesRead: Int { lock.withLock { bytesReadValue } }
    public var skippedLongLine: Bool { lock.withLock { skippedLongLineValue } }

    public init?(file: CodexRolloutFile) {
        guard let fd = openOwnRegularFile(file.path) else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else { Darwin.close(fd); return nil }
        descriptor = fd
        cursor = UInt64(info.st_size)
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    public func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    public func readBackward(pageBytes: Int, maximumLineBytes: Int) -> TranscriptBackwardPage {
        lock.withLock {
            guard descriptor >= 0, cursor > 0, !Task.isCancelled else {
                return TranscriptBackwardPage(records: [], startOffset: cursor, reachedStart: cursor == 0)
            }
            let upper = cursor
            let amount = UInt64(max(1, min(pageBytes, 1024 * 1024)))
            let lower = upper > amount ? upper - amount : 0
            var bytes = [UInt8](repeating: 0, count: Int(upper - lower))
            let count = pread(descriptor, &bytes, bytes.count, off_t(lower))
            guard count > 0 else { return TranscriptBackwardPage(records: [], startOffset: cursor, reachedStart: false) }
            bytesReadValue += count
            bytes.removeSubrange(count..<bytes.count)
            // A partial last line is not a message, even when this page begins in the middle of an oversized line.
            guard let finalNewline = bytes.lastIndex(of: 0x0A) else {
                if lower > 0 { skippedLongLineValue = true }
                cursor = lower
                return TranscriptBackwardPage(records: [], startOffset: lower, reachedStart: lower == 0)
            }
            let end = finalNewline + 1
            var start = 0
            if lower > 0 {
                var preceding: UInt8 = 0
                let precedingCount = pread(descriptor, &preceding, 1, off_t(lower - 1))
                if precedingCount == 1 { bytesReadValue += 1 }
                if precedingCount != 1 || preceding != 0x0A {
                    start = (bytes.firstIndex(of: 0x0A) ?? finalNewline) + 1
                }
            }
            guard start < end else {
                if lower > 0 { skippedLongLineValue = true }
                cursor = lower
                return TranscriptBackwardPage(records: [], startOffset: lower, reachedStart: lower == 0)
            }
            var records: [TranscriptLineRecord] = []
            var position = start
            while position < end {
                guard let newline = bytes[position..<end].firstIndex(of: 0x0A) else { break }
                let length = newline - position
                if length > 0 {
                    let data = length <= max(0, maximumLineBytes) ? Data(bytes[position..<newline]) : nil
                    records.append(TranscriptLineRecord(offset: lower + UInt64(position), length: length, bytes: data))
                }
                position = newline + 1
            }
            cursor = lower + UInt64(start)
            return TranscriptBackwardPage(records: records, startOffset: cursor, reachedStart: cursor == 0)
        }
    }
}
