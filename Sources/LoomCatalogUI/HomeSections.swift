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
            .padding(LoomTheme.Home.itemPadding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-entry")
    }
}

// MARK: Plan limits

/// Both plan windows with their pace line. The pace is arithmetic over the last answer at `model.now`, which
/// the model's minute tick moves while the window is visible; nothing here asks the CLI.
struct HomePlanLimits: View {
    let model: CatalogModel

    var body: some View {
        if let usage = model.usage {
            let now = model.now
            let paces = model.homePaces()
            if !paces.isEmpty {
                HomeSideCard(title: "Plan limits", meta: usage.limits.map { "updated " + UsageText.time($0.fetchedAt, usage.timeZone) },
                             identifier: "home-limits") {
                    VStack(alignment: .leading, spacing: LoomTheme.Home.limitGap) {
                        ForEach(Array(paces.enumerated()), id: \.offset) { _, pace in
                            PlanPaceLine(pace: pace, now: now, timeZone: usage.timeZone)
                        }
                    }
                }
            } else if let failure = usage.limitsFailure, failure.category != .noToolchain {
                HomeSideCard(title: "Plan limits", identifier: "home-limits") {
                    Text("Claude did not report them, so Loom shows none.")
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: Today

/// Today's figures: Claude's tokens since midnight (the footer chip's own number), how many sessions were used
/// and, under them, how much of what was sent came from the cache and how the tokens split by kind.
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
}

extension CatalogModel {
    /// The figures of the Today block, from the usage chip and the catalog read; nil when neither has anything.
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

struct HomeToday: View {
    let model: CatalogModel

    var body: some View {
        if let figures = model.homeTodayFigures() {
            HomeSideCard(title: "Today", identifier: "home-today") {
                VStack(alignment: .leading, spacing: LoomTheme.Space.chipInset) {
                    HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.usageTotalsGap) {
                        if let tokens = figures.tokens { stat(tokens, "tokens") }
                        if let sessions = figures.sessions { stat("\(sessions)", sessions == 1 ? "session" : "sessions") }
                        if let share = figures.cacheShare { stat(share, "from cache") }
                    }
                    if let kinds = figures.kinds { HomeTodayBars(kinds: kinds) }
                    if let note = figures.note {
                        Text(note).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    }
                }
            }
        }
    }

    private func stat(_ figure: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.cardGap) {
            Text(figure).font(LoomTheme.TypeScale.title).monospacedDigit().foregroundStyle(LoomTheme.Text.primary)
            Text(label).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(figure) \(label) today")
    }
}

/// Today's tokens by kind as four bars, the largest kind filling the track; the cache reads are the one drawn in
/// the text colour, as the preview's latest bar is.
struct HomeTodayBars: View {
    let kinds: UsageToday

    private var parts: [(label: String, tokens: Int64)] {
        [("Input", kinds.input), ("Output", kinds.output), ("Cache read", kinds.cacheRead), ("Cache write", kinds.cacheWrite)]
    }

    var body: some View {
        let parts = parts
        let peak = CGFloat(max(parts.map(\.tokens).max() ?? 1, 1))
        HStack(alignment: .bottom, spacing: LoomTheme.Home.todayBarGap) {
            ForEach(parts, id: \.label) { part in
                VStack(spacing: LoomTheme.Home.todayBarGap) {
                    Spacer(minLength: 0)
                    UnevenRoundedRectangle(topLeadingRadius: LoomTheme.Home.todayBarRadius, topTrailingRadius: LoomTheme.Home.todayBarRadius)
                        .fill(part.label == "Cache read" ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Surface.controlPressed))
                        .frame(height: max(LoomTheme.Home.todayBarMinHeight, CGFloat(part.tokens) / peak * LoomTheme.Home.todayBarsHeight))
                    Text(part.label).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: LoomTheme.Home.todayBarsHeight + LoomTheme.Home.todayBarsLabel)
        .padding(.top, LoomTheme.Home.todayBarsTop)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("home-today-bars")
        .accessibilityLabel("Today by kind: " + parts.map { "\($0.label) \(UsageFormat.spokenTokens($0.tokens))" }.joined(separator: ", "))
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
