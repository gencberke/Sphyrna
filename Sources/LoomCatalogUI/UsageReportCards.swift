import SwiftUI
import LoomCore

// MARK: Rules

/// The cards of the Usage report, top to bottom.
enum UsageCardKind: Hashable {
    case planLimits, period, activity, models
}

/// What the plan-limits card shows: the windows (with a note when the last ask failed and the earlier
/// answer stays), the unavailable text, or no card at all.
enum UsagePlanLimitsCard: Equatable {
    case limits(notRefreshed: Bool)
    case unavailable(String)
    case none
}

/// One token kind in the period card's ranked list.
struct UsageTokenKindRow: Equatable {
    let title: String
    let tokens: Int64
    /// Of the period's total; 0 when the total is 0.
    let fraction: Double
    let tooltip: String

    var value: String { UsageFormat.tokens(tokens) }
}

/// A plan-limit row's texts and meter: the remaining share shows ("38% left", the same words and direction as Home's line and
/// the footer chip), the used share is the tooltip. The meter fills what is left, from the leading edge; `isLow` turns it
/// attention orange (under 20 % left, or the window runs out before it resets), as `PlanPaceLine` does.
struct UsagePlanLimitRowText: Equatable {
    let title: String
    let used: String
    let left: String
    let remainingFraction: Double
    let isLow: Bool
    /// Capitalised, e.g. `Resets 14:20`; nil when the CLI did not say.
    let reset: String?
    let accessibilityLabel: String
}

/// The local five hours, as one row of the activity card.
struct UsageLocalHoursText: Equatable {
    let label: String
    let total: String
    let tooltip: String
    let accessibilityLabel: String
}

/// The texts and orderings of the Usage report's cards, apart from the views so tests can pin them.
enum UsageCardText {
    static func planLimitsCard(limits: PlanLimits?, failureReason: String?, now: Date) -> UsagePlanLimitsCard {
        if let limits, !limits.current(at: now).isEmpty { return .limits(notRefreshed: failureReason != nil) }
        if let failureReason { return .unavailable(failureReason) }
        return .none
    }

    /// Plan limits first, then the period, the activity and the models.
    static func cards(for planLimits: UsagePlanLimitsCard) -> [UsageCardKind] {
        (planLimits == .none ? [] : [.planLimits]) + [.period, .activity, .models]
    }

    static func planLimitsMeta(fetchedAt: Date, notRefreshed: Bool, timeZone: TimeZone) -> String {
        "Updated \(UsageText.time(fetchedAt, timeZone))" + (notRefreshed ? " · could not refresh" : "")
    }

    /// `measuredAt` is when the used share was read (`PlanLimits.fetchedAt`), which the pace is measured at.
    static func planLimitRow(_ kind: PlanLimitKind, _ window: PlanLimitWindow, now: Date, timeZone: TimeZone,
                             measuredAt: Date? = nil) -> UsagePlanLimitRowText {
        let reset = UsageChipContent.resetPhrase(window, now: now, timeZone: timeZone)
        let remaining = Double(window.remainingPercent) / 100
        // Over pace needs a reset time; without one only the share left says anything.
        let isLow = PlanPace(kind: kind, window: window, at: now, measuredAt: measuredAt).map(PlanPaceLine.isLow)
            ?? (remaining < LoomTheme.PlanPaceLine.lowBelow)
        return UsagePlanLimitRowText(
            title: kind.title, used: "\(UsageFormat.percent(window.usedPercent)) used", left: "\(UsageFormat.percent(window.remainingPercent)) left",
            remainingFraction: remaining, isLow: isLow,
            reset: reset?.capitalizedFirst,
            accessibilityLabel: "\(kind.title) limit, \(window.usedPercent) percent used, "
                + "\(window.remainingPercent) percent remaining" + (reset.map { ", " + $0 } ?? ""))
    }

    /// "Last 7 days": the period's headline wording, capitalised.
    static func periodTitle(_ period: UsagePeriod) -> String { period.phrase.capitalizedFirst }

