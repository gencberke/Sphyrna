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
            SearchDoor(model: model)
            HomeRow(model: model)
            NewSessionRow(model: model)
            SidebarListHeading(model: model)
            SidebarList(model: model)
            SidebarFooter(model: model)
        }
        .background(SidebarBackground(reduceTransparency: reduceTransparency, appearance: model.sidebarAppearance))
        .ignoresSafeArea(.container, edges: .top)
        .tint(LoomTheme.Accent.base)
        // Indicators stand still while the window is inactive/hidden or the sidebar is collapsed.
        .environment(\.indicatorsAnimate, Self.indicatorsAnimate(model))
    }
}

/// The 52 pt header row (DESIGN §2 item 1): the clearance for the native window buttons (none in full screen) and the sidebar
/// toggle at the trailing end. Nothing else: the view's title, its action and the view picker are the list's heading.
struct SidebarHeader: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: LoomTheme.Space.headerSpacing) {
            // Full screen has no native window buttons to clear.
            if !model.isFullScreen { Color.clear.frame(width: LoomTheme.Layout.sidebarButtonsGap) }
            Spacer(minLength: LoomTheme.Space.headerSpacing)
            Button { model.onToggleSidebar?() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(ChromeButtonStyle())
            .help("Hide Sidebar (⌃⌘S)")
            .accessibilityLabel("Hide sidebar")
        }
        .font(LoomTheme.Typography.body)
        .focusEffectDisabled()
        .padding(.leading, LoomTheme.Space.headerInset)
        .padding(.trailing, LoomTheme.Sidebar.headerTrailing)
        .frame(height: LoomTheme.Layout.headerHeight)
    }
}

/// The Home row under the search door: opens Home and shows how many sessions need the user (the Dock
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
                    .frame(width: LoomTheme.Sidebar.homeGlyphColumn)
                Text("Home").font(selected ? LoomTheme.Sidebar.lineTitleSelected : LoomTheme.Sidebar.lineTitle)
                    .foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: LoomTheme.Space.headerSpacing)
                if count > 0 { HomeCountBadge(count: count) }
            }
            .padding(.horizontal, LoomTheme.Sidebar.homeRowInset)
            .frame(height: LoomTheme.Sidebar.homeRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusCompact))
        }
        .buttonStyle(RowButtonStyle(selected: selected, radius: LoomTheme.Highlight.radiusCompact, key: "sidebar-home"))
        .focusEffectDisabled()
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
    static let key = "sidebar-new-session"
    @State private var hovering = false

    /// The key cap at the trailing end, from the command's own key (⌘N), so the cap and the shortcut never differ.
    static var keyHint: String {
        PaletteKeyHint.text(modifiers: ShellCommand.newSession.modifiers, key: ShellCommand.newSession.keyEquivalent)
    }

    /// The row is an action: its text is secondary and takes primary under the pointer (the reference's `.row.act`).
    static func titleIsPrimary(hovering: Bool) -> Bool { hovering }

    var body: some View {
        // Drawn only where the model offers Claude (C2B): switched off, or its CLI not found, the row is not there.
        if model.offersNewSession(.newSessionDefault) { newSessionRow }
    }

    @ViewBuilder private var newSessionRow: some View {
        // Whether Claude can start at all is asked here. A start somewhere else does not matter: the row opens a draft, it
        // starts nothing, and the project is read when the row is clicked.
        let enabled = model.newSessionRowAvailable
        let primary = Self.titleIsPrimary(hovering: hovering || LookEvidence.forcesHover(Self.key))
        Button { model.beginNewSessionInRecentProject() } label: {
            HStack(spacing: LoomTheme.Sidebar.homeRowSpacing) {
                Image(systemName: "plus").font(LoomTheme.Sidebar.newSessionGlyph)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).accessibilityHidden(true)
                    .frame(width: LoomTheme.Sidebar.homeGlyphColumn)
                Text(Self.title).font(LoomTheme.Sidebar.lineTitle)
                    .foregroundStyle(primary ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                Spacer(minLength: LoomTheme.Space.headerSpacing)
                SidebarKeyCap(text: Self.keyHint)
            }
            .padding(.horizontal, LoomTheme.Sidebar.homeRowInset)
            .frame(height: LoomTheme.Sidebar.homeRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusCompact))
        }
        .buttonStyle(RowButtonStyle(radius: LoomTheme.Highlight.radiusCompact, key: Self.key))
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .padding(.horizontal, LoomTheme.Space.listInset)
        .padding(.bottom, LoomTheme.Sidebar.homeRowBottom)
        .accessibilityLabel(Self.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(Self.key)
        .help("New session in the project you used last (\u{2318}N on Home does the same)")
    }
}

