import AppKit
import LoomCore
import SwiftUI

public struct SidebarView: View {
    let model: CatalogModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(model: CatalogModel) { self.model = model }

    static func indicatorsAnimate(_ model: CatalogModel) -> Bool {
        model.windowIsActive && !model.sidebarCollapsed
    }

    public var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model)
            SearchField(model: model)
                .padding(.horizontal, LoomTheme.Space.searchInset)
                .padding(.bottom, LoomTheme.Space.searchBottom)
            HomeRow(model: model)
            NewSessionRow(model: model)
            SidebarList(model: model)
            SidebarFooter(model: model)
        }
        .background(SidebarBackground(reduceTransparency: reduceTransparency, style: model.sidebarStyle))
        .ignoresSafeArea(.container, edges: .top)
        .tint(LoomTheme.Accent.base)
        // Indicators stand still while the window is inactive/hidden or the sidebar is collapsed.
        .environment(\.indicatorsAnimate, Self.indicatorsAnimate(model))
    }
}

struct SidebarHeader: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: LoomTheme.Space.headerSpacing) {
            // Full screen has no native window buttons to clear.
            if !model.isFullScreen { Color.clear.frame(width: LoomTheme.Layout.sidebarButtonsGap) }
            Button { model.onToggleSidebar?() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(ChromeButtonStyle())
            .help("Hide Sidebar (⌃⌘S)")
            .accessibilityLabel("Hide sidebar")
            Spacer(minLength: LoomTheme.Space.headerSpacing)
            ModeButton(model: model, mode: .projects, symbol: "folder", help: "Group by project (⌘2)")
            ModeButton(model: model, mode: .activity, symbol: "clock", help: "Sort by recent activity (⌘1)")
            Menu {
                Button("Add Project…") { model.presentAddProject() }
                Divider()
                Button("Group by Project") { model.setViewMode(.projects) }
                Button("Recent Activity") { model.setViewMode(.activity) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize()
            .help("More")
            .accessibilityLabel("More actions")
        }
        .font(LoomTheme.Typography.body)
        .focusEffectDisabled()
        .padding(.horizontal, LoomTheme.Space.headerInset)
        .frame(height: LoomTheme.Layout.headerHeight)
    }
}

struct ModeButton: View {
    let model: CatalogModel
    let mode: CatalogViewMode
    let symbol: String
    let help: String

    var body: some View {
        let selected = model.viewMode == mode
        Button { model.setViewMode(mode) } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(ChromeButtonStyle(selected: selected))
        .help(help)
        .accessibilityLabel(mode == .projects ? "Group by project" : "Recent activity")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Home row under the search field: opens Home and shows how many sessions need the user (the Dock
/// badge's count). It is its own view and reads only the destination and that count, so a selection or a
/// frame that changes neither redraws nothing here.
struct HomeRow: View {
    let model: CatalogModel

    /// "Home, 3 sessions need you"; the count is left out when nothing does.
    static func accessibilityLabel(count: Int) -> String {
        switch count {
        case ..<1: "Home"
        case 1: "Home, 1 session needs you"
        default: "Home, \(count) sessions need you"
        }
    }

    var body: some View {
        let selected = model.destination == .home
        let count = model.attentionCount
        Button { model.showHome() } label: {
            HStack(spacing: LoomTheme.Sidebar.homeRowSpacing) {
                Image(systemName: "house").font(LoomTheme.Sidebar.homeGlyph)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).accessibilityHidden(true)
                Text("Home").font(LoomTheme.Typography.cardTitle(selected: selected))
                    .foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: LoomTheme.Space.headerSpacing)
                if count > 0 { HomeCountBadge(count: count) }
            }
            .padding(.horizontal, LoomTheme.Sidebar.homeRowInset)
            .frame(height: LoomTheme.Sidebar.homeRowHeight)
            .background(SelectedRowBackground(selected: selected, radius: LoomTheme.Radius.search))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.search))
        }
        .buttonStyle(RowButtonStyle()).focusEffectDisabled()
        .padding(.horizontal, LoomTheme.Space.listInset)
        .padding(.bottom, LoomTheme.Sidebar.homeRowBottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(count: count))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .help("Home")
    }
}

