import SwiftUI
import Testing
@testable import LoomCatalogUI

/// Ink's values as data (WCAG 2.x relative luminance): the contrast math, the tokens that hold their RGB data, the type,
/// radius and height scale, and the sidebar's Glass | Solid tint. The floors per appearance and tone are in
/// `ThemeAppearanceTests`. The sidebar is a translucent tint over a material, so it is checked over the darkest and the
/// lightest backdrop and as the opaque Reduce Transparency color. The lightest backdrop is what the dark `.sidebar`
/// material passes of a pure white window behind it: measured 0.38-0.51 per sRGB channel on macOS 27 (12 Oct 2026,
/// captures at tint 0.86 and 0.6), taken as 0.5 gray.
struct LoomThemeTests {
    typealias RGB = LoomTheme.RGB
    private static let black = RGB(red: 0, green: 0, blue: 0)
    private static let white = RGB(red: 1, green: 1, blue: 1)

    private static let neutral = LoomTheme.Surface.greys(.dark, tone: .neutral)
    /// The sidebar is Neutral's Ink canvas: opaque, over black, and over the glass's lightest extreme.
    private static let sidebarOpaque = neutral.canvas
    private static let sidebarOverBlack = sidebarOpaque.composited(over: black, opacity: LoomTheme.Surface.sidebarTintOpacity)
    private static let sidebarOverWhite = sidebarOpaque
        .composited(over: RGB(red: 0.5, green: 0.5, blue: 0.5), opacity: LoomTheme.Surface.sidebarTintOpacity)
    private static let selectedCard = white.composited(over: sidebarOpaque, opacity: LoomTheme.Surface.selectedOpacity)

    @Test func contrastMathMatchesTheWCAGReferences() {
        #expect(abs(Self.white.contrast(with: Self.black) - 21) < 0.001)
        #expect(abs(Self.white.contrast(with: Self.white) - 1) < 0.001)
        #expect(abs(RGB(red: 0.5, green: 0.5, blue: 0.5).luminance - 0.2140) < 0.001)
    }

    @Test func primaryTextIsAAAOnEverySidebarSurface() {
        for surface in [Self.sidebarOpaque, Self.sidebarOverBlack, Self.sidebarOverWhite, Self.selectedCard] {
            #expect(LoomTheme.Text.primaryRGB.contrast(with: surface) >= 7)
        }
    }

