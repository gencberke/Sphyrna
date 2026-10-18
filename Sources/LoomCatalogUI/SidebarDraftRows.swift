import SwiftUI

/// A new-session draft with text, as the sidebar lists it (CHAT-SPEC → Draft session): a one-line row under its
/// project in the project view, and at the top of the activity view. A click opens the draft; Discard throws it away
/// (the × while the pointer is on the row, the context menu, and an accessibility action). An empty draft never gets
/// a row.
struct DraftRow: View {
    let model: CatalogModel
    let draft: SessionDraft
    /// The activity view says which project the draft is in; the project view already groups it.
    var showsProject = false
    @State private var hovering = false

    /// The longest title read; the row shows one line, and a draft can be 128 KiB of one.
    static let maximumTitleLength = 200

    /// The draft's first line, which is what the user typed first. Found by scanning to the first line break (at
    /// most `maximumTitleLength` characters of it), never the whole text: the row redraws on every keystroke.
    static func title(of draft: SessionDraft) -> String {
        let line = draft.text.drop { $0.isWhitespace }.prefix { !$0.isNewline }.prefix(maximumTitleLength)
        let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "New session" : title
    }

    static func accessibilityLabel(title: String, project: String?) -> String {
        "Draft, " + title + (project.map { ", \($0)" } ?? "")
    }

    var body: some View {
        let _ = SidebarRenderProbe.draftRow(draft.id)
        let selected = model.destination == .draft(projectID: draft.projectID)
        let title = Self.title(of: draft)
        let project = model.draftProject(draft.projectID)?.name
        HStack(spacing: LoomTheme.Space.cardSpacing) {
            Color.clear.frame(width: LoomTheme.Layout.indicatorSlot.width, height: LoomTheme.Layout.indicatorSlot.height)
            Button { model.showDraft(projectID: draft.projectID) } label: {
                HStack(spacing: LoomTheme.Space.cardSpacing) {
                    Text(title)
                        .font(selected ? LoomTheme.Typography.bodyStrong : LoomTheme.Typography.body).italic()
                        .foregroundStyle(LoomTheme.Text.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: LoomTheme.Space.headerSpacing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle()).focusEffectDisabled()
            .accessibilityLabel(Self.accessibilityLabel(title: title, project: project))
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction(named: "Discard") { model.discardDraft(projectID: draft.projectID) }
            if hovering {
                Button { model.discardDraft(projectID: draft.projectID) } label: {
                    Image(systemName: "xmark").font(LoomTheme.Typography.chevron)
                }
                .buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.projectMenuButton))
                .help("Discard draft")
                .accessibilityLabel("Discard draft")
            } else {
                Text(showsProject ? [project, "draft"].compactMap { $0 }.joined(separator: " · ") : "draft")
                    .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, LoomTheme.Space.cardH)
        .frame(height: LoomTheme.Sidebar.lineRowHeight)
        .background(SelectedRowBackground(selected: selected, radius: LoomTheme.Radius.search))
        .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.search))
        // The button is what the keyboard operates; a click anywhere on the row does the same.
        .onTapGesture { model.showDraft(projectID: draft.projectID) }
        .onHover { hovering = $0 }
        .projectStripe(model.projectTone(forProject: draft.projectID))
        .contextMenu {
            Button("Open Draft") { model.showDraft(projectID: draft.projectID) }
            Button("Discard Draft") { model.discardDraft(projectID: draft.projectID) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The draft rows of one place in the sidebar: every draft at the top of the activity view (under a "Drafts"
/// heading), or the drafts of one project, or of no project, in the project view. Nothing while a search shows
/// its plain result.
struct DraftRows: View {
    enum Scope: Equatable {
        case all
        case project(UUID?)
    }

    let model: CatalogModel
    var scope = Scope.all

    /// The drafts a scope lists, newest first.
    static func drafts(in scope: Scope, of model: CatalogModel) -> [SessionDraft] {
        guard !model.isSearching else { return [] }
        switch scope {
        case .all: return model.visibleDrafts
        case .project(let id): return model.visibleDrafts.filter { $0.projectID == id }
        }
    }

    var body: some View {
        let drafts = Self.drafts(in: scope, of: model)
        if !drafts.isEmpty {
            if scope == .all {
                ActivityHeading {
                    HStack(spacing: LoomTheme.Space.sectionSpacing) {
                        Text("Drafts").foregroundStyle(LoomTheme.Text.primary)
                        Text("\(drafts.count)").foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ForEach(drafts) { draft in
                // The same draft is drawn by the activity view and by its project; each place is its own row.
                DraftRow(model: model, draft: draft, showsProject: scope == .all)
                    .id("\(scope == .all ? "all" : "project"):\(draft.id)")
            }
        }
    }
}
