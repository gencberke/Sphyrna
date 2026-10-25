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

        public init(tokens: UsageTokens = UsageTokens(), estimatedCostUSD: Double? = 0, messageCount: Int = 0) {
            self.tokens = tokens
            self.estimatedCostUSD = estimatedCostUSD
            self.messageCount = messageCount
        }
    }

    public var main: Part
    public var subagents: Part

    public init(main: Part = Part(), subagents: Part = Part()) {
        self.main = main
        self.subagents = subagents
    }

    public var total: Part {
        var tokens = main.tokens
        tokens.add(subagents.tokens)
        let cost = main.estimatedCostUSD.flatMap { first in subagents.estimatedCostUSD.map { first + $0 } }
        return Part(tokens: tokens, estimatedCostUSD: cost, messageCount: main.messageCount + subagents.messageCount)
    }

    public var isEmpty: Bool { main.messageCount == 0 && subagents.messageCount == 0 }

    public static let empty = SessionUsage()
}
