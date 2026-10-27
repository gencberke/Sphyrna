import Foundation
import LoomCore
import SwiftUI

/// A project's page (V08; DESIGN §10): its head on the window's first 52 pt line, a line of numbers, and three view tabs. Sessions
/// lists the project's sessions with their last line beside the presets and the past week's usage; Branches lists the repository's
/// local branches; Instructions shows the project's CLAUDE.md. The page draws no header row: its head is the first line of its
/// scrolling column, and the window's buttons float over that line while the sidebar is collapsed (`DetailPageChrome`). The page
/// reads when it opens and not before (its task ends when it closes); `DetailContent` draws it for `.projectPage`.
struct ProjectPageView: View {
    let model: CatalogModel
    let projectID: UUID
    @State private var width = LoomTheme.ProjectPage.wideBreakpoint

    private var project: CatalogProject? { model.projects.first { $0.id == projectID } }

    var body: some View {
        Group {
            if let project {
                content(project)
            } else {
                Message(symbol: "folder", title: "Project not found", text: "This project is no longer in Sphyrna.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-page")
        .task(id: projectID) { await model.openProjectPage(projectID) }
        .onDisappear { model.closeProjectPage() }
    }

    private var wide: Bool { ProjectPageLayout.isWide(paneWidth: width) }

    private func content(_ project: CatalogProject) -> some View {
        let page = model.projectPage
        let inset = ProjectPageLayout.inset(paneWidth: width)
        let sessions = model.sessionCounts[project.id] ?? page.records.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProjectPageHeader(model: model, project: project, paneWidth: width)
                ProjectStatsLine(model: model, project: project)
                ViewTabs(tabs: ProjectTabsText.items(sessions: sessions, branches: page.branches?.branches.count),
                         selection: page.tab) { page.tab = $0 }
                Group {
                    switch page.tab {
                    case .sessions: ProjectSessionsTab(model: model, project: project, wide: wide)
                    case .branches: ProjectBranchesTab(model: model)
                    case .instructions: ProjectInstructionsTab(page: page, project: project, now: model.now)
                    }
                }
                .padding(.top, LoomTheme.ProjectPage.panelTop)
            }
            .padding(.horizontal, inset)
            .frame(maxWidth: LoomTheme.ProjectPage.maxWidth, alignment: .leading)
            .padding(.bottom, LoomTheme.ProjectPage.bottom)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Where the page's parts go (pure, so a test reads it).
enum ProjectPageLayout {
    /// The side column sits beside the sessions from `wideBreakpoint` of pane width.
    static func isWide(paneWidth: CGFloat) -> Bool { paneWidth >= LoomTheme.ProjectPage.wideBreakpoint }

    /// The column's side inset: 32, and 20 below the breakpoint.
    static func inset(paneWidth: CGFloat) -> CGFloat {
        isWide(paneWidth: paneWidth) ? LoomTheme.ProjectPage.sideInset : LoomTheme.ProjectPage.sideInsetNarrow
    }

    /// How far the column's content starts from the pane's leading edge: the centred column's margin and its inset.
    static func columnEdge(paneWidth: CGFloat) -> CGFloat {
        max(0, (paneWidth - min(paneWidth, LoomTheme.ProjectPage.maxWidth)) / 2) + inset(paneWidth: paneWidth)
    }

    /// How much further the head keeps from the column's leading edge so that the window's buttons and "Show Sidebar", which
    /// float over the top 52 pt while the sidebar is collapsed, stay clear: the head starts at `max(the column's inset,
    /// detailLeadingClearance)`, less what the column already has. The "Preparing…" notice is not drawn on this page
    /// (`DetailPageChrome.showsNotice`).
    static func headLeadingExtra(paneWidth: CGFloat, clearance: CGFloat) -> CGFloat {
        max(0, clearance - columnEdge(paneWidth: paneWidth))
    }
}

/// The head: the project's mark (26), its name in title type and its folder in mono, which can be selected; at the trailing edge,
/// 8 apart, ⋯ (the project menu, `ProjectActionsMenu`) and New session, the page's main action.
private struct ProjectPageHeader: View {
    let model: CatalogModel
    let project: CatalogProject
    let paneWidth: CGFloat
    /// What keeps the head clear of the window's buttons and "Show Sidebar" (`ProjectPageLayout.headLeadingExtra`).
    @Environment(\.detailLeadingClearance) private var clearance

    var body: some View {
        HStack(spacing: LoomTheme.ProjectPage.headGap) {
            ProjectMarkView(name: project.name, tone: model.projectTone(forProject: project.id), size: .page)
            HStack(alignment: .firstTextBaseline, spacing: LoomTheme.ProjectPage.headGap + LoomTheme.ProjectPage.pathLeading) {
                Text(project.name).projectType(LoomTheme.ProjectPage.name).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("project-name")
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .projectType(LoomTheme.ProjectPage.path).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(project.path)
                    .accessibilityIdentifier("project-path")
            }
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            HStack(spacing: LoomTheme.ProjectPage.endGap) {
                ProjectMenuButton(model: model, project: project, origin: .page)
                Button { model.beginNewSession(projectID: project.id) } label: {
                    HStack(spacing: LoomTheme.ProjectPage.newSessionGlyphGap) {
                        Image(systemName: "square.and.pencil").font(LoomTheme.ProjectPage.newSessionGlyph)
                        Text("New session").lineLimit(1)
                    }
                }
                .buttonStyle(ControlButtonStyle(kind: .default, size: .page))
                .accessibilityIdentifier("project-new-session")
            }
            .fixedSize()
        }
        .padding(.leading, ProjectPageLayout.headLeadingExtra(paneWidth: paneWidth, clearance: clearance))
        .frame(height: LoomTheme.ProjectPage.headHeight)
    }
}

// MARK: The stats line

/// The words of the stats line, "3 running · 9 sessions · 3.1M tokens, past 7 days" and the branch. Nothing is counted when there is
/// nothing to count: no "running" without a run, no tokens without usage, no branch outside Git (DESIGN §10 Stats). The sessions
/// figure is always there, "0 sessions" included.
enum ProjectStatsText {
    enum Item: Equatable {
        case figure(count: Int, noun: String)
        case tokens(figure: String, spoken: String)
        case branch(String)

        /// What assistive technologies read for the item.
        var accessibilityLabel: String {
            switch self {
            case .figure(let count, let noun): "\(count) \(noun)"
            case .tokens(_, let spoken): "\(spoken) tokens in the past 7 days"
            case .branch(let label): "Branch \(label)"
            }
        }
    }

    /// `tokens` is the past week's total (`nil` while unread or unreadable); `branch` is the folder's, `nil` or unavailable outside Git.
    static func items(running: Int, total: Int, tokens: Int64?, branch: GitBranch?) -> [Item] {
        var items: [Item] = []
        if running > 0 { items.append(.figure(count: running, noun: "running")) }
        items.append(.figure(count: total, noun: total == 1 ? "session" : "sessions"))
        if let tokens, tokens > 0 {
            items.append(.tokens(figure: UsageFormat.tokens(tokens), spoken: UsageFormat.spokenTokens(tokens)))
        }
        if let branch, branch != .unavailable { items.append(.branch(branch.label)) }
        return items
    }
}

/// The numbers the page already holds. The items wrap as whole items when the page is narrow; an item is never split across two
/// lines.
private struct ProjectStatsLine: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let page = model.projectPage
        _ = model.liveRevision
        // Sessions with a run under way (a live run, whether or not its turn is working): "running", never
        // "active", which is the sidebar's Active section and counts a different set.
        let running = page.records.filter { model.liveStates[$0.session.id]?.runID != nil }.count
        let total = model.sessionCounts[project.id] ?? page.records.count
        let branch = model.branches[project.path] ?? page.branches.map(\.current)
        let items = ProjectStatsText.items(running: running, total: total, tokens: page.usage?.tokens.total, branch: branch)
        return FlowLayout(spacing: LoomTheme.ProjectPage.statsGap, lineSpacing: LoomTheme.ProjectPage.statsLineGap, centered: false) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                view(item)
                    .lineLimit(1).fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .projectType(LoomTheme.ProjectPage.stats).foregroundStyle(LoomTheme.Text.secondaryStyle)
        .padding(.top, LoomTheme.ProjectPage.statsTop).padding(.bottom, LoomTheme.ProjectPage.statsBottom)
        .accessibilityIdentifier("project-stats")
    }

    @ViewBuilder private func view(_ item: ProjectStatsText.Item) -> some View {
        switch item {
        case .figure(let count, let noun): figure("\(count)", noun)
        case .tokens(let figure, _): self.figure(figure, "tokens, past 7 days")
        case .branch(let label):
            HStack(spacing: LoomTheme.ProjectPage.statsBranchGap) {
                Image(systemName: "arrow.triangle.branch").font(LoomTheme.ProjectPage.statsBranchGlyph)
                Text(label).projectType(LoomTheme.ProjectPage.statsBranch)
            }
        }
    }

    private func figure(_ figure: String, _ noun: String) -> some View {
        HStack(spacing: LoomTheme.ProjectPage.figureGap) {
            Text(figure).projectType(LoomTheme.ProjectPage.statsFigure).foregroundStyle(LoomTheme.Text.primary)
            Text(noun)
        }
    }
}

// MARK: The tabs

/// The view tabs' titles and counts: Sessions and Branches show how many they hold (nothing while there is none, or while the
/// branches are unread), Instructions none.
enum ProjectTabsText {
    static func items(sessions: Int, branches: Int?) -> [ViewTabItem<ProjectPageTab>] {
        ProjectPageTab.allCases.map { tab in
            let count: Int? = switch tab {
            case .sessions: sessions
            case .branches: branches
            case .instructions: nil
            }
            return ViewTabItem(id: tab, title: tab.rawValue, count: count.flatMap { $0 > 0 ? $0 : nil },
                               identifier: "project-tab-\(tab.rawValue.lowercased())", hoverKey: "project-tab:\(tab.rawValue)")
        }
    }
}