/// The count on the Home row: the attention text, in mono, on an attention wash.
struct HomeCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)").font(LoomTheme.Sidebar.badgeFont)
            .foregroundStyle(LoomTheme.Status.attentionLight)
            .padding(.horizontal, LoomTheme.Sidebar.badgePadding)
            .frame(minWidth: LoomTheme.Sidebar.badgeMinWidth, minHeight: LoomTheme.Sidebar.badgeHeight)
            .background(Capsule().fill(LoomTheme.Status.attentionWash))
            .accessibilityHidden(true)
    }
}

struct SidebarList: View {
    let model: CatalogModel
    /// The project view's live reorder (A1): one model for the drag, its measured blocks and the list's own scroll.
    @State private var reorder = ProjectReorderModel()

    // The scroll content is at least as tall as the list, so the empty area below short content
    // belongs to the content and its context menu (a menu on the ScrollView itself is not hit there).
    // Cards and project headers keep their own menus; the innermost one wins.

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LoomTheme.Sidebar.listSpacing) {
                        switch model.viewMode {
                        case .activity: ActivityList(model: model)
                        case .projects: ProjectList(model: model, reorder: reorder)
                        }
                    }
                    .padding(.horizontal, LoomTheme.Space.listInset)
                    .padding(.bottom, LoomTheme.Space.listBottom)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                    .coordinateSpace(.named(ProjectReorderModel.contentSpace))
                    .background(ProjectReorderScrollLocator { reorder.attach($0) }.allowsHitTesting(false))
                    .contentShape(Rectangle())
                    .contextMenu { SidebarEmptySpaceMenu(model: model) }
                }
                .scrollContentBackground(.hidden)
                // The pointer is read in the viewport's coordinates; the blocks are measured in the content's, so the list's
                // own scroll is what ties them together (and what the edge scroll moves under a held pointer).
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    reorder.setContentOffset(offset)
                }
                .overlay(alignment: .topLeading) { ProjectReorderLiftedOverlay(model: model, reorder: reorder) }
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
        .coordinateSpace(.named(ProjectReorderModel.viewportSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { reorder.viewportSize = $0 }
        // Losing the window's key status ends a held drag the way Escape does (A1).
        .onChange(of: model.windowIsActive) { _, active in if !active { reorder.cancel() } }
        .onChange(of: model.projects.map(\.id)) { _, ids in reorder.forget(notIn: Set(ids)) }
        // The list scrolls itself while the pointer stands near its top or bottom edge; the task lives only for the drag.
        .task(id: reorder.dragging) {
            guard reorder.dragging != nil else { return }
            while !Task.isCancelled, reorder.dragging != nil {
                reorder.scrollByEdgeStep()
                try? await Task.sleep(for: ProjectReorder.edgeInterval)
            }
        }
        .onDisappear {
            reorder.cancel()
            reorder.attach(nil)
        }
    }
}

struct ActivityList: View {
    let model: CatalogModel

