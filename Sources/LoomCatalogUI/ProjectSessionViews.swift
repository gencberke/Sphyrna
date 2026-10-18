import Foundation
import LoomCore
import SwiftUI

/// What the Sessions tab draws and where (pure, so a test reads it): the cards of the side column. Wide:
/// Presets and the past week beside the list. Narrow: the list, then the cards under it, and no Presets card
/// while there is no preset to show.
enum ProjectSessionsLayout {
    enum Card: Hashable { case presets, usage }

    static func sideCards(wide: Bool, hasPresets: Bool) -> [Card] {
        wide || hasPresets ? [.presets, .usage] : [.usage]
    }
}

/// The Sessions tab: the project's sessions with their last line, and beside them (or, in a narrow pane,
/// under them) the presets and the past week's usage.
struct ProjectSessionsTab: View {
    let model: CatalogModel
    let project: CatalogProject
    let wide: Bool

    var body: some View {
        let cards = ProjectSessionsLayout.sideCards(wide: wide, hasPresets: !model.presets(for: project.id).isEmpty)
        if wide {
            HStack(alignment: .top, spacing: LoomTheme.ProjectPage.columnGap) {
                ProjectSessionList(model: model, project: project)
                VStack(spacing: LoomTheme.ProjectPage.cardGap) { sideCards(cards) }
                    .frame(width: LoomTheme.ProjectPage.sideColumn)
            }
        } else {
            VStack(alignment: .leading, spacing: LoomTheme.ProjectPage.cardGap) {
                ProjectSessionList(model: model, project: project)
                sideCards(cards)
            }
        }
    }

    @ViewBuilder private func sideCards(_ cards: [ProjectSessionsLayout.Card]) -> some View {
        ForEach(cards, id: \.self) { card in
            switch card {
            case .presets: ProjectPresetsCard(model: model, project: project)
            case .usage: ProjectUsageCard(model: model)
            }
        }
    }
}

/// One row per session, newest activity first. Rows are lazy: a row's last line is read only once it is
/// drawn, so a long list costs nothing for the part nobody scrolled to.
private struct ProjectSessionList: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let page = model.projectPage
        VStack(alignment: .leading, spacing: 0) {
            if page.records.isEmpty {
                if page.sessionsFailed {
                    Text("Could not read this project's sessions.")
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .padding(LoomTheme.ProjectPage.noticePadding)
                        .accessibilityIdentifier("project-sessions-failed")
                } else if page.sessionsLoad == .done {
                    Text("No sessions in this project yet. New session starts one.")
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .padding(LoomTheme.ProjectPage.noticePadding)
                        .accessibilityIdentifier("project-no-sessions")
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(page.records.enumerated()), id: \.element.session.id) { index, record in
                        if index > 0 {
                            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                        }
                        ProjectSessionRow(model: model, record: record)
                    }
                }
                if page.hasMore {
                    Button { model.loadMoreProjectSessions() } label: {
                        Text(page.isLoadingMore ? "Loading\u{2026}" : "Show more sessions")
                    }
                    .buttonStyle(ChipButtonStyle()).disabled(page.isLoadingMore)
                    .padding(.top, LoomTheme.ProjectPage.cardGap)
                    .accessibilityIdentifier("project-more-sessions")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }
}

/// A session: indicator, title with its last line, branch, time. A click shows the session.
private struct ProjectSessionRow: View {
    let model: CatalogModel
    let record: CatalogSession
    @State private var hovering = false
    @State private var rowWidth = LoomTheme.ProjectPage.rowBranchBreakpoint

