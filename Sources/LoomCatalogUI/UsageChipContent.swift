import Foundation
import LoomCore

/// What the sidebar footer's usage chip says, as plain data so it can be tested and compared:
/// the chip's readers redraw only when this value changes.
public struct UsageChipContent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case indexing, empty, today }

    public var kind: Kind
    /// Secondary tone: `Today ` (or the whole text of the indexing and empty states).
    public var lead: String
    /// Primary tone, semibold: `1.2M tok`.
    public var figure: String
    /// `~$3.10` when a cost is known; the chip drops it whole before it cuts the figure.
    public var cost: String?
    public var tooltip: String
    public var accessibilityLabel: String

    /// Tokens and, when it is known, the estimated cost: `Today 1.2M tok · ~$3.10`.
    public var full: String { short + (cost.map { " · " + $0 } ?? "") }
    /// Tokens only; the chip falls back to it, never to a cut-off cost.
    public var short: String { lead + figure }

    /// nil hides the chip: no index, or a first scan that failed (Settings says why).
    static func make(state: UsageState, today: UsageSnapshot?, hasHistory: Bool) -> UsageChipContent? {
        switch state {
        case .idle, .failed:
            return nil
        case .indexing:
            return UsageChipContent(
                kind: .indexing, lead: "Indexing…", figure: "", cost: nil,
                tooltip: "Loom is reading Claude's local transcripts for the first time. Usage appears when it finishes. Click to open Usage.",
                accessibilityLabel: "Claude usage, indexing")
        case .ready:
            guard let today else { return nil }
            guard today.tokens.total > 0 || hasHistory else {
                return UsageChipContent(
                    kind: .empty, lead: "No usage yet", figure: "", cost: nil,
                    tooltip: "No Claude usage found in this profile yet. Click to open Usage.",
                    accessibilityLabel: "No Claude usage yet")
            }
            let tokens = today.tokens
            let priced = today.estimatedCostUSD > 0
            var tooltip = "Claude usage today, this Claude profile\n"
                + "\(UsageFormat.grouped(tokens.total)) tokens: input \(UsageFormat.grouped(tokens.input)), "
                + "output \(UsageFormat.grouped(tokens.output)), cache write \(UsageFormat.grouped(tokens.cacheWrite)), "
                + "cache read \(UsageFormat.grouped(tokens.cacheRead))."
            if priced { tooltip += "\nAPI-equivalent estimate about \(UsageFormat.fullCost(today.estimatedCostUSD))." }
            if today.hasUnknownCost { tooltip += "\nSome models have no known price; their tokens are counted, their cost is left out." }
            tooltip += "\nClick to open Usage."
            return UsageChipContent(
                kind: .today, lead: "Today ", figure: "\(UsageFormat.tokens(tokens.total)) tok",
                cost: priced ? UsageFormat.cost(today.estimatedCostUSD) : nil, tooltip: tooltip,
                accessibilityLabel: "Claude usage today, \(UsageFormat.spokenTokens(tokens.total)) tokens"
                    + (priced ? ", estimated cost about \(UsageFormat.fullCost(today.estimatedCostUSD))" : ""))
        }
    }
}
