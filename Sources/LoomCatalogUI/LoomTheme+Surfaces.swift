import SwiftUI

/// Night Fleece 2 surfaces and lines (design/DESIGN.md §3, concept §6.1). Values are `RGB` data first so
/// `LoomThemeTests` can compute contrast; the `Color` is derived. Back to front: sidebar glass, backdrop,
/// inspector, chat canvas, terminal (= `Surface.panel`), card, raised, popover.
extension LoomTheme.Surface {
    // The panel family in Night fleece, Dark: the values these names always had. The other tones and Light are
    // `levels(_:tone:)`; the colours views draw are `inspector`, `canvas`, `card`, `raised` and `popover` below, which follow the
    // appearance and the tone.
    static let inspectorRGB = LoomTheme.RGB(hex: 0x141318)
    static let canvasRGB = LoomTheme.RGB(hex: 0x19181E)
    /// Today's panel colour, the default tone's terminal background (`TerminalTheme.defaultBackgroundRGB`); `LoomThemeTests`
    /// pins the two together.
    static let terminalRGB = LoomTheme.RGB(hex: 0x1D1C22)
    /// Cards and the composer.
    static let cardRGB = LoomTheme.RGB(hex: 0x222128)
    /// Raised surfaces and hover.
    static let raisedRGB = LoomTheme.RGB(hex: 0x2A2930)
    /// Popovers and the palette.
    static let popoverRGB = LoomTheme.RGB(hex: 0x302F38)

    static var inspector: Color { current.inspector }
    static var canvas: Color { current.canvas }
    static var card: Color { current.card }
    static var raised: Color { current.raised }
    static var popover: Color { current.popover }

    /// Every opaque surface in the panel, back to front, in Night fleece Dark: the contrast tests walk this list (and
    /// `levels(_:tone:)` for the other appearance and tones).
    static let panelLevelsRGB = [inspectorRGB, canvasRGB, terminalRGB, cardRGB, raisedRGB, popoverRGB]

    /// The strong hairline (white 13 %, ink 16 % in Light) for a border that must hold on a raised surface; the plain
    /// hairline is `hairline` (8 %).
    static let strongHairlineOpacity = 0.13
    static let strongHairlineLightOpacity = 0.16
    static let strongHairlineTone = LoomTheme.overlay(dark: strongHairlineOpacity, light: strongHairlineLightOpacity)
    static let strongHairline = strongHairlineTone.color

    /// The scrim behind the command palette: black at 40 % in Dark, the warm ink at 22 % in Light.
    static let scrimOpacity = 0.4
    static let scrimLightOpacity = 0.22
    static let scrim = LoomTheme.AdaptiveTone(
        dark: LoomTheme.Tone(rgb: LoomTheme.RGB(red: 0, green: 0, blue: 0), opacity: scrimOpacity),
        light: LoomTheme.Tone(rgb: LoomTheme.inkRGB, opacity: scrimLightOpacity)).color

    /// The dark tone over the sidebar material for a style (D-57): Glass is today's 0.6, Solid is opaque.
    static func sidebarTintOpacity(for style: SidebarStyle) -> Double {
        switch style {
        case .glass: sidebarTintOpacity
        case .solid: 1
        }
    }
}