    /// The usage index counts only the sessions that have usage records in the period, which is not the
    /// catalog's number of sessions (Home's Today, the project page): the label says what it counts.
    static func sessions(_ count: Int) -> String { "\(count) session\(count == 1 ? "" : "s") with usage" }

    static func models(_ count: Int) -> String { "\(count) model\(count == 1 ? "" : "s")" }

    /// The estimated cost, unless a model without a price makes it a floor of nothing.
    static func cost(_ snapshot: UsageSnapshot) -> String? {
        snapshot.estimatedCostUSD > 0 || !snapshot.hasUnknownCost ? UsageFormat.cost(snapshot.estimatedCostUSD) : nil
    }

    /// The four token kinds, largest first; kinds of the same size keep this order (cache read, cache write,
    /// input, output). Each one's share is of the period's total.
    static func rankedKinds(_ tokens: UsageTokens) -> [UsageTokenKindRow] {
        let whole = tokens.total
        func row(_ title: String, _ value: Int64, _ tooltip: String) -> UsageTokenKindRow {
            UsageTokenKindRow(title: title, tokens: value, fraction: whole > 0 ? Double(value) / Double(whole) : 0,
                              tooltip: tooltip)
        }
        let listed = [
            row("Cache read", tokens.cacheRead, UsageFormat.grouped(tokens.cacheRead)),
            row("Cache write", tokens.cacheWrite,
                "5 min \(UsageFormat.grouped(tokens.cacheWrite5m)), 1 h \(UsageFormat.grouped(tokens.cacheWrite1h))"),
            row("Input", tokens.input, UsageFormat.grouped(tokens.input)),
            row("Output", tokens.output, UsageFormat.grouped(tokens.output)),
        ]
        return listed.enumerated()
            .sorted { $0.element.tokens != $1.element.tokens ? $0.element.tokens > $1.element.tokens : $0.offset < $1.offset }
            .map(\.element)
    }

    /// `95 %`, or a dash when nothing was read on the prompt side.
    static func servedFromCache(_ tokens: UsageTokens) -> String {
        tokens.cacheShare.map(UsageFormat.percent(fraction:)) ?? "—"
    }

    static let servedFromCacheTooltip = "Share of input-side tokens served from the cache."

    static func activityTitle(_ period: UsagePeriod) -> String {
        period == .hours24 ? "Tokens per hour" : "Tokens per day"
    }

    /// `Peak 13.2M, Mon 13 Oct`; nil while no bar has tokens.
    static func peak(_ bars: [UsageBar], period: UsagePeriod, timeZone: TimeZone) -> String? {
        guard let peak = bars.max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 else { return nil }
        return "Peak \(UsageFormat.tokens(peak.tokens)), \(UsageText.bucket(peak.start, period, timeZone))"
    }

    static func localHours(_ cells: [UsageBar]) -> UsageLocalHoursText {
        let total = cells.reduce(Int64(0)) { $0 + $1.tokens }
        return UsageLocalHoursText(
            label: "Last 5 hours, local", total: UsageFormat.tokens(total),
            tooltip: "\(UsageFormat.tokens(total)) tokens, approximate. Local activity, not your plan limit.",
            accessibilityLabel: "Last 5 hours, approximate. \(UsageFormat.spokenTokens(total)) tokens. "
                + "Local activity, not your plan limit.")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Views

/// One card of the report: the Settings card surface, a header line (the title, a meta text on the
/// right) and the body.
struct UsageCard<Content: View>: View {
    let title: String
    var meta: String?
    @ViewBuilder let content: Content

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.usageLocalGap) {
                    Text(title).font(LoomTheme.Typography.bodyStrong).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if let meta {
                        Text(meta).font(LoomTheme.Typography.caption).lineLimit(1)
                            .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    }
                }
                .padding(.bottom, LoomTheme.Space.usageCardHeaderBottom)
                content
            }
            .padding(.top, LoomTheme.Space.usageCardTop).padding(.bottom, LoomTheme.Space.usageCardBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .monospacedDigit()
    }
}

