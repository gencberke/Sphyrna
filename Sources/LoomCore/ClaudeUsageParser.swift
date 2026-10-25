import Foundation

/// One deduplicated-to-be assistant message with usage, as read from a transcript line.
struct ClaudeUsageRecord: Sendable, Equatable {
    var messageID: String?
    var requestID: String?
    var sessionID: String?
    var model: String
    var timestampMs: Int64
    var tokens: UsageTokens
    var fast: Bool
    var usGeo: Bool
    var sidechain: Bool
    /// Legacy `costUSD` written by old Claude Code versions; nil in current ones.
    var legacyCostUSD: Double?
}

enum ClaudeUsageLineResult: Equatable {
    case record(ClaudeUsageRecord)
    /// Not an assistant usage line (most lines): skipped without decoding.
    case ignored
    /// Looked like a usage line but could not be decoded or failed validation.
    case malformed
}

/// Turns one transcript line into a record. Defensive on purpose: the format is
/// private to Claude Code and drifts, so anything unexpected skips the line.
struct ClaudeUsageParser {
    static let defaultMaximumLineBytes = 16 * 1024 * 1024
    /// Counters above this are corrupt, not usage (and would overflow sums).
    private static let counterLimit: Int64 = 1_000_000_000_000

    private let decoder = JSONDecoder()
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = Self.defaultMaximumLineBytes) {
        self.maximumLineBytes = maximumLineBytes
    }

    func parse(_ line: UnsafeRawBufferPointer) -> ClaudeUsageLineResult {
        guard let base = line.baseAddress, line.count > 0 else { return .ignored }
        // Cheap byte gate before any JSON decoding: roughly half the lines carry no usage.
        guard Self.contains(base, line.count, "\"usage\""), Self.contains(base, line.count, "\"assistant\"") else {
            return .ignored
        }
        guard line.count <= maximumLineBytes else { return .malformed }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        guard let wire = try? decoder.decode(Line.self, from: data) else {
            // A record of another type (one Claude Code added, `system/permission_check_status` and the like) is not a usage
            // line, whatever shape its fields have: skipped silently. Only an assistant line, or one that is not JSON, is not
            // understood.
            if let kind = try? decoder.decode(Kind.self, from: data), kind.type != "assistant" { return .ignored }
            return .malformed
        }
        guard wire.type == "assistant" else { return .ignored }
        // API errors and synthetic placeholders carry no real usage.
        if wire.isApiErrorMessage == true { return .ignored }
        guard let message = wire.message, let model = message.model, !model.isEmpty else { return .malformed }
        if model == "<synthetic>" { return .ignored }
        guard let usage = message.usage else { return .malformed }
        guard let timestamp = wire.timestamp, let stamp = Self.timestampMs(timestamp) else { return .malformed }
        guard let tokens = usage.tokens else { return .malformed }
        guard tokens.total > 0 || tokens.webSearches > 0 else { return .ignored }
        guard message.id != nil || wire.requestId != nil else { return .malformed }
        let cost = wire.costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return .record(ClaudeUsageRecord(
            messageID: message.id, requestID: wire.requestId, sessionID: wire.sessionId,
            model: model, timestampMs: stamp, tokens: tokens,
            fast: usage.speed?.lowercased() == "fast", usGeo: usage.inferenceGeo?.lowercased() == "us",
            sidechain: wire.isSidechain ?? false, legacyCostUSD: cost))
    }

    private static func contains(_ base: UnsafeRawPointer, _ count: Int, _ needle: StaticString) -> Bool {
        memmem(base, count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fff](Z|+HH:MM|-HH:MM)` to milliseconds since the epoch.
    static func timestampMs(_ text: String) -> Int64? {
        var utf8 = text.utf8.makeIterator()
        func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let byte = utf8.next(), byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        func expect(_ byte: UInt8) -> Bool { utf8.next() == byte }
        guard let year = digits(4), expect(0x2D), let month = digits(2), expect(0x2D), let day = digits(2),
              expect(0x54), let hour = digits(2), expect(0x3A), let minute = digits(2), expect(0x3A),
              let second = digits(2) else { return nil }
        guard (1970...2200).contains(year), (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 61 else { return nil }
        var millis = 0
        var next = utf8.next()
        if next == 0x2E {
            var places = 0
            next = utf8.next()
            while let byte = next, byte >= 0x30, byte <= 0x39 {
                if places < 3 { millis = millis * 10 + Int(byte - 0x30); places += 1 }
                next = utf8.next()
            }
            guard places > 0 else { return nil }
            while places < 3 { millis *= 10; places += 1 }
        }
        var offsetSeconds = 0
        switch next {
        case 0x5A: // Z
            guard utf8.next() == nil else { return nil }
        case 0x2B, 0x2D:
            let sign = next == 0x2B ? 1 : -1
            guard let offsetHour = digits(2), expect(0x3A), let offsetMinute = digits(2), utf8.next() == nil,
                  offsetHour < 24, offsetMinute < 60 else { return nil }
            offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
        default:
            return nil
        }
        // Days from civil (Howard Hinnant).
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = shiftedYear / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + min(second, 59) - offsetSeconds
        return Int64(seconds) * 1_000 + Int64(millis)
    }

    // MARK: wire shapes

    /// A token counter: absent, a non-negative integer, or invalid (negative,
    /// fractional, a string, absurdly large). Invalid anywhere skips the line.
    private enum Counter: Decodable {
        case value(Int64)
        case invalid

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int64.self), value >= 0, value <= ClaudeUsageParser.counterLimit {
                self = .value(value)
            } else {
                self = .invalid
            }
        }
    }

    /// A line's record type alone.
    private struct Kind: Decodable {
        let type: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
        }

        private enum CodingKeys: String, CodingKey { case type }
    }

    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let sessionId: String?
        let isSidechain: Bool?
        let isApiErrorMessage: Bool?
        let costUSD: Double?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let input_tokens: Counter?
        let output_tokens: Counter?
        let cache_creation_input_tokens: Counter?
        let cache_read_input_tokens: Counter?
        let cache_creation: CacheCreation?
        let speed: String?
        let inference_geo: String?
        let server_tool_use: ServerToolUse?

        var inferenceGeo: String? { inference_geo }

        struct CacheCreation: Decodable {
            let ephemeral_5m_input_tokens: Counter?
            let ephemeral_1h_input_tokens: Counter?
        }

        struct ServerToolUse: Decodable {
            let web_search_requests: Counter?
        }

        /// nil when any present counter is invalid. A `cache_creation` split wins over the
        /// legacy single field; a legacy total larger than the split's sum keeps the
        /// remainder as 5-minute writes so no billed token is dropped.
        var tokens: UsageTokens? {
            func read(_ counter: Counter?) -> Int64? {
                switch counter {
                case nil: 0
                case let .value(value)?: value
                case .invalid?: nil
                }
            }
            guard let input = read(input_tokens), let output = read(output_tokens),
                  let legacyWrite = read(cache_creation_input_tokens), let cacheRead = read(cache_read_input_tokens),
                  let web = read(server_tool_use?.web_search_requests) else { return nil }
            var write5m = legacyWrite
            var write1h: Int64 = 0
            if let split = cache_creation {
                guard let five = read(split.ephemeral_5m_input_tokens), let hour = read(split.ephemeral_1h_input_tokens)
                else { return nil }
                write5m = five + max(legacyWrite - five - hour, 0)
                write1h = hour
            }
            return UsageTokens(input: input, output: output, cacheWrite5m: write5m, cacheWrite1h: write1h,
                               cacheRead: cacheRead, webSearches: web)
        }
    }
}
