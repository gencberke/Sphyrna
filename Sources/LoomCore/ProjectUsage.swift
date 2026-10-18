import Foundation

/// What one project's sessions used in a range (the project page's "past 7 days"). It is made from the
/// usage index's own database by `ClaudeUsageIndex.projectUsage`; nothing here opens a transcript.
public struct ProjectUsage: Sendable, Equatable {
    public var tokens: UsageTokens
    /// The price-table estimate; nil when a model in the range has no known price.
    public var estimatedCostUSD: Double?
    public var messageCount: Int
    /// Sessions with at least one message in the range.
    public var sessionCount: Int

    public init(tokens: UsageTokens = UsageTokens(), estimatedCostUSD: Double? = 0, messageCount: Int = 0, sessionCount: Int = 0) {
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.messageCount = messageCount
        self.sessionCount = sessionCount
    }

    public static let empty = ProjectUsage()
}
