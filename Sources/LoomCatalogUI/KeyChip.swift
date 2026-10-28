import SwiftUI

/// A shortcut in SF Mono 11, with the same hairline cap in menus, the palette and the sidebar.
struct KeyChip: View {
    let text: String
    /// A hint whose parent already has a label is decorative; a standalone spoken hint opts in.
    var isDecorative = true

    var body: some View {
        Text(text).font(LoomTheme.InkType.meta.font)
            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .padding(.horizontal, LoomTheme.Control.keyCapPaddingH)
            .frame(minWidth: LoomTheme.Control.keyCapMinSide, minHeight: LoomTheme.Control.keyCapMinSide)
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Control.keyCapRadius)
                .strokeBorder(LoomTheme.Surface.strongEdgeStyle, lineWidth: LoomTheme.Line.hairline))
            .accessibilityHidden(isDecorative)
    }
}
