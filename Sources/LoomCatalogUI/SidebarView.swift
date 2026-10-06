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
            SidebarList(model: model)
            SidebarFooter(model: model)
        }
        .background(SidebarBackground(reduceTransparency: model.sidebarTransparencyOverride ?? reduceTransparency))
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
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

struct SearchField: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: LoomTheme.Space.searchSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(LoomTheme.Text.secondary)
            TextField("Search conversations", text: Binding(
                get: { model.searchText }, set: { model.setSearchText($0) }
            ))
            .textFieldStyle(.plain)
            .foregroundStyle(LoomTheme.Text.primary)
            .accessibilityLabel("Search conversations")
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

struct SidebarFooter: View {
    let model: CatalogModel

    var body: some View {
        HStack {
            Menu {
                NewConversationButtons(model: model, projectID: model.contextProjectID)
                Divider()
                Button("Add Project…") { model.presentAddProject() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.button).buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.footerButton))
            .menuIndicator(.hidden).fixedSize()
            .help("New conversation or project")
            .accessibilityLabel("New conversation or project")
            Spacer()
            Button { model.onShowSettings?() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.footerButton))
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .font(LoomTheme.Typography.footerIcon)
        .focusEffectDisabled()
        .padding(.horizontal, LoomTheme.Space.footerInset)
        .frame(height: LoomTheme.Layout.footerHeight)
    }
}

struct SidebarList: View {
    let model: CatalogModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LoomTheme.Space.cardGap) {
                switch model.viewMode {
                case .activity: ActivityList(model: model)
                case .projects: ProjectList(model: model)
                }
            }
            .padding(.horizontal, LoomTheme.Space.listInset)
            .padding(.bottom, LoomTheme.Space.listBottom)
        }
        .scrollContentBackground(.hidden)
    }
}

struct ActivityList: View {
    let model: CatalogModel

    var body: some View {
        let list = model.list(for: .activity)
        if list.rows.isEmpty {
            EmptyListHint(model: model, isLoaded: list.isLoaded)
        } else {
            ForEach(DayGrouping.sections(list.rows, now: model.now)) { section in
                Text(section.title)
                    .font(LoomTheme.Typography.dayHeading)
                    .foregroundStyle(LoomTheme.Text.secondary)
                    .padding(.horizontal, LoomTheme.Space.sectionInset).padding(.top, LoomTheme.Space.sectionTop).padding(.bottom, LoomTheme.Space.sectionBottom)
                ForEach(section.rows) { row in
                    SessionCardView(row: row, model: model, showsProject: true)
                        .onAppear { if row.id == list.rows.last?.id { model.loadMore(.activity) } }
                }
            }
            if list.hasMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(LoomTheme.Space.loadingPadding) }
        }
    }
}

struct ProjectList: View {
    let model: CatalogModel

    var body: some View {
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
                ForEach(list.rows) { row in
                    SessionCardView(row: row, model: model, showsProject: false)
                        .onAppear { if row.id == list.rows.last?.id { model.loadMore(.project(project.id)) } }
                }
                if list.rows.isEmpty && list.isLoaded && !model.isSearching {
                    Text("No conversations")
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                        .padding(.horizontal, LoomTheme.Space.emptyNoteInset).padding(.vertical, LoomTheme.Space.emptyNoteVertical)
                }
            }
        }
        if !unassigned.rows.isEmpty {
            SectionTitle(title: "Sessions", symbol: "tray")
            ForEach(unassigned.rows) { row in
                SessionCardView(row: row, model: model, showsProject: false)
                    .onAppear { if row.id == unassigned.rows.last?.id { model.loadMore(.unassigned) } }
            }
        }
    }
}

struct SectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: LoomTheme.Space.sectionSpacing) {
            Image(systemName: symbol).foregroundStyle(LoomTheme.Text.secondary)
            Text(title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
            Spacer()
        }
        .padding(.horizontal, LoomTheme.Space.sectionInset).padding(.top, LoomTheme.Space.sectionTop).padding(.bottom, LoomTheme.Space.sectionBottom)
    }
}

struct ProjectHeader: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let count = model.sessionCounts[project.id] ?? 0
        let attention = model.attention(forProject: project.id)
        let index = model.projects.firstIndex { $0.id == project.id } ?? 0
        HStack(spacing: LoomTheme.Space.sectionSpacing) {
            Image(systemName: "folder").foregroundStyle(LoomTheme.Text.secondary)
            Text(project.name).font(LoomTheme.Typography.bodyStrong)
                .foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
            Spacer(minLength: LoomTheme.Space.headerSpacing)
            if let attention {
                Circle().fill(attention.color).frame(width: LoomTheme.Layout.projectDot, height: LoomTheme.Layout.projectDot)
                    .accessibilityLabel(attention.label)
            }
            Image(systemName: project.collapsed && !model.isSearching ? "chevron.right" : "chevron.down")
                .font(LoomTheme.Typography.chevron).foregroundStyle(LoomTheme.Text.secondary)
            Menu {
                Button("Move Up") { Task { await model.moveProject(project.id, by: -1) } }
                    .disabled(index == 0)
                Button("Move Down") { Task { await model.moveProject(project.id, by: 1) } }
                    .disabled(index >= model.projects.count - 1)
                Divider()
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
        .padding(.horizontal, LoomTheme.Space.sectionInset).padding(.top, LoomTheme.Space.sectionTop).padding(.bottom, LoomTheme.Space.sectionBottom)
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.toggleCollapsed(project.id) } }
        .contextMenu { NewConversationButtons(model: model, projectID: project.id) }
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
                Text("No matching conversations").foregroundStyle(LoomTheme.Text.primary)
                Text("Search covers title, provider and project.").foregroundStyle(LoomTheme.Text.secondary)
            } else {
                Text("No conversations yet. Add a project folder to begin.").foregroundStyle(LoomTheme.Text.secondary)
            }
        }
        .font(LoomTheme.Typography.small)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, LoomTheme.Space.hintTop).padding(.horizontal, LoomTheme.Space.sectionInset)
    }
}