    var body: some View {
        let list = model.list(for: .activity)
        if list.rows.isEmpty {
            DraftRows(model: model)
            EmptyListHint(isLoaded: list.isLoaded)
        } else {
            // Grouped once per list change, membership flip and calendar day (`model.today`), not once per minute.
            let layout = model.activityLayout()
            let lastRowID = layout.lastRowID
            DraftRows(model: model)
            if !layout.active.isEmpty {
                ActivityHeading(model: model, title: "Active", count: layout.active.count, position: .firstUnlessDrafts)
                ForEach(layout.active) { row in activityEntry(row, lastRowID: lastRowID) }
            }
            ForEach(layout.days) { section in
                ActivityHeading(model: model, title: section.title,
                                position: layout.active.isEmpty && section.id == layout.days.first?.id ? .firstUnlessDrafts : .later)
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

/// A heading of the activity list (Drafts, Active or a day): 11.5 medium tertiary, the count in mono 6 apart. It starts on the
/// status column's left edge, pads 12 above and 5 below, and the list's first heading pads nothing above.
struct ActivityHeading: View {
    /// Where the heading stands in the list.
    enum Position {
        /// The list's first entry: Drafts.
        case first
        /// The first entry unless drafts stand above it: Active, or the first day when nothing is Active.
        case firstUnlessDrafts
        case later
    }

    let model: CatalogModel
    let title: String
    var count: Int?
    var position = Position.later

    /// The padding above a heading; `hasDrafts` matters only for a heading that may follow the drafts.
    static func top(for position: Position, hasDrafts: Bool) -> CGFloat {
        switch position {
        case .first: 0
        case .firstUnlessDrafts: hasDrafts ? LoomTheme.Sidebar.activityHeadingTop : 0
        case .later: LoomTheme.Sidebar.activityHeadingTop
        }
    }

    var body: some View {
        // Only the heading that may follow the drafts reads them, so a keystroke in a draft redraws this line and not the list.
        let hasDrafts = position == .firstUnlessDrafts && !DraftRows.drafts(in: .all, of: model).isEmpty
        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Sidebar.activityHeadingSpacing) {
            Text(title).font(LoomTheme.Sidebar.sectionFont)
            if let count { Text("\(count)").font(LoomTheme.Sidebar.sectionCountFont) }
        }
        .foregroundStyle(LoomTheme.Text.tertiaryStyle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .padding(.leading, LoomTheme.Sidebar.rowLeading).padding(.trailing, LoomTheme.Space.sectionInset)
        .padding(.top, Self.top(for: position, hasDrafts: hasDrafts))
        .padding(.bottom, LoomTheme.Sidebar.activityHeadingBottom)
    }
}

/// The project view's list. It never reads the drafts itself: typing in a draft changes them on every keystroke,
/// and a body that read them would redraw the whole list each time. The draft rows, and the notes that depend on
/// whether a place has a draft, are children that read them.
struct ProjectList: View {
    let model: CatalogModel
    let reorder: ProjectReorderModel

    var body: some View {
        let _ = SidebarRenderProbe.projectList(of: model)
        let unassigned = model.list(for: .unassigned)
        let order = model.projects.map(\.id)
        if model.projects.isEmpty && unassigned.rows.isEmpty {
            EmptyListHint(isLoaded: model.isReady)
        }
        // A project's head, drafts, cards and note are direct children of the list, each a part of the live reorder (A1).
        // A wrapper view around a project's rows would be one child of the list and build every row at once
        // (SidebarPagingTests).
        ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
            let list = model.list(for: .project(project.id))
            let topGap = ProjectHeader.topGap(isFirst: index == 0)
            ProjectHeader(model: model, project: project, reorder: reorder)
                .padding(.top, topGap)
                .projectReorderPart(reorder, project: project.id, part: .head, index: index, order: order, topGap: topGap)
            if !project.collapsed {
                DraftRows(model: model, scope: .project(project.id))
                    .projectReorderPart(reorder, project: project.id, part: .drafts, index: index, order: order)
                ForEach(list.rows) { row in
                    SessionListEntry(row: row, model: model)
                        .projectReorderPart(reorder, project: project.id, part: .session(row.id), index: index, order: order)
                        .id(row.id)
                        .onAppear { if row.id == list.rows.last?.id { model.loadMore(.project(project.id)) } }
                }
                if list.rows.isEmpty && list.isLoaded {
                    NoSessionsNote(model: model, projectID: project.id)
                        .projectReorderPart(reorder, project: project.id, part: .note, index: index, order: order)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// A group's title in the project view where there is no project (the sessions without one): a head of the project heads'
/// shape, with a tray in place of the mark.
struct SectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: LoomTheme.Sidebar.headSpacing) {
            Image(systemName: symbol).foregroundStyle(LoomTheme.Text.secondaryStyle).accessibilityHidden(true)
                .frame(width: LoomTheme.ProjectMarkStyle.Size.head.side)
            Text(title).font(LoomTheme.Sidebar.headName).foregroundStyle(LoomTheme.Text.primary)
            Spacer()
        }
        .padding(.leading, LoomTheme.Sidebar.headLeading)
        .frame(height: LoomTheme.InkHeight.sidebarRow)
        .padding(.top, LoomTheme.Sidebar.groupGap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A project's head in the project view, one 28 pt line: its mark, its name and its attention dot. A click on the name opens
/// the project page (concept §3); the chevron, `+` and ⋯ show while the pointer is on the head or one of them has the keyboard,
/// and stay accessibility actions at all times. The chevron expands and collapses the project's sessions. While its page is
/// open the head takes the neutral selected fill (D-76).
struct ProjectHeader: View {
    let model: CatalogModel
    let project: CatalogProject
    let reorder: ProjectReorderModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var hovering = false
    @FocusState private var focused: Control?
    /// The head's own controls, for the focus that reveals them.
    enum Control: Hashable { case chevron, start, menu }

    /// The chevron's value for assistive technologies.
    static func disclosureValue(expanded: Bool) -> String { expanded ? "Expanded" : "Collapsed" }

    /// Whether the chevron, `+` and ⋯ are drawn: under the pointer, or while one of them has the keyboard.
    static func showsControls(hovering: Bool, focused: Bool) -> Bool { hovering || focused }

    /// The room the three controls keep at the head's trailing end, drawn or not.
    static var controlsWidth: CGFloat { 3 * LoomTheme.Layout.projectMenuButton.width }

    /// How far the attention dot's trailing edge sits from the end of the head's content row: at the head's trailing end at rest,
    /// just before the controls while they are shown.
    static func attentionDotTrailing(showsControls: Bool) -> CGFloat {
        showsControls ? controlsWidth : LoomTheme.Sidebar.headDotTrailing - LoomTheme.Sidebar.headTrailing
    }

    /// The gap above a head.
    static func topGap(isFirst: Bool) -> CGFloat { isFirst ? LoomTheme.Sidebar.firstHeadTop : LoomTheme.Sidebar.groupGap }

    var body: some View {
        let count = model.sessionCounts[project.id] ?? 0
        let attention = model.attention(forProject: project.id)
        let expanded = !project.collapsed
        let selected = model.destination == .projectPage(project.id)
        let key = "sidebar-project:\(project.id)"
        let showsControls = Self.showsControls(hovering: hovering || LookEvidence.forcesHover(key), focused: focused != nil)
        HStack(spacing: 0) {
            // The name is plain content, not a button: a button takes the mouse-down a drag starts with (FB6-4). A click anywhere
            // on the row (the tap gesture below) opens the page, and VoiceOver operates it as a button.
            HStack(spacing: LoomTheme.Sidebar.headSpacing) {
                ProjectMarkView(name: project.name, tone: model.projectTone(forProject: project.id), size: .head)
                Text(project.name).font(LoomTheme.Sidebar.headName)
                    .foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                Spacer(minLength: LoomTheme.Space.headerSpacing)
                // The dot itself is drawn by the overlay below; its room keeps the name from running under it.
                if attention != nil {
                    Color.clear.frame(width: LoomTheme.StatusMark.dot, height: LoomTheme.StatusMark.dot)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(project.name + (attention.map { ", \($0.label)" } ?? ""))
            .accessibilityHint("Opens the project page")
            .accessibilityAddTraits(selected ? [.isButton, .isHeader, .isSelected] : [.isButton, .isHeader])
            .accessibilityAction { model.showProjectPage(project.id) }
            .accessibilityAction(named: "Move Up") { Task { await model.moveProject(project.id, by: -1) } }
            .accessibilityAction(named: "Move Down") { Task { await model.moveProject(project.id, by: 1) } }
            Button { Task { await model.toggleCollapsed(project.id) } } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(LoomTheme.Typography.chevron)
            }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.projectMenuButton))
            .focused($focused, equals: .chevron)
            .revealed(showsControls)
            .help(expanded ? "Collapse" : "Expand")
            .accessibilityLabel("Sessions in \(project.name)")
            .accessibilityValue(Self.disclosureValue(expanded: expanded))
            ProjectStartButton(model: model, project: project)
                .focused($focused, equals: .start)
                .revealed(showsControls)
            // The project menu opens in the window's host (DESIGN §10); the right-click menu below stays native.
            ProjectMenuButton(model: model, project: project, origin: .sidebar,
                              style: ChromeButtonStyle(size: LoomTheme.Layout.projectMenuButton),
                              help: count > 0 ? "Only an empty project can be removed" : "Project actions")
                .revealed(showsControls)
        }
        .overlay(alignment: .trailing) {
            // The name takes the room and the dot stands at the head's trailing end (just before the controls while they show).
            if let attention {
                ProjectAttentionMark(attention: attention, differentiateWithoutColor: differentiateWithoutColor)
                    .padding(.trailing, Self.attentionDotTrailing(showsControls: showsControls))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.leading, LoomTheme.Sidebar.headLeading)
        .padding(.trailing, LoomTheme.Sidebar.headTrailing)
        .frame(height: LoomTheme.InkHeight.sidebarRow)
        .rowPill(selected: selected, radius: LoomTheme.Highlight.radiusCompact, key: key)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.showProjectPage(project.id) }
        // A held head becomes the live reorder after a few points (A1, FB7-3): a click still opens the project page, a right
        // click still opens the menu, and the head's name is still plain content. Move Up and Move Down stay in the menus and
        // are accessibility actions on the head.
        .gesture(
            DragGesture(minimumDistance: LoomTheme.Sidebar.reorderStartDistance,
                        coordinateSpace: .named(ProjectReorderModel.viewportSpace))
                .onChanged { value in
                    if reorder.dragging == nil {
                        reorder.begin(project.id, pointer: value.location, order: model.projects.map(\.id))
                    }
                    reorder.move(pointer: value.location)
                }
                .onEnded { value in
                    reorder.move(pointer: value.location)
                    reorder.end { id, gap in
                        // The released slides hold until the move has run: its new order lands, or it fails (`settle`).
                        Task { @MainActor in
                            await model.endProjectReorder(id, gap: gap)
                            reorder.settle(id)
                        }
                    }
                }
        )
        .contextMenu { ProjectActionsMenu(model: model, project: project) }
        .accessibilityElement(children: .contain)
        .help(project.path)
    }
}

extension View {
    /// Draws a control only while `shown`. At zero opacity SwiftUI drops it from the accessibility tree, so it is said to stay: the
    /// project head's controls are accessibility actions at all times.
    fileprivate func revealed(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).accessibilityHidden(false)
    }
}

/// A project row's attention mark: a dot, or the failure diamond under "Differentiate without color"
/// (the rule is `ProjectAttention.drawsDiamond`, the same one the card's indicator asks).
struct ProjectAttentionMark: View {
    let attention: ProjectAttention
    let differentiateWithoutColor: Bool

    var body: some View {
        if ProjectAttention.drawsDiamond(attention, differentiateWithoutColor: differentiateWithoutColor) {
            Diamond().fill(attention.color)
                .frame(width: LoomTheme.Layout.failureDiamond, height: LoomTheme.Layout.failureDiamond)
                .frame(width: LoomTheme.StatusMark.dot, height: LoomTheme.StatusMark.dot)
        } else {
            Circle().fill(attention.color).frame(width: LoomTheme.StatusMark.dot, height: LoomTheme.StatusMark.dot)
        }
    }
}

struct EmptyListHint: View {
    let isLoaded: Bool

    var body: some View {
        VStack(spacing: LoomTheme.Space.hintSpacing) {
            if !isLoaded {
                ProgressView().controlSize(.small)
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

/// A session's card with the subagents of its session below it (D-39).
/// A session without subagents draws exactly the card: the stack holds no second view and adds no space.
struct SessionListEntry: View {
    let row: SessionRowModel
    let model: CatalogModel
    var body: some View {
        let subagents = row.live?.subagents ?? []
        VStack(alignment: .leading, spacing: 0) {
            SessionCardView(row: row, model: model)
                .overlay {
                    // A card is taller than a 28 pt row: its line leaves the status mark inside it (DESIGN §4).
                    if !subagents.isEmpty {
                        SubagentTrunkShape()
                            .stroke(LoomTheme.Surface.tree, style: StrokeStyle(lineWidth: LoomTheme.Branches.lineWidth))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            if !subagents.isEmpty {
                SubagentTreeView(sessionID: row.id, records: subagents, model: model, waiting: SubagentWaiting.ids(in: row.live))
            }
        }
    }
}

/// The relative time on a row or card ("5m"), or "Deleting…", in mono 11. The only part of a card that reads the minute tick, so
/// the tick redraws these labels and nothing else of the card. The tooltip comes formatted with the row.
struct CardTimeLabel: View {
    let row: SessionRowModel
    let model: CatalogModel
    /// A selected row on its project's tint reads the time in secondary: tertiary is not promised on a tint.
    var onTint = false

    static func text(for row: SessionRowModel, deleting: Bool, now: Date) -> String {
        deleting ? "Deleting…" : RelativeTime.string(from: row.record.lastActivityAt, to: now)
    }

    var body: some View {
        let _ = SidebarRenderProbe.timeLabel(row.id)
        Text(Self.text(for: row, deleting: model.isDeleting(row.id), now: model.now))
            .font(LoomTheme.Sidebar.timeFont)
            .foregroundStyle(onTint ? LoomTheme.Text.secondaryStyle : LoomTheme.Text.tertiaryStyle)
            .help(row.activityTooltip)
    }
}

/// The harness's mark on a card or a row: 12 pt, one leading edge with the title and the lines under it at 20 (FB6-2).
struct HarnessMark: View {
    let provider: ManagedSession.Provider

    var body: some View {
        ProviderIcon(provider: provider)
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
        let title = model.title(of: row, repeatsProject: Self.repeatsProject(mode: mode))
        let projectName = model.projectName(for: row.record)
        let origin = model.origin(of: row)
        // The selected row takes its project's tint; no tone (None, no project, colours off) keeps the neutral fill.
        let tone = model.projectTone(forProject: row.record.projectID)
        let onTint = selected && tone != nil
        // The reason is read from the row's own property: only this card depends on it.
        // Only a card of the Active section says it; `inActiveSection` is held per row, like the selection.
        let reasonLine = row.inActiveSection ? SessionReasonLine(row.reason) : nil
        // A click in the list never scrolls it (the card is already under the pointer).
        Button { model.selectFromList(row.id) } label: {
            cardLabel(title: title, indicator: indicator, selected: selected, mode: mode, projectName: projectName,
                      origin: origin, reasonLine: reasonLine, onTint: onTint)
        }
        .buttonStyle(RowButtonStyle(selected: selected, radius: LoomTheme.Highlight.radius,
                                    key: "sidebar-card:\(row.id)", tint: tone))
        .focusEffectDisabled()
        // Resting on the row peeks at its last ask and answer, in its tooltip.
        .modifier(SidebarPeekHover(record: row.record, model: model))
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTab(row.id, revealInList: false) })
        // Dropped on the tab strip it opens there (U4).
        .sessionDragSource(row.id, title: title)
        .contextMenu {
            Button("Rename…") { model.beginRename(row.id) }
            Button("Open in Tab") { model.openTab(row.id, revealInList: false) }.disabled(model.tabs.isPinned(row.id))
            Button(row.record.pinned ? "Unpin" : "Pin") { Task { await model.setPinned(row.id, !row.record.pinned) } }
                .help(Self.pinHelp(cleanupReviewOffered: model.cleanupReview != nil))
            Button("Mark as Read") { model.markRead(row.id) }.disabled(!indicator.canMarkRead)
            Divider()
            Button("Resume") { model.resumeConversation(row.id) }.disabled(!model.canResume(row))
            Button("Stop") { model.stopConversation(row.id) }.disabled(!model.canStop(row))
            SessionLocationMenuItems(row: row, model: model)
            DeletionMenuItems(model: model, row: row)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(
            title: title, provider: row.record.session.provider, status: indicator.label,
            reason: reasonLine?.text, origin: origin, pinned: row.record.pinned))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: The card, in three layers (RESCUE C3)

    /// Top: the status column, then in the activity view the project (its colour mark while project colours are on) and in the
    /// project view the harness's mark and the model, then the time. Middle: the title, and only in the Active section the reason
    /// under it. Bottom: the branch (or the origin) and the pin, and in the activity view the harness's mark and the model at the
    /// trailing end. Every line after the status column starts at the same indent.
    @ViewBuilder
    private func cardLabel(title: String, indicator: SessionIndicator, selected: Bool, mode: CatalogViewMode,
                           projectName: String?, origin: SessionOrigin?, reasonLine: SessionReasonLine?,
                           onTint: Bool) -> some View {
        let quiet = onTint ? LoomTheme.Text.secondaryStyle : LoomTheme.Text.tertiaryStyle
        VStack(alignment: .leading, spacing: LoomTheme.Space.cardLineSpacing) {
            HStack(spacing: LoomTheme.Space.cardSpacing) {
                IndicatorView(indicator: indicator)
                Group {
                    if mode == .activity {
                        projectLine(name: SessionCardView.projectLabel(mode: mode, name: projectName))
                    } else {
                        CardModelLabel(row: row, model: model, spacing: LoomTheme.Space.cardSpacing)
                    }
                }
                .foregroundStyle(quiet)
                Spacer(minLength: LoomTheme.Space.headerSpacing)
                CardTimeLabel(row: row, model: model, onTint: onTint)
            }
            titleText(title, indicator: indicator, selected: selected)
                .padding(.leading, LoomTheme.Sidebar.cardTextIndent)
            if let reasonLine {
                // What the session waits for or did last: its own line under the title (D-69), so the card is one line taller
                // while it needs the user. A command is mono.
                reasonText(reasonLine)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, LoomTheme.Sidebar.cardTextIndent)
                    .help(reasonLine.help)
            }
            HStack(spacing: LoomTheme.Sidebar.metaSpacing) {
                branchLabel(origin: origin)
                if row.record.pinned {
                    Image(systemName: "pin.fill").font(LoomTheme.Typography.pinGlyph)
                        .help(Self.pinnedGlyphHelp(cleanupReviewOffered: model.cleanupReview != nil))
                }
                Spacer(minLength: LoomTheme.Space.headerSpacing)
                if mode == .activity { CardModelLabel(row: row, model: model) }
            }
            .foregroundStyle(quiet)
            .padding(.leading, LoomTheme.Sidebar.cardTextIndent)
        }
        .padding(.leading, LoomTheme.Sidebar.rowLeading).padding(.trailing, LoomTheme.Space.cardH)
        .padding(.top, LoomTheme.Sidebar.cardTop).padding(.bottom, LoomTheme.Sidebar.cardBottom)
        .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radius))
    }

    /// The activity card's top line: the project's colour mark (while project colours are on) and its name; nothing for a
    /// session without a project.
    @ViewBuilder
    private func projectLine(name: String?) -> some View {
        HStack(spacing: LoomTheme.Space.cardSpacing) {
            if let name {
                // The mark stands in the harness's column, so the name starts where the title does.
                Group {
                    if model.projectColorsEnabled {
                        ProjectMarkView(name: name, tone: model.projectTone(forProject: row.record.projectID), size: .card)
                    }
                }
                .frame(width: LoomTheme.Sidebar.markSlot, alignment: .leading)
                Text(name).font(LoomTheme.Sidebar.metaFont).lineLimit(1)
            }
        }
    }

    /// The branch of the session's folder, or the origin where it says more (the same branch as the session that opened it).
    @ViewBuilder
    private func branchLabel(origin: SessionOrigin?) -> some View {
        if let origin, origin.replacesBranch {
            Label(origin.cardLabel, systemImage: "arrow.turn.down.right")
                .font(LoomTheme.Sidebar.metaFont).lineLimit(1)
                .help(origin.tooltip)
        } else {
            Label {
                Text((model.branches[row.record.session.workingDirectory] ?? .unavailable).label)
                    .font(LoomTheme.Sidebar.metaMonoFont)
            } icon: {
                Image(systemName: "arrow.triangle.branch").font(LoomTheme.Sidebar.metaGlyph)
            }
            .lineLimit(1)
            .help(origin.map { "Git branch. " + $0.tooltip } ?? "Git branch")
        }
    }

    private func titleText(_ title: String, indicator: SessionIndicator, selected: Bool) -> some View {
        Text(title)
            .font(selected ? LoomTheme.Sidebar.lineTitleSelected : LoomTheme.Sidebar.lineTitle)
            .foregroundStyle(indicator == .stale ? LoomTheme.Text.secondary : LoomTheme.Text.primary)
            .lineLimit(1).truncationMode(.tail)
    }

    private func reasonText(_ line: SessionReasonLine) -> some View {
        Group {
            if let mono = line.mono {
                Text("\(Text(line.lead).font(LoomTheme.Sidebar.reasonFont))\(Text(mono).font(LoomTheme.Sidebar.reasonMonoFont))")
            } else {
                Text(line.text).font(LoomTheme.Sidebar.reasonFont)
            }
        }
    }
}

/// The "new conversation" entries of the footer menu; all go through the model's one start path (a project's menu lists the same
/// entries through `ProjectActionsMenu`). Codex is listed in every build (D-69); where the build cannot start it the entry is
/// disabled and followed by the reason.
struct NewConversationButtons: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        ForEach(NewConversationAction.listed(on: model), id: \.provider) { action in
            Button { action.perform(on: model, projectID: projectID) } label: {
                HarnessMenuLabel(provider: action.provider, title: action.title)
            }
            .disabled(!action.isEnabled(on: model, projectID: projectID))
            if let reason = action.unavailableReason(on: model) { Text(reason) }
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
        NewConversationAction.startable(on: model).first { $0.provider == .newSessionDefault }
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
            Button { entry.perform(on: model) } label: {
                HarnessMenuLabel(provider: .newSessionDefault, title: entry.title)
            }
            .disabled(!entry.isEnabled(on: model))
        }
    }
}

struct NewConversationAction {
    let provider: ManagedSession.Provider
    let title: String

    private static let all = [
        NewConversationAction(provider: .newSessionDefault, title: "New Claude Session"),
        NewConversationAction(provider: .codex, title: "New Codex Session"),
    ]

    /// The actions the model may start now: the build's, narrowed by the connect switch and the CLI (C2B).
    @MainActor static func startable(on model: CatalogModel) -> [NewConversationAction] {
        all.filter { model.capabilities(of: $0.provider).startable }
    }

    /// The entries a menu lists (C2B): the harnesses that are switched on and can start, or say why they cannot. So Codex stays
    /// listed, disabled, where this build cannot start it or its CLI is not found; a switched-off harness is not listed.
    @MainActor static func listed(on model: CatalogModel) -> [NewConversationAction] {
        all.filter { model.offersNewSession($0.provider) }
    }

    /// Why this entry is disabled now (`CatalogModel.startUnavailableReason`); nil when it starts.
    @MainActor func unavailableReason(on model: CatalogModel) -> String? {
        model.startUnavailableReason(provider)
    }

    @MainActor func perform(on model: CatalogModel, projectID: UUID?) {
        guard isEnabled(on: model, projectID: projectID) else { return }
        // A harness with a structured face starts from the draft (V07): a session exists only after its first send. Other
        // providers keep their direct start.
        if model.capabilities(of: provider).structuredFace {
            model.beginNewSession(projectID: projectID)
        } else {
            model.startConversation(provider, projectID: projectID)
        }
    }

    @MainActor func isEnabled(on model: CatalogModel, projectID: UUID?) -> Bool {
        model.canStart(provider, projectID: projectID)
    }
}
