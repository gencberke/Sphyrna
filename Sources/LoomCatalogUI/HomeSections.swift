import LoomCore
import SwiftUI

// MARK: Surfaces

/// The Night Fleece 2 card: the card surface, radius 12, a hairline and the card depth.
struct HomeCard<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.block).fill(LoomTheme.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.block)
                .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            .shadow(color: LoomTheme.Depth.shadowColor(LoomTheme.Depth.card.shadow.opacity),
                    radius: LoomTheme.Depth.card.shadow.blur / 2, y: LoomTheme.Depth.card.shadow.y)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

/// A list block: a heading row above (a status dot, the title, the count), then the card with its rows.
struct HomeSectionCard<Content: View>: View {
    let title: String
    let count: Int
    let pip: Color
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Home.headingGap) {
            HStack(spacing: LoomTheme.Space.chipInset) {
                Circle().fill(pip).frame(width: LoomTheme.Home.pip, height: LoomTheme.Home.pip).accessibilityHidden(true)
                Text(title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(count)").font(LoomTheme.Typography.small).monospacedDigit()
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityAddTraits(.isHeader)
            HomeCard(identifier: identifier) {
                VStack(spacing: 0) { content }
            }
        }
    }
}

/// A block of the side column: a heading with an optional right-hand note, then its content.
struct HomeSideCard<Content: View>: View {
    let title: String
    var meta: String?
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        HomeCard(identifier: identifier) {
            VStack(alignment: .leading, spacing: LoomTheme.Home.limitGap) {
                HStack {
                    Text(title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: LoomTheme.Space.chipSplitGap)
                    if let meta {
                        Text(meta).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    }
                }
                content
            }
            .padding(LoomTheme.Home.sideCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Time and project

/// "5m ago", "just now": the relative time of the cards, spelled out for a sentence.
enum HomeAgeText {
    static func ago(from date: Date, to now: Date) -> String {
        let age = RelativeTime.string(from: date, to: now)
        return age == "now" ? "just now" : age + " ago"
    }
}

/// The project (its stripe and name) and a time, on one line. It is the only part of a card that reads the
/// minute tick, so the tick redraws these lines and nothing else.
struct HomeMeta: View {
    let model: CatalogModel
    let projectName: String?
    let tone: ProjectTone?
    let date: Date
    /// Spells the time out after this word ("Last active 2h ago"); nil shows the card's short "2h".
    var verb: String?

    var body: some View {
        let age = verb.map { "\($0) " + HomeAgeText.ago(from: date, to: model.now) }
            ?? RelativeTime.string(from: date, to: model.now)
        HStack(spacing: LoomTheme.Space.hintSpacing) {
            if let tone {
                RoundedRectangle(cornerRadius: LoomTheme.ProjectColor.stripeRadius)
                    .fill(LoomTheme.ProjectColor.stripe(tone))
                    .frame(width: LoomTheme.Home.toneStripe.width, height: LoomTheme.Home.toneStripe.height)
                    .accessibilityHidden(true)
            }
            Text(projectName.map { $0 + " · " + age } ?? age)
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                .lineLimit(1).truncationMode(.middle)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Needs you, Finished

/// One session in a list: its state, title, project and age, the line (what it waits for or did last) and
/// the ways on: open it, or mark a finished turn read.
struct HomeEntryRow: View {
    let model: CatalogModel
    let entry: HomeEntry
    let showsRule: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsRule {
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: LoomTheme.Space.requestPadding) {
                IndicatorView(indicator: entry.indicator).padding(.top, LoomTheme.Space.cardIndicatorTop)
                VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.chipInset) {
                        Text(entry.title).font(LoomTheme.Typography.cardTitle(selected: false))
                            .foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                        Spacer(minLength: LoomTheme.Space.chipInset)
                        HomeMeta(model: model, projectName: entry.projectName, tone: entry.tone, date: entry.lastActivityAt)
                    }
                    Text(entry.line).font(LoomTheme.Typography.small)
                        .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home-entry-line")
                    HStack(spacing: LoomTheme.Space.chipSplitGap) {
                        Button("Open Session") { model.select(entry.id) }
                            .buttonStyle(AccentButtonStyle(kind: .tinted))
                            .accessibilityLabel("Open \(entry.title)")
                            .accessibilityIdentifier("home-open")
                        if entry.canMarkRead {
                            Button("Mark as Read") { model.markRead(entry.id) }
                                .buttonStyle(ChipButtonStyle())
                                .accessibilityLabel("Mark \(entry.title) as read")
                                .accessibilityIdentifier("home-mark-read")
                        }
                    }
                    .padding(.top, LoomTheme.Space.headerSpacing)
                }
            }
            // The text keeps `itemPadding` and `itemPaddingV` from the card's edge and the hairline; the pill sits `Highlight.inset` inside the card and a little
            // inside the hairlines. A click on the row opens the session, as Open Session does.
            .padding(.horizontal, LoomTheme.Home.itemPadding - LoomTheme.Highlight.inset)
            .padding(.vertical, LoomTheme.Home.itemPaddingV - LoomTheme.Home.rowPillGap)
            .rowPill(radius: LoomTheme.Highlight.radius, key: "home-entry:\(entry.id)")
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radius))
            .onTapGesture { model.select(entry.id) }
            .padding(.horizontal, LoomTheme.Highlight.inset)
            .padding(.vertical, LoomTheme.Home.rowPillGap)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-entry")
    }
}

// MARK: Usage

/// Home's usage in one compact card (V25): the plan limits as one line, with the meters and the pace one click away, and
/// today's tokens, sessions and cache share under it. A part with nothing to say is left out, and so is the card.
struct HomeUsage: View {
    let model: CatalogModel