struct SessionCardView: View {
    let row: SessionRowModel
    let model: CatalogModel
    let showsProject: Bool

    /// The project name appears on a card only where the card is not already
    /// grouped under its project (activity view).
    static func projectLabel(showsProject: Bool, name: String?) -> String? { showsProject ? name : nil }

    var body: some View {
        let indicator = row.indicator
        let selected = model.selectedSessionID == row.id
        let title = model.title(of: row, repeatsProject: showsProject)
        let projectName = model.projectName(for: row.record)
        Button { model.select(row.id) } label: {
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
                        Text(RelativeTime.string(from: row.record.lastUsedAt, to: model.now))
                            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                            .help("Last used \(row.record.lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    HStack(spacing: LoomTheme.Space.cardRowSpacing) {
                        Label((model.branches[row.record.session.workingDirectory] ?? .unavailable).label,
                              systemImage: "arrow.triangle.branch")
                            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary).lineLimit(1)
                            .help("Git branch")
                        Spacer(minLength: LoomTheme.Space.headerSpacing)
                        if let projectName = SessionCardView.projectLabel(showsProject: showsProject, name: projectName) {
                            Text(projectName).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                                .lineLimit(1)
                        }
                        ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.providerIconCard)
                    }
                }
            }
            .padding(.horizontal, LoomTheme.Space.cardH).padding(.vertical, LoomTheme.Space.cardV)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.Radius.card)
                    .fill(selected ? LoomTheme.Surface.selected : .clear)
                    .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.card)
                        .stroke(selected ? LoomTheme.Surface.hairline : .clear, lineWidth: LoomTheme.Line.hairline))
            )
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.card))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { model.beginRename(row.id) }
            Divider()
            Button("Resume") { model.resumeConversation(row.id) }.disabled(!model.canResume(row))
            Button("Stop") { model.stopConversation(row.id) }.disabled(!model.canStop(row))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(ProviderName.title(row.record.session.provider))"
            + (indicator.label.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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

struct NewConversationAction {
    let provider: ManagedSession.Provider
    let title: String

    private static let all = [
        NewConversationAction(provider: .claude, title: "New Claude Conversation"),
        NewConversationAction(provider: .codex, title: "New Codex Conversation"),
    ]

    /// The actions the model may start (production: Claude only).
    @MainActor static func startable(on model: CatalogModel) -> [NewConversationAction] {
        all.filter { model.startableProviders.contains($0.provider) }
    }

    @MainActor func perform(on model: CatalogModel, projectID: UUID?) {
        model.startConversation(provider, projectID: projectID)
    }

    @MainActor func isEnabled(on model: CatalogModel, projectID: UUID?) -> Bool {
        model.canStart(provider, projectID: projectID)
    }
}

/// Monochrome chrome button: explicit colors (a plain button otherwise picks up
/// the accent tint for its symbol), hover and pressed backgrounds, and a
/// subtle ring while focused (the system focus effect is switched off).
struct ChromeButtonStyle: ButtonStyle {
    var selected = false
    var size = LoomTheme.Layout.chromeButton

    /// A mouse user's launch focus must not draw a ring: only with keyboard navigation on.
    static func showsFocusRing(focused: Bool, keyboardNavigation: Bool) -> Bool { focused && keyboardNavigation }

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, size: size)
    }

    private struct Chrome: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let size: CGSize
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        var body: some View {
            let background: Color = configuration.isPressed ? LoomTheme.Surface.controlPressed
                : (hovering ? LoomTheme.Surface.controlHover : (selected ? LoomTheme.Surface.selected : .clear))
            configuration.label
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected || hovering || configuration.isPressed ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.control).fill(background))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                    .strokeBorder(ChromeButtonStyle.showsFocusRing(
                        focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
                        ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }
    }
}

/// Whether Full Keyboard Access is on, read once and refreshed when a window
/// becomes key (the setting changes in System Settings, outside the app), so
/// each chrome button only reads a flag instead of subscribing on its own.
@MainActor @Observable
final class KeyboardNavigation {
    static let shared = KeyboardNavigation()

    private(set) var isEnabled = NSApplication.shared.isFullKeyboardAccessEnabled
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() { isEnabled = NSApplication.shared.isFullKeyboardAccessEnabled }
}
