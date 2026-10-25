import SwiftUI
import LoomCore

// The Limits section of the Usage page (D-99): one group per harness, one card per limit window, from the probe's
// readings. The rules here are plain data so tests can state them from fixture readings; the views only draw them.

// MARK: Words and choices

enum UsageHarnessText {
    static func name(_ harness: ManagedSession.Provider) -> String {
        switch harness {
        case .claude: "Claude"
        case .codex: "Codex"
        case .synthetic: "Test"
        }
    }

    /// Why a read failed when the probe says no more than that it gave nothing new.
    static func didNotAnswer(_ harness: ManagedSession.Provider) -> String { "\(name(harness)) did not answer." }

    /// "Could not read: Codex did not answer."
    static func couldNotRead(_ reason: String) -> String { "Could not read: \(reason)" }
}

/// Which harness the page shows: all the connected ones, or one of them.
enum UsageHarnessFilter: Hashable, CaseIterable, Sendable {
    case all, claude, codex

    var title: String {
        switch self {
        case .all: "All"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var provider: ManagedSession.Provider? {
        switch self {
        case .all: nil
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// The harnesses this choice shows out of the connected ones. A choice whose harness is switched off shows them all.
    func shown(among connected: [ManagedSession.Provider]) -> [ManagedSession.Provider] {
        guard let provider, connected.contains(provider) else { return connected }
        return [provider]
    }

    /// The choices offered: only when more than one harness is connected.
    static func offered(among connected: [ManagedSession.Provider]) -> [UsageHarnessFilter] {
        connected.count > 1 ? allCases : []
    }
}

extension HarnessLimitWindow {
    /// The plan kind whose length this window has; the pace is worked out for those two lengths only.
    var planKind: PlanLimitKind? {
        switch durationMinutes {
        case 300: .fiveHour
        case 7 * 1_440: .weekly
        default: nil
        }
    }

    /// The pace of this window at `now`, its used share measured at `measuredAt`; nil for another length, with no reset
    /// time, or once it has ended.
    func pace(at now: Date, measuredAt: Date) -> PlanPace? {
        guard let kind = planKind else { return nil }
        return PlanPace(kind: kind, window: PlanLimitWindow(usedPercent: usedPercent, resetsAt: resetsAt), at: now,
                        measuredAt: measuredAt)
    }
}

extension PlanLimits {
    /// The two windows of a Claude reading (`five_hour`, `seven_day`); nil when it holds neither.
    init?(reading: HarnessReading) {
        func window(_ id: String) -> PlanLimitWindow? {
            reading.windows.first { $0.id == id }.map { PlanLimitWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        }
        let five = window("five_hour"), week = window("seven_day")
        guard five != nil || week != nil else { return nil }
        self.init(fiveHour: five, weekly: week, fetchedAt: reading.readAt)
    }
}

// MARK: Rules

/// One limit window's card.
struct UsageLimitCard: Identifiable, Equatable {
    let id: String
    let content: PlanPaceLine.Content
    /// `Read 14:52`.
    let read: String
    let accessibilityLabel: String
    let accessibilityValue: String
}

/// What a group says instead of cards.
struct UsageLimitMessage: Equatable {
    let title: String
    let detail: String?
}

/// One harness's part of the Limits page.
struct UsageLimitsGroup: Identifiable, Equatable {
    let harness: ManagedSession.Provider
    var id: ManagedSession.Provider { harness }
    let heading: String
    /// The plan the account is on (`Max`, `Plus`); never the email.
    let plan: String?
    let cards: [UsageLimitCard]
    let message: UsageLimitMessage?
    /// `Could not read: …`; shown beside the cards of the last good reading, or alone when there are none.
    let failure: String?
}

enum UsageLimitsPage {
    /// The groups of the harnesses shown, in the order given.
    static func groups(
        harnesses: [ManagedSession.Provider], readings: [ManagedSession.Provider: HarnessReading],
        failures: [ManagedSession.Provider: String], now: Date, timeZone: TimeZone
    ) -> [UsageLimitsGroup] {
        harnesses.map {
            group(harness: $0, reading: readings[$0], failure: failures[$0], now: now, timeZone: timeZone)
        }
    }

    static func group(
        harness: ManagedSession.Provider, reading: HarnessReading?, failure: String?, now: Date, timeZone: TimeZone
    ) -> UsageLimitsGroup {
        let name = UsageHarnessText.name(harness)
        var plan: String?
        if case let .subscription(_, named)? = reading?.account, let named, !named.isEmpty { plan = named.capitalizedFirst }
        func group(cards: [UsageLimitCard] = [], message: UsageLimitMessage? = nil, failure: String? = nil) -> UsageLimitsGroup {
            UsageLimitsGroup(harness: harness, heading: name, plan: plan, cards: cards, message: message, failure: failure)
        }
        if let account = reading?.account {
            switch account {
            case .apiKey:
                return group(message: UsageLimitMessage(
                    title: "No subscription limits",
                    detail: "\(name) is using an API key, so there is no plan limit to show."))
            case .none:
                return group(message: UsageLimitMessage(
                    title: "Not signed in",
                    detail: "Sign in with the \(name) CLI, then check Settings → Connections."))
            case .subscription:
                break
            }
        }
        let failureText = failure.map(UsageHarnessText.couldNotRead)
        guard let reading else {
            return failureText == nil
                ? group(message: UsageLimitMessage(title: "Reading limits…", detail: nil))
                : group(failure: failureText)
        }
        let windows = reading.currentWindows(at: now)
        guard !windows.isEmpty else {
            if failureText != nil { return group(failure: failureText) }
            return group(message: reading.windows.isEmpty
                ? UsageLimitMessage(title: "No limits reported", detail: "\(name) reported no limit windows for this account.")
                : UsageLimitMessage(title: "No limit window is running",
                                    detail: "The last windows have reset. Update usage to read them again."))
        }
        let read = "Read \(UsageText.time(reading.readAt, timeZone))"
        let cards = windows.map { window -> UsageLimitCard in
            let content = PlanPaceLine.Content(
                window: window, measuredAt: reading.readAt, now: now, timeZone: timeZone, relative: true)
            return UsageLimitCard(
                id: "\(harness.rawValue).\(window.id)", content: content, read: read,
                accessibilityLabel: "\(name) \(content.title), \(content.left)",
                accessibilityValue: "\(content.sentence). \(read)")
        }
        return group(cards: cards, failure: failureText)
    }
}

// MARK: Views

private typealias S = LoomTheme.Settings

/// The Limits section: a heading per harness and its cards.
struct UsageLimitsView: View {
    let groups: [UsageLimitsGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: S.limitGroupGap) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: S.cardGap) {
                    heading(group)
                    ForEach(group.cards) { UsageLimitCardView(card: $0) }
                    if let message = group.message { UsageLimitMessageCard(message: message) }
                    if let failure = group.failure {
                        Text(failure).projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Status.failureLight)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func heading(_ group: UsageLimitsGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: S.headGap) {
            Text(group.heading).projectType(S.headTitle).foregroundStyle(LoomTheme.Text.primary)
            if let plan = group.plan {
                Text(plan).projectType(S.headMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One window: the pace line (name, what is left, the meter with its tick, the reset and verdict) and when it was read.
/// VoiceOver reads the card as one element.
struct UsageLimitCardView: View {
    let card: UsageLimitCard

    var body: some View {
        SettingsCard(holdsRows: false) {
            VStack(alignment: .leading, spacing: S.limitCardGap) {
                PlanPaceLine(content: card.content)
                Text(card.read).projectType(S.headMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            .padding(.top, S.cardPaddingTop).padding(.horizontal, S.cardPaddingH).padding(.bottom, S.cardPaddingBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .monospacedDigit()
        .help(card.content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityValue(card.accessibilityValue)
    }
}

/// "Not signed in" and the other things a harness says instead of windows.
struct UsageLimitMessageCard: View {
    let message: UsageLimitMessage

    var body: some View {
        SettingsCard(holdsRows: false) {
            VStack(alignment: .leading, spacing: S.limitCardGap) {
                Text(message.title).projectType(S.limitLabel).foregroundStyle(LoomTheme.Text.primary)
                if let detail = message.detail {
                    Text(detail).projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, S.cardPaddingTop).padding(.horizontal, S.cardPaddingH).padding(.bottom, S.cardPaddingBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
