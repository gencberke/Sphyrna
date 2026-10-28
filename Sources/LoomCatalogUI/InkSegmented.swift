import SwiftUI

/// A 32 pt muted track with the chosen segment lifted. The evidence key defaults to the segment's title.
struct InkSegmented<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    let selection: Value
    var enabled = true
    var key: ((Value) -> String)?
    let onSelect: (Value) -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    private typealias C = LoomTheme.Control

    var body: some View {
        HStack(spacing: C.segmentGap) {
            ForEach(values, id: \.self) { value in
                InkSegment(title: title(value), chosen: value == selection,
                           key: key?(value) ?? "segment:\(title(value))") { onSelect(value) }
            }
        }
        .padding(C.segmentInset)
        .background(RoundedRectangle(cornerRadius: C.segmentGroupRadius).fill(LoomTheme.Surface.muted))
        .frame(height: C.segmentedHeight)
        .fixedSize()
        .disabled(!enabled)
        .opacity(enabled && environmentEnabled ? 1 : LoomTheme.Opacity.disabled)
        .accessibilityElement(children: .contain)
    }
}

private struct InkSegment: View {
    let title: String
    let chosen: Bool
    let key: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(InkSegmentStyle(chosen: chosen, key: key))
            .focusEffectDisabled()
            .accessibilityLabel(title)
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct InkSegmentStyle: ButtonStyle {
    let chosen: Bool
    let key: String

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, chosen: chosen, key: key)
    }

    private struct Face: View {
        let configuration: ButtonStyle.Configuration
        let chosen: Bool
        let key: String
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private typealias C = LoomTheme.Control

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: C.segmentRadius)
            let lit = enabled && (hovering || LookEvidence.forcesHover(key))
            let pressed = enabled && configuration.isPressed
            configuration.label
                .projectType(C.segmentFont).lineLimit(1)
                .foregroundStyle(chosen || lit || pressed ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .padding(.horizontal, C.segmentPaddingH)
                .frame(height: C.segmentedHeight - 2 * C.segmentInset)
                .background {
                    if chosen {
                        shape.fill(LoomTheme.Surface.segmentOn)
                            .depth(LoomTheme.Elevation.lift)
                            .overlay(shape.strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
                    } else if pressed {
                        shape.fill(LoomTheme.Surface.pressed)
                    } else if lit {
                        shape.fill(LoomTheme.Surface.hover)
                    }
                }
                .animation(LoomTheme.Motion.animation(.selection, reduceMotion: reduceMotion), value: lit)
                .animation(LoomTheme.Motion.animation(.selection, reduceMotion: reduceMotion), value: chosen)
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: C.segmentRadius)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}
