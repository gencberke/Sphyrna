import Foundation
import LoomCore

/// What the sidebar footer's usage chip says, as plain data so it can be tested and compared:
/// the chip's readers redraw only when this value changes. It carries tokens and plan limits, never money.
public struct UsageChipContent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case indexing, empty, today }

    public var kind: Kind
    /// Secondary tone, before the figure: the whole text of the indexing and empty states.
    public var lead: String
    /// Primary tone, semibold: `1.2M`.
    public var figure: String
    /// Secondary tone, after the figure: ` today`.
    public var suffix: String
    /// The plan window that runs out first, `5h 62% left`; nil when plan limits are unknown.
    public var limit: String?
    public var tooltip: String
    public var accessibilityLabel: String

    /// Tokens and, when it is known, the limit: `1.2M today · 5h 62% left`.
    public var full: String { short + (limit.map { " · " + $0 } ?? "") }
    /// Tokens only; the chip falls back to the limit alone or to this, never to a cut-off limit.
    public var short: String { lead + figure + suffix }

    /// nil hides the chip: no index, or a first scan that failed (Settings says why).
    static func make(
        state: UsageState, today: UsageSnapshot?, hasHistory: Bool, limits: PlanLimits? = nil,
        now: Date = Date(), timeZone: TimeZone = .current
    ) -> UsageChipContent? {
        switch state {
        case .idle, .failed:
            return nil
        case .indexing:
            return UsageChipContent(
                kind: .indexing, lead: "Indexing…", figure: "", suffix: "", limit: nil,
                tooltip: "Loom is reading Claude's local transcripts for the first time. Usage appears when it finishes. Click to open Usage.",
                accessibilityLabel: "Claude usage, indexing")
        case .ready:
            guard let today else { return nil }
            guard today.tokens.total > 0 || hasHistory else {
                return UsageChipContent(
                    kind: .empty, lead: "No usage yet", figure: "", suffix: "", limit: nil,
                    tooltip: "No Claude usage found in this profile yet. Click to open Usage.",
                    accessibilityLabel: "No Claude usage yet")
            }
            let tokens = today.tokens
            var tooltip = "Claude usage today, this Claude profile\n"
                + "\(UsageFormat.grouped(tokens.total)) tokens: input \(UsageFormat.grouped(tokens.input)), "
                + "output \(UsageFormat.grouped(tokens.output)), cache write \(UsageFormat.grouped(tokens.cacheWrite)), "
                + "cache read \(UsageFormat.grouped(tokens.cacheRead))."
            var label = "Claude usage today, \(UsageFormat.spokenTokens(tokens.total)) tokens"
            var limit: String?
            if let limits, let bottleneck = limits.bottleneck(at: now) {
                limit = "\(bottleneck.kind.chipName) \(bottleneck.window.remainingPercent)% left"
                label += ", \(bottleneck.kind.spokenName) limit \(bottleneck.window.remainingPercent) percent remaining"
                tooltip += "\nPlan limits, updated \(UsageText.time(limits.fetchedAt, timeZone)):"
                for (kind, window) in limits.current(at: now) {
                    tooltip += "\n\(kind.title): \(window.remainingPercent)% left"
                        + (resetPhrase(window, now: now, timeZone: timeZone).map { ", " + $0 } ?? "")
                }
            }
            tooltip += "\nClick to open Usage."
            return UsageChipContent(
                kind: .today, lead: "", figure: UsageFormat.tokens(tokens.total), suffix: " today", limit: limit,
                tooltip: tooltip, accessibilityLabel: label)
        }
    }

    /// `resets 16:30`, or `resets Mon 10:00` when it is not today; nil when the reset time is unknown.
    static func resetPhrase(_ window: PlanLimitWindow, now: Date, timeZone: TimeZone) -> String? {
        guard let resets = window.resetsAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.isDate(resets, inSameDayAs: now) ? "" : UsageText.weekday(resets, timeZone) + " "
        return "resets \(day)\(UsageText.time(resets, timeZone))"
    }
}

extension PlanLimitKind {
    /// Short name in the chip.
    var chipName: String { self == .fiveHour ? "5h" : "Wk" }
    var spokenName: String { self == .fiveHour ? "five-hour" : "weekly" }
    /// Name in tooltips and on the Usage page.
    var title: String { self == .fiveHour ? "5-hour" : "Weekly" }
}
