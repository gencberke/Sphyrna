import Foundation
import LoomCore
import SwiftUI

/// What the Sessions tab draws and where (pure, so a test reads it): the list and the two side cards. Wide: the list, with Presets
/// and the past week in a column beside it. Narrow (under 760 of pane width): one column, Presets above the list and the past week
/// under it (DESIGN §10 Side cards); the Presets card is always there, with its one line while the project has no preset.
enum ProjectSessionsLayout {
    enum Block: Hashable { case presets, list, usage }

    struct Arrangement: Equatable {
        /// The main column, top to bottom.
        let main: [Block]
        /// The side column beside it; empty in a narrow pane.
        let side: [Block]
    }

    static func arrangement(wide: Bool) -> Arrangement {
        wide ? Arrangement(main: [.list], side: [.presets, .usage]) : Arrangement(main: [.presets, .list, .usage], side: [])
    }
}

/// The Sessions tab: the project's sessions with their last line, and beside them (or, in a narrow pane, around them) the presets
/// and the past week's usage.
struct ProjectSessionsTab: View {
    let model: CatalogModel
    let project: CatalogProject
    let wide: Bool

    var body: some View {
        let arrangement = ProjectSessionsLayout.arrangement(wide: wide)
        if arrangement.side.isEmpty {
            VStack(alignment: .leading, spacing: LoomTheme.ProjectPage.blockGap) { blocks(arrangement.main) }
        } else {
            HStack(alignment: .top, spacing: LoomTheme.ProjectPage.columnGap) {
                VStack(alignment: .leading, spacing: LoomTheme.ProjectPage.blockGap) { blocks(arrangement.main) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(spacing: LoomTheme.ProjectPage.blockGap) { blocks(arrangement.side) }
                    .frame(width: LoomTheme.ProjectPage.sideColumn)
            }
        }
    }

    @ViewBuilder private func blocks(_ blocks: [ProjectSessionsLayout.Block]) -> some View {
        ForEach(blocks, id: \.self) { block in
            switch block {
            case .presets: ProjectPresetsCard(model: model, project: project)
            case .list: ProjectSessionList(model: model, project: project)
            case .usage: ProjectUsageCard(model: model)
            }
        }
    }
}

/// One row per session, newest activity first. Rows are lazy: a row's last line is read only once it is drawn, so a long list costs
/// nothing for the part nobody scrolled to.
private struct ProjectSessionList: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let page = model.projectPage
        VStack(alignment: .leading, spacing: 0) {
            if page.records.isEmpty {
                if page.sessionsFailed {
                    Text("Could not read this project's sessions.")
                        .projectType(LoomTheme.ProjectPage.cardText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .padding(.horizontal, LoomTheme.ProjectPage.notePaddingH).padding(.vertical, LoomTheme.ProjectPage.notePaddingV)
                        .accessibilityIdentifier("project-sessions-failed")
                } else if page.sessionsLoad == .done {
                    ProjectEmptyList()
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(page.records.enumerated()), id: \.element.session.id) { index, record in
                        if index > 0 {
                            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                        }
                        ProjectSessionRow(model: model, record: record, isFirst: index == 0)
                    }
                }
                if page.hasMore {
                    Button { model.loadMoreProjectSessions() } label: {
                        Text(page.isLoadingMore ? "Loading\u{2026}" : "Show more sessions")
                    }
                    .buttonStyle(ControlButtonStyle(kind: .secondary)).disabled(page.isLoadingMore)
                    .padding(.top, LoomTheme.ProjectPage.blockGap)
                    .accessibilityIdentifier("project-more-sessions")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }
}

/// An empty project: a small hammerhead swimming in place over one line in the list's place (DESIGN §10 Empty project, §17, D-76).
struct ProjectEmptyList: View {
    static let line = "No sessions in this project yet. New session starts one."

    var body: some View {
        VStack(spacing: 0) {
            ArtSurface(place: .emptyProject)
                .frame(maxWidth: .infinity).frame(height: LoomTheme.Art.projectBoxHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Text(Self.line)
                .projectType(LoomTheme.ProjectPage.emptyLine).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, LoomTheme.Art.projectLineTop)
                .accessibilityIdentifier("project-no-sessions")
        }
        .padding(.top, LoomTheme.ProjectPage.emptyTop).padding(.bottom, LoomTheme.ProjectPage.emptyBottom)
    }
}

/// A session: the status slot, the harness's mark, the title with its last line, the branch and the time (DESIGN §10 Session row).
/// A click shows the session.
private struct ProjectSessionRow: View {
    let model: CatalogModel
    let record: CatalogSession
    let isFirst: Bool
    @State private var rowWidth = LoomTheme.ProjectPage.rowBranchBreakpoint

    var body: some View {
        // The live state is read here so a status change redraws this row; the transcript is not.
        _ = model.liveRevision
        let id = record.session.id
        let provider = record.session.provider
        let live = model.liveStates[id]
        let indicator = SessionIndicator(
            record: record, live: live, awaitingOpenApproval: model.awaitingOpenApproval.contains(id))
        let reason = live?.displayReason
        let line = ProjectSessionLine.line(reason: reason, transcript: model.projectPage.lastLines[id])
        let branch = model.branches[record.session.workingDirectory]
        let time = RelativeTime.string(from: record.lastActivityAt, to: model.now)
        let title = record.displayTitle(projectName: nil, repeatsProject: false)
        let showsBranch = ProjectRowLayout.showsBranch(rowWidth: rowWidth, branch: branch)
        return Button { model.select(id) } label: {
            HStack(alignment: .top, spacing: LoomTheme.ProjectPage.rowColumnGap) {
                IndicatorView(indicator: indicator)
                    .frame(width: LoomTheme.Layout.indicatorSlot.width, height: LoomTheme.Layout.indicatorSlot.height)
                    .padding(.top, LoomTheme.ProjectPage.rowIndicatorTop)
                ProviderIcon(provider: provider).padding(.top, LoomTheme.ProjectPage.rowMarkTop)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .projectType(LoomTheme.ProjectPage.rowTitle)
                        .foregroundStyle(indicator == .stale ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.primary))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(height: LoomTheme.ProjectPage.rowTitleHeight, alignment: .leading)
                    if let line {
                        ProjectLastLineText(line: line).lineLimit(1).truncationMode(.tail)
                            .frame(height: LoomTheme.ProjectPage.rowLineHeight, alignment: .leading)
                            .padding(.top, LoomTheme.ProjectPage.rowLineTop)
                            .accessibilityIdentifier("project-session-line")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsBranch, let branch {
                    HStack(spacing: LoomTheme.ProjectPage.rowBranchGap) {
                        Image(systemName: "arrow.triangle.branch").font(LoomTheme.ProjectPage.rowBranchGlyph)
                        Text(branch.label).lineLimit(1).truncationMode(.middle)
                    }
                    .projectType(LoomTheme.ProjectPage.rowBranch).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.ProjectPage.rowBranchWidth, height: LoomTheme.ProjectPage.rowMetaHeight, alignment: .leading)
                }
                Text(time).projectType(LoomTheme.ProjectPage.rowTime).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .frame(width: LoomTheme.ProjectPage.rowTimeWidth, height: LoomTheme.ProjectPage.rowMetaHeight, alignment: .trailing)
            }
            .padding(.horizontal, LoomTheme.ProjectPage.rowPaddingH)
            .padding(.top, LoomTheme.ProjectPage.rowPaddingTop).padding(.bottom, LoomTheme.ProjectPage.rowPaddingBottom)
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.ProjectPage.rowRadius))
        }
        .buttonStyle(RowButtonStyle(radius: LoomTheme.ProjectPage.rowRadius, key: "project-row:\(id)"))
        .focusEffectDisabled()
        // The pill sits a little inside the hairlines between rows: the first row has none above it.
        .padding(.top, isFirst ? 0 : LoomTheme.ProjectPage.rowPillGap).padding(.bottom, LoomTheme.ProjectPage.rowPillGap)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        // A last line from the transcript is read only for a row that is drawn and holds no line of its own.
        .task(id: ProjectSessionLine.holdsLine(reason)) {
            if !ProjectSessionLine.holdsLine(reason) { await model.loadProjectLastLine(record) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, ProviderName.title(provider), line?.text, time].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("project-session-row")
    }
}

