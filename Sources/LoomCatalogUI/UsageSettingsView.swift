import SwiftUI
import LoomCore

/// The Usage section: the limit windows and the tokens of each connected harness, from the usage model only.
struct UsageSettings: View {
    let usage: UsageModel?
    let profile: URL?

    var body: some View {
        if let usage {
            UsageContent(usage: usage, profile: profile)
        } else {
            SettingsNote(title: "Usage is not available",
                         text: "Sphyrna could not open its usage index, so no usage is shown.")
        }
    }
}

extension UsageSection {
    var title: String {
        switch self {
        case .limits: "Limits"
        case .tokens: "Tokens"
        }
    }
}

private struct UsageContent: View {
    let usage: UsageModel
    let profile: URL?
    /// Which harness the page shows; not kept (it is a look at one part, not a setting).
    @State private var filter: UsageHarnessFilter = .all

    private typealias S = LoomTheme.Settings

    var body: some View {
        let connected = usage.connectedHarnesses
        let chosen = (filter.provider.map(connected.contains) ?? true) ? filter : .all
        let shown = chosen.shown(among: connected)
        VStack(spacing: 0) {
            if shown.isEmpty {
                VStack(spacing: 0) {
                    head(connected: connected, chosen: chosen, shown: shown)
                        .padding(.horizontal, S.bodyInset).padding(.top, S.bodyTop)
                    SettingsNote(title: "No harness is connected",
                                 text: "Switch Claude or Codex on in Settings → Connections to see its usage.")
                }
            } else {
                switch usage.section {
                case .limits: limitsPage(connected: connected, chosen: chosen, shown: shown)
                case .tokens: tokensPage(connected: connected, chosen: chosen, shown: shown)
                }
            }
            UsageFooter(usage: usage)
        }
        .onAppear { usage.setUsageSectionSelected(true) }
        .onDisappear { usage.setUsageSectionSelected(false) }
    }

    /// The page's first lines, which scroll with it: the section switch and the harness filter, and for Tokens the period
    /// line (what the numbers cover, and the periods).
    private func head(connected: [ManagedSession.Provider], chosen: UsageHarnessFilter,
                      shown: [ManagedSession.Provider]) -> some View {
        VStack(alignment: .leading, spacing: S.periodGap) {
            HStack(spacing: S.periodGap) {
                InkSegmented(values: UsageSection.allCases, title: \.title, selection: usage.section,
                             onSelect: { usage.selectSection($0) })
                    .accessibilityLabel("Section")
                Spacer(minLength: 0)
                let offered = UsageHarnessFilter.offered(among: connected)
                if !offered.isEmpty {
                    InkSegmented(values: offered, title: \.title, selection: chosen, onSelect: { filter = $0 })
                        .accessibilityLabel("Harness")
                }
            }
            if usage.section == .tokens { periodLine(shown: shown) }
        }
        .padding(.bottom, S.periodBottom)
    }

    /// What the tokens cover and the periods.
    private func periodLine(shown: [ManagedSession.Provider]) -> some View {
        HStack(spacing: S.periodGap) {
            Text(UsageCardText.coverage(of: shown)).projectType(S.periodText).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Spacer(minLength: 0)
            InkSegmented(values: UsagePeriod.allCases, title: \.title, selection: usage.period,
                         enabled: usage.state == .ready || !shown.contains(.claude), onSelect: { usage.select($0) })
                .accessibilityLabel("Period")
        }
    }

    // Limits

