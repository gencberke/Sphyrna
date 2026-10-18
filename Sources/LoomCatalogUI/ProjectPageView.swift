import Foundation
import LoomCore
import SwiftUI

/// A project's page (V08; design preview `v2-studio-preview` "Project"): its name and folder, a line of
/// numbers, and three tabs. Sessions lists the project's sessions with their last line beside the presets
/// and the past week's usage; Branches lists the repository's local branches; Instructions shows the
/// project's CLAUDE.md. The page reads when it opens and not before (its task ends when it closes);
/// `DetailContent` draws it for `.projectPage`.
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
                Message(symbol: "folder", title: "Project not found", text: "This project is no longer in Loom.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-page")
        .task(id: projectID) { await model.openProjectPage(projectID) }
        .onDisappear { model.closeProjectPage() }
    }

    private var wide: Bool { width >= LoomTheme.ProjectPage.wideBreakpoint }

    private func content(_ project: CatalogProject) -> some View {
        let page = model.projectPage
        let inset = wide ? LoomTheme.ProjectPage.sideInset : LoomTheme.ProjectPage.sideInsetNarrow
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProjectPageHeader(model: model, project: project)
                ProjectStatsLine(model: model, project: project)
                ProjectTabs(page: page)
                switch page.tab {
                case .sessions: ProjectSessionsTab(model: model, project: project, wide: wide)
                case .branches: ProjectBranchesTab(model: model)
                case .instructions: ProjectInstructionsTab(page: page)
                }
            }
            .padding(.horizontal, inset)
            .padding(.top, LoomTheme.ProjectPage.top)
            .padding(.bottom, LoomTheme.ProjectPage.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The tone stripe, the name and folder, and New session.
private struct ProjectPageHeader: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        HStack(alignment: .center, spacing: LoomTheme.ProjectPage.headerGap) {
            if let tone = model.projectTone(forProject: project.id) {
                RoundedRectangle(cornerRadius: LoomTheme.ProjectColor.stripeRadius)
                    .fill(LoomTheme.ProjectColor.stripe(tone))
                    .frame(width: LoomTheme.ProjectPage.stripe.width, height: LoomTheme.ProjectPage.stripe.height)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: LoomTheme.Space.aboutHeadSpacing) {
                Text(project.name).font(LoomTheme.ProjectPage.name).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("project-name")
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(LoomTheme.ProjectPage.pathFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .accessibilityIdentifier("project-path")
            }
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            Button { model.beginNewSession(projectID: project.id) } label: {
                Label("New session", systemImage: "square.and.pencil").lineLimit(1)
            }
            .buttonStyle(AccentButtonStyle(kind: .filled))
            .accessibilityIdentifier("project-new-session")
        }
    }
}

/// "3 running · 18 sessions · 4.8M tokens, past 7 days · main": the numbers the page already holds. The
/// figures wrap as whole items when the page is narrow; an item is never split across two lines.
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
        return FlowLayout(spacing: LoomTheme.ProjectPage.statsGap, lineSpacing: LoomTheme.ProjectPage.statsLineGap,
                          centered: false) {
            if running > 0 { figure(running, "running") }
            figure(total, total == 1 ? "session" : "sessions")
            if let usage = page.usage, usage.tokens.total > 0 {
                HStack(spacing: LoomTheme.ProjectPage.figureGap) {
                    Text(UsageFormat.tokens(usage.tokens.total)).fontWeight(.semibold).foregroundStyle(LoomTheme.Text.primary)
                    Text("tokens, past 7 days")
                }
                .lineLimit(1).fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(UsageFormat.spokenTokens(usage.tokens.total)) tokens in the past 7 days")
            }
            if let branch, branch != .unavailable {
                Text(branch.label).lineLimit(1).fixedSize().accessibilityLabel("Branch \(branch.label)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
        .padding(.top, LoomTheme.ProjectPage.statsTop).padding(.bottom, LoomTheme.ProjectPage.statsBottom)
        .accessibilityIdentifier("project-stats")
    }

    private func figure(_ count: Int, _ noun: String) -> some View {
        HStack(spacing: LoomTheme.ProjectPage.figureGap) {
            Text("\(count)").fontWeight(.semibold).foregroundStyle(LoomTheme.Text.primary)
            Text(noun)
        }
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(noun)")
    }
}

/// Sessions, Branches, Instructions: a 32 pt bar with a 2 pt accent underline under the open one.
private struct ProjectTabs: View {
    let page: ProjectPageState

    var body: some View {
        HStack(spacing: LoomTheme.ProjectPage.tabGap) {
            ForEach(ProjectPageTab.allCases, id: \.self) { tab in
                Button { page.tab = tab } label: {
                    Text(tab.rawValue)
                        .font(LoomTheme.ProjectPage.tabFont)
                        .foregroundStyle(page.tab == tab ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                        .padding(.horizontal, LoomTheme.ProjectPage.tabInset)
                        .frame(height: LoomTheme.ProjectPage.tabHeight)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(page.tab == tab ? LoomTheme.Accent.base : Color.clear)
                                .frame(height: LoomTheme.ProjectPage.tabUnderline)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle(radius: LoomTheme.Highlight.radiusCompact, key: "project-tab:\(tab.rawValue)"))
                .focusEffectDisabled()
                .accessibilityAddTraits(page.tab == tab ? .isSelected : [])
                .accessibilityIdentifier("project-tab-\(tab.rawValue.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
        }
        .padding(.bottom, LoomTheme.ProjectPage.tabsBottom)
    }
}