/// The New session row under Home (V19): opens the draft page in the most recently used project; the draft's own
/// project picker changes it. It is an action, so it is never drawn selected.
struct NewSessionRow: View {
    let model: CatalogModel

    static let title = "New session"

    var body: some View {
        // Whether Claude can start at all is asked here. A start somewhere else does not matter: the row opens a draft, it
        // starts nothing, and the project is read when the row is clicked.
        let enabled = model.newSessionRowAvailable
        Button { model.beginNewSessionInRecentProject() } label: {
            HStack(spacing: LoomTheme.Sidebar.homeRowSpacing) {
                Image(systemName: "square.and.pencil").font(LoomTheme.Sidebar.homeGlyph)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).accessibilityHidden(true)
                Text(Self.title).font(LoomTheme.Typography.cardTitle(selected: false))
                    .foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: LoomTheme.Space.headerSpacing)
            }
            .padding(.horizontal, LoomTheme.Sidebar.homeRowInset)
            .frame(height: LoomTheme.Sidebar.homeRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.search))
        }
        .buttonStyle(RowButtonStyle()).focusEffectDisabled()
        .disabled(!enabled)
        .padding(.horizontal, LoomTheme.Space.listInset)
        .padding(.bottom, LoomTheme.Sidebar.homeRowBottom)
        .accessibilityLabel(Self.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sidebar-new-session")
        .help("New session in the project you used last (\u{2318}N on Home does the same)")
    }
}

/// The count on the Home row: the light attention text on an attention wash.
struct HomeCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)").font(LoomTheme.Sidebar.badgeFont)
            .foregroundStyle(LoomTheme.Status.attentionLight)
            .padding(.horizontal, LoomTheme.Sidebar.badgePadding)
            .frame(minWidth: LoomTheme.Sidebar.badgeMinWidth, minHeight: LoomTheme.Sidebar.badgeHeight)
            .background(Capsule().fill(LoomTheme.Status.attention.opacity(LoomTheme.Sidebar.badgeWash)))
            .accessibilityHidden(true)
    }
}

/// The fill and hairline of a selected row, the same on a card, a one-line row and the Home row.
struct SelectedRowBackground: View {
    let selected: Bool
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(selected ? LoomTheme.Surface.selected : .clear)
            .overlay(RoundedRectangle(cornerRadius: radius)
                .stroke(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline)
                .opacity(selected ? 1 : 0))
            .animation(LoomTheme.Motion.animation(.selection, reduceMotion: reduceMotion), value: selected)
    }
}

struct SearchField: View {
    let model: CatalogModel
    @FocusState private var focused: Bool

    /// Esc clears a search that has text; with nothing to clear it leaves the field.
    static func escapeClearsSearch(_ text: String) -> Bool { !text.isEmpty }

    var body: some View {
        HStack(spacing: LoomTheme.Space.searchSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(LoomTheme.Text.secondary)
            TextField("Search sessions", text: Binding(
                get: { model.searchText }, set: { model.setSearchText($0) }
            ))
            .textFieldStyle(.plain)
            .foregroundStyle(LoomTheme.Text.primary)
            .focused($focused)
            .onExitCommand {
                if Self.escapeClearsSearch(model.searchText) {
                    model.setSearchText("")
                } else {
                    focused = false
                    // The keyboard goes back to the terminal, not to the bare window.
                    Task { @MainActor in
                        let id = model.selectedSessionID
                        let view = id.flatMap { model.terminalView(for: $0) }
                        (view as? TerminalContainerView)?.focusTerminal()
                    }
                }
            }
            .onChange(of: model.searchFocusRequest) { focused = true }
            .accessibilityLabel("Search sessions")
            if !model.searchText.isEmpty {
                Button { model.setSearchText("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(LoomTheme.Text.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(LoomTheme.Typography.body)
        .padding(.horizontal, LoomTheme.Space.searchPadding)
        .frame(height: LoomTheme.Layout.searchHeight)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.search).fill(LoomTheme.Surface.control))
    }
}

struct SidebarList: View {
    let model: CatalogModel

    // The scroll content is at least as tall as the list, so the empty area below short content
    // belongs to the content and its context menu (a menu on the ScrollView itself is not hit there).
    // Cards and project headers keep their own menus; the innermost one wins.

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LoomTheme.Space.cardGap) {
                        switch model.viewMode {
                        case .activity: ActivityList(model: model)
                        case .projects: ProjectList(model: model)
                        }
                    }
                    .padding(.horizontal, LoomTheme.Space.listInset)
                    .padding(.bottom, LoomTheme.Space.listBottom)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .contextMenu { WithoutProjectStartButton(model: model, title: ClaudeStartEntry.withoutProjectTitle) }
                }
                .scrollContentBackground(.hidden)
                // The selection moved by something other than a click here (a tab, a shortcut, "Show Session"):
                // scroll the least that shows the card, without animation. One turn later, so rows that a
                // project's expansion just loaded are laid out.
                .onChange(of: model.revealRequest) { _, request in
                    guard let id = request?.id else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }
}

