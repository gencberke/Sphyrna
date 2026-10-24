import LoomCore
import SwiftUI

// Remora's brief on the new-session page (DESIGN §8, D-80): the row under the presets and the line above the composer. The row's
// click is the page's one call of the model's Draft Brief API (`RemoraReachTests` counts it here). Nothing here sends: the brief
// lands in the draft's text by Put in Draft's rule (`CatalogModel.landRemoraDraft`), and only the composer's own ↵ starts the
// session.

private typealias D = LoomTheme.Draft
private typealias R = LoomTheme.Remora

/// "Remora can write this session's brief from loom's recent work." with Draft Brief; then the reading line with the spinner and
/// Stop; then "Remora drafted the brief above…" with the time and Draft Again. No row with Remora off, for an excluded project and
/// before the project's first session.
struct DraftRemoraRowView: View {
    let model: CatalogModel
    let projectID: UUID?
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate
    @State private var sourcesOpen = false

    var body: some View {
        if let projectID, let row = model.draftRemoraRow(projectID: projectID) {
            HStack(spacing: D.remoraGap) {
                if row.showsSpinner {
                    // Its own height: an NSView in a row with no height of its own would take the column's.
                    BrailleSpinner(animating: indicatorsAnimate)
                        .frame(width: LoomTheme.Layout.indicatorSlot.width, height: LoomTheme.Layout.indicatorSlot.height)
                        .accessibilityHidden(true)
                }
                Text(row.text).draftType(D.remoraText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .accessibilityIdentifier("draft-remora-text")
                if let time = row.time {
                    Text(time).draftType(D.remoraMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle).fixedSize()
                        .accessibilityIdentifier("draft-remora-time")
                }
                if row.showsSources, let origin = model.newSession.remoraOrigin(for: projectID) {
                    DraftRemoraSourcesLink(model: model, isOpen: $sourcesOpen, citedSessionIDs: origin.citedSessionIDs,
                                           sessionsRead: origin.sessionsRead, duration: origin.duration)
                        .draftType(D.remoraMeta)
                }
                Button(row.actionTitle) { act(row.action, projectID: projectID) }
                    .buttonStyle(ControlButtonStyle(kind: row.action == .draft ? .secondary : .ghost, size: .small))
                    .disabled(!row.actionEnabled)
                    .fixedSize()
                    .accessibilityIdentifier(Self.identifier(row.action))
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, D.remoraTop)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("draft-remora")
        }
    }

    static func identifier(_ action: DraftRemoraRow.Action) -> String {
        switch action {
        case .draft: "draft-remora-draft"
        case .stop: "draft-remora-stop"
        case .draftAgain: "draft-remora-again"
        }
    }

    private func act(_ action: DraftRemoraRow.Action, projectID: UUID) {
        switch action {
        case .stop:
            model.stopRemora()
        case .draft, .draftAgain:
            model.noteRemoraDraftClick(projectID: projectID)
            Task { @MainActor in
                if !(await model.draftRemoraBrief(project: projectID)) { model.forgetRemoraDraftClick(projectID: projectID) }
            }
        }
    }
}

/// "Remora's draft" and "from 3 sessions in loom · not sent", with Sources and Clear, above the composer while its text is the brief
/// Remora placed.
struct DraftRemoraOriginView: View {
    let model: CatalogModel
    let projectID: UUID?
    let line: DraftRemoraOriginLine
    @State private var sourcesOpen = false

    var body: some View {
        HStack(spacing: D.originGap) {
            Text(line.title).draftType(D.originTitle).foregroundStyle(LoomTheme.Text.secondaryStyle).fixedSize()
            Text(line.detail).draftType(D.originDetail).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("draft-remora-origin-detail")
            DraftRemoraSourcesLink(model: model, isOpen: $sourcesOpen, citedSessionIDs: line.citedSessionIDs,
                                   sessionsRead: line.sessionsRead, duration: line.duration)
                .draftType(D.originDetail)
            HomeRemoraLink(title: DraftRemoraText.clear, identifier: "draft-remora-clear") {
                if let projectID { model.clearRemoraDraft(projectID: projectID) }
            }
            .draftType(D.originDetail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, D.originInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-remora-origin")
    }
}

/// Sources: a popover that lists the sessions the brief cites, each with its age; a click opens the session.
struct DraftRemoraSourcesLink: View {
    let model: CatalogModel
    @Binding var isOpen: Bool
    let citedSessionIDs: [UUID]
    let sessionsRead: Int
    let duration: TimeInterval?

    var body: some View {
        HomeRemoraLink(title: DraftRemoraText.sources, identifier: "draft-remora-sources") { isOpen.toggle() }
            .inkPopover(isPresented: $isOpen, id: "draft-remora-sources", label: HomeRemoraText.sourcesLabel(brief: true),
                        side: .below, alignment: .leading) {
                DraftRemoraSourcesView(model: model, citedSessionIDs: citedSessionIDs, sessionsRead: sessionsRead,
                                       duration: duration, close: { isOpen = false })
            }
    }
}

/// The cited sessions, read from the catalog when the popover opens (a deleted or excluded one is not named), in Home's Sources look.
struct DraftRemoraSourcesView: View {
    let model: CatalogModel
    let citedSessionIDs: [UUID]
    let sessionsRead: Int
    let duration: TimeInterval?
    let close: () -> Void
    @State private var sessions: [HomeRemoraSession] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomeRemoraText.sourcesLabel(brief: true)).homeType(LoomTheme.InkType.label).textCase(.uppercase)
                .foregroundStyle(LoomTheme.OnPopover.placeholder)
                .padding(.horizontal, R.sourcesLabelAside).padding(.top, R.sourcesLabelTop).padding(.bottom, R.sourcesLabelBottom)
                .accessibilityAddTraits(.isHeader)
            ForEach(sessions) { session in
                Button {
                    model.select(session.id)
                    close()
                } label: {
                    HStack(spacing: R.sourcesRowGap) {
                        Group {
                            if let name = session.projectName { ProjectMarkView(name: name, tone: session.tone, size: .chip) } else { Color.clear }
                        }
                        .frame(width: R.sourcesMarkColumn).accessibilityHidden(true)
                        Text(session.title).homeType(R.sourcesText).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(RelativeTime.string(from: session.lastActivityAt, to: model.now)).homeType(R.sourcesMeta)
                            .foregroundStyle(LoomTheme.OnPopover.placeholder)
                    }
                    .padding(.horizontal, R.sourcesRowPadding)
                    .frame(height: R.sourcesRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(session.title), \(RelativeTime.string(from: session.lastActivityAt, to: model.now))")
            }
            Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
                .padding(.top, R.sourcesFootTop).padding(.horizontal, -R.sourcesInset)
            Text(DraftRemoraText.sourcesFoot(sessionsRead: sessionsRead, duration: duration))
                .homeType(R.sourcesMeta).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .padding(.horizontal, R.sourcesFootH - R.sourcesInset).padding(.top, R.sourcesFootV)
        }
        .padding(R.sourcesInset)
        .frame(width: R.sourcesWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .task { await read() }
    }

    private func read() async {
        guard let catalog = model.catalog else { return }
        let excluded = model.remora.preferences.excludedProjects
        var found: [HomeRemoraSession] = []
        for id in citedSessionIDs {
            guard let record = try? await catalog.listedSession(id: id), let session = model.homeRemoraSession(record) else { continue }
            if let project = session.projectID, excluded.contains(project) { continue }
            found.append(session)
        }
        sessions = found.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
