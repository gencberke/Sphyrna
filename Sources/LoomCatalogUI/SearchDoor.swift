import SwiftUI

/// The sidebar's search field is the command palette's door (DESIGN §2 item 3, V2-PLAN §14): a 30 pt hairline box holding the
/// search glyph, "Search" and ⌘K in mono at its trailing end. A click runs what ⌘K runs. It filters nothing itself: the palette
/// finds a session by its title, provider and project, and by its text.
struct SearchDoor: View {
    let model: CatalogModel

    static let title = "Search"
    static let accessibilityLabel = "Search, opens the command palette"

    /// The key cap's text, from the command's own key so the two never differ.
    static var keyHint: String {
        PaletteKeyHint.text(modifiers: ShellCommand.commandPalette.modifiers, key: ShellCommand.commandPalette.keyEquivalent)
    }

    var body: some View {
        Button { model.openPalette() } label: {
            HStack(spacing: LoomTheme.Sidebar.doorSpacing) {
                Image(systemName: "magnifyingglass").font(LoomTheme.Sidebar.doorGlyph)
                    .accessibilityHidden(true)
                Text(Self.title).font(LoomTheme.Sidebar.doorLabel)
                Spacer(minLength: LoomTheme.Sidebar.doorSpacing)
                SidebarKeyCap(text: Self.keyHint)
            }
            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
        }
        .buttonStyle(SearchDoorStyle())
        .focusEffectDisabled()
        .padding(.horizontal, LoomTheme.Sidebar.doorInset)
        .padding(.bottom, LoomTheme.Sidebar.doorBottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sidebar-search")
        .help("Search sessions, projects and commands (\(Self.keyHint))")
    }
}

/// A key's cap: mono, tertiary, a strong hairline around it.
struct SidebarKeyCap: View {
    let text: String

    var body: some View {
        Text(text).font(LoomTheme.Sidebar.keyCapFont)
            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .padding(.horizontal, LoomTheme.Sidebar.keyCapPaddingH)
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Sidebar.keyCapRadius)
                .strokeBorder(LoomTheme.Surface.strongEdgeStyle, lineWidth: LoomTheme.Line.hairline))
            .accessibilityHidden(true)
    }
}

/// The door: a field-shaped box on the canvas with a strong hairline, the stronger one under the pointer, and Sphyrna's focus
/// ring with keyboard navigation. A press takes the pill's pressed fill.
private struct SearchDoorStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Door(configuration: configuration)
    }

    private struct Door: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: LoomTheme.Sidebar.doorRadius)
            // Increase Contrast already draws the raised edge; the stronger step would be weaker than it.
            let edge: AnyShapeStyle = hovering && contrast != .increased
                ? AnyShapeStyle(LoomTheme.Surface.strongerHairline) : AnyShapeStyle(LoomTheme.Surface.strongEdgeStyle)
            configuration.label
                .padding(.leading, LoomTheme.Sidebar.doorPaddingLeading)
                .padding(.trailing, LoomTheme.Sidebar.doorPaddingTrailing)
                .frame(height: LoomTheme.Sidebar.doorHeight)
                .background(shape.fill(configuration.isPressed ? LoomTheme.Highlight.pressed : .clear))
                .overlay(shape.strokeBorder(edge, lineWidth: LoomTheme.Line.hairline))
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: LoomTheme.Sidebar.doorRadius)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}
