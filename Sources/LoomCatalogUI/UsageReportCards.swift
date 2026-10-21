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

private typealias S = LoomTheme.Settings

/// One card of the report: the Settings card, a header line (the title, a mono meta text at the end, on one baseline) and the body.
struct UsageCard<Content: View>: View {
    let title: String
    var meta: String?
    @ViewBuilder let content: Content

    var body: some View {
        SettingsCard(holdsRows: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: S.headGap) {
                    Text(title).projectType(S.headTitle).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if let meta {
                        Text(meta).projectType(S.headMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                    }
                }
                .padding(.bottom, S.headBottom)
                content
            }
            .padding(.top, S.cardPaddingTop).padding(.horizontal, S.cardPaddingH).padding(.bottom, S.cardPaddingBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .monospacedDigit()
    }
}

/// A thin share track; the fill never shrinks below 2 pt, so a small share stays visible.
private struct UsageMeterBar: View {
    let fraction: Double
    let fill: Color
    let track: Color
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let share = CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius).fill(track)
                RoundedRectangle(cornerRadius: radius).fill(fill)
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
        VStack(alignment: .leading, spacing: S.cardGap) {
            ForEach(UsageCardText.cards(for: planLimits), id: \.self) { kind in
                switch kind {
                case .planLimits: planLimitsCard(planLimits)
                case .period: periodCard(report.snapshot)
                case .activity: activityCard
                case .models: modelsCard(report.snapshot)
                }
            }
            if let skipped = UsageText.skippedLines(linesNotUnderstood) {
                Text(skipped).projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
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
                HStack(spacing: S.unavailableGap) {
                    Text("Plan limits unavailable").projectType(S.limitLabel).foregroundStyle(LoomTheme.Text.primary)
                    Spacer(minLength: 0)
                    Text(reason).projectType(S.unavailableReason).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                .accessibilityElement(children: .combine)
            }
        case .none:
            EmptyView()
        }
    }

