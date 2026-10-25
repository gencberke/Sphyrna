import Darwin
import Foundation

/// Claude Code's own retention: `cleanupPeriodDays` in the profile's `settings.json` (transcripts older than that many days are
/// deleted by Claude at startup; absent means 30). Sphyrna reads it to say so in Settings → Sessions and, when the user asks
/// and confirms, writes that one key and nothing else.
public enum ClaudeRetention: Sendable, Equatable {
    /// The days in force; `stated` is false when the file or the key is absent (Claude's default).
    case days(Int, stated: Bool)
    /// The file cannot be read as a JSON object, or the key is not a whole number: shown with the reason, never written.
    case unreadable(String)

    /// Claude's default when the key is absent.
    public static let defaultDays = 30
    public static let key = "cleanupPeriodDays"
    /// What Settings offers.
    public static let allowedDays: ClosedRange<Int> = 1...3_650
}

public enum ClaudeRetentionError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(String)
    case outOfRange(Int)
    case writeFailed(String)

    public var description: String {
        switch self {
        case let .unreadable(reason): reason
        case let .outOfRange(days): "\(days) days is outside 1 to \(ClaudeRetention.allowedDays.upperBound)"
        case let .writeFailed(reason): "settings.json could not be written (\(reason))"
        }
    }
}

public enum ClaudeRetentionFile {
    /// `settings.json` of a profile.
    public static func url(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    public static func read(_ url: URL) -> ClaudeRetention {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path)
                ? .unreadable("settings.json could not be read") : .days(ClaudeRetention.defaultDays, stated: false)
        }
        guard let object = parseObject(data) else { return .unreadable("settings.json is not a JSON object") }
        guard let value = object[ClaudeRetention.key] else { return .days(ClaudeRetention.defaultDays, stated: false) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), let days = Int(exactly: number.doubleValue) else {
            return .unreadable("\(ClaudeRetention.key) in settings.json is not a whole number")
        }
        return .days(days, stated: true)
    }

    /// Writes `cleanupPeriodDays = days` and nothing else: the key's value is replaced in place, or the key is added as the
    /// object's first member; every other byte of the file stays. The result must parse to the same object with only that key
    /// changed, else nothing is written. An unreadable or non-object file is never written. Atomic, keeping the file's mode,
    /// and through a link to the file it names. A missing file is created holding just the key.
    public static func write(days: Int, to url: URL) throws {
        guard ClaudeRetention.allowedDays.contains(days) else { throw ClaudeRetentionError.outOfRange(days) }
        let target = url.resolvingSymlinksInPath()
        var mode: mode_t = 0o644
        let updated: Data
        if let data = try? Data(contentsOf: target) {
            guard let original = parseObject(data) else {
                throw ClaudeRetentionError.unreadable("settings.json is not a JSON object, so Sphyrna does not change it")
            }
            var info = stat()
            if stat(target.path, &info) == 0 { mode = info.st_mode & 0o7777 }
            guard let edited = edit(data, days: days) else {
                throw ClaudeRetentionError.unreadable("settings.json could not be edited safely, so Sphyrna does not change it")
            }
            guard let result = parseObject(edited), keepsEverythingElse(original, result, days: days) else {
                throw ClaudeRetentionError.unreadable("settings.json could not be edited safely, so Sphyrna does not change it")
            }
            updated = edited
        } else if FileManager.default.fileExists(atPath: target.path) {
            throw ClaudeRetentionError.unreadable("settings.json could not be read, so Sphyrna does not change it")
        } else {
            updated = Data("{\n  \"\(ClaudeRetention.key)\": \(days)\n}\n".utf8)
        }
        do {
            try updated.write(to: target, options: .atomic)
            _ = chmod(target.path, mode)
        } catch {
            throw ClaudeRetentionError.writeFailed(String(describing: (error as NSError).localizedDescription))
        }
    }

    // MARK: Internals

    private static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private static func keepsEverythingElse(_ before: [String: Any], _ after: [String: Any], days: Int) -> Bool {
        var old = before, new = after
        old[ClaudeRetention.key] = nil
        guard (new.removeValue(forKey: ClaudeRetention.key) as? NSNumber)?.intValue == days else { return false }
        return NSDictionary(dictionary: old).isEqual(to: new)
    }

    /// The file's bytes with the top-level key's value replaced, or the key inserted after the opening brace. Nil when the
    /// text is not shaped as one object (the parse already said it is one, so this is a guard).
    static func edit(_ data: Data, days: Int) -> Data? {
        let bytes = [UInt8](data)
        guard let open = bytes.firstIndex(where: { !isSpace($0) && $0 != 0xEF && $0 != 0xBB && $0 != 0xBF }),
              bytes[open] == UInt8(ascii: "{") else { return nil }
        let value = Array(String(days).utf8)
        if let span = valueSpan(bytes, open: open) {
            return Data(bytes[..<span.lowerBound] + value + bytes[span.upperBound...])
        }
        // Not there: the first member, indented as the next line is (two spaces when the object is on one line).
        var next = open + 1
        while next < bytes.count, isSpace(bytes[next]) { next += 1 }
        let empty = next < bytes.count && bytes[next] == UInt8(ascii: "}")
        let member = Array("\"\(ClaudeRetention.key)\": ".utf8) + value
        if empty {
            return Data(bytes[...open] + Array("\n  ".utf8) + member + Array("\n".utf8) + bytes[next...])
        }
        let gap = bytes[(open + 1)..<next]
        let indent: [UInt8] = gap.contains(0x0A) ? Array(gap) : Array("\n  ".utf8)
        return Data(bytes[...open] + indent + member + Array(",".utf8) + bytes[(open + 1)...])
    }

    /// Where the value of the top-level `cleanupPeriodDays` lies (trimmed), or nil when the object has no such member.
    private static func valueSpan(_ bytes: [UInt8], open: Int) -> Range<Int>? {
        let key = Array("\"\(ClaudeRetention.key)\"".utf8)
        var depth = 0
        var index = open
        var expectKey = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let end = stringEnd(bytes, from: index)
                guard end > index else { return nil }
                if depth == 1, expectKey {
                    let token = Array(bytes[index..<end])
                    expectKey = false
                    if token == key {
                        var cursor = end
                        while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                        guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { return nil }
                        cursor += 1
                        while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                        let start = cursor
                        guard let stop = valueEnd(bytes, from: start) else { return nil }
                        var last = stop
                        while last > start, isSpace(bytes[last - 1]) { last -= 1 }
                        return start..<last
                    }
                }
                index = end
                continue
            }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth == 1 { expectKey = true }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            case UInt8(ascii: ","):
                if depth == 1 { expectKey = true }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// The index just past a string token starting at `start` (a quote); `start` when it never ends.
    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
            if bytes[index] == UInt8(ascii: "\"") { return index + 1 }
            index += 1
        }
        return start
    }

    /// Where a member's value ends: the `,` or `}` that closes it at the object's own level.
    private static func valueEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let end = stringEnd(bytes, from: index)
                guard end > index else { return nil }
                index = end
                continue
            }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 0 { return index }
                depth -= 1
            case UInt8(ascii: ","):
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
}