struct ActivityList: View {
    let model: CatalogModel

    var body: some View {
        let list = model.list(for: .activity)
        if list.rows.isEmpty {
            DraftRows(model: model)
            EmptyListHint(model: model, isLoaded: list.isLoaded)
        } else {
            // Grouped once per list change, membership flip and calendar day (`model.today`), not once per minute.
            let layout = model.activityLayout()
            let lastRowID = layout.lastRowID
            DraftRows(model: model)
            if !layout.active.isEmpty {
                ActivityHeading {
                    HStack(spacing: LoomTheme.Space.sectionSpacing) {
                        Text("Active").foregroundStyle(LoomTheme.Text.primary)
                        Text("\(layout.active.count)").foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(layout.active) { row in activityEntry(row, lastRowID: lastRowID) }
            }
            ForEach(layout.days) { section in
                ActivityHeading { Text(section.title).foregroundStyle(LoomTheme.Text.secondaryStyle) }
                ForEach(section.rows) { row in activityEntry(row, lastRowID: lastRowID) }
            }
            if list.hasMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(LoomTheme.Space.loadingPadding) }
        }
    }

    /// Paging starts from the last row actually drawn, which may be an Active row.
    private func activityEntry(_ row: SessionRowModel, lastRowID: UUID?) -> some View {
        SessionListEntry(row: row, model: model)
            .id(row.id)
            .onAppear { if row.id == lastRowID { model.loadMore(.activity) } }
    }
}

/// A heading of the activity list, a day or "Active": one font, one trait and the same paddings.
struct ActivityHeading<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(LoomTheme.Typography.dayHeading)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, LoomTheme.Space.sectionInset).padding(.top, LoomTheme.Space.sectionTop).padding(.bottom, LoomTheme.Space.sectionBottom)
    }
}

/// The project view's list. It never reads the drafts itself: typing in a draft changes them on every keystroke,
/// and a body that read them would redraw the whole list each time. The draft rows, and the notes that depend on
/// whether a place has a draft, are children that read them.
struct ProjectList: View {
    let model: CatalogModel

    var body: some View {
        let _ = SidebarRenderProbe.projectList()
        let unassigned = model.list(for: .unassigned)
        let visibleProjects = model.projects.filter {
            !model.isSearching || !model.list(for: .project($0.id)).rows.isEmpty
        }
        if visibleProjects.isEmpty && unassigned.rows.isEmpty {
            EmptyListHint(model: model, isLoaded: model.isReady)
        }
        ForEach(visibleProjects) { project in
            ProjectHeader(model: model, project: project)
            let list = model.list(for: .project(project.id))
            if model.isSearching || !project.collapsed {
                DraftRows(model: model, scope: .project(project.id))
                ForEach(list.rows) { row in
                    SessionListEntry(row: row, model: model)
                        .id(row.id)
                        .onAppear { if row.id == list.rows.last?.id { model.loadMore(.project(project.id)) } }
                }
                if list.rows.isEmpty && list.isLoaded && !model.isSearching {
                    NoSessionsNote(model: model, projectID: project.id)
                }
            }
        }
        if unassigned.rows.isEmpty {
            LoneDraftsSection(model: model)
        } else {
            SectionTitle(title: "Sessions", symbol: "tray")
            DraftRows(model: model, scope: .project(nil))
            ForEach(unassigned.rows) { row in
                SessionListEntry(row: row, model: model)
                    .id(row.id)
                    .onAppear { if row.id == unassigned.rows.last?.id { model.loadMore(.unassigned) } }
            }
        }
    }
}

