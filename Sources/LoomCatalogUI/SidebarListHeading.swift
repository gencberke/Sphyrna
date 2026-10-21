import SwiftUI

/// The list's heading (DESIGN §2 item 3; the reference's `side-sec`): the view's name as a section label, and at the trailing
/// end the switch "projects · activity" in text, the chosen word in primary medium and the other in tertiary. A click on a word
/// switches the view, as ⌘2 and ⌘1 do. To assistive technologies the switch is a two-option control.
struct SidebarListHeading: View {
    let model: CatalogModel

    /// The label over the list.
    static func name(of mode: CatalogViewMode) -> String {
        switch mode {
        case .projects: "Projects"
        case .activity: "Activity"
        }
    }

    /// The word the switch writes for a view.
    static func word(of mode: CatalogViewMode) -> String {
        switch mode {
        case .projects: "projects"
        case .activity: "activity"
        }
    }

    static let switchLabel = "List view"
    /// The switch's options in the order it writes them.
    static let options: [CatalogViewMode] = [.projects, .activity]

    var body: some View {
        HStack(spacing: LoomTheme.Space.headerSpacing) {
            Text(Self.name(of: model.viewMode))
                .sidebarType(LoomTheme.Sidebar.headingLabel)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LoomTheme.Space.headerSpacing)
            ViewSwitch(model: model)
        }
        .padding(.horizontal, LoomTheme.Sidebar.headingInset)
        .padding(.top, LoomTheme.Sidebar.headingTop)
        .padding(.bottom, LoomTheme.Sidebar.headingBottom)
    }
}

/// "projects · activity": two words that are one control. It reads the view mode and nothing else.
struct ViewSwitch: View {
    let model: CatalogModel

    var body: some View {
        let mode = model.viewMode
        HStack(spacing: LoomTheme.Sidebar.switchGap) {
            word(.projects, chosen: mode == .projects)
            Text("·").font(LoomTheme.Sidebar.switchFont).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            word(.activity, chosen: mode == .activity)
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

    private func word(_ mode: CatalogViewMode, chosen: Bool) -> some View {
        Button { model.setViewMode(mode) } label: {
            Text(SidebarListHeading.word(of: mode))
        }
        .buttonStyle(ViewSwitchWordStyle(chosen: chosen))
        .help(mode == .projects ? "Group by project (⌘2)" : "Sort by recent activity (⌘1)")
    }
}

/// A word of the switch: primary medium when chosen, tertiary otherwise (secondary under the pointer), 24 pt high to be hit.
private struct ViewSwitchWordStyle: ButtonStyle {
    let chosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        Word(configuration: configuration, chosen: chosen)
    }

    private struct Word: View {
        let configuration: ButtonStyle.Configuration
        let chosen: Bool
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(chosen ? LoomTheme.Sidebar.switchFontChosen : LoomTheme.Sidebar.switchFont)
                .foregroundStyle(chosen ? AnyShapeStyle(LoomTheme.Text.primary)
                                 : hovering || configuration.isPressed ? AnyShapeStyle(LoomTheme.Text.secondaryStyle)
                                 : AnyShapeStyle(LoomTheme.Text.tertiaryStyle))
                .frame(minHeight: LoomTheme.Layout.minimumHitTarget.height)
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: LoomTheme.InkRadius.key)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
