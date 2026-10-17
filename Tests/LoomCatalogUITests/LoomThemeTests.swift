import Testing
@testable import LoomCatalogUI

/// Contrast of today's token values (WCAG 2.x relative luminance). The sidebar
/// is a translucent tint over a material, so it is checked over the darkest
/// and the lightest backdrop and as the opaque Reduce Transparency color.
/// The lightest backdrop is what the dark `.sidebar` material passes of a pure
/// white window behind it: measured 0.38-0.51 per sRGB channel on macOS 27
/// (12 Oct 2026, captures at tint 0.86 and 0.6), taken as 0.5 gray.
struct LoomThemeTests {
    typealias RGB = LoomTheme.RGB
    private static let black = RGB(red: 0, green: 0, blue: 0)
    private static let white = RGB(red: 1, green: 1, blue: 1)

    private static let sidebarOpaque = LoomTheme.Surface.sidebarRGB
    private static let sidebarOverBlack = LoomTheme.Surface.sidebarRGB
        .composited(over: black, opacity: LoomTheme.Surface.sidebarTintOpacity)
    private static let materialOverWhite = RGB(red: 0.5, green: 0.5, blue: 0.5)
    private static let sidebarOverWhite = LoomTheme.Surface.sidebarRGB
        .composited(over: materialOverWhite, opacity: LoomTheme.Surface.sidebarTintOpacity)
    private static let panel = LoomTheme.Surface.panelRGB
    private static let selectedCard = white.composited(over: sidebarOpaque, opacity: LoomTheme.Surface.selectedOpacity)

    @Test func contrastMathMatchesTheWCAGReferences() {
        #expect(abs(Self.white.contrast(with: Self.black) - 21) < 0.001)
        #expect(abs(Self.white.contrast(with: Self.white) - 1) < 0.001)
        #expect(abs(RGB(red: 0.5, green: 0.5, blue: 0.5).luminance - 0.2140) < 0.001)
    }

    @Test func primaryTextIsAAAOnEverySurface() {
        for surface in [Self.sidebarOpaque, Self.sidebarOverBlack, Self.sidebarOverWhite, Self.panel, Self.selectedCard] {
            #expect(LoomTheme.Text.primaryRGB.contrast(with: surface) >= 7)
        }
    }

