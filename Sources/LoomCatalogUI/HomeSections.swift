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
        let lead = Text(verb.map { "\($0) " } ?? "").font(LoomTheme.InkType.caption.font)
        let time = Text(verb == nil ? RelativeTime.string(from: date, to: model.now) : HomeAgeText.ago(from: date, to: model.now))
            .font(LoomTheme.Home.rowMeta.font)
        Text("\(lead)\(time)").foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// The project's mark and name after a row's title. A session without a project shows neither.
struct HomeProjectTag: View {
    let name: String
    let tone: ProjectTone?

    var body: some View {
        HStack(spacing: LoomTheme.Home.projectGap) {
            ProjectMarkView(name: name, tone: tone, size: .chip)
            Text(name).homeType(LoomTheme.Home.projectName).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: Usage

/// Home's usage as the previews draw it: a "Plan limits" card (both windows as meters, each with its reset and pace line)
/// and a "Today" card under it (tokens, sessions and cache share). A card with nothing to say is left out. With Codex connected
/// and read, its windows stand under Claude's, each group headed by the harness name.
struct HomeUsage: View {
    let model: CatalogModel

    var body: some View {
        let usage = model.usage
        let paces = usage == nil ? [] : model.homePaces()
        let codex = usage == nil ? [] : model.homeCodexLimits()
        let limitsFailure = paces.isEmpty && codex.isEmpty && usage?.isConnected(.claude) != false
            ? usage?.limitsFailure.flatMap { $0.category == .noToolchain ? nil : $0 } : nil
        let figures = model.homeTodayFigures()
        // Nothing at all when no card has something to say: an empty stack would still take a gap in the side column.
        if !paces.isEmpty || !codex.isEmpty || limitsFailure != nil || figures != nil {
            VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
                if let usage, !paces.isEmpty || !codex.isEmpty {
                    let readAt = paces.isEmpty ? usage.readings[.codex]?.readAt : usage.limits?.fetchedAt
                    HomePlanLimits(paces: paces, codex: codex, now: model.now, timeZone: usage.timeZone,
                                   updated: readAt.map { UsageText.time($0, usage.timeZone) })
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

/// One harness's windows in the Plan limits card; the name is nil for Claude alone, which looks as it always did.
struct HomeLimitGroup: Equatable {
    let name: String?
    let lines: [PlanPaceLine.Content]
}

/// The words of the Plan limits card with and without Codex: its groups, what VoiceOver reads and the tooltip. Plain data
/// so a test can state them from fixture numbers.
enum HomeLimitsText {
    static func groups(paces: [PlanPace], codex: [PlanPaceLine.Content], now: Date, timeZone: TimeZone) -> [HomeLimitGroup] {
        let claude = paces.map { PlanPaceLine.Content(pace: $0, now: now, timeZone: timeZone) }
        if codex.isEmpty { return [HomeLimitGroup(name: nil, lines: claude)] }
        return (paces.isEmpty ? [] : [HomeLimitGroup(name: ProviderName.title(.claude), lines: claude)]) + [HomeLimitGroup(name: ProviderName.title(.codex), lines: codex)]
    }

    /// "Plan limits, 5-hour window 62% left, on pace. Codex, 5-hour 77% left, Weekly 39% left".
    static func spoken(paces: [PlanPace], codex: [PlanPaceLine.Content], now: Date, timeZone: TimeZone) -> String {
        let claude = PlanLimitsLine(paces: paces, now: now, timeZone: timeZone).spoken
        guard !codex.isEmpty else { return claude }
        let codexText = "\(ProviderName.title(.codex)), " + codex.map { "\($0.title) \($0.left)" }.joined(separator: ", ")
        return paces.isEmpty ? "Plan limits, " + codexText : claude + ". " + codexText
    }

    /// Each window's sentence, Claude's first, Codex's under them with the harness name.
    static func tooltip(paces: [PlanPace], codex: [PlanPaceLine.Content], now: Date, timeZone: TimeZone) -> String {
        let claude = PlanLimitsLine(paces: paces, now: now, timeZone: timeZone).tooltip(paces: paces, now: now, timeZone: timeZone)
        let lines = (paces.isEmpty ? [] : [claude]) + codex.map { "\(ProviderName.title(.codex)) \($0.tooltip)" }
        return lines.joined(separator: "\n")
    }
}

/// The "Plan limits" card: "updated 14:52" at the heading's right, then one `PlanPaceLine` per window (name and what is
/// left, the meter, the reset and pace line). VoiceOver reads the card as one element with `PlanLimitsLine.spoken`; the
/// tooltip carries each window's sentence. The windows' reset lines wrap, so a time a limit runs out is never cut.
struct HomePlanLimits: View {
    let paces: [PlanPace]
    var codex: [PlanPaceLine.Content] = []
    let now: Date
    let timeZone: TimeZone
    let updated: String?

    var body: some View {
        let groups = HomeLimitsText.groups(paces: paces, codex: codex, now: now, timeZone: timeZone)
        HomeSideCard(title: "Plan limits", meta: updated.map { "updated " + $0 }, contentTop: LoomTheme.Home.paceGap,
                     summary: HomeLimitsText.spoken(paces: paces, codex: codex, now: now, timeZone: timeZone),
                     identifier: "home-limits") {
            VStack(alignment: .leading, spacing: codex.isEmpty ? LoomTheme.Home.paceGap : LoomTheme.Home.limitGroupGap) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: LoomTheme.Home.limitGroupHeadGap) {
                        if let name = group.name {
                            Text(name).homeType(LoomTheme.Home.limitGroup).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        }
                        VStack(alignment: .leading, spacing: LoomTheme.Home.paceGap) {
                            ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                                PlanPaceLine(content: line)
                            }
                        }
                    }
                }
            }
        }
        .help(HomeLimitsText.tooltip(paces: paces, codex: codex, now: now, timeZone: timeZone))
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
