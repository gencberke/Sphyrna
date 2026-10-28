import SwiftUI

/// The shared switch. A visible label is optional; VoiceOver always receives the native toggle and its value.
struct InkSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var showsLabel = false

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(InkSwitchStyle(showsLabel: showsLabel))
            .accessibilityLabel(title)
    }
}

struct InkSwitchStyle: ToggleStyle {
    var showsLabel = false

    func makeBody(configuration: Configuration) -> some View { Track(configuration: configuration, showsLabel: showsLabel) }

    private struct Track: View {
        let configuration: ToggleStyleConfiguration
        let showsLabel: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private typealias C = LoomTheme.Control

        var body: some View {
            let travel = C.switchSize.width - C.switchThumb - 2 * C.switchInset
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: showsLabel ? C.switchLabelGap : 0) {
                    if showsLabel {
                        configuration.label.font(LoomTheme.InkType.small.font).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    Capsule().fill(configuration.isOn ? C.switchOnFill : C.switchOffFill)
                        .frame(width: C.switchSize.width, height: C.switchSize.height)
                        .overlay(alignment: .leading) {
                            Circle().fill(C.switchThumbFill)
                                .frame(width: C.switchThumb, height: C.switchThumb)
                                .offset(x: C.switchInset + (configuration.isOn ? travel : 0))
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Highlight.fadeDuration), value: configuration.isOn)
                }
                .frame(minHeight: LoomTheme.Layout.minimumHitTarget.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(SwitchButtonStyle())
            .focusEffectDisabled()
            .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
        }
    }
}

/// ButtonStyle reads focus inside the button's environment, including when the switch has a visible label.
private struct SwitchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label.overlay(alignment: .trailing) {
                Color.clear.frame(width: LoomTheme.Control.switchSize.width, height: LoomTheme.Control.switchSize.height)
                    .controlFocusRing(
                        visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                        radius: LoomTheme.Control.switchSize.height / 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