    @Test func secondaryTextIsAAOnTheSidebar() {
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOpaque) >= 4.5)
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOverBlack) >= 4.5)
        // The lighter tint the user chose (12 Oct 2026) trades AA over a white window behind
        // the sidebar (about 3.7:1 measured) for the glass look; it must not get any lower.
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOverWhite) >= 3)
    }

    @Test func secondaryTextIsAAOnPanelAndSelectedCard() {
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.panel) >= 4.5)
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.selectedCard) >= 4.5)
    }

    @Test func accentIsAAOnEverySurface() {
        for surface in [Self.sidebarOpaque, Self.sidebarOverBlack, Self.panel, Self.selectedCard] {
            #expect(LoomTheme.Accent.baseRGB.contrast(with: surface) >= 4.5)
        }
    }

    /// Light text on the accent fill is 2.2 to 3.0:1, so filled accent controls use dark text.
    @Test func accentFillCarriesDarkTextNotLightText() {
        #expect(LoomTheme.Accent.onAccentRGB.contrast(with: LoomTheme.Accent.baseRGB) >= 4.5)
        #expect(LoomTheme.Text.primaryRGB.contrast(with: LoomTheme.Accent.baseRGB) < 4.5)
    }

    /// Tertiary is for placeholders, disabled items and decoration only: not AA, but not invisible.
    @Test func tertiaryTextStaysReadableAsAPlaceholder() {
        for surface in [Self.sidebarOpaque, Self.panel, Self.selectedCard] {
            #expect(LoomTheme.Text.tertiaryRGB.contrast(with: surface) >= 2.5)
        }
    }

    @Test func statusColorsAreAAOnSidebarPanelAndSelectedCard() {
        for status in [LoomTheme.Status.attentionRGB, LoomTheme.Status.unviewedRGB, LoomTheme.Status.failureRGB] {
            for surface in [Self.sidebarOpaque, Self.sidebarOverBlack, Self.panel, Self.selectedCard] {
                #expect(status.contrast(with: surface) >= 4.5)
            }
        }
    }

    @Test func colorTokensAreBackedByTheirRGBData() {
        // The SwiftUI `Color` and the RGB data must not drift apart: one value, two views.
        #expect(LoomTheme.Surface.sidebarRGB == RGB(red: 0.043, green: 0.055, blue: 0.086))
        #expect(LoomTheme.Text.primaryRGB == RGB(hex: 0xECE8F4))
        #expect(LoomTheme.Text.secondaryRGB == RGB(hex: 0x9A9EB0))
        #expect(LoomTheme.Text.tertiaryRGB == RGB(hex: 0x636779))
        #expect(LoomTheme.Accent.baseRGB == RGB(hex: 0x8791CF))
        #expect(LoomTheme.Surface.sidebarTintOpacity == 0.6)
    }

    // MARK: Night Fleece 2 (concept §6.1)

    /// Every opaque level of the panel, back to front, with its name for failure messages.
    private static let levels: [(name: String, rgb: RGB)] = [
        ("inspector", LoomTheme.Surface.inspectorRGB), ("canvas", LoomTheme.Surface.canvasRGB),
        ("terminal", LoomTheme.Surface.terminalRGB), ("card", LoomTheme.Surface.cardRGB),
        ("raised", LoomTheme.Surface.raisedRGB), ("popover", LoomTheme.Surface.popoverRGB),
    ]
    private static let belowPopover = levels.filter { $0.name != "popover" }

    @Test func theNewSurfacesAndTextTokensHoldTheirValues() {
        #expect(Self.levels.map(\.rgb) == LoomTheme.Surface.panelLevelsRGB)
        #expect(Self.levels.map(\.rgb) == [RGB(hex: 0x141318), RGB(hex: 0x19181E), RGB(hex: 0x1D1C22),
                                            RGB(hex: 0x222128), RGB(hex: 0x2A2930), RGB(hex: 0x302F38)])
        // The terminal level is today's panel, read from the terminal's own theme.
        for (a, b) in [(LoomTheme.Surface.terminalRGB.red, Self.panel.red), (LoomTheme.Surface.terminalRGB.green, Self.panel.green),
                       (LoomTheme.Surface.terminalRGB.blue, Self.panel.blue)] {
            #expect(abs(a - b) < 0.5 / 255)
        }
        #expect(LoomTheme.Accent.highRGB == RGB(hex: 0xA9B0E3) && LoomTheme.Accent.lowRGB == RGB(hex: 0x5E68A8))
        #expect(LoomTheme.Status.attentionLightRGB == RGB(hex: 0xFFB547))
        #expect(LoomTheme.Status.unviewedLightRGB == RGB(hex: 0x8FB0FF))
        #expect(LoomTheme.Status.failureLightRGB == RGB(hex: 0xFF8A85))
        #expect(LoomTheme.Success.baseRGB == RGB(hex: 0x4CC38A) && LoomTheme.Success.lightRGB == RGB(hex: 0x7BDBA8))
        // Status hues are today's, written as hex like the concept.
        #expect(LoomTheme.Status.attentionRGB == RGB(hex: 0xFF9E0A))
        #expect(LoomTheme.Status.unviewedRGB == RGB(hex: 0x5C8CFF))
        #expect(LoomTheme.Status.failureRGB == RGB(hex: 0xF2615C))
        // Lines and fills: hairline 8 %, strong 13 %, fill 6 %, hover fill 9 %.
        #expect(LoomTheme.Surface.hairlineOpacity == 0.08 && LoomTheme.Surface.strongHairlineOpacity == 0.13)
        #expect(LoomTheme.Surface.controlOpacity == 0.06 && LoomTheme.Surface.controlHoverOpacity == 0.09)
        // The header's labels are the light variants.
        #expect(LoomTheme.Header.attentionLabelRGB == LoomTheme.Status.attentionLightRGB)
        #expect(LoomTheme.Header.failureLabelRGB == LoomTheme.Status.failureLightRGB)
        #expect(LoomTheme.Header.unviewedLabelRGB == LoomTheme.Status.unviewedLightRGB)
    }

    @Test func primaryAndSecondaryHoldTheirTiersOnEveryLevel() {
        for (name, level) in Self.levels {
            #expect(LoomTheme.Text.primaryRGB.contrast(with: level) >= 10.9, "primary on \(name)")
            #expect(LoomTheme.Text.secondaryRGB.contrast(with: level) >= 4.9, "secondary on \(name)")
            #expect(LoomTheme.Text.secondaryIncreasedRGB.contrast(with: level) >= LoomTheme.Text.secondaryRGB.contrast(with: level),
                    "Increase Contrast secondary on \(name)")
        }
    }

    @Test func tertiaryHoldsItsFloorOnEveryLevelButAPopover() {
        for (name, level) in Self.belowPopover {
            #expect(LoomTheme.Text.tertiaryRGB.contrast(with: level) >= 2.5, "tertiary on \(name)")
        }
    }

    @Test func accentAndStatusHuesAreAAOnEveryLevelButAPopover() {
        let hues: [(String, RGB)] = [
            ("accent", LoomTheme.Accent.baseRGB), ("attention", LoomTheme.Status.attentionRGB),
            ("unviewed", LoomTheme.Status.unviewedRGB), ("failure", LoomTheme.Status.failureRGB)]
        for (hue, rgb) in hues {
            for (name, level) in Self.belowPopover { #expect(rgb.contrast(with: level) >= 4.5, "\(hue) on \(name)") }
        }
        // Attention holds on a popover as well (6.4:1).
        #expect(LoomTheme.Status.attentionRGB.contrast(with: LoomTheme.Surface.popoverRGB) >= 4.5)
    }

    @Test func theHighAccentTheLightStatusVariantsAndSuccessAreAAOnEveryLevel() {
        let texts: [(String, RGB)] = [
            ("accent high", LoomTheme.Accent.highRGB), ("attention light", LoomTheme.Status.attentionLightRGB),
            ("unviewed light", LoomTheme.Status.unviewedLightRGB), ("failure light", LoomTheme.Status.failureLightRGB),
            ("success", LoomTheme.Success.baseRGB), ("success light", LoomTheme.Success.lightRGB)]
        for (text, rgb) in texts {
            for (name, level) in Self.levels { #expect(rgb.contrast(with: level) >= 4.5, "\(text) on \(name)") }
        }
    }

    @Test func textOnAFilledAccentStaysDark() {
        #expect(LoomTheme.Accent.onAccentRGB == LoomTheme.Surface.sidebarRGB)
        #expect(LoomTheme.Accent.onAccentRGB.contrast(with: LoomTheme.Accent.baseRGB) >= 6.4)
        #expect(LoomTheme.Accent.onAccentRGB.contrast(with: LoomTheme.Accent.highRGB) >= 4.5)
    }

    // The four pairs that fall short, and the rule for each (concept §6.1).

    @Test func ruleOneTertiaryOnAPopoverFallsShortSoPlaceholdersUseSecondary() {
        let popover = LoomTheme.Surface.popoverRGB
        #expect(LoomTheme.Text.tertiaryRGB.contrast(with: popover) < 2.5)
        #expect(abs(LoomTheme.Text.tertiaryRGB.contrast(with: popover) - 2.36) < 0.01)
        #expect(LoomTheme.OnPopover.placeholderRGB == LoomTheme.Text.secondaryRGB)
        #expect(LoomTheme.OnPopover.placeholderRGB.contrast(with: popover) >= 4.5)
    }

    @Test func ruleTwoBaseAccentTextOnAPopoverFallsShortSoItUsesTheHighAccent() {
        let popover = LoomTheme.Surface.popoverRGB
        #expect(LoomTheme.Accent.baseRGB.contrast(with: popover) < 4.5)
        #expect(abs(LoomTheme.Accent.baseRGB.contrast(with: popover) - 4.39) < 0.01)
        #expect(LoomTheme.OnPopover.accentRGB == LoomTheme.Accent.highRGB)
        #expect(abs(LoomTheme.OnPopover.accentRGB.contrast(with: popover) - 6.3) < 0.05)
    }

    @Test func ruleThreeUnviewedAndFailureOnAPopoverFallShortSoTheyUseTheirLightVariants() {
        let popover = LoomTheme.Surface.popoverRGB
        for (plain, light) in [(LoomTheme.Status.unviewedRGB, LoomTheme.OnPopover.unviewedRGB),
                               (LoomTheme.Status.failureRGB, LoomTheme.OnPopover.failureRGB)] {
            #expect(plain.contrast(with: popover) < 4.5 && abs(plain.contrast(with: popover) - 4.2) < 0.05)
            #expect(light.contrast(with: popover) >= 4.5)
        }
        #expect(LoomTheme.OnPopover.unviewedRGB == LoomTheme.Status.unviewedLightRGB)
        #expect(LoomTheme.OnPopover.failureRGB == LoomTheme.Status.failureLightRGB)
    }

    @Test func ruleFourTheLowAccentNeverCarriesText() {
        #expect(LoomTheme.Text.primaryRGB.contrast(with: LoomTheme.Accent.lowRGB) < 4.5)
        #expect(abs(LoomTheme.Text.primaryRGB.contrast(with: LoomTheme.Accent.lowRGB) - 4.33) < 0.01)
        // No text token is the low accent.
        let texts = [LoomTheme.Text.primaryRGB, LoomTheme.Text.secondaryRGB, LoomTheme.Text.tertiaryRGB,
                     LoomTheme.Text.secondaryIncreasedRGB, LoomTheme.Text.secondaryOnTintRGB, LoomTheme.Accent.baseRGB,
                     LoomTheme.Accent.highRGB, LoomTheme.OnPopover.placeholderRGB, LoomTheme.OnPopover.accentRGB,
                     LoomTheme.OnPopover.unviewedRGB, LoomTheme.OnPopover.failureRGB, LoomTheme.Success.baseRGB]
        #expect(!texts.contains(LoomTheme.Accent.lowRGB))
    }

    @Test func shapeTypeRhythmAndDepthTokensHoldTheConceptsValues() {
        typealias R = LoomTheme.Radius
        #expect([R.xs, R.sm, R.md, R.lg, R.xl, R.xxl] == [4, 6, 8, 10, 14, 18])
        #expect(R.block == 12 && R.floating == 14)
        // Today's role radii are scale steps.
        #expect([R.bar, R.control, R.search, R.panel] == [R.xs, R.sm, R.md, R.lg])
        #expect(LoomTheme.TypeScale.readingSize == 14 && LoomTheme.TypeScale.readingLineHeight == 22)
        #expect(LoomTheme.TypeScale.terminalSize == 14)
        #expect(LoomTheme.Rhythm.grid == 4 && LoomTheme.Rhythm.readingColumn == 700 && LoomTheme.Rhythm.sessionCardRow == 46)
        #expect(LoomTheme.Rhythm.inspectorWidth == 328 && LoomTheme.Rhythm.inspectorWidthReview == 556)
        #expect(LoomTheme.Depth.card.shadow.blur == 2)
        #expect(LoomTheme.Depth.raised.shadow.blur == 28)
        #expect(LoomTheme.Depth.popover.shadow.blur == 64 && LoomTheme.Depth.popover.ring == 0.08)
    }

    // MARK: Glass | Solid (D-57)

    @Test func theSidebarTintIsTodaysForGlassAndOpaqueForSolid() {
        #expect(LoomTheme.Surface.sidebarTintOpacity(for: .glass) == 0.6)
        #expect(LoomTheme.Surface.sidebarTintOpacity(for: .solid) == 1)
    }

    @Test func reduceTransparencyDrawsSolidWhateverTheStyleIs() {
        typealias Background = SidebarBackground
        #expect(Background.effectiveStyle(.glass, reduceTransparency: false) == .glass)
        #expect(Background.effectiveStyle(.glass, reduceTransparency: true) == .solid)
        #expect(Background.effectiveStyle(.solid, reduceTransparency: false) == .solid)
        #expect(Background.effectiveStyle(.solid, reduceTransparency: true) == .solid)
    }

    @Test func solidSidebarCarriesTheTextTiersAsTheOpaqueTintDid() {
        // Solid is the opaque tint: the same surface the Reduce Transparency fallback always was.
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOpaque) >= 4.9)
        #expect(LoomTheme.Text.primaryRGB.contrast(with: Self.sidebarOpaque) >= 10.9)
    }
}