/// A thin share track; the fill never shrinks below 2 pt, so a small share stays visible. `track` is the neutral track every
/// plan meter shares (`LoomTheme.PlanPaceLine.track`, the footer chip's) unless a caller asks for another.
private struct UsageMeterBar: View {
    let fraction: Double
    let fill: Color
    let height: CGFloat
    var track: Color = LoomTheme.Surface.activityCell(0)

    var body: some View {
        GeometryReader { proxy in
            let share = CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim).fill(track)
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim).fill(fill)
                    .frame(width: share > 0 ? min(proxy.size.width, max(2, proxy.size.width * share)) : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The report of one period as cards, with the notice for records the scans could not read under them.
struct UsageReportView: View {
    let report: UsageReport
    let limits: PlanLimits?
    let limitsFailure: PlanLimitsFailure?
    let linesNotUnderstood: Int
    let timeZone: TimeZone
    var now = Date()

    var body: some View {
        let planLimits = UsageCardText.planLimitsCard(limits: limits, failureReason: limitsFailure?.category.reason, now: now)
        VStack(alignment: .leading, spacing: LoomTheme.Space.usageCardGap) {
            ForEach(UsageCardText.cards(for: planLimits), id: \.self) { kind in
                switch kind {
                case .planLimits: planLimitsCard(planLimits)
                case .period: periodCard(report.snapshot)
                case .activity: activityCard
                case .models: modelsCard(report.snapshot)
                }
            }
            if let skipped = UsageText.skippedLines(linesNotUnderstood) {
                Text(skipped).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            }
        }
        .padding(.top, LoomTheme.Space.settingsSegmentH - 4)
    }

    // Plan limits

    @ViewBuilder
    private func planLimitsCard(_ state: UsagePlanLimitsCard) -> some View {
        switch state {
        case let .limits(notRefreshed):
            if let limits {
                UsageCard(title: "Plan limits",
                          meta: UsageCardText.planLimitsMeta(fetchedAt: limits.fetchedAt, notRefreshed: notRefreshed,
                                                             timeZone: timeZone)) {
                    VStack(spacing: 0) {
                        ForEach(limits.current(at: now), id: \.kind) { item in
                            planLimitRow(UsageCardText.planLimitRow(item.kind, item.window, now: now, timeZone: timeZone,
                                                                    measuredAt: limits.fetchedAt))
                        }
                    }
                }
            }
        case let .unavailable(reason):
            UsageCard(title: "Plan limits") {
                HStack {
                    Text("Plan limits unavailable").font(LoomTheme.Typography.small)
                    Spacer()
                    Text(reason).font(LoomTheme.Typography.caption)
                        .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                }
                .accessibilityElement(children: .combine)
            }
        case .none:
            EmptyView()
        }
    }

    private func planLimitRow(_ text: UsagePlanLimitRowText) -> some View {
        HStack(spacing: LoomTheme.Space.usageLocalGap) {
            Text(text.title).frame(width: LoomTheme.Layout.planLimitLabelWidth, alignment: .leading)
            UsageMeterBar(fraction: text.remainingFraction,
                          fill: text.isLow ? LoomTheme.PlanPaceLine.fillOver : LoomTheme.PlanPaceLine.fill,
                          height: LoomTheme.Layout.planLimitBarHeight, track: LoomTheme.PlanPaceLine.track)
            Text(text.left).foregroundStyle(text.isLow ? LoomTheme.Status.attentionLight : LoomTheme.Text.primary)
                .frame(width: LoomTheme.Layout.planLimitUsedWidth, alignment: .trailing)
            Text(text.reset ?? "").foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                .frame(width: LoomTheme.Layout.planLimitResetWidth, alignment: .trailing)
        }
        .font(LoomTheme.Typography.small)
        .frame(height: LoomTheme.Layout.usageHeaderRowHeight)
        .help(text.used)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
    }

    // The period

    private func periodCard(_ snapshot: UsageSnapshot) -> some View {
        UsageCard(title: UsageCardText.periodTitle(report.period), meta: UsageCardText.sessions(snapshot.sessionCount)) {
            HStack(alignment: .top, spacing: LoomTheme.Space.usageCardColumnGap) {
                summary(snapshot).frame(width: LoomTheme.Layout.usageSummaryWidth, alignment: .leading)
                kinds(snapshot.tokens).frame(maxWidth: .infinity)
            }
        }
    }

    private func summary(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(UsageFormat.tokens(snapshot.tokens.total)).font(LoomTheme.Typography.display).lineLimit(1)
                .help("\(UsageFormat.grouped(snapshot.tokens.total)) tokens")
            Text("tokens").font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
            if let cost = UsageCardText.cost(snapshot) {
                HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.chipLimitGap) {
                    Text(cost).font(LoomTheme.Typography.body)
                    Text("estimated").font(LoomTheme.Typography.caption)
                        .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                }
                .padding(.top, LoomTheme.Space.footerSpacing)
            }
            Text("API-equivalent estimate — subscriptions are not billed per token.")
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func kinds(_ tokens: UsageTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(UsageCardText.rankedKinds(tokens), id: \.title) { row in
                HStack(spacing: LoomTheme.Space.usageLocalGap) {
                    Text(row.title).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                        .frame(width: LoomTheme.Layout.usageKindLabelWidth, alignment: .leading)
                    UsageMeterBar(fraction: row.fraction, fill: LoomTheme.Text.secondary,
                                  height: LoomTheme.Layout.planLimitBarHeight)
                    Text(row.value).frame(width: LoomTheme.Layout.usageKindValueWidth, alignment: .trailing)
                }
                .frame(height: LoomTheme.Layout.usageKindRowHeight)
                .help(row.tooltip)
                .accessibilityElement(children: .combine)
            }
            HStack {
                Text("Served from the cache").foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                Spacer()
                Text(UsageCardText.servedFromCache(tokens))
            }
            .frame(height: LoomTheme.Layout.usageKindRowHeight)
            .help(UsageCardText.servedFromCacheTooltip)
            .accessibilityElement(children: .combine)
        }
        .font(LoomTheme.Typography.small)
    }

    // Activity

    private var activityCard: some View {
        let bars = report.bars
        let slim = bars.count > 7
        let gap = slim ? (bars.count > 30 ? LoomTheme.Space.usageBarGapSlim / 2 : LoomTheme.Space.usageBarGapSlim)
            : LoomTheme.Space.usageBarGap
        return UsageCard(title: UsageCardText.activityTitle(report.period),
                         meta: UsageCardText.peak(bars, period: report.period, timeZone: timeZone)) {
            VStack(alignment: .leading, spacing: 0) {
                chart(bars, slim: slim, gap: gap)
                axisLabels(bars, gap: gap)
                SettingsRowDivider()
                    .padding(.top, LoomTheme.Space.usageRuleTop).padding(.bottom, LoomTheme.Space.usageRuleBottom)
                localHours
            }
        }
    }

    private func chart(_ bars: [UsageBar], slim: Bool, gap: CGFloat) -> some View {
        let peak = bars.max { $0.tokens < $1.tokens }
        return HStack(alignment: .bottom, spacing: gap) {
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
    }

    private func barHeight(_ bar: UsageBar, peak: Int64) -> CGFloat {
        guard bar.tokens > 0, peak > 0 else { return 0 }
        return max(2, LoomTheme.Layout.usageBarsHeight * CGFloat(bar.tokens) / CGFloat(peak))
    }

    private func chartDescription(_ bars: [UsageBar]) -> String {
        let total = bars.reduce(Int64(0)) { $0 + $1.tokens }
        return "\(UsageCardText.activityTitle(report.period)), \(UsageFormat.spokenTokens(total)) tokens in total"
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
                        // A blank line keeps the row's height; the label is wider than its bar and overlays it.
                        Text(" ").frame(maxWidth: .infinity)
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
        .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
        .padding(.top, LoomTheme.Space.usageCellLabelTop)
        .accessibilityHidden(true)
    }

    /// The local five hours: the label, the five cells and their total on one row, the hour labels under the cells.
    private var localHours: some View {
        let cells = report.cells
        let peak = cells.map(\.tokens).max() ?? 0
        let text = UsageCardText.localHours(cells)
        return VStack(alignment: .leading, spacing: LoomTheme.Space.usageCellLabelTop) {
            HStack(spacing: LoomTheme.Space.usageLocalGap) {
                Text(text.label).font(LoomTheme.Typography.caption)
                    .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle).lineLimit(1)
                    .frame(width: LoomTheme.Layout.usageLocalLabelWidth, alignment: .leading)
                HStack(spacing: LoomTheme.Space.usageCellGap) {
                    ForEach(cells.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: LoomTheme.Radius.bar)
                            .fill(LoomTheme.Surface.activityCell(peak > 0 ? Double(cells[index].tokens) / Double(peak) : 0))
                            .frame(height: LoomTheme.Layout.usageCellHeight)
                            .help("\(UsageText.hour(cells[index].start, timeZone)): \(UsageFormat.tokens(cells[index].tokens)) tokens")
                    }
                }
                Text(text.total).font(LoomTheme.Typography.small).lineLimit(1)
                    .frame(width: LoomTheme.Layout.usageLocalTotalWidth, alignment: .trailing)
            }
            HStack(spacing: LoomTheme.Space.usageLocalGap) {
                Color.clear.frame(width: LoomTheme.Layout.usageLocalLabelWidth, height: 1)
                HStack(spacing: LoomTheme.Space.usageCellGap) {
                    ForEach(cells.indices, id: \.self) { index in
                        Text(UsageText.hour(cells[index].start, timeZone)).frame(maxWidth: .infinity)
                    }
                }
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                Color.clear.frame(width: LoomTheme.Layout.usageLocalTotalWidth, height: 1)
            }
        }
        .help(text.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
    }

    // By model

    private func modelsCard(_ snapshot: UsageSnapshot) -> some View {
        let whole = snapshot.tokens.total
        return UsageCard(title: "By model", meta: UsageCardText.models(snapshot.models.count)) {
            Grid(alignment: .trailing, horizontalSpacing: LoomTheme.Space.usageTotalsGap, verticalSpacing: 0) {
                GridRow {
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Tokens")
                    Text("Share")
                    Text("Est. cost")
                }
                .font(LoomTheme.Typography.statusLabel).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                .frame(height: LoomTheme.Layout.usageHeaderRowHeight)
                SettingsRowDivider().gridCellUnsizedAxes(.horizontal)
                ForEach(snapshot.models.indices, id: \.self) { index in
                    let model = snapshot.models[index]
                    GridRow {
                        Text(model.displayName).fontWeight(.medium).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsageFormat.tokens(model.tokens.total))
                            .help("\(UsageFormat.grouped(model.tokens.total)) tokens")
                        HStack(spacing: LoomTheme.Space.usageShareGap) {
                            ShareBar(fraction: whole > 0 ? Double(model.tokens.total) / Double(whole) : 0)
                            // As wide as the widest share, so the bars line up from row to row.
                            ZStack(alignment: .trailing) {
                                Text(UsageFormat.percent(100)).hidden().accessibilityHidden(true)
                                Text(UsageFormat.percent(model.tokens.total, of: whole) ?? "—")
                            }
                        }
                        .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                        Group {
                            if let cost = model.estimatedCostUSD {
                                Text(UsageFormat.cost(cost))
                            } else {
                                Text("—").foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                                    .help("No price known for this model. Tokens are counted; cost is left out.")
                            }
                        }
                    }
                    .frame(height: LoomTheme.Layout.usageRowHeight)
                    if index < snapshot.models.count - 1 {
                        SettingsRowDivider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .font(LoomTheme.Typography.body)
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
