import LoomCore
import SwiftUI

// MARK: Surfaces

/// A card: the card surface, radius 12, a hairline and the card's depth. Its content is clipped to the shape, so a row's hover
/// fill across the whole card width follows the corners.
struct HomeCard<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Radius.block)
        content
            .clipShape(shape)
            .background(shape.fill(LoomTheme.Surface.card))
            .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            .depth(LoomTheme.Elevation.card)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

/// What VoiceOver reads for a list card's heading: "Needs you, 1", or the title alone without a count.
enum HomeListHeading {
    static func label(title: String, count: Int?) -> String { count.map { "\(title), \($0)" } ?? title }
}

/// A list card: a 42 pt heading row (an optional status dot, the title, an optional count), then its rows. Each row draws the
/// hairline above it.
struct HomeListCard<Content: View>: View {
    let title: String
    /// Nil shows no count (the empty Needs you card).
    var count: Int?
    /// Nil shows no dot.
    var pip: Color?
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        HomeCard(identifier: identifier) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: LoomTheme.Home.headGap) {
                    if let pip {
                        Circle().fill(pip).frame(width: LoomTheme.Home.pip, height: LoomTheme.Home.pip).accessibilityHidden(true)
                    }
                    Text(title).homeType(LoomTheme.Home.headTitle).foregroundStyle(LoomTheme.Text.primary)
                    if let count {
                        Text("\(count)").homeType(LoomTheme.Home.headCount).monospacedDigit()
                            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, LoomTheme.Home.itemPadding)
                .frame(height: LoomTheme.Home.headHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(HomeListHeading.label(title: title, count: count))
                .accessibilityAddTraits(.isHeader)
                content
            }
        }
    }
}

/// A block of the side column: a heading with an optional right-hand note, then its content.
struct HomeSideCard<Content: View>: View {
    let title: String
    var meta: String?
    /// How far under the heading the content starts, on top of the heading's own 4.
    var contentTop: CGFloat = LoomTheme.Home.todayTop
    /// When set, VoiceOver reads the whole block (heading and content) as one element saying this.
    var summary: String?
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        HomeCard(identifier: identifier) {
            let block = VStack(alignment: .leading, spacing: LoomTheme.Home.sideHeadGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).homeType(LoomTheme.Home.sideTitle).foregroundStyle(LoomTheme.Text.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: LoomTheme.Space.chipSplitGap)
                    if let meta {
                        Text(meta).homeType(LoomTheme.Home.sideNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    }
                }
                content.padding(.top, contentTop)
            }
            .padding(LoomTheme.Home.sideCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let summary {
                block.accessibilityElement(children: .ignore).accessibilityLabel(summary)
            } else {
                block
            }
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

/// A time in mono tertiary: "4m", or spelled out after a verb ("Last active 11h ago"). It is the only part of a row that reads
/// the minute tick, so the tick redraws these labels and nothing else.
struct HomeAgeLabel: View {
    let model: CatalogModel
    let date: Date
    /// Spells the time out after this word; nil shows the row's short "2h".
    var verb: String?

    var body: some View {
        Text(verb.map { "\($0) " + HomeAgeText.ago(from: date, to: model.now) } ?? RelativeTime.string(from: date, to: model.now))
            .homeType(LoomTheme.Home.rowMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// The project's mark (14) and its name in mono tertiary, after a row's title. A session without a project shows neither.
struct HomeProjectTag: View {
    let name: String
    let tone: ProjectTone?

    var body: some View {
        HStack(spacing: LoomTheme.Home.projectGap) {
            ProjectMarkView(name: name, tone: tone, size: .chip)
            Text(name).homeType(LoomTheme.Home.rowMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: Usage

/// Home's usage as the previews draw it: a "Plan limits" card (both windows as meters, each with its reset and pace line)
/// and a "Today" card under it (tokens, sessions and cache share). A card with nothing to say is left out.
struct HomeUsage: View {
    let model: CatalogModel

    var body: some View {
        let usage = model.usage
        let paces = usage == nil ? [] : model.homePaces()
        let limitsFailure = paces.isEmpty ? usage?.limitsFailure.flatMap { $0.category == .noToolchain ? nil : $0 } : nil
        let figures = model.homeTodayFigures()
        // Nothing at all when no card has something to say: an empty stack would still take a gap in the side column.
        if !paces.isEmpty || limitsFailure != nil || figures != nil {
            VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
                if let usage, !paces.isEmpty {
                    HomePlanLimits(paces: paces, now: model.now, timeZone: usage.timeZone,
                                   updated: usage.limits.map { UsageText.time($0.fetchedAt, usage.timeZone) })
                } else if limitsFailure != nil {
                    HomeSideCard(title: "Plan limits", identifier: "home-limits") {
                        Text("Claude did not report plan limits, so Sphyrna shows none.")
                            .homeType(LoomTheme.Home.reason).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let figures {
                    HomeSideCard(title: "Today", identifier: "home-usage") { HomeTodayLine(figures: figures) }
                }
            }
        }
    }
}

/// The "Plan limits" card: "updated 14:52" at the heading's right, then one `PlanPaceLine` per window (name and what is
/// left, the meter, the reset and pace line). VoiceOver reads the card as one element with `PlanLimitsLine.spoken`; the
/// tooltip carries each window's sentence. The windows' reset lines wrap, so a time a limit runs out is never cut.
struct HomePlanLimits: View {
    let paces: [PlanPace]
    let now: Date
    let timeZone: TimeZone
    let updated: String?

    var body: some View {
        let line = PlanLimitsLine(paces: paces, now: now, timeZone: timeZone)
        HomeSideCard(title: "Plan limits", meta: updated.map { "updated " + $0 }, contentTop: LoomTheme.Home.paceGap,
                     summary: line.spoken, identifier: "home-limits") {
            VStack(alignment: .leading, spacing: LoomTheme.Home.paceGap) {
                ForEach(Array(paces.enumerated()), id: \.offset) { _, pace in
                    PlanPaceLine(pace: pace, now: now, timeZone: timeZone)
                }
            }
        }
        .help(line.tooltip(paces: paces, now: now, timeZone: timeZone))
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
        case .indexing?: figures.note = "Sphyrna is reading Claude's usage for the first time."
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
        VStack(alignment: .leading, spacing: LoomTheme.Home.todayGap) {
            let stats = figures.stats
            if !stats.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LoomTheme.Space.chipInset) { statViews(stats) }.fixedSize()
                    VStack(alignment: .leading, spacing: LoomTheme.Home.todayGap) { statViews(stats) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(figures.kindsTooltip ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(figures.spoken)
                .accessibilityIdentifier("home-today")
            }
            if let note = figures.note {
                Text(note).homeType(LoomTheme.Home.sideNote).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
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
            Text("\(figure)\(label)").homeType(LoomTheme.Home.today).lineLimit(1)
        }
    }
}