    var body: some View {
        let usage = model.usage
        let now = model.now
        let paces = usage == nil ? [] : model.homePaces()
        let limitsFailure = paces.isEmpty ? usage?.limitsFailure.flatMap { $0.category == .noToolchain ? nil : $0 } : nil
        let figures = model.homeTodayFigures()
        if !paces.isEmpty || limitsFailure != nil || figures != nil {
            HomeSideCard(title: "Usage", identifier: "home-usage") {
                VStack(alignment: .leading, spacing: LoomTheme.Home.usageRowGap) {
                    if let usage, !paces.isEmpty {
                        HomePlanLimitsLine(line: PlanLimitsLine(paces: paces, now: now, timeZone: usage.timeZone),
                                           paces: paces, now: now, timeZone: usage.timeZone,
                                           updated: usage.limits.map { UsageText.time($0.fetchedAt, usage.timeZone) })
                    } else if limitsFailure != nil {
                        Text("Claude did not report plan limits, so Loom shows none.")
                            .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("home-limits")
                    }
                    if let figures { HomeTodayLine(figures: figures) }
                }
            }
        }
    }
}

/// "5h 62% left · Wk 74% left · on pace" on one line when it fits. When it does not (a narrow card, a limit that runs out on
/// another day), the windows stay on the first line and the verdict takes the second, so the time a limit runs out is never
/// cut. A click shows the meters and the pace of each window in a popover; the tooltip says it in words.
struct HomePlanLimitsLine: View {
    let line: PlanLimitsLine
    let paces: [PlanPace]
    let now: Date
    let timeZone: TimeZone
    let updated: String?
    @State private var open = false

