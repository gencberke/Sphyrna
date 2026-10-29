import Foundation

/// What one session used over its whole life, from the usage index (`ClaudeUsageIndex.sessionUsage`): its main thread and
/// its subagents apart, since a short session can spend most of its tokens in two subagents. The cost is the price table's
/// API equivalent, not a share of the plan.
public struct SessionUsage: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var tokens: UsageTokens
        /// The price-table estimate; nil when a model of the part has no known price.
        public var estimatedCostUSD: Double?
        public var messageCount: Int
        /// Some providers report token counters without a count of assistant messages.
        public var messageCountKnown: Bool

        public init(tokens: UsageTokens = UsageTokens(), estimatedCostUSD: Double? = 0, messageCount: Int = 0,
                    messageCountKnown: Bool = true) {
            self.tokens = tokens
            self.estimatedCostUSD = estimatedCostUSD
            self.messageCount = messageCount
            self.messageCountKnown = messageCountKnown
        }
    }

    public var main: Part
    public var subagents: Part
    /// Some harnesses do not report a separate subagent split.
    public var subagentBreakdownKnown: Bool
    /// The bounded read or its source omitted part of the accounting.
    public var partial: Bool

    public init(main: Part = Part(), subagents: Part = Part(), subagentBreakdownKnown: Bool = true, partial: Bool = false) {
        self.main = main
        self.subagents = subagents
        self.subagentBreakdownKnown = subagentBreakdownKnown
        self.partial = partial
    }

    public var total: Part {
        var tokens = main.tokens
        tokens.add(subagents.tokens)
        let cost = main.estimatedCostUSD.flatMap { first in subagents.estimatedCostUSD.map { first + $0 } }
        return Part(tokens: tokens, estimatedCostUSD: cost, messageCount: main.messageCount + subagents.messageCount,
                    messageCountKnown: main.messageCountKnown && subagents.messageCountKnown)
    }

    public var isEmpty: Bool {
        func empty(_ part: Part) -> Bool {
            part.messageCount == 0 && (part.messageCountKnown || (part.tokens.total == 0 && part.tokens.webSearches == 0))
        }
        return empty(main) && empty(subagents)
    }

    public static let empty = SessionUsage()
}
