import SwiftUI

/// The text buttons of the control family (DESIGN §0.4 Buttons): six roles at four heights (`LoomTheme.Control.Size`), one radius
/// and one focus ring. Default is the neutral fill of the one affirmative action; secondary the muted fill; outline the input fill
/// and edge at elevation 2; ghost no fill; link the accent text; destructive the failure red with white text. Hover adds the hover
/// fill (a default action's fill fades to 90 %), a press the pressed fill, a disabled button is drawn at 38 %, and keyboard focus
/// draws Sphyrna's ring.
struct ControlButtonStyle: ButtonStyle {
    enum Kind: CaseIterable, Sendable { case `default`, secondary, outline, ghost, link, destructive }

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
        case .default: AnyShapeStyle(LoomTheme.Control.defaultTextPair.color)
        case .secondary, .outline: AnyShapeStyle(LoomTheme.Text.primary)
        case .ghost: hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
        case .link: AnyShapeStyle(LoomTheme.Accent.high)
        case .destructive: AnyShapeStyle(LoomTheme.Control.destructiveText)
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
                .background(shape.fill(base(active: active, pressed: pressed)).overlay(shape.fill(layer(active: active, pressed: pressed))))
                .overlay(shape.strokeBorder(edge(active: active), lineWidth: LoomTheme.Line.hairline))
                .depth(kind == .outline ? LoomTheme.Elevation.lift : LoomTheme.Elevation.card)
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: size.radius)
                .contentShape(shape)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }

        /// The fill under the label: the kind's own fill; the default action's fades under the pointer and the press.
        private func base(active: Bool, pressed: Bool) -> Color {
            switch kind {
            case .default:
                let fill = LoomTheme.Control.defaultFillPair.color
                if pressed { return fill.opacity(LoomTheme.Control.defaultPressedOpacity) }
                return active ? fill.opacity(LoomTheme.Control.defaultHoverOpacity) : fill
            case .secondary: return LoomTheme.Surface.muted
            case .outline: return LoomTheme.Surface.inputFill
            case .ghost, .link: return .clear
            case .destructive:
                return pressed || active ? LoomTheme.Control.destructiveHover.color : LoomTheme.Control.destructiveFill.color
            }
        }

        /// The layer over the fill under the pointer or the press (the family's hover and pressed fills).
        private func layer(active: Bool, pressed: Bool) -> Color {
            switch kind {
            case .secondary, .outline, .ghost:
                return pressed ? LoomTheme.Surface.pressed : (active ? LoomTheme.Surface.hover : .clear)
            case .default, .link, .destructive:
                return .clear
            }
        }

        /// An outline button's edge: the input edge, the strong hairline under the pointer, the raised hairline under Increase Contrast.
        private func edge(active: Bool) -> AnyShapeStyle {
            guard kind == .outline else { return AnyShapeStyle(Color.clear) }
            if contrast == .increased { return AnyShapeStyle(LoomTheme.Surface.hairlineStyle) }
            return AnyShapeStyle(active ? LoomTheme.Surface.strongHairline : LoomTheme.Surface.inputEdge)
        }
    }
}
