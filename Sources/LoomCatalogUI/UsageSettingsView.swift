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
                            text: "Loom found no transcripts in this Claude profile. Usage appears after a conversation finishes its first turn.",
                            path: profile.map { SettingsPaths.display($0.appendingPathComponent("projects")) })
            } else if let report = usage.report, report.period == usage.period {
                ScrollView {
                    UsageReportView(report: report, limits: usage.limits, timeZone: usage.timeZone)
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

// MARK: Plan limits

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The Claude plan's 5-hour and weekly windows, as the Claude CLI reports them: used and remaining
/// percent, and when each resets. Shown only while the CLI answered; a window that has reset is left out.
private struct PlanLimitsBlock: View {
    let limits: PlanLimits
    let timeZone: TimeZone

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Plan limits").fontWeight(.semibold)
                Spacer()
                Text("Updated \(UsageText.time(limits.fetchedAt, timeZone))")
            }
            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            .padding(.bottom, LoomTheme.Space.footerSpacing)
            ForEach(limits.current(at: now), id: \.kind) { item in
                row(item.kind, item.window, now: now)
            }
        }
        .monospacedDigit()
    }

    private func row(_ kind: PlanLimitKind, _ window: PlanLimitWindow, now: Date) -> some View {
        let reset = UsageChipContent.resetPhrase(window, now: now, timeZone: timeZone)
        return HStack(spacing: LoomTheme.Space.usageColumnGap / 2) {
            Text(kind.title).frame(width: LoomTheme.Layout.planLimitLabelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim).fill(LoomTheme.Surface.activityCell(0))
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim).fill(LoomTheme.Text.primary)
                        .frame(width: proxy.size.width * CGFloat(window.usedPercent) / 100)
                }
            }
            .frame(height: LoomTheme.Layout.planLimitBarHeight)
            Text("\(window.usedPercent)% used · \(window.remainingPercent)% left")
            Text(reset?.capitalizedFirst ?? "").foregroundStyle(LoomTheme.Text.secondary)
                .frame(width: LoomTheme.Layout.planLimitResetWidth, alignment: .trailing)
        }
        .font(LoomTheme.Typography.small)
        .frame(height: LoomTheme.Layout.usageHeaderRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title) limit, \(window.usedPercent) percent used, \(window.remainingPercent) percent remaining"
            + (reset.map { ", " + $0 } ?? ""))
    }
}

// MARK: Report

private struct UsageReportView: View {
    let report: UsageReport
    let limits: PlanLimits?
    let timeZone: TimeZone

