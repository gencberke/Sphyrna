import SwiftUI

/// One view tab: its title, an optional count (left out while there is nothing to count) and the names that find it.
struct ViewTabItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var count: Int?
    /// The accessibility identifier, and the evidence run's `hover:` key.
    let identifier: String
    let hoverKey: String

    /// What assistive technologies read: "Branches, 7", or the title alone.
    var accessibilityLabel: String { count.map { "\(title), \($0)" } ?? title }
}

/// The view tabs (DESIGN §6 Tabs): underlined text on a 36 pt bar with a hairline under it, 18 apart. Each shows its name; the open
/// one has a 1.5 pt accent underline on the bar's hairline, and a count in mono 10.5 follows a label. Secondary text, primary on hover
/// and when open; there is no pill.
struct ViewTabs<ID: Hashable>: View {
    let tabs: [ViewTabItem<ID>]
    let selection: ID
    let onSelect: (ID) -> Void

    var body: some View {
        HStack(spacing: LoomTheme.ViewTabs.gap) {
            ForEach(tabs) { tab in
                let selected = tab.id == selection
                Button { onSelect(tab.id) } label: {
                    HStack(spacing: LoomTheme.ViewTabs.contentGap) {
                        Text(tab.title).projectType(LoomTheme.ViewTabs.label)
                        if let count = tab.count {
                            Text("\(count)").projectType(LoomTheme.ViewTabs.count).monospacedDigit()
                                .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ViewTabStyle(selected: selected, key: tab.hoverKey))
                .focusEffectDisabled()
                .accessibilityLabel(tab.accessibilityLabel)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(tab.identifier)
            }
            Spacer(minLength: 0)
        }
        .frame(height: LoomTheme.ViewTabs.barHeight)
        // Behind the tabs, so the open tab's underline is drawn over the hairline it sits on.
        .background(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
        }
    }
}

/// A view tab's look: secondary text, primary on hover and when open, and the open tab's accent underline along the bar's bottom
/// edge. `key` names the tab for the evidence run's `hover:` command.
private struct ViewTabStyle: ButtonStyle {
    let selected: Bool
    let key: String

    func makeBody(configuration: Configuration) -> some View {
        Tab(configuration: configuration, selected: selected, key: key)
    }

    private struct Tab: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let key: String
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            let ring = ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
            let lit = selected || hovering || LookEvidence.forcesHover(key)
            configuration.label
                .foregroundStyle(lit ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .opacity(configuration.isPressed ? LoomTheme.Opacity.rowPressed : 1)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(LoomTheme.Accent.base).frame(height: LoomTheme.ViewTabs.underline)
                        .opacity(selected ? 1 : 0).accessibilityHidden(true)
                }
                .controlFocusRing(visible: ring, radius: LoomTheme.InkRadius.key)
                .onHover { hovering = $0 }
        }
    }
}
