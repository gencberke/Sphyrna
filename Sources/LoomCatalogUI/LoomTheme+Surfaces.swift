import SwiftUI

/// Night Fleece 2 surfaces and lines (design/DESIGN.md §3, concept §6.1). Values are `RGB` data first so
/// `LoomThemeTests` can compute contrast; the `Color` is derived. Back to front: sidebar glass, backdrop,
/// inspector, chat canvas, terminal (= `Surface.panel`), card, raised, popover.
extension LoomTheme.Surface {
    static let inspectorRGB = LoomTheme.RGB(hex: 0x141318)
    static let canvasRGB = LoomTheme.RGB(hex: 0x19181E)
    /// Today's panel colour; `panelRGB` reads it from `TerminalTheme`, and `LoomThemeTests` pins the two together.
    static let terminalRGB = LoomTheme.RGB(hex: 0x1D1C22)
    /// Cards and the composer.
    static let cardRGB = LoomTheme.RGB(hex: 0x222128)
    /// Raised surfaces and hover.
    static let raisedRGB = LoomTheme.RGB(hex: 0x2A2930)
    /// Popovers and the palette.
    static let popoverRGB = LoomTheme.RGB(hex: 0x302F38)

    static let inspector = inspectorRGB.color
    static let canvas = canvasRGB.color
    static let card = cardRGB.color
    static let raised = raisedRGB.color
    static let popover = popoverRGB.color

    /// Every opaque surface in the panel, back to front: the contrast tests walk this list.
    static let panelLevelsRGB = [inspectorRGB, canvasRGB, terminalRGB, cardRGB, raisedRGB, popoverRGB]

    /// The strong hairline (white 13 %) for a border that must hold on a raised surface; the plain
    /// hairline is `hairline` (8 %).
    static let strongHairlineOpacity = 0.13
    static let strongHairline = Color.white.opacity(strongHairlineOpacity)

    /// The dark tone over the sidebar material for a style (D-57): Glass is today's 0.6, Solid is opaque.
    static func sidebarTintOpacity(for style: SidebarStyle) -> Double {
        switch style {
        case .glass: sidebarTintOpacity
        case .solid: 1
        }
    }
}
