import LoomCore
import SwiftUI

// MARK: Shared parts

/// What decides whether a row shows its actions: the pointer on it (or the evidence run's held hover), or keyboard focus on
/// one of them. They are accessibility elements at all times either way.
enum HomeRowActions {
    static func revealed(hovering: Bool, focused: Bool) -> Bool { hovering || focused }
}

/// The hairline above a row, from edge to edge of the card.
private struct HomeRule: View {
    var body: some View {
        Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
    }
}

/// A row's first line (DESIGN §9 Row): the status mark, the harness's mark and the title, the project's mark and name. The age
/// or the actions follow in the row itself.
private struct HomeRowTitle: View {
    let provider: ManagedSession.Provider
    let title: String
    let projectName: String?
    let tone: ProjectTone?

    var body: some View {
        HStack(spacing: LoomTheme.Home.rowColumnGap) {
            HarnessMark(provider: provider)
            Text(title).homeType(LoomTheme.Home.rowTitle).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                .layoutPriority(1)
            if let projectName { HomeProjectTag(name: projectName, tone: tone) }
        }
    }
}

/// The hover fill across the whole row; the card's clip gives it the corners.
private struct HomeRowFill: View {
    let hot: Bool

    var body: some View { RowHighlight(state: hot ? .hover : .none, radius: 0) }
}

// MARK: Needs you, Finished

/// One session in a list, on one line: its state, the harness's mark, the title, the project and the age. Under it the line
/// (what it waits for or did last), and on hover or keyboard focus the ways on: open it, or mark a finished turn read. A click
/// on the row opens the session, as Open Session does.
struct HomeEntryRow: View {
    let model: CatalogModel
    let entry: HomeEntry
    @State private var hovering = false
    @FocusState private var focus: Action?

    enum Action: Hashable { case open, markRead }

    var body: some View {
        let key = "home-entry:\(entry.id)"
        let hot = hovering || LookEvidence.forcesHover(key)
        let revealed = HomeRowActions.revealed(hovering: hot, focused: focus != nil)
        VStack(spacing: 0) {
            HomeRule()
            VStack(alignment: .leading, spacing: LoomTheme.Home.rowLineGap) {
                HStack(spacing: LoomTheme.Home.rowColumnGap) {
                    IndicatorView(indicator: entry.indicator)
                    HomeRowTitle(provider: entry.provider, title: entry.title, projectName: entry.projectName, tone: entry.tone)
                    Spacer(minLength: LoomTheme.Home.rowColumnGap)
                    HomeAgeLabel(model: model, date: entry.lastActivityAt)
                }
                HStack(alignment: .top, spacing: LoomTheme.Home.rowColumnGap) {
                    HomeReasonLine(entry: entry)
                    Spacer(minLength: 0)
                    HStack(spacing: LoomTheme.Home.rowActionsGap) {
                        Button("Open Session") { model.select(entry.id) }
                            .buttonStyle(ControlButtonStyle(kind: .primary, size: .small))
                            .focused($focus, equals: .open)
                            .accessibilityLabel("Open \(entry.title)")
                            .accessibilityIdentifier("home-open")
                        if entry.canMarkRead {
                            Button("Mark as Read") { model.markRead(entry.id) }
                                .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                                .focused($focus, equals: .markRead)
                                .accessibilityLabel("Mark \(entry.title) as read")
                                .accessibilityIdentifier("home-mark-read")
                        }
                    }
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
                    .animation(.easeOut(duration: LoomTheme.Highlight.fadeDuration), value: revealed)
                }
                .padding(.leading, LoomTheme.Home.statusColumn + LoomTheme.Home.rowColumnGap)
            }
            .padding(.top, LoomTheme.Home.rowTop).padding(.bottom, LoomTheme.Home.rowBottom)
            .padding(.horizontal, LoomTheme.Home.itemPadding)
            .background(HomeRowFill(hot: hot))
            .contentShape(Rectangle())
            .onTapGesture { model.select(entry.id) }
            .onHover { hovering = $0 }
        }
        .accessibilityElement(children: .contain)
        // The buttons are not in the tree while they are hidden, so the actions are the row's own at all times.
        .accessibilityActions {
            Button("Open Session") { model.select(entry.id) }
            if entry.canMarkRead { Button("Mark as Read") { model.markRead(entry.id) } }
        }
        .accessibilityIdentifier("home-entry")
    }
}

