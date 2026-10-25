import SwiftUI

/// The list's heading (DESIGN §2 item 3, RESCUE C3): the current view's name once, beside it that view's own action (Add Project in
/// Projects, New Session in Activity), and at the trailing end the view picker, a separate compact control of two icon buttons.
/// A click on an icon switches the view, as ⌘2 and ⌘1 do. To assistive technologies the picker is a two-option control.
struct SidebarListHeading: View {
    let model: CatalogModel

    /// The label over the list, written once.
    static func name(of mode: CatalogViewMode) -> String {
        switch mode {
        case .projects: "Projects"
        case .activity: "Activity"
        }
    }

    /// The picker's icon for a view.
    static func symbol(of mode: CatalogViewMode) -> String {
        switch mode {
        case .projects: "folder"
        case .activity: "clock"
        }
    }

    /// The view's own action beside its name.
    enum Action: Equatable {
        case addProject
        case newSession

        var title: String {
            switch self {
            case .addProject: "Add Project…"
            case .newSession: "New Session"
            }
        }

        var symbol: String {
            switch self {
            case .addProject: "folder.badge.plus"
            case .newSession: "plus"
            }
        }
    }

    static func action(of mode: CatalogViewMode) -> Action {
        switch mode {
        case .projects: .addProject
        case .activity: .newSession
        }
    }

    static let switchLabel = "List view"
    /// The picker's options in the order it draws them.
    static let options: [CatalogViewMode] = [.activity, .projects]

    var body: some View {
        let mode = model.viewMode
        let action = Self.action(of: mode)
        HStack(spacing: LoomTheme.Sidebar.headingActionGap) {
            Text(Self.name(of: mode))
                .sidebarType(LoomTheme.Sidebar.headingLabel)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Button { Self.perform(action, on: model) } label: {
                Image(systemName: action.symbol).font(LoomTheme.Sidebar.headingGlyph)
            }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.Sidebar.headingButton, key: "sidebar-heading-action"))
            .focusEffectDisabled()
            .disabled(!Self.isEnabled(action, on: model))
            .help(action.title)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier("sidebar-heading-action")
            Spacer(minLength: LoomTheme.Space.headerSpacing)
            ViewPicker(model: model)
        }
        .padding(.horizontal, LoomTheme.Sidebar.headingInset)
        .padding(.top, LoomTheme.Sidebar.headingTop)
        .padding(.bottom, LoomTheme.Sidebar.headingBottom)
    }

    static func isEnabled(_ action: Action, on model: CatalogModel) -> Bool {
        switch action {
        case .addProject: model.isReady
        case .newSession: model.newSessionRowAvailable
        }
    }

    /// The same paths as the footer's Add Project… and the New session row.
    static func perform(_ action: Action, on model: CatalogModel) {
        switch action {
        case .addProject: model.presentAddProject()
        case .newSession: model.beginNewSessionInRecentProject()
        }
    }
}

/// The view picker: an icon button per view, the chosen one drawn selected. It reads the view mode and nothing else.
struct ViewPicker: View {
    let model: CatalogModel

    var body: some View {
        let mode = model.viewMode
        HStack(spacing: LoomTheme.Sidebar.switchGap) {
            ForEach(SidebarListHeading.options, id: \.self) { option in
                Button { model.setViewMode(option) } label: {
                    Image(systemName: SidebarListHeading.symbol(of: option)).font(LoomTheme.Sidebar.headingGlyph)
                }
                .buttonStyle(ChromeButtonStyle(selected: mode == option, size: LoomTheme.Sidebar.headingButton,
                                               key: "sidebar-view-\(option)"))
                .focusEffectDisabled()
                .help(option == .projects ? "Group by project (⌘2)" : "Sort by recent activity (⌘1)")
            }
        }
        .accessibilityRepresentation {
            Picker(SidebarListHeading.switchLabel, selection: Binding(
                get: { model.viewMode }, set: { model.setViewMode($0) })
            ) {
                ForEach(SidebarListHeading.options, id: \.self) { option in
                    Text(SidebarListHeading.name(of: option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// What a right-click on the list's empty space offers (RESCUE C3): Add Project… and New Session always, then the session
/// without a project where the build can start one.
struct SidebarEmptySpaceMenu: View {
    let model: CatalogModel

    var body: some View {
        Button(SidebarListHeading.Action.addProject.title) { model.presentAddProject() }
            .disabled(!SidebarListHeading.isEnabled(.addProject, on: model))
        Button(SidebarListHeading.Action.newSession.title) { model.beginNewSessionInRecentProject() }
            .disabled(!SidebarListHeading.isEnabled(.newSession, on: model))
        WithoutProjectStartButton(model: model, title: ClaudeStartEntry.withoutProjectTitle)
    }
}