    var body: some View {
        let snapshot = report.snapshot
        VStack(alignment: .leading, spacing: LoomTheme.Space.settingsSectionGap) {
            HStack(alignment: .top, spacing: LoomTheme.Space.usageColumnGap) {
                headline(snapshot).frame(maxWidth: .infinity, alignment: .leading)
                activityBlock.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let limits, !limits.current(at: Date()).isEmpty {
                PlanLimitsBlock(limits: limits, timeZone: timeZone)
            }
            totals(snapshot.tokens)
            chart
            modelTable(snapshot)
        }
        .padding(.top, LoomTheme.Space.settingsSegmentH - 4)
    }

    // Headline

    private func headline(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.footerSpacing) {
                Text(UsageFormat.tokens(snapshot.tokens.total)).font(LoomTheme.Typography.display)
                Text("tokens, \(report.period.phrase)")
                    .font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.secondary)
            }
            .lineLimit(1)
            .help("\(UsageFormat.grouped(snapshot.tokens.total)) tokens")
            Text(subline(snapshot)).font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.secondary)
            Text("API-equivalent estimate — subscriptions are not billed per token.")
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                .padding(.top, LoomTheme.Space.usageNoteTop - 2)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func subline(_ snapshot: UsageSnapshot) -> String {
        var parts: [String] = []
        if snapshot.estimatedCostUSD > 0 || !snapshot.hasUnknownCost {
            parts.append("\(UsageFormat.cost(snapshot.estimatedCostUSD)) est.")
        }
        parts.append("\(snapshot.sessionCount) session\(snapshot.sessionCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // Local five-hour cells

    private var activityBlock: some View {
        let cells = report.cells
        let peak = cells.map(\.tokens).max() ?? 0
        let total = cells.reduce(Int64(0)) { $0 + $1.tokens }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Last 5 hours").fontWeight(.semibold)
                Spacer()
                Text("approximate")
            }
            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            .padding(.bottom, LoomTheme.Space.footerSpacing)
            HStack(spacing: LoomTheme.Space.usageCellGap) {
                ForEach(cells.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.bar)
                        .fill(LoomTheme.Surface.activityCell(peak > 0 ? Double(cells[index].tokens) / Double(peak) : 0))
                        .frame(height: LoomTheme.Layout.usageCellHeight)
                        .help("\(UsageText.hour(cells[index].start, timeZone)): \(UsageFormat.tokens(cells[index].tokens)) tokens")
                }
            }
            HStack(spacing: LoomTheme.Space.usageCellGap) {
                ForEach(cells.indices, id: \.self) { index in
                    Text(UsageText.hour(cells[index].start, timeZone)).frame(maxWidth: .infinity)
                }
            }
            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            .padding(.top, LoomTheme.Space.usageCellLabelTop)
            Text("\(UsageFormat.tokens(total)) tokens. Local activity, not your plan limit.")
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                .padding(.top, LoomTheme.Space.usageNoteTop)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 5 hours, approximate. \(UsageFormat.spokenTokens(total)) tokens. Local activity, not your plan limit.")
    }

    // Totals

    private func totals(_ tokens: UsageTokens) -> some View {
        let share = tokens.cacheShare.map { "\(Int(($0 * 100).rounded())) %" } ?? "—"
        let items: [(String, String, String?)] = [
            ("Input", UsageFormat.tokens(tokens.input), UsageFormat.grouped(tokens.input)),
            ("Output", UsageFormat.tokens(tokens.output), UsageFormat.grouped(tokens.output)),
            ("Cache write", UsageFormat.tokens(tokens.cacheWrite),
             "5 min \(UsageFormat.grouped(tokens.cacheWrite5m)), 1 h \(UsageFormat.grouped(tokens.cacheWrite1h))"),
            ("Cache read", UsageFormat.tokens(tokens.cacheRead), UsageFormat.grouped(tokens.cacheRead)),
            ("Cache share", share, "Share of input-side tokens served from the cache."),
        ]
        return HStack(alignment: .top, spacing: LoomTheme.Space.usageTotalsGap) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[index].0).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                    Text(items[index].1).font(LoomTheme.Typography.title).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(items[index].2 ?? "")
                .accessibilityElement(children: .combine)
            }
        }
    }

    // Bars

    private var chart: some View {
        let bars = report.bars
        let peak = bars.max { $0.tokens < $1.tokens }
        let slim = bars.count > 7
        let gap = slim ? (bars.count > 30 ? LoomTheme.Space.usageBarGapSlim / 2 : LoomTheme.Space.usageBarGapSlim)
            : LoomTheme.Space.usageBarGap
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(report.period == .hours24 ? "Tokens per hour" : "Tokens per day").fontWeight(.semibold)
                Spacer()
                if let peak, peak.tokens > 0 {
                    Text("Peak \(UsageFormat.tokens(peak.tokens)), \(UsageText.bucket(peak.start, report.period, timeZone))")
                }
            }
            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            .padding(.bottom, LoomTheme.Space.footerSpacing)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(bars.indices, id: \.self) { index in
                    let bar = bars[index]
                    UnevenRoundedRectangle(topLeadingRadius: slim ? LoomTheme.Radius.barSlim : LoomTheme.Radius.bar,
                                           topTrailingRadius: slim ? LoomTheme.Radius.barSlim : LoomTheme.Radius.bar)
                        .fill(bar.isCurrent ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                        .frame(height: barHeight(bar, peak: peak?.tokens ?? 0))
                        .frame(maxWidth: .infinity)
                        .help("\(UsageText.bucket(bar.start, report.period, timeZone)), \(UsageFormat.tokens(bar.tokens)) tokens")
                }
            }
            .frame(height: LoomTheme.Layout.usageBarsHeight, alignment: .bottom)
            .overlay(alignment: .bottom) { SettingsRowDivider() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chartDescription(bars))
            axisLabels(bars, gap: gap)
        }
        .monospacedDigit()
    }

    private func barHeight(_ bar: UsageBar, peak: Int64) -> CGFloat {
        guard bar.tokens > 0, peak > 0 else { return 0 }
        return max(2, LoomTheme.Layout.usageBarsHeight * CGFloat(bar.tokens) / CGFloat(peak))
    }

    private func chartDescription(_ bars: [UsageBar]) -> String {
        let total = bars.reduce(Int64(0)) { $0 + $1.tokens }
        return "\(report.period == .hours24 ? "Tokens per hour" : "Tokens per day"), \(UsageFormat.spokenTokens(total)) tokens in total"
    }

    @ViewBuilder
    private func axisLabels(_ bars: [UsageBar], gap: CGFloat) -> some View {
        Group {
            switch report.period {
            case .days7:
                HStack(spacing: gap) {
                    ForEach(bars.indices, id: \.self) { index in
                        Text(UsageText.weekday(bars[index].start, timeZone)).frame(maxWidth: .infinity)
                    }
                }
            case .hours24:
                HStack(spacing: gap) {
                    ForEach(bars.indices, id: \.self) { index in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            .overlay { if UsageText.isLabelledHour(bars[index].start, timeZone) {
                                Text(UsageText.hour(bars[index].start, timeZone)).fixedSize()
                            } }
                    }
                }
            case .days30, .days90:
                HStack {
                    Text(bars.first.map { UsageText.date($0.start, timeZone) } ?? "")
                    Spacer()
                    Text(bars.last.map { UsageText.date($0.start, timeZone) } ?? "")
                }
            }
        }
        .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
        .padding(.top, LoomTheme.Space.usageCellLabelTop)
        .accessibilityHidden(true)
    }

    // By model

    private func modelTable(_ snapshot: UsageSnapshot) -> some View {
        let whole = snapshot.tokens.total
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("By model").fontWeight(.semibold)
                Spacer()
                Text("\(snapshot.models.count) model\(snapshot.models.count == 1 ? "" : "s")")
            }
            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            .padding(.bottom, LoomTheme.Space.footerSpacing)
            Grid(alignment: .trailing, horizontalSpacing: LoomTheme.Space.usageTotalsGap, verticalSpacing: 0) {
                GridRow {
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Tokens")
                    Text("Share")
                    Text("Est. cost")
                }
                .font(LoomTheme.Typography.statusLabel).foregroundStyle(LoomTheme.Text.secondary)
                .frame(height: LoomTheme.Layout.usageHeaderRowHeight)
                SettingsRowDivider().gridCellUnsizedAxes(.horizontal)
                ForEach(snapshot.models, id: \.model) { model in
                    GridRow {
                        Text(model.displayName).fontWeight(.medium).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsageFormat.tokens(model.tokens.total))
                            .help("\(UsageFormat.grouped(model.tokens.total)) tokens")
                        HStack(spacing: LoomTheme.Space.usageShareGap) {
                            ShareBar(fraction: whole > 0 ? Double(model.tokens.total) / Double(whole) : 0)
                            Text(UsageFormat.percent(model.tokens.total, of: whole) ?? "—")
                        }
                        .foregroundStyle(LoomTheme.Text.secondary)
                        Group {
                            if let cost = model.estimatedCostUSD {
                                Text(UsageFormat.cost(cost))
                            } else {
                                Text("—").foregroundStyle(LoomTheme.Text.secondary)
                                    .help("No price known for this model. Tokens are counted; cost is left out.")
                            }
                        }
                    }
                    .frame(height: LoomTheme.Layout.usageRowHeight)
                    SettingsRowDivider().gridCellUnsizedAxes(.horizontal)
                }
            }
            .font(LoomTheme.Typography.body).monospacedDigit()
        }
    }
}

