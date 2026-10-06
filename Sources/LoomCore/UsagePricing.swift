import Foundation

/// Static list prices for Claude models, in USD per million tokens.
///
/// Source: https://platform.claude.com/docs/en/about-claude/pricing, fetched
/// 2026-10-07 (the page carries no date of its own). The table is hard-coded
/// on purpose: Loom never fetches prices, and a table update re-prices history
/// because cost is computed at query time from stored token counts.
///
/// Every cache price on that page is a multiple of the base input price: a 5m
/// write is 1.25x, a 1h write 2x, a read 0.1x (0.05x on Opus 5.5, 0.025x on
/// Fable/Mythos 5.1). Fast mode replaces the base input and output prices and
/// the cache multipliers apply on top of the fast input price. `inference_geo`
/// "us" multiplies every token category by 1.1 on Claude 4.6 and later models.
/// Web search is $10 per 1,000 searches and is not multiplied. Batch pricing
/// never applies to transcripts. The result is an API-equivalent estimate;
/// subscription users are not billed per token.
public struct UsageModelPrice: Sendable, Equatable {
    public let displayName: String
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadMultiplier: Double
    /// Fast-mode base prices; nil when the model has no fast mode (a "fast"
    /// speed on such a model is billed at standard rates).
    public let fastInputPerMTok: Double?
    public let fastOutputPerMTok: Double?
    public let supportsUSGeo: Bool

    static let cacheWrite5mMultiplier = 1.25
    static let cacheWrite1hMultiplier = 2.0
}

public enum UsagePricing {
    /// Date the table was last checked against the official page.
    public static let asOf = "2026-10-07"
    public static let sourceURL = "https://platform.claude.com/docs/en/about-claude/pricing"
    static let webSearchUSD = 10.0 / 1_000.0

    private static func price(
        _ name: String, _ input: Double, _ output: Double, read: Double = 0.1,
        fast: (Double, Double)? = nil, geo: Bool = true
    ) -> UsageModelPrice {
        UsageModelPrice(
            displayName: name, inputPerMTok: input, outputPerMTok: output, cacheReadMultiplier: read,
            fastInputPerMTok: fast?.0, fastOutputPerMTok: fast?.1, supportsUSGeo: geo)
    }

    /// Keyed by canonical id (see `canonicalModelID`).
    static let table: [String: UsageModelPrice] = [
        "claude-fable-5-1": price("Fable 5.1", 10, 50, read: 0.025),
        "claude-mythos-5-1": price("Mythos 5.1", 10, 50, read: 0.025),
        "claude-fable-5": price("Fable 5", 10, 50),
        "claude-mythos-5": price("Mythos 5", 10, 50),
        "claude-opus-5-5": price("Opus 5.5", 4, 20, read: 0.05, fast: (8, 40)),
        "claude-opus-5": price("Opus 5", 5, 25, fast: (10, 50)),
        "claude-opus-4-8": price("Opus 4.8", 5, 25, fast: (10, 50)),
        "claude-opus-4-7": price("Opus 4.7", 5, 25),
        "claude-opus-4-6": price("Opus 4.6", 5, 25),
        "claude-opus-4-5": price("Opus 4.5", 5, 25, geo: false),
        "claude-opus-4-1": price("Opus 4.1", 15, 75, geo: false),
        "claude-opus-4": price("Opus 4", 15, 75, geo: false),
        "claude-sonnet-5-5": price("Sonnet 5.5", 2, 10),
        "claude-sonnet-5": price("Sonnet 5", 2, 10),
        "claude-sonnet-4-6": price("Sonnet 4.6", 3, 15),
        "claude-sonnet-4-5": price("Sonnet 4.5", 3, 15, geo: false),
        "claude-sonnet-4": price("Sonnet 4", 3, 15, geo: false),
        "claude-haiku-4-5": price("Haiku 4.5", 1, 5, geo: false),
        "claude-haiku-3-5": price("Haiku 3.5", 0.8, 4, geo: false),
    ]

    private static let aliases = ["claude-3-5-haiku": "claude-haiku-3-5"]

    /// Lower-cases and strips decoration so ids written by different tools meet
    /// one table key: provider prefixes (`anthropic/`, `us.anthropic.`), a
    /// `[1m]` context suffix, Vertex `@date`, Bedrock `-v1:0`, `-latest`, a
    /// trailing `-YYYYMMDD`, and dots (`4.5` becomes `4-5`). Unknown ids pass
    /// through normalized; nothing is guessed by prefix.
    public static func canonicalModelID(_ raw: String) -> String {
        var id = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let claude = id.range(of: "claude") { id = String(id[claude.lowerBound...]) }
        if let colon = id.lastIndex(of: ":"), let dash = id[..<colon].lastIndex(of: "-"),
           id[id.index(after: dash)..<colon].first == "v" {
            id = String(id[..<dash])
        }
        id = id.replacingOccurrences(of: ".", with: "-")
        if id.hasSuffix("-latest") { id = String(id.dropLast(7)) }
        if let dash = id.lastIndex(of: "-") {
            let tail = id[id.index(after: dash)...]
            if tail.count == 8, tail.hasPrefix("20"), tail.allSatisfy(\.isNumber) { id = String(id[..<dash]) }
        }
        return aliases[id] ?? id
    }

    public static func price(forModel raw: String) -> UsageModelPrice? {
        table[canonicalModelID(raw)]
    }

    /// Estimated cost of one message or an aggregate of messages sharing the
    /// same speed and geography; nil when the model has no price.
    public static func costUSD(model raw: String, tokens: UsageTokens, fast: Bool, usGeo: Bool) -> Double? {
        price(forModel: raw).map { costUSD(price: $0, tokens: tokens, fast: fast, usGeo: usGeo) }
    }

    static func costUSD(price: UsageModelPrice, tokens: UsageTokens, fast: Bool, usGeo: Bool) -> Double {
        var input = price.inputPerMTok
        var output = price.outputPerMTok
        if fast, let fastInput = price.fastInputPerMTok, let fastOutput = price.fastOutputPerMTok {
            input = fastInput
            output = fastOutput
        }
        var perMillion = Double(tokens.input) * input
        perMillion += Double(tokens.output) * output
        perMillion += Double(tokens.cacheWrite5m) * input * UsageModelPrice.cacheWrite5mMultiplier
        perMillion += Double(tokens.cacheWrite1h) * input * UsageModelPrice.cacheWrite1hMultiplier
        perMillion += Double(tokens.cacheRead) * input * price.cacheReadMultiplier
        var dollars = perMillion / 1_000_000
        if usGeo && price.supportsUSGeo { dollars *= 1.1 }
        return dollars + Double(tokens.webSearches) * webSearchUSD
    }
}