    @Test func secondaryTextIsAAOnTheSidebar() {
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOpaque) >= 4.5)
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOverBlack) >= 4.5)
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.selectedCard) >= 4.5)
        // The lighter tint the user chose (12 Oct 2026) trades AA over a white window behind the sidebar for the glass
        // look; it must not get any lower.
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOverWhite) >= 3)
    }

    /// Light text on the accent fill is 3.0:1, so filled accent controls use the dark on-accent text.
    @Test func accentFillCarriesTheOnAccentTextNotLightText() {
        #expect(LoomTheme.Accent.onAccentRGB.contrast(with: LoomTheme.Accent.baseRGB) >= 4.5)
        #expect(LoomTheme.Text.primaryRGB.contrast(with: LoomTheme.Accent.baseRGB) < 4.5)
    }

    @Test func colorTokensAreBackedByTheirRGBData() {
        // The SwiftUI `Color` and the RGB data must not drift apart: one value, two views.
        #expect(LoomTheme.Text.primaryRGB == RGB(hex: 0xECECEF))
        #expect(LoomTheme.Text.secondaryRGB == RGB(hex: 0x9E9EA8))
        #expect(LoomTheme.Text.tertiaryRGB == RGB(hex: 0x868690))
        #expect(LoomTheme.Text.faintRGB == RGB(hex: 0x6B6B75))
        #expect(LoomTheme.Accent.baseRGB == RGB(hex: 0x8791CF))
        #expect(LoomTheme.Accent.onAccentRGB == RGB(hex: 0x0B0E16))
        #expect(LoomTheme.Surface.sidebarTintOpacity == 0.8)
        #expect(LoomTheme.inkRGB == RGB(hex: 0x1E1C1A))
    }

    @Test func theHighAccentTheTextVariantsAndSuccessKeepTheirInkValues() {
        #expect(LoomTheme.Accent.highRGB == RGB(hex: 0xA9B0E3) && LoomTheme.Accent.lowRGB == RGB(hex: 0x5E68A8))
        #expect(LoomTheme.Status.attentionLightRGB == RGB(hex: 0xFFB547))
        #expect(LoomTheme.Status.unviewedLightRGB == RGB(hex: 0x8FB0FF))
        #expect(LoomTheme.Status.failureLightRGB == RGB(hex: 0xFF8A85))
        #expect(LoomTheme.Success.baseRGB == RGB(hex: 0x4CC38A) && LoomTheme.Success.lightRGB == RGB(hex: 0x7BDBA8))
        #expect(LoomTheme.Status.attentionRGB == RGB(hex: 0xFF9E0A))
        #expect(LoomTheme.Status.unviewedRGB == RGB(hex: 0x5C8CFF))
        #expect(LoomTheme.Status.failureRGB == RGB(hex: 0xF2615C))
        // The header's labels are the text variants.
        #expect(LoomTheme.Header.attentionLabelRGB == LoomTheme.Status.attentionLightRGB)
        #expect(LoomTheme.Header.failureLabelRGB == LoomTheme.Status.failureLightRGB)
        #expect(LoomTheme.Header.unviewedLabelRGB == LoomTheme.Status.unviewedLightRGB)
    }

    @Test func onAPopoverQuietTextIsSecondaryAndAccentTextIsTheHighStep() {
        let popover = Self.neutral.popover
        #expect(LoomTheme.OnPopover.placeholderPair == LoomTheme.Text.secondaryPair)
        #expect(LoomTheme.OnPopover.placeholderRGB.contrast(with: popover) >= 4.5)
        #expect(LoomTheme.OnPopover.accentPair == LoomTheme.Accent.highPair)
        #expect(LoomTheme.OnPopover.unviewedPair == LoomTheme.Status.unviewedLightPair)
        #expect(LoomTheme.OnPopover.failurePair == LoomTheme.Status.failureLightPair)
        // Ink's hover fill leaves plain secondary readable on a popover row, so the Night Fleece lift is gone.
        #expect(LoomTheme.OnPopover.hoveredSecondaryPair == LoomTheme.Text.secondaryPair)
        #expect(LoomTheme.OnPopover.secondary(lit: true) == LoomTheme.OnPopover.secondary(lit: false))
    }

    @Test func theLowAccentNeverCarriesText() {
        // No text token is the low accent.
        let texts = [LoomTheme.Text.primaryRGB, LoomTheme.Text.secondaryRGB, LoomTheme.Text.tertiaryRGB, LoomTheme.Text.faintRGB,
                     LoomTheme.Text.secondaryIncreasedRGB, LoomTheme.Text.secondaryOnTintRGB, LoomTheme.Accent.baseRGB,
                     LoomTheme.Accent.highRGB, LoomTheme.OnPopover.placeholderRGB, LoomTheme.OnPopover.accentRGB,
                     LoomTheme.OnPopover.unviewedRGB, LoomTheme.OnPopover.failureRGB, LoomTheme.Success.baseRGB]
        #expect(!texts.contains(LoomTheme.Accent.lowRGB))
    }

    // MARK: Ink's scale (tokens for the surface slices; no view draws with them yet)

    @Test func inkTypeRolesHoldDesignsScale() {
        typealias T = LoomTheme.InkType
        #expect(T.display.size == 46 && T.display.weight == .ultraLight && T.display.tracking == -0.03 && T.display.display)
        #expect(T.statement.size == 42 && T.statement.weight == .ultraLight && T.statement.tracking == -0.03)
        #expect(T.title.size == 20 && T.title.weight == .semibold)
        #expect(T.header.size == 13 && T.header.weight == .semibold)
        #expect(T.body.size == 13 && T.body.weight == .regular)
        #expect(T.button.size == 12.5 && T.button.weight == .medium)
        #expect(T.pageButton.size == 13 && T.smallButton.size == 11.5 && T.small.size == 12)
        #expect(T.label.size == 10.5 && T.label.mono && T.label.capitals && T.label.tracking == 0.09)
        #expect(T.meta.size == 11 && T.meta.mono && T.metaLarge.size == 11.5 && T.metaLarge.mono)
        #expect(T.reading.size == 14 && T.reading.lineHeight == 22)
        #expect(T.code.size == 12.5 && T.code.mono && T.code.lineHeight == 20)
        #expect(abs(T.display.trackingPoints - -1.38) < 0.001)
    }

    @Test func inkRadiiAndHeightsHoldDesignsScale() {
        typealias R = LoomTheme.InkRadius
        #expect([R.key, R.control, R.row, R.activityCard, R.card, R.composer] == [4, 6, 8, 10, 12, 18])
        #expect(R.group == 7 && R.groupInner == 5 && R.palette == 14)
        typealias H = LoomTheme.InkHeight
        #expect([H.chip, H.subagentRow, H.control, H.sidebarRow, H.field, H.tabRow, H.composerBar, H.header]
                == [22, 24, 26, 28, 30, 36, 38, 52])
        // Today's view-facing scale is untouched, and the Usage figure keeps its name.
        typealias R0 = LoomTheme.Radius
        #expect([R0.xs, R0.sm, R0.md, R0.lg, R0.xl, R0.xxl] == [4, 6, 8, 10, 14, 18] && R0.block == 12 && R0.floating == 14)
        #expect([R0.bar, R0.control, R0.search, R0.panel] == [R0.xs, R0.sm, R0.md, R0.lg])
        #expect(LoomTheme.TypeScale.readingSize == 14 && LoomTheme.TypeScale.readingLineHeight == 22)
        #expect(LoomTheme.TypeScale.terminalSize == 14)
        #expect(LoomTheme.Rhythm.grid == 4 && LoomTheme.Rhythm.readingColumn == 700 && LoomTheme.Rhythm.sessionCardRow == 46)
        #expect(LoomTheme.Rhythm.inspectorWidth == 328 && LoomTheme.Rhythm.inspectorWidthReview == 556
                && LoomTheme.Rhythm.inspectorWidthSide == 392)
    }

    // MARK: Glass | Solid (D-57)

    @Test func theSidebarTintIsTheCanvasAtEightTenthsForGlassAndOpaqueForSolid() {
        #expect(LoomTheme.Surface.sidebarTintOpacity(for: .glass) == 0.8)
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
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOpaque) >= 7)
        #expect(LoomTheme.Text.primaryRGB.contrast(with: Self.sidebarOpaque) >= 15)
    }
}