    var body: some View {
        // The live state is read here so a status change redraws this row; the transcript is not.
        _ = model.liveRevision
        let id = record.session.id
        let live = model.liveStates[id]
        let indicator = SessionIndicator(
            record: record, live: live, awaitingOpenApproval: model.awaitingOpenApproval.contains(id))
        let reason = live?.displayReason
        let line = ProjectSessionLine.text(reason: reason, transcript: model.projectPage.lastLines[id])
        let branch = model.branches[record.session.workingDirectory]
        let time = RelativeTime.string(from: record.lastActivityAt, to: model.now)
        let showsBranch = rowWidth >= LoomTheme.ProjectPage.rowBranchBreakpoint
        return Button { model.select(id) } label: {
            HStack(alignment: .top, spacing: LoomTheme.ProjectPage.rowColumnGap) {
                IndicatorView(indicator: indicator)
                    .frame(width: LoomTheme.Layout.indicatorSlot.width, height: LoomTheme.Layout.indicatorSlot.height)
                    .padding(.top, LoomTheme.Space.cardIndicatorTop)
                VStack(alignment: .leading, spacing: LoomTheme.ProjectPage.rowLineGap) {
                    Text(record.displayTitle(projectName: nil, repeatsProject: false))
                        .font(LoomTheme.ProjectPage.rowTitle)
                        .foregroundStyle(indicator == .stale ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.primary))
                        .lineLimit(1).truncationMode(.tail)
                    if let line {
                        Text(line).font(LoomTheme.ProjectPage.rowLine).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(1).truncationMode(.tail)
                            .accessibilityIdentifier("project-session-line")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsBranch, let branch, branch != .unavailable {
                    HStack(spacing: LoomTheme.Header.chipBranchGap) {
                        Image(systemName: "arrow.triangle.branch").font(LoomTheme.ProjectPage.branchGlyph)
                        Text(branch.label).lineLimit(1).truncationMode(.middle)
                    }
                    .font(LoomTheme.ProjectPage.rowBranch).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.ProjectPage.rowBranchWidth, alignment: .leading)
                }
                Text(time).font(LoomTheme.ProjectPage.rowTime).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.ProjectPage.rowTimeWidth, alignment: .trailing)
            }
            .padding(.horizontal, LoomTheme.ProjectPage.rowPaddingH).padding(.vertical, LoomTheme.ProjectPage.rowPaddingV)
            .background(RoundedRectangle(cornerRadius: LoomTheme.ProjectPage.rowRadius)
                .fill(hovering ? LoomTheme.Surface.control : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.ProjectPage.rowRadius))
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        // A last line from the transcript is read only for a row that is drawn and holds no line of its own.
        .task(id: ProjectSessionLine.holdsLine(reason)) {
            if !ProjectSessionLine.holdsLine(reason) { await model.loadProjectLastLine(record) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([record.displayTitle(projectName: nil, repeatsProject: false), line, time].compactMap { $0 }
            .joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("project-session-row")
    }
}

/// A card of the side column: a title and its rows.
struct ProjectCard<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.requestListSpacing) {
            HStack {
                Text(title).font(LoomTheme.ProjectPage.cardTitle).foregroundStyle(LoomTheme.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                trailing.font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            content
        }
        .padding(LoomTheme.ProjectPage.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.card).fill(LoomTheme.Surface.card))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.card)
            .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// The saved starts for this project (and those for every project). A click opens the project's draft with the
/// preset in it; nothing starts, exactly as in the draft.
private struct ProjectPresetsCard: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let presets = model.presets(for: project.id)
        ProjectCard(title: "Presets") {
            Text(presets.isEmpty ? "" : "this project")
        } content: {
            if presets.isEmpty {
                Text("Save a first message as a preset from a new session, and it shows up here.")
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(presets) { preset in
                    ProjectPresetRow(model: model, preset: preset, projectID: project.id)
                }
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
    @State private var hovering = false

    var body: some View {
        let mode = preset.permissionMode.flatMap { ClaudePermissionMode(rawValue: $0)?.title }
        Button { model.usePreset(preset, projectID: projectID) } label: {
            HStack(spacing: LoomTheme.Space.chipInset) {
                Image(systemName: preset.permissionMode == ClaudePermissionMode.plan.rawValue ? "list.bullet.rectangle" : "play")
                    .font(LoomTheme.ProjectPage.cardRowGlyph).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.Layout.indicatorSlot.width)
                Text(preset.name).font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                if let mode {
                    Text(mode).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                }
            }
            .frame(minHeight: LoomTheme.ProjectPage.cardRowHeight)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                .fill(hovering ? LoomTheme.Surface.control : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove Preset") { model.removePreset(preset) } }
        .help(preset.message)
        .accessibilityLabel([preset.name, mode].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens a new session with this message in it")
        .accessibilityIdentifier("project-preset")
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
            } else {
                Text(page.usageLoad == .loading ? "Reading usage\u{2026}"
                     : page.usageFailed ? "Could not read this project's usage."
                     : model.usage == nil ? "No usage index is available." : "No usage in the past 7 days.")
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
        .accessibilityLabel("Usage in the past 7 days")
        .accessibilityIdentifier("project-usage")
    }

    private func stat(_ figure: String, _ label: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.ProjectPage.statLabelGap) {
            Text(figure).font(LoomTheme.ProjectPage.statFigure).foregroundStyle(LoomTheme.Text.primary).monospacedDigit()
            Text(label).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
