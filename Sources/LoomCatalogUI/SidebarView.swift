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
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            SidebarList(model: model)
            SidebarFooter(model: model)
        }
        .background(SidebarBackground(reduceTransparency: model.sidebarTransparencyOverride ?? reduceTransparency))
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        // Indicators stand still while the window is inactive/hidden or the sidebar is collapsed.
        .environment(\.indicatorsAnimate, Self.indicatorsAnimate(model))
    }
}

struct SidebarHeader: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: 4) {
            // Full screen has no native window buttons to clear.
            if !model.isFullScreen { Color.clear.frame(width: CatalogTheme.sidebarButtonsGap) }
            Button { model.onToggleSidebar?() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(ChromeButtonStyle())
            .help("Hide Sidebar (⌃⌘S)")
            .accessibilityLabel("Hide sidebar")
            Spacer(minLength: 4)
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
        .font(.system(size: 13))
        .focusEffectDisabled()
        .padding(.horizontal, 10)
        .frame(height: CatalogTheme.headerHeight)
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(CatalogTheme.secondary)
            TextField("Search conversations", text: Binding(
                get: { model.searchText }, set: { model.setSearchText($0) }
            ))
            .textFieldStyle(.plain)
            .foregroundStyle(CatalogTheme.text)
            .accessibilityLabel("Search conversations")
            if !model.searchText.isEmpty {
                Button { model.setSearchText("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(CatalogTheme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
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
            .menuStyle(.button).buttonStyle(ChromeButtonStyle(size: CGSize(width: 28, height: 26)))
            .menuIndicator(.hidden).fixedSize()
            .help("New conversation or project")
            .accessibilityLabel("New conversation or project")
            Spacer()
            Button { model.onShowSettings?() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ChromeButtonStyle(size: CGSize(width: 28, height: 26)))
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .font(.system(size: 14))
        .focusEffectDisabled()
        .padding(.horizontal, 10)
        .frame(height: 38)
    }
}

struct SidebarList: View {
    let model: CatalogModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch model.viewMode {
                case .activity: ActivityList(model: model)
                case .projects: ProjectList(model: model)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CatalogTheme.secondary)
                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                ForEach(section.rows) { row in
                    SessionCardView(row: row, model: model, showsProject: true)
                        .onAppear { if row.id == list.rows.last?.id { model.loadMore(.activity) } }
                }
            }
            if list.hasMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8) }
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
                        .font(.system(size: 12)).foregroundStyle(CatalogTheme.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
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
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(CatalogTheme.secondary)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CatalogTheme.text)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
    }
}

struct ProjectHeader: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let count = model.sessionCounts[project.id] ?? 0
        let attention = model.attention(forProject: project.id)
        let index = model.projects.firstIndex { $0.id == project.id } ?? 0
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(CatalogTheme.secondary)
            Text(project.name).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CatalogTheme.text).lineLimit(1)
            Spacer(minLength: 4)
            if let attention {
                Circle().fill(attention.color).frame(width: 7, height: 7)
                    .accessibilityLabel(attention.label)
            }
            Image(systemName: project.collapsed && !model.isSearching ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(CatalogTheme.secondary)
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
            .menuStyle(.button).buttonStyle(ChromeButtonStyle(size: CGSize(width: 22, height: 20)))
            .menuIndicator(.hidden).fixedSize()
            .help(count > 0 ? "Only an empty project can be removed" : "Project actions")
            .accessibilityLabel("Actions for \(project.name)")
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
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
        VStack(spacing: 6) {
            if !isLoaded {
                ProgressView().controlSize(.small)
            } else if model.isSearching {
                Text("No matching conversations").foregroundStyle(CatalogTheme.text)
                Text("Search covers title, provider and project.").foregroundStyle(CatalogTheme.secondary)
            } else {
                Text("No conversations yet").foregroundStyle(CatalogTheme.text)
                Text("Add a project folder to get started.").foregroundStyle(CatalogTheme.secondary)
            }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 40).padding(.horizontal, 12)
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
            HStack(alignment: .top, spacing: 8) {
                IndicatorView(indicator: indicator)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(indicator == .stale ? CatalogTheme.secondary : CatalogTheme.text)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(RelativeTime.string(from: row.record.lastUsedAt, to: model.now))
                            .font(.system(size: 11)).foregroundStyle(CatalogTheme.secondary)
                            .help("Last used \(row.record.lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    HStack(spacing: 6) {
                        Label((model.branches[row.record.session.workingDirectory] ?? .unavailable).label,
                              systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11)).foregroundStyle(CatalogTheme.secondary).lineLimit(1)
                            .help("Git branch")
                        Spacer(minLength: 4)
                        if let projectName = SessionCardView.projectLabel(showsProject: showsProject, name: projectName) {
                            Text(projectName).font(.system(size: 11)).foregroundStyle(CatalogTheme.secondary)
                                .lineLimit(1)
                        }
                        ProviderIcon(provider: row.record.session.provider, size: 14)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? CatalogTheme.selection : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? CatalogTheme.hairline : .clear, lineWidth: 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
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
        ForEach(NewConversationAction.all, id: \.provider) { action in
            Button(action.title + suffix) { action.perform(on: model, projectID: projectID) }
                .disabled(!action.isEnabled(on: model, projectID: projectID))
        }
    }
}

struct NewConversationAction {
    let provider: ManagedSession.Provider
    let title: String

    static let all = [
        NewConversationAction(provider: .claude, title: "New Claude Conversation"),
        NewConversationAction(provider: .codex, title: "New Codex Conversation"),
    ]

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
    var size = CGSize(width: 26, height: 24)

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
        @State private var keyboardNavigation = NSApplication.shared.isFullKeyboardAccessEnabled

        var body: some View {
            let background = configuration.isPressed ? 0.14 : (hovering ? 0.09 : (selected ? 0.07 : 0))
            configuration.label
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected || hovering || configuration.isPressed ? CatalogTheme.text : CatalogTheme.secondary)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(background)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(
                        ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: keyboardNavigation)
                            ? 0.4 : 0), lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    keyboardNavigation = NSApplication.shared.isFullKeyboardAccessEnabled
                }
        }
    }
}