/// "No sessions" under a project, unless the project has a draft row.
private struct NoSessionsNote: View {
    let model: CatalogModel
    let projectID: UUID

    var body: some View {
        if DraftRows.drafts(in: .project(projectID), of: model).isEmpty {
            Text("No sessions")
                .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                .padding(.horizontal, LoomTheme.Space.emptyNoteInset).padding(.vertical, LoomTheme.Space.emptyNoteVertical)
        }
    }
}

/// The "Sessions" section when only drafts without a project are in it (no session without a project).
private struct LoneDraftsSection: View {
    let model: CatalogModel

    var body: some View {
        if !DraftRows.drafts(in: .project(nil), of: model).isEmpty {
            SectionTitle(title: "Sessions", symbol: "tray")
            DraftRows(model: model, scope: .project(nil))
        }
    }
}

struct SectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: LoomTheme.Space.sectionSpacing) {
            Image(systemName: symbol).foregroundStyle(LoomTheme.Text.secondaryStyle).accessibilityHidden(true)
            Text(title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
            Spacer()
        }
        .padding(.horizontal, LoomTheme.Space.sectionInset).padding(.top, LoomTheme.Space.sectionTop).padding(.bottom, LoomTheme.Space.sectionBottom)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A project's row in the project view, one line. A click on its name opens the project page (concept §3);
/// the chevron beside it expands and collapses the project's sessions, as the whole row did before.
struct ProjectHeader: View {
    let model: CatalogModel
    let project: CatalogProject

    /// A search shows every matching project open, whatever its collapsed flag says.
    static func isExpanded(collapsed: Bool, searching: Bool) -> Bool { searching || !collapsed }

    /// The chevron's value for assistive technologies.
    static func disclosureValue(expanded: Bool) -> String { expanded ? "Expanded" : "Collapsed" }