/// A row's last line in two voices: the words in 12 secondary and a command or a path in mono 11.5 primary.
struct ProjectLastLineText: View {
    let line: SessionReasonLine

    var body: some View {
        if let mono = line.mono {
            let words = Text(line.lead).font(LoomTheme.ProjectPage.rowLine.font).foregroundStyle(LoomTheme.Text.secondaryStyle)
            let machine = Text(mono).font(LoomTheme.ProjectPage.rowLineMono.font).foregroundStyle(LoomTheme.Text.primary)
            Text("\(words)\(machine)")
        } else {
            Text(line.text).font(LoomTheme.ProjectPage.rowLine.font).foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
    }
}

/// Which columns a session row draws.
enum ProjectRowLayout {
    /// The branch drops when the row is under 460 and outside Git; the time keeps its column.
    static func showsBranch(rowWidth: CGFloat, branch: GitBranch?) -> Bool {
        guard let branch, branch != .unavailable else { return false }
        return rowWidth >= LoomTheme.ProjectPage.rowBranchBreakpoint
    }
}

// MARK: The side cards

/// A card of the side column: raised 1, radius 12, a hairline edge and the card's depth, 16 padded; the title in header type with an
/// optional note in mono tertiary beside it.
struct ProjectCard<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.ProjectPage.cardRadius)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).projectType(LoomTheme.ProjectPage.cardTitle).foregroundStyle(LoomTheme.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                trailing.projectType(LoomTheme.ProjectPage.cardNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            content
        }
        .padding(LoomTheme.ProjectPage.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LoomTheme.Surface.card))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.card)
        .accessibilityElement(children: .contain)
    }
}

