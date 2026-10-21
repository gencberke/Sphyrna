import SwiftUI

// The control family as Settings draws it (DESIGN §6 Controls; the reference's `.seg`, `.sw`, `.popup`, `.stepper`, `.cbx`, `.lk2`):
// a segmented control, a switch, a checkbox, a stepper, a menu picker and a link-style button. The older `SegmentButtonStyle` and
// `SettingsButtonStyle` stay for the Changes tab.

// MARK: Segmented control

/// A 26 pt group on the hover fill with one chosen segment raised. `hover:segment:<title>` holds a segment's hover for a shot.
struct InkSegmented<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    let selection: Value
    var enabled = true
    let onSelect: (Value) -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    private typealias S = LoomTheme.Settings

    var body: some View {
        HStack(spacing: S.segmentGap) {
            ForEach(values, id: \.self) { value in
                InkSegment(title: title(value), chosen: value == selection, key: "segment:\(title(value))") { onSelect(value) }
            }
        }
        .padding(S.segmentPadding)
        .background(RoundedRectangle(cornerRadius: S.segmentGroupRadius).fill(LoomTheme.Surface.hover))
        .frame(height: S.segmentGroupHeight)
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
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    private typealias S = LoomTheme.Settings

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: S.segmentRadius)
        let lit = enabled && (hovering || LookEvidence.forcesHover(key))
        Button(action: action) {
            Text(title).projectType(S.segmentFont).lineLimit(1)
                .foregroundStyle(chosen || lit ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .padding(.horizontal, S.segmentPaddingH)
                .frame(height: S.segmentHeight)
                .background {
                    if chosen {
                        shape.fill(LoomTheme.Surface.segmentOn)
                            .shadow(color: S.segmentDrop, radius: S.segmentDropRadius, x: 0, y: S.segmentDropY)
                            .overlay(shape.strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
                    }
                }
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: S.segmentRadius)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// MARK: Switch

/// The switch: 28×16, the accent when on, a 12 pt knob. For VoiceOver it is a native switch (`accessibilityRepresentation`), so it reads
/// as one with its value. Hide the toggle's label (`labelsHidden`): the style draws no text.
struct InkSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Track(configuration: configuration) }

    private struct Track: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private typealias S = LoomTheme.Settings

        var body: some View {
            let travel = S.switchSize.width - S.switchKnob - 2 * S.switchInset
            Button { configuration.isOn.toggle() } label: {
                Capsule().fill(configuration.isOn ? S.switchOnFill : S.switchOffFill)
                    .frame(width: S.switchSize.width, height: S.switchSize.height)
                    .overlay(alignment: .leading) {
                        Circle().fill(S.switchKnobFill)
                            .shadow(color: S.switchKnobShadow, radius: 1, x: 0, y: 1)
                            .frame(width: S.switchKnob, height: S.switchKnob)
                            .offset(x: S.switchInset + (configuration.isOn ? travel : 0))
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Highlight.fadeDuration), value: configuration.isOn)
                    .controlFocusRing(
                        visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                        radius: S.switchSize.height / 2)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
        }
    }
}

// MARK: Checkbox

/// The checkbox: 14×14, radius 4, the stronger hairline for an edge; checked it is the accent with an on-accent check. The click
/// answers over 24×24; the layout takes 14. For VoiceOver it is a native checkbox (`accessibilityRepresentation`).
struct InkCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Box(configuration: configuration) }

    private struct Box: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        private typealias S = LoomTheme.Settings

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: S.checkboxRadius)
            let reach = (S.checkboxHit - S.checkboxSide) / 2
            Button { configuration.isOn.toggle() } label: {
                shape.fill(configuration.isOn ? LoomTheme.Accent.base : Color.clear)
                    .overlay { if !configuration.isOn { shape.strokeBorder(LoomTheme.Surface.strongerHairline, lineWidth: LoomTheme.Line.hairline) } }
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(S.checkboxGlyph).foregroundStyle(LoomTheme.Accent.onAccent)
                        }
                    }
                    .frame(width: S.checkboxSide, height: S.checkboxSide)
                    .controlFocusRing(
                        visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                        radius: S.checkboxRadius)
                    .padding(reach)
                    .contentShape(Rectangle())
                    .padding(-reach)
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox) }
        }
    }
}

// MARK: Stepper

/// What a stepper's buttons do: a step is held inside the range, and a button at an end does nothing.
enum StepperRule {
    static func canStep(_ value: Int, by direction: Int, in range: ClosedRange<Int>) -> Bool {
        direction < 0 ? value > range.lowerBound : value < range.upperBound
    }

    /// The value after a step, held inside the range (a value outside it comes to the nearest end).
    static func stepped(_ value: Int, by direction: Int, in range: ClosedRange<Int>) -> Int {
        let next = canStep(value, by: direction, in: range) ? value + (direction < 0 ? -1 : 1) : value
        return min(max(next, range.lowerBound), range.upperBound)
    }
}

