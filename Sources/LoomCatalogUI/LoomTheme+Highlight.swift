import SwiftUI

/// The one hover and selection treatment (D-63, V25; the user's feedback of 18 Oct 2026, after Codex's rounded pill): a
/// rounded highlight under a row, inset from the edges of the list, card or popover it sits in. Every row, card, menu
/// row and chrome button draws it from these tokens (`RowHighlight`, `RowButtonStyle`, `ChromeButtonStyle`); only the
/// conversation tab strip keeps its own tinted tabs (D-50).
///
/// Selection reads stronger than hover: a stronger fill and a hairline. The fills are white overlays in Dark and ink
/// overlays in Light, like every other fill, and are chosen so the text tiers hold on the pill (`ThemeAppearanceTests`):
/// primary at least 7:1 on every surface under every state, secondary at least 4.5:1 under the selected fill on the
/// sidebar, panel, canvas, inspector and card, and at least 4.0:1 under the hover fill on a popover, where a plain 4.5:1
/// leaves room for no visible fill at all.
extension LoomTheme {
    enum Highlight {
        /// A row or card of 34 pt and more; a row under 32 pt (a sidebar line, a Home row) takes the compact radius, a chrome
        /// button its own small one.
        static let radius: CGFloat = Radius.lg
        static let radiusCompact: CGFloat = Radius.md
        static let radiusControl: CGFloat = Radius.control
        /// How far the pill sits inside the edge of the list, card or popover that holds the rows.
        static let inset: CGFloat = 8

        static let hoverOpacity = 0.06
        static let selectedOpacity = 0.09
        static let pressedOpacity = 0.12
        static let hoverLightOpacity = 0.05
        static let selectedLightOpacity = 0.07
        static let pressedLightOpacity = 0.10
        static let hoverTone = overlay(dark: hoverOpacity, light: hoverLightOpacity)
        static let selectedTone = overlay(dark: selectedOpacity, light: selectedLightOpacity)
        static let pressedTone = overlay(dark: pressedOpacity, light: pressedLightOpacity)
        static let hover = hoverTone.color
        static let selected = selectedTone.color
        static let pressed = pressedTone.color

        /// Under Increase Contrast the fill is drawn at this share of its opacity and the hairline carries the state (a stronger
        /// pill would take the lifted secondary text under 7:1).
        static let increasedFillScale = 0.75

        /// The fade in and out, 120 ms; instant under Reduce Motion.
        static let fadeDuration = Motion.selectionDuration
    }
}