/// A card's line of text: 12 secondary on 1.5, 8 under the title.
private struct ProjectCardText: View {
    let text: String

    var body: some View {
        Text(text).projectType(LoomTheme.ProjectPage.cardText).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .lineSpacing(LoomTheme.ProjectPage.cardTextSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, LoomTheme.ProjectPage.textTop)
    }
}

/// The words of a preset row's tooltip and label: "Accept edits · Sonnet 5.5", then the message; "All projects" leads for a preset
/// every project shares.
enum ProjectPresetText {
    static func summary(_ preset: NewSessionPreset) -> String {
        [preset.projectID == nil ? "All projects" : nil,
         preset.permissionMode.map(ClaudePermissionMode.title(forRaw:)),
         preset.model.map(NewSessionModels.title(of:))]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    static func tooltip(_ preset: NewSessionPreset) -> String {
        let summary = summary(preset)
        return summary.isEmpty ? preset.message : summary + "\n" + preset.message
    }

    static let empty = "Save a first message as a preset from a new session, and it shows up here."
    static let thisProject = "this project"
}

/// The saved starts for this project (and those for every project). A click opens the project's draft with the preset in it; nothing
/// starts, exactly as in the draft.
private struct ProjectPresetsCard: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let presets = model.presets(for: project.id)
        ProjectCard(title: "Presets") {
            Text(presets.isEmpty ? "" : ProjectPresetText.thisProject)
        } content: {
            if presets.isEmpty {
                ProjectCardText(text: ProjectPresetText.empty)
            } else {
                VStack(spacing: 0) {
                    ForEach(presets) { preset in
                        ProjectPresetRow(model: model, preset: preset, projectID: project.id)
                    }
                }
                .padding(.top, LoomTheme.ProjectPage.presetsTop)
            }
        }
        .accessibilityLabel("Presets")
        .accessibilityIdentifier("project-presets")
    }
}

private struct ProjectPresetRow: View {
    let model: CatalogModel
    let preset: NewSessionPreset
    let projectID: UUID