/// A thin track with the model's share in the secondary text tone.
private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim)
            .fill(LoomTheme.Surface.hairline)
            .frame(width: LoomTheme.Layout.usageShareBar.width, height: LoomTheme.Layout.usageShareBar.height)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim)
                    .fill(LoomTheme.Text.secondary)
                    .frame(width: LoomTheme.Layout.usageShareBar.width * CGFloat(min(max(fraction, 0), 1)))
            }
            .accessibilityHidden(true)
    }
}

/// English date text in the usage model's time zone (the app's copy is English).
enum UsageText {
    private static let formatters = FormatterCache()
    static var formattersCreated: Int { formatters.created }

    private static func format(_ pattern: String, _ date: Date, _ zone: TimeZone) -> String {
        formatters.string(from: date, key: "\(pattern)|\(zone.identifier)") {
            $0.locale = Locale(identifier: "en_US_POSIX")
            $0.timeZone = zone
            $0.dateFormat = pattern
        }
    }

    static func weekday(_ date: Date, _ zone: TimeZone) -> String { format("EEE", date, zone) }
    static func date(_ date: Date, _ zone: TimeZone) -> String { format("EEE d MMM", date, zone) }
    static func time(_ date: Date, _ zone: TimeZone) -> String { format("HH:mm", date, zone) }

    /// `9 AM`, or `9:30 AM` when the zone's hour boundary is not on the hour.
    static func hour(_ date: Date, _ zone: TimeZone) -> String {
        format(zone.secondsFromGMT(for: date) % 3_600 == 0 ? "h a" : "h:mm a", date, zone)
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

    /// `2026-10-07` as `7 Oct 2026`.
    static func priceDate(_ text: String) -> String {
        guard let date = priceParser.date(from: text) else { return text }
        return format("d MMM yyyy", date, TimeZone(identifier: "UTC")!)
    }
}
