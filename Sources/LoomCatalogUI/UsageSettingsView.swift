import SwiftUI
import LoomCore

/// The Usage section: this Claude profile's tokens by period, from the usage model only.
struct UsageSettings: View {
    let usage: UsageModel?
    let profile: URL?

    var body: some View {
        if let usage {
            UsageContent(usage: usage, profile: profile)
        } else {
            UsageNotice(title: "Usage is not available",
                        text: "Loom could not open its usage index, so no Claude usage is shown.")
        }
    }
}

private struct UsageContent: View {
    let usage: UsageModel
    let profile: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("This Claude profile, all projects")
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                Spacer()
                SegmentedControl(
                    values: UsagePeriod.allCases, title: \.title, selection: usage.period,
                    compact: true, enabled: usage.state == .ready, onSelect: { usage.select($0) })
                    .accessibilityLabel("Period")
            }
            .frame(height: LoomTheme.Layout.usageControlHeight)
            .padding(.horizontal, LoomTheme.Space.settingsInset)
            body(for: usage.state)
            UsageFooter(usage: usage)
        }
        .onAppear { usage.setUsageSectionSelected(true) }
        .onDisappear { usage.setUsageSectionSelected(false) }
    }

    @ViewBuilder
    private func body(for state: UsageState) -> some View {
        switch state {
        case .idle, .indexing:
            UsageNotice(title: "Reading Claude's usage",
                        text: "Loom is reading the transcripts Claude keeps on this Mac. This happens once; after that only new lines are read.")
        case let .failed(message):
            UsageNotice(title: "Usage could not be read", text: message, retry: { usage.refresh(reason: .manual) })
        case .ready:
            if !usage.hasHistory {
                UsageNotice(title: "No Claude usage yet",
                            text: "Loom found no transcripts in this Claude profile. Usage appears after a session finishes its first turn.",
                            path: profile.map { SettingsPaths.display($0.appendingPathComponent("projects")) })
            } else if let report = usage.report, report.period == usage.period {
                ScrollView {
                    UsageReportView(report: report, limits: usage.limits, limitsFailure: usage.limitsFailure,
                                    linesNotUnderstood: usage.linesNotUnderstood, timeZone: usage.timeZone)
                        .padding(.horizontal, LoomTheme.Space.settingsInset)
                        .padding(.bottom, LoomTheme.Space.settingsSectionGap)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

private struct UsageNotice: View {
    let title: String
    let text: String
    var path: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: LoomTheme.Space.hintSpacing) {
            Text(title).font(LoomTheme.Typography.heading)
            Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: LoomTheme.Layout.messageMaxWidth)
            if let path {
                Text(path).font(LoomTheme.Typography.mono).foregroundStyle(LoomTheme.Text.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if let retry { Button("Try again", action: retry).buttonStyle(AccentButtonStyle(kind: .tinted)) }
        }
        .padding(.horizontal, LoomTheme.Space.settingsInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct UsageFooter: View {
    let usage: UsageModel

    var body: some View {
        HStack(spacing: LoomTheme.Space.footerSpacing) {
            if let message = usage.lastFailure {
                Text("Could not update: \(message)").foregroundStyle(LoomTheme.Status.failure).lineLimit(1)
            } else {
                Text(updated)
                if let asOf = usage.report?.snapshot.priceTableAsOf {
                    Text("·")
                    Text("Prices as of \(UsageText.priceDate(asOf))")
                }
            }
            Spacer(minLength: 0)
            Button { usage.refresh(reason: .manual) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ChromeButtonStyle())
                .disabled(usage.isRefreshing)
                .help("Update usage now")
                .accessibilityLabel("Update usage")
        }
        .font(LoomTheme.Typography.caption).monospacedDigit()
        .foregroundStyle(LoomTheme.Text.secondary)
        .padding(.leading, LoomTheme.Space.settingsInset).padding(.trailing, LoomTheme.Space.settingsFooterInset)
        .frame(height: LoomTheme.Layout.settingsFooterHeight)
        .overlay(alignment: .top) { SettingsRowDivider() }
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
