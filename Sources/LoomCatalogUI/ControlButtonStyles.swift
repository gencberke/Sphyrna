import SwiftUI

/// The text buttons of the control family (DESIGN §6 Controls). One filled accent style with on-accent text for the default or
/// main action; secondary buttons with a strong-hairline edge; ghost buttons in secondary text; destructive buttons in the
/// failure text with the failure wash on hover. Hover adds the hover fill, a press the pressed fill, a disabled button is drawn
/// at 38 %, and keyboard focus draws Sphyrna's ring (accent, 2 pt, 2 pt outside). `tinted` is the quieter accent action (accent
/// text on the accent wash). Sizes: 26 high with radius 6 (regular), 30 with radius 8 (a page's main action), 22 with radius 5.
struct ControlButtonStyle: ButtonStyle {
    enum Kind: CaseIterable, Sendable { case primary, secondary, ghost, destructive, tinted }

    var kind: Kind = .secondary
    var size: LoomTheme.Control.Size = .regular
    /// Names the button for the evidence run's `hover:` command.
    var key: String?

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, size: size, key: key)
    }

    /// The label's colour for a kind, hovered or not.
    static func text(_ kind: Kind, hovering: Bool) -> AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(LoomTheme.Accent.onAccent)
        case .secondary: AnyShapeStyle(LoomTheme.Text.primary)
        case .ghost: hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
        case .destructive: AnyShapeStyle(LoomTheme.Status.failureLight)
        case .tinted: AnyShapeStyle(LoomTheme.Accent.high)
        }
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let size: LoomTheme.Control.Size
        let key: String?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let _ = SidebarRenderProbe.pill(key)
            let active = enabled && (hovering || LookEvidence.forcesHover(key))
            let pressed = enabled && configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: size.radius)
            configuration.label
                .font(size.font)
                .foregroundStyle(ControlButtonStyle.text(kind, hovering: active || pressed))
                .padding(.horizontal, size.paddingH)
                .frame(height: size.height)
                .background(shape.fill(fill(active: active, pressed: pressed)))
                .overlay(shape.strokeBorder(edge(active: active), lineWidth: LoomTheme.Line.hairline))
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: size.radius)
                .contentShape(shape)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }

        private func fill(active: Bool, pressed: Bool) -> Color {
            switch kind {
            case .primary:
                if pressed { return LoomTheme.Accent.base.opacity(LoomTheme.Opacity.accentPressed) }
                return active ? LoomTheme.Control.primaryHover : LoomTheme.Accent.base
            case .secondary, .ghost:
                return pressed ? LoomTheme.Surface.pressed : (active ? LoomTheme.Surface.hover : .clear)
            case .destructive:
                return pressed || active ? LoomTheme.Status.failureWash : .clear
            case .tinted:
                return LoomTheme.Accent.base.opacity(pressed ? LoomTheme.Opacity.accentTintPressed : LoomTheme.Opacity.accentTint)
            }
        }

        /// A secondary button has the strong hairline for an edge, the stronger one while hovered; under Increase Contrast the
        /// raised hairline.
        private func edge(active: Bool) -> AnyShapeStyle {
            guard kind == .secondary else { return AnyShapeStyle(Color.clear) }
            if contrast == .increased { return AnyShapeStyle(LoomTheme.Surface.hairlineStyle) }
            return AnyShapeStyle(active ? LoomTheme.Surface.strongerHairline : LoomTheme.Surface.strongHairline)
        }
    }
}