    var body: some View {
        let count = model.sessionCounts[project.id] ?? 0
        let attention = model.attention(forProject: project.id)
        let index = model.projects.firstIndex { $0.id == project.id } ?? 0
        let expanded = Self.isExpanded(collapsed: project.collapsed, searching: model.isSearching)
        let selected = model.destination == .projectPage(project.id)
        let projectMenuExtra = (ChromeButtonStyle.hitSize(for: LoomTheme.Layout.projectMenuButton).height
                                - LoomTheme.Layout.projectMenuButton.height) / 2
        HStack(spacing: LoomTheme.Space.sectionSpacing) {
            // The row's own button is what the keyboard and VoiceOver operate; a mouse click anywhere
            // on the padded row (the tap gesture below) does the same.
            Button { model.showProjectPage(project.id) } label: {
                HStack(spacing: LoomTheme.Space.sectionSpacing) {
                    Image(systemName: "folder").foregroundStyle(LoomTheme.Text.secondaryStyle)
                    Text(project.name).font(LoomTheme.Typography.bodyStrong)
                        .foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    Spacer(minLength: LoomTheme.Space.headerSpacing)
                    if let attention {
                        Circle().fill(attention.color).frame(width: LoomTheme.Layout.projectDot, height: LoomTheme.Layout.projectDot)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle()).focusEffectDisabled()
            .accessibilityLabel(project.name + (attention.map { ", \($0.label)" } ?? ""))
            .accessibilityHint("Opens the project page")
            .accessibilityAddTraits(selected ? [.isHeader, .isSelected] : .isHeader)
            Button { Task { await model.toggleCollapsed(project.id) } } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(LoomTheme.Typography.chevron)
            }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.projectMenuButton))
            .help(expanded ? "Collapse" : "Expand")
            .accessibilityLabel("Sessions in \(project.name)")
            .accessibilityValue(Self.disclosureValue(expanded: expanded))
            ProjectStartButton(model: model, project: project)
            Menu {
                Button("Move Up") { Task { await model.moveProject(project.id, by: -1) } }
                    .disabled(index == 0)
                Button("Move Down") { Task { await model.moveProject(project.id, by: 1) } }
                    .disabled(index >= model.projects.count - 1)
                Divider()
                if model.projectColorsEnabled {
                    ProjectColorMenu(model: model, project: project)
                    Divider()
                }
                NewConversationButtons(model: model, projectID: project.id, suffix: " Here")
                Divider()
                Button("Remove Empty Project") { Task { await model.removeProject(project.id) } }
                    .disabled(count > 0)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button).buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.projectMenuButton))
            .menuIndicator(.hidden).fixedSize()
            .help(count > 0 ? "Only an empty project can be removed" : "Project actions")
            .accessibilityLabel("Actions for \(project.name)")
        }
        // The open page's fill reaches the row's own padding, so the content keeps its place inside it.
        .padding(.horizontal, LoomTheme.Sidebar.headerFillInset)
        .background(SelectedRowBackground(selected: selected, radius: LoomTheme.Radius.search))
        // The menu button's 24 pt hit area is taller than its 20 pt drawing; the row keeps its height.
        .padding(.horizontal, LoomTheme.Space.sectionInset - LoomTheme.Sidebar.headerFillInset)
        .padding(.top, LoomTheme.Space.sectionTop - projectMenuExtra)
        .padding(.bottom, LoomTheme.Space.sectionBottom - projectMenuExtra)
        .projectStripe(model.projectTone(forProject: project.id),
                       top: LoomTheme.ProjectColor.headerStripeTop, bottom: LoomTheme.ProjectColor.headerStripeBottom)
        .contentShape(Rectangle())
        .onTapGesture { model.showProjectPage(project.id) }
        .contextMenu {
            NewConversationButtons(model: model, projectID: project.id)
            if model.projectColorsEnabled {
                Divider()
                ProjectColorMenu(model: model, project: project)
            }
        }
        .accessibilityElement(children: .contain)
        .help(project.path)
    }
}

struct EmptyListHint: View {
    let model: CatalogModel
    let isLoaded: Bool

    var body: some View {
        VStack(spacing: LoomTheme.Space.hintSpacing) {
            if !isLoaded {
                ProgressView().controlSize(.small)
            } else if model.isSearching {
                Text("No matching sessions").foregroundStyle(LoomTheme.Text.primary)
                Text("Search covers title, provider and project.").foregroundStyle(LoomTheme.Text.secondary)
            } else {
                Text("No sessions yet. Add a project folder to begin.").foregroundStyle(LoomTheme.Text.secondary)
            }
        }
        .font(LoomTheme.Typography.small)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, LoomTheme.Space.hintTop).padding(.horizontal, LoomTheme.Space.sectionInset)
    }
}

/// A card (activity view) or a one-line row (project view) with the subagents of its session below it (D-39).
/// A session without subagents draws exactly the card: the stack holds no second view and adds no space.
struct SessionListEntry: View {
    let row: SessionRowModel
    let model: CatalogModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionCardView(row: row, model: model)
            if let subagents = row.live?.subagents, !subagents.isEmpty {
                SubagentTreeView(sessionID: row.id, records: subagents, model: model)
            }
        }
    }
}

/// The relative time on a card ("5m"), or "Deleting…". The only part of a card that reads the minute tick, so
/// the tick redraws these labels and nothing else of the card. The tooltip comes formatted with the row.
struct CardTimeLabel: View {
    let row: SessionRowModel
    let model: CatalogModel

    static func text(for row: SessionRowModel, deleting: Bool, now: Date) -> String {
        deleting ? "Deleting…" : RelativeTime.string(from: row.record.lastActivityAt, to: now)
    }

    var body: some View {
        let _ = SidebarRenderProbe.timeLabel(row.id)
        Text(Self.text(for: row, deleting: model.isDeleting(row.id), now: model.now))
            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            .help(row.activityTooltip)
    }
}