    init(line: PlanLimitsLine, paces: [PlanPace], now: Date, timeZone: TimeZone, updated: String?) {
        self.line = line
        self.paces = paces
        self.now = now
        self.timeZone = timeZone
        self.updated = updated
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: LoomTheme.Space.chipInset) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(LoomTheme.Typography.small)
                    .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    .frame(width: LoomTheme.Layout.indicatorSlot.width)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    text.lineLimit(1)
                    VStack(alignment: .leading, spacing: LoomTheme.Home.limitsWrapSpacing) {
                        windowsText.lineLimit(1).truncationMode(.tail)
                        if let verdictText { verdictText.lineLimit(1).truncationMode(.tail) }
                    }
                    .padding(.vertical, LoomTheme.Home.limitsWrapSpacing)
                }
                .font(LoomTheme.Typography.small)
                Spacer(minLength: LoomTheme.Space.headerSpacing)
                Image(systemName: "chevron.right").font(LoomTheme.Typography.chevron)
                    .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle).accessibilityHidden(true)
            }
            .padding(.horizontal, LoomTheme.Highlight.inset)
            .frame(minHeight: LoomTheme.Home.usageRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusCompact))
        }
        .buttonStyle(RowButtonStyle(radius: LoomTheme.Highlight.radiusCompact, key: "home-limits"))
        .focusEffectDisabled()
        // The pill reaches the card's padding, so the text keeps its place.
        .padding(.horizontal, -LoomTheme.Highlight.inset)
        .help(line.tooltip(paces: paces, now: now, timeZone: timeZone))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HomePlanLimitsDetail(paces: paces, now: now, timeZone: timeZone, updated: updated)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spoken)
        .accessibilityHint("Shows the meters")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home-limits")
    }

    private var dim: AnyShapeStyle { AnyShapeStyle(LoomTheme.Text.secondaryOnCardStyle) }
    private var dot: Text { Text(" \u{00B7} ").foregroundStyle(dim) }

    /// Names in secondary, the figure in primary (attention when it is low).
    private var windowsText: Text {
        var result = Text("")
        for (index, window) in line.windows.enumerated() {
            let figure = Text(window.left).fontWeight(.semibold)
                .foregroundStyle(window.isLow ? AnyShapeStyle(LoomTheme.Status.attentionLight) : AnyShapeStyle(LoomTheme.Text.primary))
            let part = Text("\(Text(window.name + " ").foregroundStyle(dim))\(figure)")
            result = index == 0 ? part : Text("\(result)\(dot)\(part)")
        }
        return result
    }

    /// The verdict in secondary, or attention when a limit runs out; nil early in a window.
    private var verdictText: Text? {
        line.verdict.map { verdict in
            Text(verdict.text).foregroundStyle(verdict.isWarning ? AnyShapeStyle(LoomTheme.Status.attentionLight) : dim)
        }
    }

    /// The whole line: the windows, then the verdict.
    private var text: Text {
        guard let verdictText else { return windowsText }
        return Text("\(windowsText)\(dot)\(verdictText)")
    }
}

/// The popover: both windows as meters with their pace line, as the Home card showed them before V25.
private struct HomePlanLimitsDetail: View {
    let paces: [PlanPace]
    let now: Date
    let timeZone: TimeZone
    let updated: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Home.limitGap) {
            HStack {
                Text("Plan limits").font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LoomTheme.Space.chipSplitGap)
                if let updated {
                    Text("updated " + updated).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.OnPopover.placeholder)
                }
            }
            ForEach(Array(paces.enumerated()), id: \.offset) { _, pace in
                PlanPaceLine(pace: pace, now: now, timeZone: timeZone)
            }
        }
        .padding(LoomTheme.Home.sideCardPadding)
        .frame(width: LoomTheme.Home.limitsPopoverWidth, alignment: .leading)
        .background(LoomTheme.Surface.popover)
        .accessibilityIdentifier("home-limits-detail")
    }
}

// MARK: Today

/// Today's figures: Claude's tokens since midnight (the footer chip's own number), how many sessions were used
/// and how much of what was sent came from the cache. The split by kind is the tooltip's.
struct HomeTodayFigures: Equatable {
    var tokens: String?
    var sessions: Int?
    /// Said under the figures when the tokens are not there yet.
    var note: String?
    /// Today's tokens by kind; nil until the usage read has found any.
    var kinds: UsageToday?

    /// "82%": cache reads over everything sent as prompt, when anything was.
    var cacheShare: String? {
        kinds?.cacheShare.map(UsageFormat.percent(fraction:))
    }

    /// The parts of the line, figure and label: ("1.2M", "tokens"), ("6", "sessions"), ("82%", "from cache").
    var stats: [(figure: String, label: String)] {
        var result: [(String, String)] = []
        if let tokens { result.append((tokens, "tokens")) }
        if let sessions { result.append(("\(sessions)", sessions == 1 ? "session" : "sessions")) }
        if let share = cacheShare { result.append((share, "from cache")) }
        return result
    }

