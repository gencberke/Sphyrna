import SwiftUI

/// A row that is a button (a project header): no drawn state of its own, only the focus ring
/// while it has keyboard focus under Full Keyboard Access.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? LoomTheme.Opacity.rowPressed : 1)
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                    .strokeBorder(ChromeButtonStyle.showsFocusRing(
                        focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
                        ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing(for: contrast))
                        .padding(-LoomTheme.Space.rowFocusOutset))
        }
    }
}