struct SessionCardView: View {
    let row: SessionRowModel
    let model: CatalogModel
    /// The project name appears on a card only where the card is not already grouped under its project
    /// (activity view). The mode is read from the model inside `body`, not handed down by the list: the
    /// same card ids exist in both views, and a flag passed in kept the value of the view that drew the
    /// card first. The projectless "Sessions" group exists only in the project view, so the mode alone decides.
    static func projectLabel(mode: CatalogViewMode, name: String?) -> String? { mode == .activity ? name : nil }
    static func repeatsProject(mode: CatalogViewMode) -> Bool { mode == .activity }
    /// The project view lists its sessions as calm one-line rows; the activity view keeps the two-row card.
    static func isOneLine(mode: CatalogViewMode) -> Bool { mode == .projects }

    /// What Pin promises. "Out of cleanup" is true only where the cleanup review exists (development
    /// builds); the daily app has none, and pinning never blocks a manual delete.
    static func pinHelp(cleanupReviewOffered: Bool) -> String {
        cleanupReviewOffered
            ? "Keeps this session out of cleanup. Not the same as a pinned tab."
            : "Marks this session with a pin. Not the same as a pinned tab."
    }

    static func pinnedGlyphHelp(cleanupReviewOffered: Bool) -> String {
        cleanupReviewOffered ? "Pinned: kept out of session cleanup" : "Pinned"
    }

