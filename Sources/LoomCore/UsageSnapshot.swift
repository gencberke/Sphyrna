import Foundation

/// Token counters by billing class. Provider-generic; Claude is the only
/// producer today. `cacheWrite5m` also carries the legacy single-field cache
/// creation count (older transcripts do not split by TTL).
public struct UsageTokens: Sendable, Equatable {
    public var input: Int64
    public var output: Int64
    public var cacheWrite5m: Int64
    public var cacheWrite1h: Int64
    public var cacheRead: Int64
    public var webSearches: Int64

    public init(
        input: Int64 = 0, output: Int64 = 0, cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0,
        cacheRead: Int64 = 0, webSearches: Int64 = 0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.webSearches = webSearches
    }

    public var cacheWrite: Int64 { cacheWrite5m + cacheWrite1h }
    /// Input, output and both cache classes; web searches are not tokens.
    public var total: Int64 { input + output + cacheWrite + cacheRead }
    /// Cache reads over all prompt-side tokens, or nil when there are none.
    public var cacheShare: Double? {
        let prompt = input + cacheWrite + cacheRead
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    public mutating func add(_ other: UsageTokens) {
        input += other.input
        output += other.output
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        cacheRead += other.cacheRead
        webSearches += other.webSearches
    }
}

/// The period a snapshot covers. Day counts are calendar days in the
/// snapshot's time zone, today included.
public enum UsageRange: Sendable, Equatable {
    case last24Hours
    case days(Int)
    case all
    case interval(start: Date, end: Date)

    /// Inclusive start and exclusive end; nil means unbounded on that side.
    func bounds(now: Date, calendar: Calendar) -> (start: Date?, end: Date?) {
        switch self {
        case .last24Hours:
            return (now.addingTimeInterval(-86_400), nil)
        case let .days(count):
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(max(count, 1) - 1), to: today) ?? today
            return (start, nil)
        case .all:
            return (nil, nil)
        case let .interval(start, end):
            return (start, end)
        }
    }
}

/// The unit of `ClaudeUsageIndex.buckets`: a local calendar hour or day in the caller's time zone.
public enum UsageBucketSize: Sendable, Equatable {
    case hour, day

    var component: Calendar.Component { self == .hour ? .hour : .day }

    /// The `count + 1` edges of `count` consecutive buckets, the last containing `now`; bucket `i`
    /// is `[edges[i], edges[i + 1])`. Follows the calendar, so a day can be 23 or 25 hours long.
    public func edges(count: Int, endingAt now: Date, calendar: Calendar) -> [Date] {
        guard count > 0, let current = calendar.dateInterval(of: component, for: now) else { return [] }
        var starts = [current.start]
        while starts.count < count, let previous = calendar.dateInterval(of: component, for: starts[0].addingTimeInterval(-1)) {
            starts.insert(previous.start, at: 0)
        }
        return starts + [current.end]
    }
}

/// Token and message totals of one bucket (a bar of the usage chart). Equal to the snapshot of
/// the bucket's own interval.
public struct UsageBucket: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public internal(set) var tokens: UsageTokens
    public internal(set) var messageCount: Int

    public init(start: Date, end: Date, tokens: UsageTokens, messageCount: Int) {
        self.start = start
        self.end = end
        self.tokens = tokens
        self.messageCount = messageCount
    }
}

/// One model's totals. `model` is the canonical price-table id when the model
/// is known and the raw transcript id otherwise; unknown models keep their
/// tokens but have no cost.
public struct UsageModelTotal: Sendable, Equatable {
    public let model: String
    public let displayName: String
    public let tokens: UsageTokens
    /// nil when the model is not in the price table (cost shown as "-").
    public let estimatedCostUSD: Double?
    public let messageCount: Int
    public var isPriceKnown: Bool { estimatedCostUSD != nil }
}

public struct UsageDay: Sendable, Equatable {
    /// `yyyy-MM-dd` in the snapshot's time zone.
    public let day: String
    public let start: Date
    public let tokens: UsageTokens
    /// Sum over models with a known price.
    public let estimatedCostUSD: Double
    public let hasUnknownCost: Bool
    public let messageCount: Int
    public let sessionCount: Int
    public let models: [UsageModelTotal]
}

/// Approximate 5-hour activity window by ccusage's block rule (a block starts
/// at the first message floored to the UTC hour and lasts five hours; a gap
/// over five hours starts a new one). It is not Anthropic's plan accounting.
public struct UsageActivityWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let lastActivity: Date
    public let tokens: UsageTokens
    public let estimatedCostUSD: Double
    public let hasUnknownCost: Bool
    public let messageCount: Int
}

public struct UsageSnapshot: Sendable, Equatable {
    public let provider: ManagedSession.Provider
    public let asOf: Date
    /// Date the static price table was last checked against the official page.
    public let priceTableAsOf: String
    public let range: UsageRange
    public let tokens: UsageTokens
    /// API-equivalent estimate over models with a known price.
    public let estimatedCostUSD: Double
    /// Models seen in the range that have no price (tokens counted, cost not).
    public let unknownModels: [String]
    public var hasUnknownCost: Bool { !unknownModels.isEmpty }
    public let messageCount: Int
    /// Distinct sessions still linked to their messages (see `forget`).
    public let sessionCount: Int
    public var cacheShare: Double? { tokens.cacheShare }
    /// Oldest day first; days without messages are omitted.
    public let days: [UsageDay]
    /// Highest token total first.
    public let models: [UsageModelTotal]
    /// The window containing `asOf`, or nil when the last activity is over five hours old.
    public let activityWindow: UsageActivityWindow?
}

/// What one `refresh` did; tests and diagnostics read it, the UI does not.
public struct UsageScanReport: Sendable, Equatable, Codable {
    public var filesSeen = 0
    public var filesUnchanged = 0
    public var filesParsed = 0
    /// Files dropped and re-parsed from byte 0 (shrink, new inode, guard mismatch).
    public var filesReset = 0
    /// Not indexed yet and last modified before the cold-start window.
    public var filesSkippedOld = 0
    public var bytesRead: Int64 = 0
    /// Lines that carried usage and were offered to the index.
    public var recordsAccepted = 0
    /// Candidate lines that could not be decoded or failed validation.
    public var linesMalformed = 0
}

public enum ClaudeUsageIndexError: Error, CustomStringConvertible, Sendable {
    case sqlite(operation: String, code: Int32, message: String)

    public var description: String {
        switch self {
        case let .sqlite(operation, code, message):
            "usage index \(operation) failed (\(code)): \(message)"
        }
    }
}
