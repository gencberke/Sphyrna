import SwiftUI

/// The one hover and selection treatment (D-63, V25; the user's feedback of 18 Oct 2026, after Codex's rounded pill): a
/// rounded highlight under a row, inset from the edges of the list, card or popover it sits in. Every row, card, menu
/// row and chrome button draws it from these tokens (`RowHighlight`, `RowButtonStyle`, `ChromeButtonStyle`); only the
/// conversation tab strip keeps its own tinted tabs (D-50).
///
/// Selection reads stronger than hover: a stronger fill and a hairline. The fills are white overlays in Ink and ink
/// overlays in Paper, like every other fill, and are chosen so the text tiers hold on the pill (`ThemeAppearanceTests`,
/// `HighlightTests`): primary at least 7:1 under every state on the canvas and both raised levels, secondary and tertiary
/// at least 4.5:1 under the hover and selected fills on the canvas, and secondary at least 4.5:1 under the hover fill on a
/// popover.
extension LoomTheme {
    enum Highlight {
        /// A row or card of 34 pt and more; a row under 32 pt (a sidebar line, a Home row) takes the compact radius, a chrome
        /// button its own small one.
        static let radius: CGFloat = Radius.lg
        static let radiusCompact: CGFloat = Radius.md
        static let radiusControl: CGFloat = Radius.control
        /// How far the pill sits inside the edge of the list, card or popover that holds the rows.
        static let inset: CGFloat = 8

        /// Ink's fills (DESIGN §3 The pill): hover 5 %, selected 8 %, pressed 12 %; Paper 4.5 %, 7 %, 10 % of the ink.
        static let hoverOpacity = Surface.hoverOpacity
        static let selectedOpacity = Surface.selectedOpacity
        static let pressedOpacity = Surface.pressedOpacity
        static let hoverLightOpacity = Surface.hoverLightOpacity
        static let selectedLightOpacity = Surface.selectedLightOpacity
        static let pressedLightOpacity = Surface.pressedLightOpacity
        static let hoverTone = Surface.hoverTone
        static let selectedTone = Surface.selectedTone
        static let pressedTone = Surface.pressedTone
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