    var body: some View {
        Button { model.usePreset(preset, projectID: projectID) } label: {
            HStack(spacing: LoomTheme.ProjectPage.presetGap) {
                Image(systemName: ComposerModeLook.symbol(forRaw: preset.permissionMode))
                    .font(LoomTheme.ProjectPage.presetModeGlyph)
                    .foregroundStyle(ComposerModeLook.color(forRaw: preset.permissionMode))
                    .frame(width: LoomTheme.ProjectPage.presetModeBox)
                    .accessibilityHidden(true)
                Text(preset.name).projectType(LoomTheme.ProjectPage.presetName).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if preset.projectID == nil {
                    Text("all").projectType(LoomTheme.ProjectPage.presetAll).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .padding(.horizontal, LoomTheme.ProjectPage.presetAllPadding)
                        .overlay(RoundedRectangle(cornerRadius: LoomTheme.ProjectPage.presetAllRadius)
                            .strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
                        .fixedSize()
                }
                if let alias = preset.model {
                    HStack(spacing: LoomTheme.ProjectPage.presetModelGap) {
                        ProviderIcon(provider: .claude)
                        Text(NewSessionModels.title(of: alias)).projectType(LoomTheme.ProjectPage.presetModel)
                            .foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, LoomTheme.ProjectPage.presetBleed)
            .frame(height: LoomTheme.ProjectPage.presetHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(radius: LoomTheme.ProjectPage.rowRadius, key: "project-preset:\(preset.id)"))
        .focusEffectDisabled()
        // The pill reaches the card's padding, so the row's text keeps its place.
        .padding(.horizontal, -LoomTheme.ProjectPage.presetBleed)
        .contextMenu { Button("Remove Preset") { model.removePreset(preset) } }
        .help(ProjectPresetText.tooltip(preset))
        .accessibilityLabel(([preset.name] + [ProjectPresetText.summary(preset)].filter { !$0.isEmpty }).joined(separator: ", "))
        .accessibilityHint("Opens a new session with this message in it")
        .accessibilityIdentifier("project-preset")
    }
}

/// The words of the past week's card when there are no figures: one line, never two.
enum ProjectUsageText {
    static func line(loading: Bool, failed: Bool) -> String {
        loading ? "Reading usage\u{2026}" : failed ? "Could not read this project's usage." : "No usage in the past 7 days."
    }
}

/// The project's tokens, sessions and estimated cost over the past seven days, from the usage index.
private struct ProjectUsageCard: View {
    let model: CatalogModel

    var body: some View {
        let page = model.projectPage
        ProjectCard(title: "Past 7 days") { EmptyView() } content: {
            if let usage = page.usage, usage.messageCount > 0 {
                HStack(alignment: .top, spacing: LoomTheme.ProjectPage.statGap) {
                    stat(UsageFormat.tokens(usage.tokens.total), "tokens", spoken: "\(UsageFormat.spokenTokens(usage.tokens.total)) tokens")
                    // Only the sessions with usage records in the week, not the page's count of the project's sessions.
                    stat("\(usage.sessionCount)", usage.sessionCount == 1 ? "session with usage" : "sessions with usage",
                         spoken: "\(usage.sessionCount) \(usage.sessionCount == 1 ? "session" : "sessions") with usage")
                    stat(usage.estimatedCostUSD.map(UsageFormat.cost) ?? "\u{2013}", "estimate",
                         spoken: usage.estimatedCostUSD.map { "estimated cost \(UsageFormat.fullCost($0))" } ?? "estimated cost unknown")
                }
                .padding(.top, LoomTheme.ProjectPage.figuresTop)
            } else {
                ProjectCardText(text: ProjectUsageText.line(loading: page.usageLoad == .loading, failed: page.usageFailed))
            }
        }
        .accessibilityLabel("Usage in the past 7 days")
        .accessibilityIdentifier("project-usage")
    }

    private func stat(_ figure: String, _ label: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.ProjectPage.statLabelGap) {
            Text(figure).projectType(LoomTheme.ProjectPage.statFigure).foregroundStyle(LoomTheme.Text.primary).monospacedDigit()
            Text(label).projectType(LoomTheme.ProjectPage.statLabel).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
