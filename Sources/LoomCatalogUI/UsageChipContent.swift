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
    /// The plan window that runs out first; nil when plan limits are unknown.
    public var limit: Limit?
    public var tooltip: String
    public var accessibilityLabel: String
    /// One line per connected harness that reports usage, in Connections' order: `[mark] 168M  Wk ▬ 15%` (FB6-3). Empty
    /// where the chip says one thing (indexing, no usage yet).
    public var lines: [Line] = []

    /// One harness's line in the footer.
    public struct Line: Equatable, Sendable {
        public var harness: ManagedSession.Provider
        /// The tokens of today, or `—` for a harness that is not signed in or has not said.
        public var figure: String
        public var limit: Limit?

        public init(harness: ManagedSession.Provider, figure: String, limit: Limit?) {
            self.harness = harness
            self.figure = figure
            self.limit = limit
        }
    }

    /// The bottleneck plan window as data, so the view draws it (name, meter, percent) without formatting.
    public struct Limit: Equatable, Sendable {
        /// Below this many percent remaining the chip takes the attention colour.
        public static let lowBelowPercent = 20

        /// `5h` or `Wk`.
        public var name: String
        /// The share still left, 0...100.
        public var remainingPercent: Int
        public var isLow: Bool { remainingPercent < Self.lowBelowPercent }
        /// `5h 62%`.
        public var text: String { "\(name) \(UsageFormat.percent(remainingPercent))" }

        public init(name: String, remainingPercent: Int) {
            self.name = name
            self.remainingPercent = remainingPercent
        }
    }

    /// Tokens and, when it is known, the limit: `1.2M today · 5h 62%`.
    public var full: String { short + (limit.map { " · " + $0.text } ?? "") }
    /// Tokens only; the narrow chip drops the meter first and then cuts these, never the limit.
    public var short: String { lead + figure + suffix }

    /// nil hides the chip: no index, or a first scan that failed (Settings says why). `codex` is Codex's last reading: its
    /// windows are listed in the tooltip, and the chip's own number stays Claude's.
    static func make(
        state: UsageState, today: UsageSnapshot?, hasHistory: Bool, limits: PlanLimits? = nil, codex: HarnessReading? = nil,
        codexConnected: Bool = false, now: Date = Date(), timeZone: TimeZone = .current
    ) -> UsageChipContent? {
        switch state {
        case .idle, .failed:
            return nil
        case .indexing:
            return UsageChipContent(
                kind: .indexing, lead: "Indexing…", figure: "", suffix: "", limit: nil,
                tooltip: "Sphyrna is reading Claude's local transcripts for the first time. Usage appears when it finishes. Click to open Usage.",
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
            var limit: Limit?
            if let limits, let bottleneck = limits.bottleneck(at: now) {
                limit = Limit(name: bottleneck.kind.chipName, remainingPercent: bottleneck.window.remainingPercent)
                label += ", \(bottleneck.kind.spokenName) limit \(bottleneck.window.remainingPercent) percent remaining"
                tooltip += "\nPlan limits, updated \(UsageText.time(limits.fetchedAt, timeZone)):"
                for (kind, window) in limits.current(at: now) {
                    tooltip += "\n\(kind.title): \(UsageFormat.percent(window.remainingPercent)) left"
                        + (resetPhrase(window, now: now, timeZone: timeZone).map { ", " + $0 } ?? "")
                }
            }
            if let codex {
                let windows = codex.currentWindows(at: now)
                if !windows.isEmpty {
                    tooltip += "\nCodex limits, read \(UsageText.time(codex.readAt, timeZone)):"
                    for window in windows {
                        tooltip += "\n\(window.name): \(UsageFormat.percent(window.remainingPercent)) left"
                            + (resetPhrase(window.resetsAt, now: now, timeZone: timeZone).map { ", " + $0 } ?? "")
                    }
                }
            }
            var lines = [Line(harness: .claude, figure: UsageFormat.tokens(tokens.total), limit: limit)]
            if codexConnected {
                let line = codexLine(codex, now: now, timeZone: timeZone)
                lines.append(line)
                label += ". Codex, " + (codex?.account == nil ? "not signed in" : "\(line.figure) tokens today"
                    + (line.limit.map { ", limit \($0.name) \($0.remainingPercent) percent remaining" } ?? ""))
                if let day = codexTokens(codex, now: now, timeZone: timeZone) {
                    tooltip += "\nCodex tokens today: \(UsageFormat.grouped(day))"
                }
            }
            tooltip += "\nClick to open Usage."
            return UsageChipContent(
                kind: .today, lead: "", figure: UsageFormat.tokens(tokens.total), suffix: " today", limit: limit,
                tooltip: tooltip, accessibilityLabel: label, lines: lines)
        }
    }

    /// Codex's line: today's tokens and its tightest current window; `—` while it is not signed in or has not answered.
    static func codexLine(_ reading: HarnessReading?, now: Date, timeZone: TimeZone) -> Line {
        guard let reading, reading.account != nil else { return Line(harness: .codex, figure: "\u{2014}", limit: nil) }
        let tightest = reading.currentWindows(at: now).min { $0.remainingPercent < $1.remainingPercent }
        let figure = codexTokens(reading, now: now, timeZone: timeZone).map(UsageFormat.tokens) ?? "\u{2014}"
        return Line(harness: .codex, figure: figure, limit: tightest.map {
            Limit(name: chipName(of: $0), remainingPercent: $0.remainingPercent)
        })
    }

    /// The tokens Codex counted for today's date, when it listed that day.
    static func codexTokens(_ reading: HarnessReading?, now: Date, timeZone: TimeZone) -> Int64? {
        guard let reading else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let today = String(format: "%04d-%02d-%02d", year, month, day)
        return reading.tokenDays.first { $0.day == today }?.tokens
    }

    /// A window's short name in the chip: `5h`, `Wk`, `3d`; its own name when its length is unknown.
    static func chipName(of window: HarnessLimitWindow) -> String {
        guard let minutes = window.durationMinutes else { return window.name }
        if minutes == 7 * 1_440 { return "Wk" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// `resets 16:30`, or `resets Mon 10:00` when it is not today; nil when the reset time is unknown.
    static func resetPhrase(_ window: PlanLimitWindow, now: Date, timeZone: TimeZone) -> String? {
        resetPhrase(window.resetsAt, now: now, timeZone: timeZone)
    }

    static func resetPhrase(_ resetsAt: Date?, now: Date, timeZone: TimeZone) -> String? {
        guard let resets = resetsAt else { return nil }
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