/// The stepper: − and + around the value in mono, 26 high, a strong-hairline edge. A button at an end of the range is drawn at 38 %
/// and does nothing. VoiceOver adjusts it up and down.
struct InkStepper: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    /// The value as it reads ("30 days").
    let valueText: String
    var decreaseHelp = "Less"
    var increaseHelp = "More"
    let onChange: (Int) -> Void
    @Environment(\.isEnabled) private var enabled

    private typealias S = LoomTheme.Settings

    var body: some View {
        HStack(spacing: 0) {
            stepButton(-1, glyph: "minus", help: decreaseHelp)
            Text(valueText).projectType(S.stepperValue).monospacedDigit().foregroundStyle(LoomTheme.Text.primary)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .frame(minWidth: S.stepperValueMinWidth).frame(height: S.stepperHeight)
                .padding(.horizontal, LoomTheme.Line.hairline)
                .overlay(alignment: .leading) { rule }
                .overlay(alignment: .trailing) { rule }
            stepButton(1, glyph: "plus", help: increaseHelp)
        }
        .frame(height: S.stepperHeight)
        .clipShape(RoundedRectangle(cornerRadius: S.stepperRadius))
        .overlay(RoundedRectangle(cornerRadius: S.stepperRadius)
            .strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            if StepperRule.canStep(value, by: step, in: range) { onChange(StepperRule.stepped(value, by: step, in: range)) }
        }
    }

    private var rule: some View {
        Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(width: LoomTheme.Line.hairline)
    }

    private func stepButton(_ direction: Int, glyph: String, help: String) -> some View {
        Button { onChange(StepperRule.stepped(value, by: direction, in: range)) } label: {
            Image(systemName: glyph).font(S.stepperGlyph).frame(width: S.stepperButton, height: S.stepperHeight)
        }
        .buttonStyle(StepButtonStyle())
        .disabled(!StepperRule.canStep(value, by: direction, in: range))
        .help(help)
    }

    private struct StepButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Step(configuration: configuration) }

        private struct Step: View {
            let configuration: ButtonStyle.Configuration
            @State private var hovering = false
            @Environment(\.isEnabled) private var enabled

            var body: some View {
                let state = HighlightState.resolve(selected: false, hovering: hovering, pressed: configuration.isPressed, enabled: enabled)
                configuration.label
                    .foregroundStyle(state == .none ? LoomTheme.Text.secondary : LoomTheme.Text.primary)
                    .background(state.fill)
                    .contentShape(Rectangle())
                    .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                    .onHover { hovering = $0 }
            }
        }
    }
}

// MARK: Popup

/// A menu picker: a secondary button with the value and two chevrons. The menu is the system's until the popover menu replaces it; the
/// seam is this view. `icon` is the Mode picker's glyph in the mode's tone.
struct SettingsPopup<Value: Hashable, Items: View>: View {
    let title: String
    @Binding var selection: Value
    /// The value as it reads in the button.
    let valueText: String
    var icon: (symbol: String, color: Color)?
    @ViewBuilder let items: Items

    private typealias S = LoomTheme.Settings

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { items }
                .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: S.popupGap) {
                if let icon { Image(systemName: icon.symbol).font(S.popupIcon).foregroundStyle(icon.color) }
                Text(valueText).projectType(S.popupFont).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(S.popupChevron).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PopupButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
}

/// The popup's button: 26 high, radius 6, a strong-hairline edge (the stronger one with the hover fill under the pointer).
private struct PopupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast

        private typealias S = LoomTheme.Settings

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: S.popupRadius)
            let active = enabled && (hovering || configuration.isPressed)
            configuration.label
                .padding(.leading, S.popupPaddingLeading).padding(.trailing, S.popupPaddingTrailing)
                .frame(height: S.popupHeight)
                .background(shape.fill(active ? LoomTheme.Surface.hover : Color.clear))
                .overlay(shape.strokeBorder(edge(active: active), lineWidth: LoomTheme.Line.hairline))
                .contentShape(shape)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }

        private func edge(active: Bool) -> AnyShapeStyle {
            if contrast == .increased { return AnyShapeStyle(LoomTheme.Surface.hairlineStyle) }
            return AnyShapeStyle(active ? LoomTheme.Surface.strongerHairline : LoomTheme.Surface.strongHairline)
        }
    }
}

// MARK: Link

/// A link-style button at the end of a group label ("Select All", "Reset to Defaults"): 18 high, radius 6, medium 11.5 in secondary, the
/// hover fill and primary text under the pointer, drawn at 45 % when disabled.
struct SettingsLinkButtonStyle: ButtonStyle {
    var key: String?

    func makeBody(configuration: Configuration) -> some View { LinkFace(configuration: configuration, key: key) }

    private struct LinkFace: View {
        let configuration: ButtonStyle.Configuration
        let key: String?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        private typealias S = LoomTheme.Settings

        var body: some View {
            let active = enabled && (hovering || LookEvidence.forcesHover(key))
            let shape = RoundedRectangle(cornerRadius: S.linkRadius)
            configuration.label
                .projectType(S.linkFont)
                .foregroundStyle(active || configuration.isPressed ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .padding(.horizontal, S.linkPaddingH)
                .frame(height: S.linkHeight)
                .background(shape.fill(configuration.isPressed && enabled ? LoomTheme.Surface.pressed : (active ? LoomTheme.Surface.hover : .clear)))
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: S.linkRadius)
                .contentShape(shape)
                .opacity(enabled ? 1 : S.linkDisabled)
                .onHover { hovering = $0 }
        }
    }
}