    /// "<title>, Claude, Needs approval, <reason>, opened by <requester>, pinned".
    static func accessibilityLabel(title: String, provider: ManagedSession.Provider, status: String?,
                                   reason: String? = nil, origin: SessionOrigin?, pinned: Bool) -> String {
        var parts = [title, ProviderName.title(provider)]
        if let status { parts.append(status) }
        if let reason { parts.append(reason) }
        if let origin { parts.append(origin.accessibilityPhrase) }
        if pinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let _ = SidebarRenderProbe.card(row.id)
        let indicator = row.indicator
        let selected = row.isSelected
        let mode = model.viewMode
        let oneLine = Self.isOneLine(mode: mode)
        let title = model.title(of: row, repeatsProject: Self.repeatsProject(mode: mode))
        let projectName = model.projectName(for: row.record)
        let origin = model.origin(of: row)
        // The reason is read from the row's own property: only this card depends on it.
        // Only a card of the Active section says it; `inActiveSection` is held per row, like the selection.
        // While a search shows the plain result there is no Active section, so no reason line either.
        let reasonLine = row.inActiveSection && !oneLine && !model.isSearching ? SessionReasonLine(row.reason) : nil
        // A click in the list never scrolls it (the card is already under the pointer).
        Button { model.selectFromList(row.id) } label: {
            if oneLine {
                lineLabel(title: title, indicator: indicator, selected: selected)
            } else {
                cardLabel(title: title, indicator: indicator, selected: selected, mode: mode,
                          projectName: projectName, origin: origin, reasonLine: reasonLine)
            }
        }
        .buttonStyle(.plain)
        .projectStripe(model.projectTone(forProject: row.record.projectID))
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTab(row.id, revealInList: false) })
        .contextMenu {
            Button("Rename…") { model.beginRename(row.id) }
            Button("Open in Tab") { model.openTab(row.id, revealInList: false) }.disabled(model.tabs.isPinned(row.id))
            Button(row.record.pinned ? "Unpin" : "Pin") { Task { await model.setPinned(row.id, !row.record.pinned) } }
                .help(Self.pinHelp(cleanupReviewOffered: model.cleanupReview != nil))
            Button("Mark as Read") { model.markRead(row.id) }.disabled(!indicator.canMarkRead)
            Divider()
            Button("Resume") { model.resumeConversation(row.id) }.disabled(!model.canResume(row))
            Button("Stop") { model.stopConversation(row.id) }.disabled(!model.canStop(row))
            SessionLocationMenuItems(row: row)
            DeletionMenuItems(model: model, row: row)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(
            title: title, provider: row.record.session.provider, status: indicator.label,
            reason: reasonLine?.text, origin: origin, pinned: row.record.pinned))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Activity view: the two-row card

    @ViewBuilder
    private func cardLabel(title: String, indicator: SessionIndicator, selected: Bool, mode: CatalogViewMode,
                           projectName: String?, origin: SessionOrigin?, reasonLine: SessionReasonLine?) -> some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.cardSpacing) {
            IndicatorView(indicator: indicator)
                .padding(.top, LoomTheme.Space.cardIndicatorTop)
            VStack(alignment: .leading, spacing: LoomTheme.Space.cardLineSpacing) {
                HStack(spacing: LoomTheme.Space.cardRowSpacing) {
                    Text(title)
                        .font(LoomTheme.Typography.cardTitle(selected: selected))
                        .foregroundStyle(indicator == .stale ? LoomTheme.Text.secondary : LoomTheme.Text.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: LoomTheme.Space.headerSpacing)
                    CardTimeLabel(row: row, model: model)
                }
                HStack(spacing: LoomTheme.Space.cardRowSpacing) {
                    if let reasonLine {
                        // What the session waits for or did last, in place of the branch (the branch is in the header).
                        Text(reasonLine.text)
                            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary).lineLimit(1)
                            .truncationMode(.tail)
                            .help(reasonLine.help)
                    } else if let origin, origin.replacesBranch {
                        // Same branch as the session that opened this one: the origin says more than the branch.
                        Label(origin.cardLabel, systemImage: "arrow.turn.down.right")
                            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary).lineLimit(1)
                            .help(origin.tooltip)
                    } else {
                        Label((model.branches[row.record.session.workingDirectory] ?? .unavailable).label,
                              systemImage: "arrow.triangle.branch")
                            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary).lineLimit(1)
                            .help(origin.map { "Git branch. " + $0.tooltip } ?? "Git branch")
                    }
                    if row.record.pinned {
                        Image(systemName: "pin.fill").font(LoomTheme.Typography.pinGlyph)
                            .foregroundStyle(LoomTheme.Text.secondary)
                            .help(Self.pinnedGlyphHelp(cleanupReviewOffered: model.cleanupReview != nil))
                    }
                    Spacer(minLength: LoomTheme.Space.headerSpacing)
                    if let projectName = SessionCardView.projectLabel(mode: mode, name: projectName) {
                        Text(projectName).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                            .lineLimit(1).layoutPriority(reasonLine == nil ? 0 : 1)
                    }
                    // The reason is the line that gives way: the project and the provider keep their room.
                    ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.providerIconCard)
                        .layoutPriority(reasonLine == nil ? 0 : 1)
                }
            }
        }
        .padding(.horizontal, LoomTheme.Space.cardH).padding(.vertical, LoomTheme.Space.cardV)
        .background(SelectedRowBackground(selected: selected, radius: LoomTheme.Radius.card))
        .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.card))
    }

    // MARK: Project view: the one-line row

    /// Indicator, title and time on one 28 pt line, on the card's leading edge (the subagent guide and the
    /// project stripe keep their places). The branch, the origin and the reason are not drawn here: the
    /// header and the Active section carry them, and the project page lists the rest.
    @ViewBuilder
    private func lineLabel(title: String, indicator: SessionIndicator, selected: Bool) -> some View {
        HStack(spacing: LoomTheme.Space.cardSpacing) {
            IndicatorView(indicator: indicator)
            Text(title)
                .font(selected ? LoomTheme.Typography.bodyStrong : LoomTheme.Typography.body)
                .foregroundStyle(indicator == .stale ? LoomTheme.Text.secondary : LoomTheme.Text.primary)
                .lineLimit(1).truncationMode(.tail)
            if row.record.pinned {
                Image(systemName: "pin.fill").font(LoomTheme.Typography.pinGlyph)
                    .foregroundStyle(LoomTheme.Text.secondary)
                    .help(Self.pinnedGlyphHelp(cleanupReviewOffered: model.cleanupReview != nil))
            }
            Spacer(minLength: LoomTheme.Space.headerSpacing)
            // Claude is the only provider of the daily app; a mark appears only where it tells sessions apart.
            if row.record.session.provider != .claude {
                ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.providerIconCard)
            }
            CardTimeLabel(row: row, model: model)
        }
        .padding(.horizontal, LoomTheme.Space.cardH)
        .frame(height: LoomTheme.Sidebar.lineRowHeight)
        .background(SelectedRowBackground(selected: selected, radius: LoomTheme.Radius.search))
        .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.search))
    }
}

