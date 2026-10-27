import SwiftUI

/// The icon button of the control family (DESIGN §6 Controls): 28 pt, radius 8, a 16 pt glyph in secondary until hovered
/// (explicit colors: a plain button otherwise picks up the accent tint for its symbol), the pill's hover, selected and pressed
/// fills, and Sphyrna's focus ring (an accent edge and a 3 pt halo, DESIGN §0.1) with keyboard navigation (the system focus effect is switched off).
struct ChromeButtonStyle: ButtonStyle {
    var selected = false
    var size = LoomTheme.Layout.chromeButton
    /// Names the button for the evidence run's `hover:` command.
    var key: String?

    /// A mouse user's launch focus must not draw a ring: only with keyboard navigation on.
    static func showsFocusRing(focused: Bool, keyboardNavigation: Bool) -> Bool { focused && keyboardNavigation }

    /// The area that answers a click on a control drawn at `size`: at least
    /// `LoomTheme.Layout.minimumHitTarget`. SwiftUI hit-tests only inside a view's layout frame,
    /// so the frame itself grows; the drawn control keeps its size, centered in it.
    static func hitSize(for size: CGSize) -> CGSize {
        CGSize(width: max(size.width, LoomTheme.Layout.minimumHitTarget.width),
               height: max(size.height, LoomTheme.Layout.minimumHitTarget.height))
    }

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, size: size, key: key)
    }

    private struct Chrome: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let size: CGSize
        let key: String?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        var body: some View {
            let hit = ChromeButtonStyle.hitSize(for: size)
            let active = hovering || LookEvidence.forcesHover(key)
            let state = HighlightState.resolve(selected: selected, hovering: active, pressed: configuration.isPressed, enabled: enabled)
            configuration.label
                .font(LoomTheme.Control.iconGlyph)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected || active || configuration.isPressed ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                .frame(width: size.width, height: size.height)
                .background(RowHighlight(state: state, radius: LoomTheme.Control.iconRadius))
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: LoomTheme.Control.iconRadius)
                .frame(width: hit.width, height: hit.height)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }
    }
}