    /// The tooltip: today's tokens by kind, when the read has found any.
    var kindsTooltip: String? {
        guard let kinds else { return nil }
        return "Today by kind: input \(UsageFormat.tokens(kinds.input)), output \(UsageFormat.tokens(kinds.output)), "
            + "cache read \(UsageFormat.tokens(kinds.cacheRead)), cache write \(UsageFormat.tokens(kinds.cacheWrite))."
    }

    var spoken: String {
        "Today, " + stats.map { "\($0.figure) \($0.label)" }.joined(separator: ", ")
    }
}

extension CatalogModel {
    /// The figures of the Today line, from the usage chip and the catalog read; nil when neither has anything.
    func homeTodayFigures() -> HomeTodayFigures? {
        var figures = HomeTodayFigures(sessions: home.sessionsToday)
        switch usage?.chip?.kind {
        case .today?:
            figures.tokens = usage?.chip?.figure
            if let kinds = usage?.todayUsage, kinds.total > 0 { figures.kinds = kinds }
        case .empty?: figures.tokens = "0"
        case .indexing?: figures.note = "Loom is reading Claude's usage for the first time."
        case nil: break
        }
        return figures.tokens == nil && figures.sessions == nil && figures.note == nil ? nil : figures
    }
}

/// "16.1K tokens · 2 sessions · 40% from cache": figures in primary, labels in secondary, on one line while it fits and as
/// a column when the card is narrower.
private struct HomeTodayLine: View {
    let figures: HomeTodayFigures

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing) {
            let stats = figures.stats
            if !stats.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LoomTheme.Space.chipInset) { statViews(stats) }.fixedSize()
                    VStack(alignment: .leading, spacing: LoomTheme.Space.cardGap) { statViews(stats) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(figures.kindsTooltip ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(figures.spoken)
                .accessibilityIdentifier("home-today")
            }
            if let note = figures.note {
                Text(note).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    .accessibilityIdentifier("home-today")
            }
        }
    }

    @ViewBuilder private func statViews(_ stats: [(figure: String, label: String)]) -> some View {
        ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
            if index > 0 {
                Text("\u{00B7}").foregroundStyle(LoomTheme.Text.secondaryOnCardStyle).accessibilityHidden(true)
            }
            let figure = Text(stat.figure).fontWeight(.semibold).monospacedDigit().foregroundStyle(LoomTheme.Text.primary)
            let label = Text(" " + stat.label).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
            Text("\(figure)\(label)").font(LoomTheme.Typography.small).lineLimit(1)
        }
    }
}

// MARK: Continue

/// Sessions Quit (or a crash) cut short, each with Resume and the time it was last active. The list comes from the
/// catalog read made when Home opened; a session that runs again, or that Resume was pressed for, drops out at once.
struct HomeContinue: View {
    let model: CatalogModel
    @State private var showsAll = false

    var body: some View {
        let entries = model.homeContinueEntries()
        if !entries.isEmpty {
            let shown = showsAll ? entries : Array(entries.prefix(LoomTheme.Home.continueShown))
            HomeSideCard(title: "Continue", meta: "\(entries.count)", identifier: "home-continue") {
                VStack(alignment: .leading, spacing: LoomTheme.Space.requestPadding) {
                    Text(entries.count == 1 ? "This session was running when Loom quit."
                         : "These sessions were running when Loom quit.")
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(shown) { entry in
                        HomeContinueRow(model: model, entry: entry)
                    }
                    if entries.count > shown.count {
                        Button("Show \(entries.count - shown.count) More") { showsAll = true }
                            .buttonStyle(ChipButtonStyle()).accessibilityIdentifier("home-continue-more")
                    }
                }
            }
        }
    }
}

private struct HomeContinueRow: View {
    let model: CatalogModel
    let entry: HomeContinueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing) {
            Text(entry.title).font(LoomTheme.Typography.cardTitle(selected: false))
                .foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
            HomeMeta(model: model, projectName: entry.projectName, tone: entry.tone, date: entry.endedAt, verb: "Last active")
            Button { model.resumeFromHome(entry.id) } label: {
                Label("Resume", systemImage: "play")
            }
            .buttonStyle(ChipButtonStyle())
            .padding(.top, LoomTheme.Space.headerSpacing)
            .accessibilityLabel("Resume \(entry.title)")
            .accessibilityIdentifier("home-resume")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-continue-entry")
    }
}
