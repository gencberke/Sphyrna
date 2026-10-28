import SwiftUI

/// The field's own content retains its binding, focus, submit handling and accessibility. This wrapper draws the v4 field.
struct InkField<Content: View>: View {
    let focused: Bool
    var hasError = false
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Control.fieldRadius)
        content
            .textFieldStyle(.plain)
            .font(LoomTheme.InkType.body.font)
            .foregroundStyle(LoomTheme.Text.primary)
            .padding(.horizontal, LoomTheme.Control.fieldPaddingH)
            .frame(height: LoomTheme.Control.fieldHeight)
            .background(shape.fill(LoomTheme.Surface.inputFill))
            .overlay(shape.strokeBorder(hasError ? LoomTheme.Status.failure : LoomTheme.Surface.inputEdge,
                                        lineWidth: LoomTheme.Line.hairline))
            .controlFocusRing(
                visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                radius: LoomTheme.Control.fieldRadius)
            .focusEffectDisabled()
    }
}
