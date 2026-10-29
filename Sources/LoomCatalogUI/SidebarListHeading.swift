import SwiftUI

/// The list's heading: the current view's name, then the view toggle and its action at the trailing end.
/// To assistive technologies the toggle is a two-option control, as the keyboard's ⌘1 and ⌘2 are.
struct SidebarListHeading: View {
    let model: CatalogModel

    /// The label over the list, written once.
    static func name(of mode: CatalogViewMode) -> String {
        switch mode {
        case .projects: "Projects"
        case .activity: "Activity"
        }
    }

    /// The view's own action.
    enum Action: Equatable {
        case addProject
        case newSession

        var title: String {
            switch self {
            case .addProject: "Add Project…"
            case .newSession: "New Session"
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
                .font(LoomTheme.Sidebar.headingLabel)
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LoomTheme.Space.headerSpacing)
            ViewPicker(model: model)
            if Self.isOffered(action, on: model) {
                Button { Self.perform(action, on: model) } label: {
                    InkIcon(.plus, size: LoomTheme.Icon.heading)
                }
                .buttonStyle(ChromeButtonStyle(size: LoomTheme.Sidebar.headingButton, key: "sidebar-heading-action"))
                .focusEffectDisabled()
                .disabled(!Self.isEnabled(action, on: model))
                .help(action.title)
                .accessibilityLabel(action.title)
                .accessibilityIdentifier("sidebar-heading-action")
            }
        }
        .padding(.leading, LoomTheme.Sidebar.headingInset)
        .padding(.trailing, LoomTheme.Sidebar.headingTrailing)
        .padding(.top, LoomTheme.Sidebar.headingTop)
        .padding(.bottom, LoomTheme.Sidebar.headingBottom)
    }

    static func isEnabled(_ action: Action, on model: CatalogModel) -> Bool {
        switch action {
        case .addProject: model.isReady
        case .newSession: model.newSessionRowAvailable
        }
    }

    /// Whether the action is listed at all (C2B): New Session only where the model offers Claude.
    static func isOffered(_ action: Action, on model: CatalogModel) -> Bool {
        switch action {
        case .addProject: true
        case .newSession: model.offersNewSession(.newSessionDefault)
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

/// One toggle changes the view; the accessible representation keeps the two-option picker.
struct ViewPicker: View {
    let model: CatalogModel

    var body: some View {
        let mode = model.viewMode
        Button { model.setViewMode(mode == .projects ? .activity : .projects) } label: {
            InkIcon(mode == .projects ? .list : .sidebarLeft, size: LoomTheme.Icon.heading)
        }
        .buttonStyle(ChromeButtonStyle(size: LoomTheme.Sidebar.headingButton, key: "sidebar-view-toggle"))
        .focusEffectDisabled()
        .help(mode == .projects ? "Show activity (⌘1)" : "Show projects (⌘2)")
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

/// What a right-click on the list's empty space offers (RESCUE C3): Add Project… always, New Session where the model offers
/// Claude (C2B), then the session without a project where the build can start one.
struct SidebarEmptySpaceMenu: View {
    let model: CatalogModel

    var body: some View {
        Button(SidebarListHeading.Action.addProject.title) { model.presentAddProject() }
            .disabled(!SidebarListHeading.isEnabled(.addProject, on: model))
        if SidebarListHeading.isOffered(.newSession, on: model) {
            Button(SidebarListHeading.Action.newSession.title) { model.beginNewSessionInRecentProject() }
                .disabled(!SidebarListHeading.isEnabled(.newSession, on: model))
        }
        WithoutProjectStartButton(model: model, title: ClaudeStartEntry.withoutProjectTitle)
    }
}