    private func limitsPage(connected: [ManagedSession.Provider], chosen: UsageHarnessFilter,
                            shown: [ManagedSession.Provider]) -> some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 0) {
                head(connected: connected, chosen: chosen, shown: shown)
                UsageLimitsView(groups: usage.limitGroups(shown: shown, now: Date()))
            }
        }
    }

    // Tokens

    @ViewBuilder
    private func tokensPage(connected: [ManagedSession.Provider], chosen: UsageHarnessFilter,
                            shown: [ManagedSession.Provider]) -> some View {
        let top = head(connected: connected, chosen: chosen, shown: shown)
        switch usage.state {
        case .idle, .indexing:
            note(top, SettingsNote(title: "Reading Claude's usage",
                                    text: "Sphyrna is reading the transcripts Claude keeps on this Mac. This happens once; after that only new lines are read."))
        case let .failed(message):
            note(top, SettingsNote(title: "Usage could not be read", text: message, retry: { usage.refresh(reason: .manual) }))
        case .ready:
            if !usage.hasHistory {
                note(top, SettingsNote(title: "No Claude usage yet",
                                        text: "Sphyrna found no transcripts in this Claude profile. Usage appears after a session finishes its first turn.",
                                        path: profile.map { SettingsPaths.display($0.appendingPathComponent("projects")) }))
            } else if let report = usage.report, report.period == usage.period {
                SettingsPage {
                    VStack(alignment: .leading, spacing: 0) {
                        top
                        UsageReportView(report: report, linesNotUnderstood: usage.linesNotUnderstood, timeZone: usage.timeZone)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    top.padding(.horizontal, S.bodyInset).padding(.top, S.bodyTop)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// A page state with the head above it (the periods disabled until a report is ready).
    private func note(_ head: some View, _ note: SettingsNote) -> some View {
        VStack(spacing: 0) {
            head.padding(.horizontal, S.bodyInset).padding(.top, S.bodyTop)
            note
        }
    }
}

private struct UsageFooter: View {
    let usage: UsageModel

    var body: some View {
        SettingsFooter {
            if let message = usage.lastFailure {
                Text("Could not update: \(message)").foregroundStyle(LoomTheme.Status.failureLight)
            } else {
                Text(text)
            }
        } trailing: {
            SettingsRefreshButton(label: "Update usage now", disabled: usage.isRefreshing) {
                usage.refresh(reason: .manual)
            }
            .accessibilityLabel("Update usage")
        }
    }

    private var text: String {
        var parts = [updated]
        if let asOf = usage.report?.snapshot.priceTableAsOf { parts.append("Prices as of \(UsageText.priceDate(asOf))") }
        return parts.joined(separator: " · ")
    }

    private var updated: String {
        // Warm refreshes keep the last time; only the first scan says it is reading.
        guard let date = usage.updatedAt else { return usage.isRefreshing ? "Reading" : "Not updated yet" }
        return "Updated \(UsageText.time(date, usage.timeZone))"
    }
}

/// Date and time text in the usage model's time zone, in the system locale (`LoomDateFormat`).
enum UsageText {
    static var formattersCreated: Int { LoomDateFormat.formattersCreated }

    /// The one line under the page when scans met records they could not understand; nil for none.
    static func skippedLines(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(UsageFormat.grouped(Int64(count))) usage \(count == 1 ? "record" : "records") could not be understood, so totals may be low."
    }

    static func weekday(_ date: Date, _ zone: TimeZone, locale: Locale = .current) -> String {
        LoomDateFormat.weekday(date, zone: zone, locale: locale)
    }

    static func date(_ date: Date, _ zone: TimeZone, locale: Locale = .current) -> String {
        LoomDateFormat.weekdayDayMonth(date, zone: zone, locale: locale)
    }

    static func time(_ date: Date, _ zone: TimeZone, locale: Locale = .current) -> String {
        LoomDateFormat.time(date, zone: zone, locale: locale)
    }

    /// `9 AM`, or `9:30 AM` when the zone's hour boundary is not on the hour (the locale's own clock).
    static func hour(_ date: Date, _ zone: TimeZone, locale: Locale = .current) -> String {
        LoomDateFormat.hour(date, zone: zone, locale: locale)
    }

    /// The 24-hour chart labels every sixth hour.
    static func isLabelledHour(_ date: Date, _ zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.hour, from: date) % 6 == 0
    }

    static func bucket(_ date: Date, _ period: UsagePeriod, _ zone: TimeZone) -> String {
        period == .hours24 ? hour(date, zone) : self.date(date, zone)
    }

    nonisolated(unsafe) private static let priceParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    /// `2026-10-07` as the locale's date (`Oct 7, 2026`).
    static func priceDate(_ text: String, locale: Locale = .current) -> String {
        guard let date = priceParser.date(from: text) else { return text }
        return LoomDateFormat.date(date, zone: TimeZone(identifier: "UTC")!, locale: locale)
    }
}