/// The "new conversation" entries of the footer menu, a project's actions menu
/// and a project row's context menu; all go through the model's one start path.
struct NewConversationButtons: View {
    let model: CatalogModel
    let projectID: UUID?
    var suffix = ""

    var body: some View {
        ForEach(NewConversationAction.startable(on: model), id: \.provider) { action in
            Button(action.title + suffix) { action.perform(on: model, projectID: projectID) }
                .disabled(!action.isEnabled(on: model, projectID: projectID))
        }
    }
}

/// The one-click Claude entries outside the per-provider menus: the "+" on a project header and the
/// "no project" entries of the sidebar's empty-area menu and the footer menu. Each goes through the
/// model's one start path (`NewConversationAction.perform`). Claude only (Codex is paused, D-14); there is
/// no entry where Claude cannot be started.
struct ClaudeStartEntry {
    let title: String
    let projectID: UUID?
    private let action: NewConversationAction

    /// One title for every projectless entry: in the project view the empty-area menu also covers
    /// gaps inside a project's group, where a bare "New Claude Session" would read as "in this project".
    static let withoutProjectTitle = "New Claude Session Without Project"

    @MainActor static func inProject(_ project: CatalogProject, on model: CatalogModel) -> ClaudeStartEntry? {
        make(title: "New Claude session in \(project.name)", projectID: project.id, on: model)
    }

    @MainActor static func withoutProject(title: String, on model: CatalogModel) -> ClaudeStartEntry? {
        make(title: title, projectID: nil, on: model)
    }

    @MainActor private static func make(title: String, projectID: UUID?, on model: CatalogModel) -> ClaudeStartEntry? {
        NewConversationAction.startable(on: model).first { $0.provider == .claude }
            .map { ClaudeStartEntry(title: title, projectID: projectID, action: $0) }
    }

    @MainActor func isEnabled(on model: CatalogModel) -> Bool { action.isEnabled(on: model, projectID: projectID) }
    @MainActor func perform(on model: CatalogModel) { action.perform(on: model, projectID: projectID) }
}

/// The "+" on a project header: same hit-target style as the actions button next to it.
struct ProjectStartButton: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        if let entry = ClaudeStartEntry.inProject(project, on: model) {
            Button { entry.perform(on: model) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.projectMenuButton))
            .disabled(!entry.isEnabled(on: model))
            .help(entry.title)
            .accessibilityLabel(entry.title)
        }
    }
}

/// A Claude session without a project (the runtime uses the home folder).
struct WithoutProjectStartButton: View {
    let model: CatalogModel
    let title: String

    var body: some View {
        if let entry = ClaudeStartEntry.withoutProject(title: title, on: model) {
            Button(entry.title) { entry.perform(on: model) }
                .disabled(!entry.isEnabled(on: model))
        }
    }
}

struct NewConversationAction {
    let provider: ManagedSession.Provider
    let title: String

    private static let all = [
        NewConversationAction(provider: .claude, title: "New Claude Session"),
        NewConversationAction(provider: .codex, title: "New Codex Session"),
    ]

    /// The actions the model may start (production: Claude only).
    @MainActor static func startable(on model: CatalogModel) -> [NewConversationAction] {
        all.filter { model.startableProviders.contains($0.provider) }
    }

    @MainActor func perform(on model: CatalogModel, projectID: UUID?) {
        guard isEnabled(on: model, projectID: projectID) else { return }
        // Claude starts from the draft (V07): a session exists only after its first send. Other providers keep
        // their direct start.
        if provider == .claude {
            model.beginNewSession(projectID: projectID)
        } else {
            model.startConversation(provider, projectID: projectID)
        }
    }

    @MainActor func isEnabled(on model: CatalogModel, projectID: UUID?) -> Bool {
        model.canStart(provider, projectID: projectID)
    }
}
