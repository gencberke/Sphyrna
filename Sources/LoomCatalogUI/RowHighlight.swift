import Observation
import SwiftUI

/// What a row's pill shows (`LoomTheme.Highlight`). Pressed beats selected, selected beats hover: a selected row stays at
/// its stronger fill under the pointer. A disabled row shows no hover or press.
enum HighlightState: Equatable {
    case none, hover, selected, pressed

    static func resolve(selected: Bool, hovering: Bool, pressed: Bool = false, enabled: Bool = true) -> HighlightState {
        guard enabled else { return selected ? .selected : .none }
        if pressed { return .pressed }
        if selected { return .selected }
        return hovering ? .hover : .none
    }

    /// The fill as data (a tone per appearance); nil for no pill.
    var tone: LoomTheme.AdaptiveTone? {
        switch self {
        case .none: nil
        case .hover: LoomTheme.Highlight.hoverTone
        case .selected: LoomTheme.Highlight.selectedTone
        case .pressed: LoomTheme.Highlight.pressedTone
        }
    }

    var fill: Color {
        switch self {
        case .none: .clear
        case .hover: LoomTheme.Highlight.hover
        case .selected: LoomTheme.Highlight.selected
        case .pressed: LoomTheme.Highlight.pressed
        }
    }

    /// Selection always carries the hairline; under Increase Contrast hover and press do too.
    func drawsStroke(for contrast: ColorSchemeContrast) -> Bool {
        switch self {
        case .none: false
        case .selected: true
        case .hover, .pressed: contrast == .increased
        }
    }
}

/// The pill: a rounded fill (and a hairline where the state asks for one) that fades in and out in 120 ms, or at once under
/// Reduce Motion. It holds no state of its own; the row that draws it does (a row's hover never reaches the list around it).
struct RowHighlight: View {
    let state: HighlightState
    var radius: CGFloat = LoomTheme.Highlight.radius
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape.fill(contrast == .increased ? state.fill.opacity(LoomTheme.Highlight.increasedFillScale) : state.fill)
            .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline)
                .opacity(state.drawsStroke(for: contrast) ? 1 : 0))
            .animation(LoomTheme.Motion.animation(.selection, reduceMotion: reduceMotion), value: state)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A row that is not a button (or whose buttons draw nothing of their own) takes the pill and tracks its own hover. The state
/// lives in this modifier, so a hover re-evaluates the pill and nothing else.
private struct RowPill: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    let key: String?
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let _ = SidebarRenderProbe.pill(key)
        content
            .background(RowHighlight(
                state: .resolve(selected: selected, hovering: hovering || LookEvidence.forcesHover(key), enabled: enabled),
                radius: radius))
            .onHover { hovering = $0 }
    }
}

extension View {
    /// The shared hover and selection pill behind a row. `key` names the row for the evidence run's `hover:` command.
    func rowPill(selected: Bool = false, radius: CGFloat = LoomTheme.Highlight.radius, key: String? = nil) -> some View {
        modifier(RowPill(selected: selected, radius: radius, key: key))
    }
}

/// A row that is a button. With a `radius` it draws the pill (hover, press, selection) and Loom's focus ring on the pill's
/// edge; without one it draws no state of its own, as before: the label (a project header) or a row around it does.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat?
    var key: String?

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected, radius: radius, key: key)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let radius: CGFloat?
        let key: String?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let _ = SidebarRenderProbe.pill(key)
            let ring = ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
            if let radius {
                let state = HighlightState.resolve(
                    selected: selected, hovering: hovering || LookEvidence.forcesHover(key),
                    pressed: configuration.isPressed, enabled: enabled)
                configuration.label
                    .background(RowHighlight(state: state, radius: radius))
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(ring ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing(for: contrast)))
                    .onHover { hovering = $0 }
            } else {
                configuration.label
                    .opacity(configuration.isPressed ? LoomTheme.Opacity.rowPressed : 1)
                    .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                        .strokeBorder(ring ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing(for: contrast))
                        .padding(-LoomTheme.Space.rowFocusOutset))
            }
        }
    }
}

// MARK: Evidence

/// Development evidence: holds one row's hover on, as the pointer would, so a screenshot can show it (the evidence run's
/// `hover:<key>` command). Off unless a run arms it: a row then reads nothing of it, and nothing is observed. Each key has a
/// flag of its own, so holding one row's hover re-evaluates that row's pill and no other.
@MainActor
final class HoverForce {
    @Observable
    final class Flag {
        var on = false
    }

    static let shared = HoverForce()
    var armed = false
    private var flags: [String: Flag] = [:]
    private(set) var held: String?

    func flag(for key: String) -> Flag {
        if let flag = flags[key] { return flag }
        let flag = Flag()
        flags[key] = flag
        return flag
    }

    func hold(_ key: String?) {
        if let held, held != key { flags[held]?.on = false }
        held = key
        if let key { flag(for: key).on = true }
    }
}

@MainActor
public enum LookEvidence {
    /// Called once at the start of an evidence run, before the first row draws.
    public static func arm() { HoverForce.shared.armed = true }

    /// Holds the hover on the row with this key (nil: none).
    public static func setHover(_ key: String?) { HoverForce.shared.hold(key) }

    public static var hoverKey: String? { HoverForce.shared.held }

    static func forcesHover(_ key: String?) -> Bool {
        guard let key, HoverForce.shared.armed else { return false }
        return HoverForce.shared.flag(for: key).on
    }
}
