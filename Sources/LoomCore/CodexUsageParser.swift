import CoreFoundation
import Foundation

/// One observed increment in the cumulative Codex counter. A nil model means the recording did not attribute it.
public struct CodexUsageIncrement: Equatable, Sendable {
    public let timestamp: Date?
    public let model: String?
    public let tokens: UsageTokens
}

/// The accounting from one rollout. The total is the last cumulative value; increments are kept only up to a fixed cap.
public struct CodexUsageReading: Equatable, Sendable {
    public let total: UsageTokens
    public let context: ContextUsage?
    /// The latest model named by `turn_context`, independent of whether a token count was recorded.
    public let model: String?
    public let increments: [CodexUsageIncrement]
    public let complete: Bool
    public let hasUsage: Bool
}

/// Codex's cumulative `token_count` is authoritative. `token_usage_record` and the last counter are not added to it.
public struct CodexUsageParser: Sendable {
    private struct Counts: Equatable, Sendable {
        var input: Int64
        var cached: Int64
        var write: Int64
        var output: Int64

        var tokens: UsageTokens {
            UsageTokens(input: input - cached - write, output: output, cacheWrite5m: write, cacheRead: cached)
        }
        func subtracting(_ previous: Counts) -> Counts? {
            let result = Counts(input: input - previous.input, cached: cached - previous.cached,
                                write: write - previous.write, output: output - previous.output)
            guard result.input >= 0, result.cached >= 0, result.write >= 0, result.output >= 0,
                  result.cached + result.write <= result.input else { return nil }
            return result
        }
    }

    private static let maximumCounter: Int64 = 1_000_000_000_000
    private static let maxIncrements = 2_048
    private static let tokenMarker = Data("\"token_count\"".utf8)
    private static let turnMarker = Data("\"turn_context\"".utf8)
    private static let startMarker = Data("\"task_started\"".utf8)
    private var model: String?
    private var cumulative: Counts?
    private var context: ContextUsage?
    private var increments: [CodexUsageIncrement] = []
    private var complete = true

    public init() {}

    public var reading: CodexUsageReading {
        CodexUsageReading(total: cumulative?.tokens ?? UsageTokens(), context: context, model: model,
                          increments: increments, complete: complete, hasUsage: cumulative != nil)
    }

    public mutating func consume(_ line: Data) {
        guard line.range(of: Self.tokenMarker) != nil || line.range(of: Self.turnMarker) != nil
                || line.range(of: Self.startMarker) != nil else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { complete = false; return }
        if type == "turn_context" {
            let value = (object["payload"] as? [String: Any])?["model"] as? String
            model = value.flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        guard type == "event_msg", let payload = object["payload"] as? [String: Any],
              let event = payload["type"] as? String else { return }
        if event == "task_started" { model = nil; return }
        guard event == "token_count" else { return }
        guard let info = payload["info"] as? [String: Any],
              let next = Self.counts(info["total_token_usage"]), let last = Self.counts(info["last_token_usage"]) else {
            complete = false
            return
        }
        let window = Self.number(info["model_context_window"]).flatMap { $0 > 0 ? $0 : nil }
        context = ContextUsage(tokens: last.input, window: window, model: model ?? "")
        let previous = cumulative ?? Counts(input: 0, cached: 0, write: 0, output: 0)
        guard let delta = next.subtracting(previous) else { complete = false; return }
        cumulative = next
        guard delta.input > 0 || delta.output > 0 else { return }
        let timestamp = (object["timestamp"] as? String).flatMap(ClaudeUsageParser.timestampMs)
            .map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        if timestamp == nil { complete = false }
        // When the cumulative jump exceeds `last`, only the last part can be attributed to this model.
        if let earlier = delta.subtracting(last), earlier.input > 0 || earlier.output > 0 {
            append(CodexUsageIncrement(timestamp: nil, model: nil, tokens: earlier.tokens))
            complete = false
            append(CodexUsageIncrement(timestamp: timestamp, model: model, tokens: last.tokens))
        } else {
            let attributed = delta == last ? model : nil
            if attributed == nil { complete = false }
            append(CodexUsageIncrement(timestamp: timestamp, model: attributed, tokens: delta.tokens))
        }
    }

    mutating func markIncomplete() { complete = false }

    private mutating func append(_ increment: CodexUsageIncrement) {
        if increments.count == Self.maxIncrements {
            increments.removeFirst(Self.maxIncrements / 8)
            complete = false
        }
        increments.append(increment)
    }

    private static func counts(_ raw: Any?) -> Counts? {
        guard let value = raw as? [String: Any], let input = number(value["input_tokens"]),
              let cached = number(value["cached_input_tokens"]),
              let write = value["cache_write_input_tokens"] == nil ? 0 : number(value["cache_write_input_tokens"]),
              let output = number(value["output_tokens"]), cached + write <= input else { return nil }
        if let total = value["total_tokens"], number(total) != input + output { return nil }
        if let reasoning = value["reasoning_output_tokens"], let count = number(reasoning) {
            guard count <= output else { return nil }
        } else if value["reasoning_output_tokens"] != nil { return nil }
        return Counts(input: input, cached: cached, write: write, output: output)
    }

    private static func number(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(exactly: number.doubleValue), integer >= 0, integer <= maximumCounter else { return nil }
        return integer
    }
}
