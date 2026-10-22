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
            SettingsNote(title: "Usage is not available",
                         text: "Sphyrna could not open its usage index, so no Claude usage is shown.")
        }
    }
}

private struct UsageContent: View {
    let usage: UsageModel
    let profile: URL?

    private typealias S = LoomTheme.Settings

    var body: some View {
        VStack(spacing: 0) {
            content(for: usage.state)
            UsageFooter(usage: usage)
        }
        .onAppear { usage.setUsageSectionSelected(true) }
        .onDisappear { usage.setUsageSectionSelected(false) }
    }

    /// "This Claude profile, all projects" and the periods; they are the page's first line and scroll with it.
    private var periodLine: some View {
        HStack(spacing: S.periodGap) {
            Text("This Claude profile, all projects").projectType(S.periodText).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Spacer(minLength: 0)
            InkSegmented(values: UsagePeriod.allCases, title: \.title, selection: usage.period,
                         enabled: usage.state == .ready, onSelect: { usage.select($0) })
                .accessibilityLabel("Period")
        }
        .padding(.bottom, S.periodBottom)
    }

    @ViewBuilder
    private func content(for state: UsageState) -> some View {
        switch state {
        case .idle, .indexing:
            note(SettingsNote(title: "Reading Claude's usage",
                              text: "Sphyrna is reading the transcripts Claude keeps on this Mac. This happens once; after that only new lines are read."))
        case let .failed(message):
            note(SettingsNote(title: "Usage could not be read", text: message, retry: { usage.refresh(reason: .manual) }))
        case .ready:
            if !usage.hasHistory {
                note(SettingsNote(title: "No Claude usage yet",
                                  text: "Sphyrna found no transcripts in this Claude profile. Usage appears after a session finishes its first turn.",
                                  path: profile.map { SettingsPaths.display($0.appendingPathComponent("projects")) }))
            } else if let report = usage.report, report.period == usage.period {
                SettingsPage {
                    VStack(alignment: .leading, spacing: 0) {
                        periodLine
                        UsageReportView(report: report, limits: usage.limits, limitsFailure: usage.limitsFailure,
                                        linesNotUnderstood: usage.linesNotUnderstood, timeZone: usage.timeZone)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    periodLine.padding(.horizontal, S.bodyInset).padding(.top, S.bodyTop)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// A page state with the periods above it (disabled until a report is ready).
    private func note(_ note: SettingsNote) -> some View {
        VStack(spacing: 0) {
            periodLine.padding(.horizontal, S.bodyInset).padding(.top, S.bodyTop)
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
