import SwiftUI
import LoomCore

// Codex's part of the Tokens section (D-99): `account/usage/read` gives one total per day and a lifetime total, with no split
// by type or model and no cost, so the card is a total, a daily line and the lifetime figure. The rules are plain data.

/// What Codex's days add up to for one period.
struct UsageCodexPeriod: Equatable {
    /// The period's total; for 24 h, today's.
    let total: Int64
    /// One bar per local day, oldest first, today last; none for 24 h (a day is the finest the harness reports).
    let bars: [UsageBar]
    let lifetime: Int64?

    /// The days of `reading` that fall in the last `period` local days (today included), in `timeZone`.
    static func make(reading: HarnessReading, period: UsagePeriod, now: Date, timeZone: TimeZone) -> UsageCodexPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        // The harness's own date text (`2026-10-24`, or a timestamp starting with it).
        let byDay = Dictionary(reading.tokenDays.map { (String($0.day.prefix(10)), $0.tokens) }, uniquingKeysWith: +)
        let count = period.dayCount ?? 1
        let bars = (0..<count).reversed().map { offset -> UsageBar in
            let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            return UsageBar(start: start, tokens: byDay[key] ?? 0, isCurrent: offset == 0)
        }
        return UsageCodexPeriod(
            total: bars.reduce(Int64(0)) { $0 + $1.tokens }, bars: period == .hours24 ? [] : bars,
            lifetime: reading.lifetimeTokens)
    }
}

/// What Codex's card shows.
enum UsageCodexCard: Equatable {
    /// The figures, and when the last ask failed, why they may be old.
    case figures(UsageCodexPeriod, failure: String?)
    case message(UsageLimitMessage)
}

enum UsageCodexTokens {
    static let fineLine = "Codex reports one total per day, with no split by type or model, so no cost is estimated."

    static func card(reading: HarnessReading?, failure: String?, period: UsagePeriod, now: Date, timeZone: TimeZone) -> UsageCodexCard {
        let failureText = failure.map(UsageHarnessText.couldNotRead)
        guard let reading else {
            return .message(failureText == nil
                ? UsageLimitMessage(title: "Reading Codex's usage…", detail: nil)
                : UsageLimitMessage(title: "Codex's usage could not be read", detail: failureText))
        }
        if let account = reading.account, account == HarnessAccount.none {
            return .message(UsageLimitMessage(
                title: "Not signed in", detail: "Sign in with the Codex CLI, then check Settings → Connections."))
        }
        guard !reading.tokenDays.isEmpty || reading.lifetimeTokens != nil else {
            return .message(UsageLimitMessage(
                title: "No token totals",
                detail: failureText ?? "Codex reported no token totals for this account."))
        }
        return .figures(UsageCodexPeriod.make(reading: reading, period: period, now: now, timeZone: timeZone), failure: failureText)
    }

    /// "Claude 12.3M · Codex 4.5M tokens, last 7 days": each harness's total for the period, above the cards. nil unless there
    /// are two totals to put side by side.
    static func totalsLine(claude: Int64?, codex: Int64?, period: UsagePeriod) -> String? {
        guard let claude, let codex else { return nil }
        return "\(ProviderName.title(.claude)) \(UsageFormat.tokens(claude)) · \(ProviderName.title(.codex)) \(UsageFormat.tokens(codex)) tokens, \(period.phrase)"
    }
}

// MARK: Views

private typealias S = LoomTheme.Settings

/// Codex's card: the period's total, a daily line (not for 24 h), the lifetime total and the line that says what is not there.
struct UsageCodexCardView: View {
    let card: UsageCodexCard
    let period: UsagePeriod
    let timeZone: TimeZone

    var body: some View {
        switch card {
        case let .figures(figures, failure):
            VStack(alignment: .leading, spacing: S.limitCardGap) {
                UsageCard(title: ProviderName.title(.codex), meta: UsageCardText.periodTitle(period)) { content(figures) }
                if let failure {
                    Text(failure).projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Status.failureLight)
                }
            }
        case let .message(message):
            UsageCard(title: ProviderName.title(.codex), meta: UsageCardText.periodTitle(period)) {
                VStack(alignment: .leading, spacing: S.limitCardGap) {
                    Text(message.title).projectType(S.limitLabel).foregroundStyle(LoomTheme.Text.primary)
                    if let detail = message.detail {
                        Text(detail).projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func content(_ figures: UsageCodexPeriod) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(UsageFormat.tokens(figures.total)).projectType(S.total).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(1).frame(minHeight: S.totalLine, alignment: .leading)
                    .help("\(UsageFormat.grouped(figures.total)) tokens")
                Text("tokens").projectType(S.caption).foregroundStyle(LoomTheme.Text.secondaryStyle).padding(.top, S.captionTop)
            }
            .accessibilityElement(children: .combine)
            if !figures.bars.isEmpty {
                UsageBarsView(bars: figures.bars, period: period, timeZone: timeZone).padding(.top, S.codexBarsTop)
            }
            if let lifetime = figures.lifetime {
                HStack {
                    Text("Lifetime").projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    Spacer(minLength: 0)
                    Text(UsageFormat.tokens(lifetime)).projectType(S.cacheValue).foregroundStyle(LoomTheme.Text.primary)
                        .help("\(UsageFormat.grouped(lifetime)) tokens")
                }
                .padding(.top, S.cachePadding)
                .overlay(alignment: .top) { SettingsRowDivider() }
                .padding(.top, S.cacheTop + S.codexBarsTop)
                .accessibilityElement(children: .combine)
            }
            Text(UsageCodexTokens.fineLine)
                .projectType(S.fine).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .fixedSize(horizontal: false, vertical: true).padding(.top, S.fineTop)
        }
    }
}
