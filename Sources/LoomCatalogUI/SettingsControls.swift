import SwiftUI

// Settings-specific checkbox, stepper and menu picker. The switch and segmented control live in the shared Ink family.

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

/// The stepper: − and + around the value in mono, 32 high, a strong-hairline edge. A button at an end of the range is drawn at 38 %
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
        .buttonStyle(ChromeButtonStyle(size: CGSize(width: S.stepperButton, height: S.stepperHeight)))
        .focusEffectDisabled()
        .disabled(!StepperRule.canStep(value, by: direction, in: range))
        .help(help)
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
        .buttonStyle(ControlButtonStyle(kind: .secondary, size: .page))
        .focusEffectDisabled()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
}