    private func planLimitRow(_ text: UsagePlanLimitRowText) -> some View {
        HStack(spacing: S.limitGap) {
            Text(text.title).projectType(S.limitLabel).foregroundStyle(LoomTheme.Text.primary)
                .frame(width: S.limitColumns.label, alignment: .leading)
            UsageMeterBar(fraction: text.remainingFraction,
                          fill: text.isLow ? LoomTheme.Status.attention : LoomTheme.Text.secondary,
                          track: LoomTheme.Surface.strongHairline, height: S.meterHeight, radius: S.meterRadius)
            Text(text.left).projectType(S.limitLeft)
                .foregroundStyle(text.isLow ? LoomTheme.Status.attentionLight : LoomTheme.Text.primary)
                .frame(width: S.limitColumns.left, alignment: .trailing)
            // 118 wide, and wider when the phrase needs it ("Resets Sun 12:00 PM"), at the meter's cost.
            Text(text.reset ?? "").projectType(S.limitReset).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: S.limitColumns.reset, alignment: .trailing)
        }
        .frame(height: S.limitHeight)
        .help(text.used)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
    }

    // The period

    private func periodCard(_ snapshot: UsageSnapshot) -> some View {
        UsageCard(title: UsageCardText.periodTitle(report.period), meta: UsageCardText.sessions(snapshot.sessionCount)) {
            HStack(alignment: .top, spacing: S.summaryGap) {
                summary(snapshot).frame(width: S.summaryWidth, alignment: .leading)
                kinds(snapshot.tokens).frame(maxWidth: .infinity)
            }
        }
    }

    private func summary(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UsageFormat.tokens(snapshot.tokens.total)).projectType(S.total).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(1).frame(minHeight: S.totalLine, alignment: .leading)
                .help("\(UsageFormat.grouped(snapshot.tokens.total)) tokens")
            caption("tokens")
            if let cost = UsageCardText.cost(snapshot) {
                Text(cost).projectType(S.cost).foregroundStyle(LoomTheme.Text.primary).padding(.top, S.costTop)
                caption("estimated")
            }
            Text("API-equivalent estimate — subscriptions are not billed per token.")
                .projectType(S.fine).lineSpacing(S.fineSpacing).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .fixedSize(horizontal: false, vertical: true).padding(.top, S.fineTop)
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(_ text: String) -> some View {
        Text(text).projectType(S.caption).foregroundStyle(LoomTheme.Text.secondaryStyle).padding(.top, S.captionTop)
    }

    private func kinds(_ tokens: UsageTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(UsageCardText.rankedKinds(tokens), id: \.title) { row in
                HStack(spacing: S.kindGap) {
                    Text(row.title).projectType(S.kindLabel).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .frame(width: S.kindColumns.label, alignment: .leading)
                    UsageMeterBar(fraction: row.fraction, fill: LoomTheme.Text.tertiary, track: LoomTheme.Surface.hairline,
                                  height: S.kindBar, radius: S.kindBarRadius)
                    Text(row.value).projectType(S.kindValue).foregroundStyle(LoomTheme.Text.primary)
                        .frame(width: S.kindColumns.value, alignment: .trailing)
                }
                .frame(height: S.kindHeight)
                .help(row.tooltip)
                .accessibilityElement(children: .combine)
            }
            HStack {
                Text("Served from the cache").projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                Spacer(minLength: 0)
                Text(UsageCardText.servedFromCache(tokens)).projectType(S.cacheValue).foregroundStyle(LoomTheme.Text.primary)
            }
            .padding(.top, S.cachePadding)
            .overlay(alignment: .top) { SettingsRowDivider() }
            .padding(.top, S.cacheTop)
            .help(UsageCardText.servedFromCacheTooltip)
            .accessibilityElement(children: .combine)
        }
    }

    // Activity

    private var activityCard: some View {
        let bars = report.bars
        return UsageCard(title: UsageCardText.activityTitle(report.period),
                         meta: UsageCardText.peak(bars, period: report.period, timeZone: timeZone)) {
            VStack(alignment: .leading, spacing: 0) {
                chart(bars)
                axisLabels(bars)
                localHours
            }
        }
    }

    private func chart(_ bars: [UsageBar]) -> some View {
        let peak = bars.max { $0.tokens < $1.tokens }
        return HStack(alignment: .bottom, spacing: S.barGap) {
            ForEach(bars.indices, id: \.self) { index in
                let bar = bars[index]
                UnevenRoundedRectangle(topLeadingRadius: S.barRadius, topTrailingRadius: S.barRadius)
                    .fill(bar.isCurrent ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Surface.strongerHairline))
                    .frame(height: barHeight(bar, peak: peak?.tokens ?? 0))
                    .frame(maxWidth: .infinity)
                    .help("\(UsageText.bucket(bar.start, report.period, timeZone)), \(UsageFormat.tokens(bar.tokens)) tokens")
            }
        }
        .frame(height: S.barsHeight, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartDescription(bars))
    }

    private func barHeight(_ bar: UsageBar, peak: Int64) -> CGFloat {
        guard bar.tokens > 0, peak > 0 else { return 0 }
        return max(2, S.barsHeight * CGFloat(bar.tokens) / CGFloat(peak))
    }

    private func chartDescription(_ bars: [UsageBar]) -> String {
        let total = bars.reduce(Int64(0)) { $0 + $1.tokens }
        return "\(UsageCardText.activityTitle(report.period)), \(UsageFormat.spokenTokens(total)) tokens in total"
    }

    @ViewBuilder
    private func axisLabels(_ bars: [UsageBar]) -> some View {
        Group {
            switch report.period {
            case .days7:
                HStack(spacing: S.barGap) {
                    ForEach(bars.indices, id: \.self) { index in
                        Text(UsageText.weekday(bars[index].start, timeZone)).frame(maxWidth: .infinity)
                    }
                }
            case .hours24:
                HStack(spacing: S.barGap) {
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
        .projectType(S.axis).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        .padding(.top, S.axisTop)
        .accessibilityHidden(true)
    }

    /// The local five hours: the label, the five cells and their total on one row, the hour labels under the cells.
    private var localHours: some View {
        let cells = report.cells
        let peak = cells.map(\.tokens).max() ?? 0
        let text = UsageCardText.localHours(cells)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: S.heatGap) {
                Text(text.label).projectType(S.heatLabel).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: S.heatCellGap) {
                    ForEach(cells.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: S.heatCellRadius)
                            .fill(LoomTheme.Surface.activityCell(peak > 0 ? Double(cells[index].tokens) / Double(peak) : 0))
                            .frame(width: S.heatCell.width, height: S.heatCell.height)
                            .help("\(UsageText.hour(cells[index].start, timeZone)): \(UsageFormat.tokens(cells[index].tokens)) tokens")
                    }
                }
                Text(text.total).projectType(S.heatTotal).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    .frame(width: S.heatTotalWidth, alignment: .trailing)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: S.heatCellGap) {
                    ForEach(cells.indices, id: \.self) { index in
                        Text(UsageText.hour(cells[index].start, timeZone)).frame(width: S.heatCell.width)
                    }
                }
                Color.clear.frame(width: S.hourLabelTrailing, height: 1)
            }
            .projectType(S.hourLabel).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .padding(.top, S.hourLabelTop)
        }
        .padding(.top, S.heatPadding)
        .overlay(alignment: .top) { SettingsRowDivider() }
        .padding(.top, S.heatTop)
        .help(text.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
    }

    // By model

    private func modelsCard(_ snapshot: UsageSnapshot) -> some View {
        let whole = snapshot.tokens.total
        return UsageCard(title: "By model", meta: UsageCardText.models(snapshot.models.count)) {
            VStack(spacing: 0) {
                modelRow(height: S.modelHeaderHeight, rule: false) {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Tokens").frame(width: S.modelColumns.tokens, alignment: .trailing)
                    Text("Share").frame(width: S.modelColumns.share, alignment: .trailing)
                    Text("Est. cost").frame(width: S.modelColumns.cost, alignment: .trailing)
                }
                .projectType(S.modelHeader).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                ForEach(snapshot.models.indices, id: \.self) { index in
                    let model = snapshot.models[index]
                    modelRow(height: S.modelRowHeight, rule: true) {
                        Text(model.displayName).projectType(S.modelName).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsageFormat.tokens(model.tokens.total)).projectType(S.modelFigure)
                            .foregroundStyle(LoomTheme.Text.primary)
                            .frame(width: S.modelColumns.tokens, alignment: .trailing)
                            .help("\(UsageFormat.grouped(model.tokens.total)) tokens")
                        HStack(spacing: S.shareGap) {
                            ShareBar(fraction: whole > 0 ? Double(model.tokens.total) / Double(whole) : 0)
                            // As wide as the widest share, so the bars line up from row to row.
                            ZStack(alignment: .trailing) {
                                Text(UsageFormat.percent(100)).hidden().accessibilityHidden(true)
                                Text(UsageFormat.percent(model.tokens.total, of: whole) ?? "—")
                            }
                            .projectType(S.modelShare).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        }
                        .frame(width: S.modelColumns.share, alignment: .trailing)
                        Group {
                            if let cost = model.estimatedCostUSD {
                                Text(UsageFormat.cost(cost)).foregroundStyle(LoomTheme.Text.primary)
                            } else {
                                Text("—").foregroundStyle(LoomTheme.Text.tertiaryStyle)
                                    .help("No price known for this model. Tokens are counted; cost is left out.")
                            }
                        }
                        .projectType(S.modelFigure)
                        .frame(width: S.modelColumns.cost, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func modelRow<Row: View>(height: CGFloat, rule: Bool, @ViewBuilder _ row: () -> Row) -> some View {
        HStack(spacing: S.modelGap) { row() }
            .frame(height: height)
            .overlay(alignment: .top) { if rule { SettingsRowDivider() } }
    }
}

/// A thin track with the model's share in the tertiary text tone.
private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        UsageMeterBar(fraction: fraction, fill: LoomTheme.Text.tertiary, track: LoomTheme.Surface.hairline,
                      height: S.shareBar.height, radius: S.kindBarRadius)
            .frame(width: S.shareBar.width)
    }
}