/// The reason line (DESIGN §9 Row): small secondary, two lines at most, the command or the path the machine said in mono.
struct HomeReasonLine: View {
    let entry: HomeEntry

    var body: some View {
        Group {
            if let reason = entry.reason, let mono = reason.mono {
                let lead = Text(reason.lead)
                let machine = Text(mono).font(LoomTheme.Home.reasonMono.font)
                Text("\(lead)\(machine)")
            } else {
                Text(entry.line)
            }
        }
        .homeType(LoomTheme.Home.reason)
        .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("home-entry-line")
    }
}

// MARK: Continue

/// Sessions Quit (or a crash) cut short, each with Resume and the time it was last active. The list comes from the
/// catalog read made when Home opened; a session that runs again, or that Resume was pressed for, drops out at once. It is
/// the lists' first card (DESIGN §9 Two columns): the one block that asks for a click.
struct HomeContinue: View {
    let model: CatalogModel
    @State private var showsAll = false

    static let lead = "These sessions were running when Sphyrna quit."
    static let leadSingle = "This session was running when Sphyrna quit."

    var body: some View {
        let entries = model.homeContinueEntries()
        if !entries.isEmpty {
            let shown = showsAll ? entries : Array(entries.prefix(LoomTheme.Home.continueShown))
            HomeListCard(title: "Continue", count: entries.count, pip: nil, identifier: "home-continue") {
                Text(entries.count == 1 ? Self.leadSingle : Self.lead)
                    .homeType(LoomTheme.Home.lead).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LoomTheme.Home.itemPadding)
                    .padding(.top, -LoomTheme.Home.leadLift).padding(.bottom, LoomTheme.Home.leadBottom)
                ForEach(shown) { entry in
                    HomeContinueRow(model: model, entry: entry)
                }
                if entries.count > shown.count {
                    VStack(spacing: 0) {
                        HomeRule()
                        Button("Show \(entries.count - shown.count) More") { showsAll = true }
                            .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                            .accessibilityIdentifier("home-continue-more")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, LoomTheme.Home.itemPadding - LoomTheme.Control.Size.small.paddingH)
                            .padding(.top, LoomTheme.Home.moreTop).padding(.bottom, LoomTheme.Home.moreBottom)
                    }
                }
            }
        }
    }
}

/// One session Continue offers: its title and project on a line, and "Last active 11h ago", which gives way to a small filled
/// Resume on hover and on keyboard focus.
private struct HomeContinueRow: View {
    let model: CatalogModel
    let entry: HomeContinueEntry
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let key = "home-entry:\(entry.id)"
        let hot = hovering || LookEvidence.forcesHover(key)
        let revealed = HomeRowActions.revealed(hovering: hot, focused: focused)
        VStack(spacing: 0) {
            HomeRule()
            HStack(spacing: LoomTheme.Home.rowColumnGap) {
                Color.clear.frame(width: LoomTheme.Home.statusColumn, height: 1)
                HomeRowTitle(provider: entry.provider, title: entry.title, projectName: entry.projectName, tone: entry.tone)
                Spacer(minLength: LoomTheme.Home.rowColumnGap)
                ZStack(alignment: .trailing) {
                    HomeAgeLabel(model: model, date: entry.endedAt, verb: "Last active")
                        .opacity(revealed ? 0 : 1)
                    Button("Resume") { model.resumeFromHome(entry.id) }
                        .buttonStyle(ControlButtonStyle(kind: .primary, size: .small))
                        .focused($focused)
                        .opacity(revealed ? 1 : 0)
                        .allowsHitTesting(revealed)
                        .accessibilityLabel("Resume \(entry.title)")
                        .accessibilityIdentifier("home-resume")
                }
                .animation(.easeOut(duration: LoomTheme.Highlight.fadeDuration), value: revealed)
            }
            .padding(.vertical, LoomTheme.Home.rowOneLine)
            .padding(.horizontal, LoomTheme.Home.itemPadding)
            .background(HomeRowFill(hot: hot))
            .onHover { hovering = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions { Button("Resume") { model.resumeFromHome(entry.id) } }
        .accessibilityIdentifier("home-continue-entry")
    }
}
