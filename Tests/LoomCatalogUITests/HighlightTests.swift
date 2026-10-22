import SwiftUI
import Testing
@testable import LoomCatalogUI

/// V25: the one hover and selection treatment (`LoomTheme.Highlight`, `RowHighlight`), its contrast in both appearances (Ink,
/// Paper) on every tone, and
/// the 4 pt grid of the gaps and paddings the spacing pass moved.
struct HighlightTests {
    typealias RGB = LoomTheme.RGB
    typealias Appearance = LoomTheme.Appearance

    private static let white = RGB(red: 1, green: 1, blue: 1)
    private static let black = RGB(red: 0, green: 0, blue: 0)

    // MARK: State

    @Test func aPressedRowBeatsASelectedOneAndASelectedRowKeepsItsFillUnderThePointer() {
        typealias S = HighlightState
        #expect(S.resolve(selected: false, hovering: false) == .none)
        #expect(S.resolve(selected: false, hovering: true) == .hover)
        #expect(S.resolve(selected: true, hovering: false) == .selected)
        #expect(S.resolve(selected: true, hovering: true) == .selected, "selection stays the stronger fill under the pointer")
        #expect(S.resolve(selected: true, hovering: true, pressed: true) == .pressed)
        #expect(S.resolve(selected: false, hovering: true, pressed: true) == .pressed)
    }

    @Test func aDisabledRowShowsNeitherHoverNorPress() {
        typealias S = HighlightState
        #expect(S.resolve(selected: false, hovering: true, pressed: true, enabled: false) == .none)
        #expect(S.resolve(selected: true, hovering: true, pressed: true, enabled: false) == .selected)
    }

    @Test func selectionAlwaysCarriesTheHairlineAndIncreaseContrastAddsItToHoverAndPress() {
        typealias S = HighlightState
        for contrast in [ColorSchemeContrast.standard, .increased] {
            #expect(S.selected.drawsStroke(for: contrast))
            #expect(!S.none.drawsStroke(for: contrast))
        }
        #expect(!S.hover.drawsStroke(for: .standard) && S.hover.drawsStroke(for: .increased))
        #expect(!S.pressed.drawsStroke(for: .standard) && S.pressed.drawsStroke(for: .increased))
    }

    // MARK: Tokens

    @Test func theTokensHoldTheirValuesAndSelectionIsStrongerThanHover() {
        #expect(LoomTheme.Highlight.radius == 10 && LoomTheme.Highlight.radiusCompact == 8 && LoomTheme.Highlight.radiusControl == 6)
        #expect(LoomTheme.Highlight.inset == 8)
        #expect(LoomTheme.Highlight.fadeDuration == 0.12 && LoomTheme.Highlight.fadeDuration == LoomTheme.Motion.selectionDuration)
        for appearance in Appearance.allCases {
            let hover = HighlightState.hover.tone![appearance].opacity
            let selected = HighlightState.selected.tone![appearance].opacity
            let pressed = HighlightState.pressed.tone![appearance].opacity
            #expect(hover < selected && selected < pressed, "\(appearance): hover \(hover), selected \(selected), pressed \(pressed)")
        }
        // The pill is white over Dark and the warm ink over Light, like every other overlay.
        #expect(HighlightState.hover.tone![.dark].rgb == Self.white && HighlightState.hover.tone![.light].rgb == LoomTheme.inkRGB)
        #expect(HighlightState.none.tone == nil)
    }

    @Test func reduceMotionMakesTheFadeInstantAndOtherwiseItIsTheSelectionFade() {
        #expect(LoomTheme.Motion.animation(.selection, reduceMotion: true) == nil)
        #expect(LoomTheme.Motion.animation(.selection, reduceMotion: false) != nil)
    }

    @Test func theMenusPopoversAndThePaletteShareThePillsRadiusAndInset() {
        #expect(LoomTheme.Composer.pickRowRadius == LoomTheme.Highlight.radius)
        // In the mode list and the / and @ menus the pill sits DESIGN's 6 inside the edge (§6 Controls, §11 Menus), as in the
        // host's other popovers and menus.
        #expect(LoomTheme.Composer.pickInset == 6)
        #expect(LoomTheme.Composer.menuInset == 6)
        #expect(LoomTheme.Host.menuInset == 6)
        #expect(PaletteMetrics.rowRadius == LoomTheme.Highlight.radius)
        #expect(PaletteMetrics.listPadding == LoomTheme.Highlight.inset)
        #expect(LoomTheme.ProjectPage.rowRadius == LoomTheme.Highlight.radiusCompact, "the project page's rows are DESIGN's 8")
        #expect(LoomTheme.Layout.minimumHitTarget == CGSize(width: 24, height: 24))
        #expect(ChromeButtonStyle.hitSize(for: LoomTheme.Layout.projectMenuButton).height >= 24, "a pill never shrinks a hit area")
    }

    // MARK: Contrast

    /// Every level a row sits on, in each tone: the canvas, both raised levels and the popover (DESIGN §3 Contrast).
    private static func surfaces(_ appearance: Appearance) -> [(name: String, rgb: RGB, level: String)] {
        var result: [(String, RGB, String)] = []
        for tone in PaneTone.allCases {
            let greys = LoomTheme.Surface.greys(appearance, tone: tone)
            let named: [(String, RGB)] = [("canvas", greys.canvas), ("raised 1", greys.raised1), ("raised 2", greys.raised2),
                                          ("popover", greys.popover)]
            for (name, rgb) in named { result.append(("\(tone) \(name)", rgb, name)) }
        }
        return result
    }

    /// The pill over a surface; `increasedContrast` draws the fill at `Highlight.increasedFillScale` (the stroke carries it then).
    private static func under(_ state: HighlightState, _ surface: RGB, _ appearance: Appearance, increasedContrast: Bool = false) -> RGB {
        guard let tone = state.tone?[appearance] else { return surface }
        let opacity = tone.opacity * (increasedContrast ? LoomTheme.Highlight.increasedFillScale : 1)
        return tone.rgb.composited(over: surface, opacity: opacity)
    }

    @Test func primaryTextHoldsItsTierUnderEveryStateOnEveryLevel() {
        for appearance in Appearance.allCases {
            for (name, surface, level) in Self.surfaces(appearance) where level != "popover" {
                for state in [HighlightState.hover, .selected, .pressed] {
                    let pill = Self.under(state, surface, appearance)
                    #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: pill) >= 7, "primary under \(state) on \(appearance) \(name)")
                }
            }
        }
    }

    @Test func secondaryTextKeepsItsTierUnderEveryFillOnTheCanvasAndBothRaisedLevels() {
        for appearance in Appearance.allCases {
            for (name, surface, level) in Self.surfaces(appearance) where level != "popover" {
                for state in [HighlightState.hover, .selected, .pressed] {
                    let pill = Self.under(state, surface, appearance)
                    #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: pill) >= 4.5,
                            "secondary under \(state) on \(appearance) \(name)")
                }
            }
        }
    }

    /// A popover row under the pointer or the cursor reads its secondary text at 4.5:1, in both appearances and all three
    /// tones, with the plain secondary: Ink's 5 % hover fill needs no lift (the pressed fill over a popover reads 4.43 to 4.45
    /// in Ink, which a row held down does not need to carry).
    @Test func secondaryTextKeepsItsTierUnderTheHoverFillOnAPopoverRow() {
        for appearance in Appearance.allCases {
            for (name, surface, level) in Self.surfaces(appearance) where level == "popover" {
                let pill = Self.under(.hover, surface, appearance)
                let text = LoomTheme.OnPopover.hoveredSecondaryPair
                #expect(text[appearance].contrast(with: pill) >= 4.5,
                        "secondary under hover on \(appearance) \(name): \(text[appearance].contrast(with: pill))")
            }
        }
    }

    @Test func increaseContrastSecondaryStaysAtSevenUnderTheSelectedAndHoverFills() {
        for appearance in Appearance.allCases {
            for (name, surface, level) in Self.surfaces(appearance) where level != "popover" {
                for state in [HighlightState.hover, .selected] {
                    let pill = Self.under(state, surface, appearance, increasedContrast: true)
                    #expect(LoomTheme.Text.secondaryIncreasedPair[appearance].contrast(with: pill) >= 7,
                            "secondary, Increase Contrast, under \(state) on \(appearance) \(name)")
                }
            }
        }
    }

    @Test func theSelectedPillIsVisiblyStrongerThanTheHoverPill() {
        // A luminance step of the pill over the surface: the selected one is the larger in both appearances and on a card.
        for appearance in Appearance.allCases {
            let card = LoomTheme.Surface.greys(appearance, tone: .neutral).raised1
            let hover = Self.under(.hover, card, appearance), selected = Self.under(.selected, card, appearance)
            #expect(abs(selected.luminance - card.luminance) > abs(hover.luminance - card.luminance), "\(appearance)")
        }
        #expect(HighlightState.hover.tone![.dark].opacity == 0.05 && HighlightState.selected.tone![.dark].opacity == 0.08
                && HighlightState.pressed.tone![.dark].opacity == 0.12)
        #expect(HighlightState.hover.tone![.light].opacity == 0.045 && HighlightState.selected.tone![.light].opacity == 0.07
                && HighlightState.pressed.tone![.light].opacity == 0.10)
    }

    // MARK: The 4 pt grid

    /// The gaps and paddings the spacing pass moved, as they are now. A gap or padding is a multiple of 4, or 2 between a glyph
    /// and its text. What stays off the grid is optical or a size: the project head's leading 6 and the door's trailing 6, which line the mark's
    /// centre up with the status column and seat the key cap, the subagent guide's 13 (the centre of the indicator slot), a hairline, and the tab's 7 pt gap, which the reference draws.
    @Test func theSpacingPassLeavesEveryMovedGapAndPaddingOnTheFourPointGrid() {
        typealias S = LoomTheme.Space
        let moved: [(String, CGFloat)] = [
            ("headerInset", S.headerInset), ("chipSplitGap", S.chipSplitGap),
            ("chipLimitGap", S.chipLimitGap), ("listInset", S.listInset), ("sectionInset", S.sectionInset),
            ("rowFocusOutset", S.rowFocusOutset),
            ("emptyNoteInset", S.emptyNoteInset), ("emptyNoteVertical", S.emptyNoteVertical), ("hintSpacing", S.hintSpacing),
            ("cardH", S.cardH), ("cardV", S.cardV), ("cardLineSpacing", S.cardLineSpacing),
            ("detailInset", S.detailInset),
            ("requestListSpacing", S.requestListSpacing),
            ("requestSpacing", S.requestSpacing), ("requestLineSpacing", S.requestLineSpacing),
            ("requestPadding", S.requestPadding), ("buttonV", S.buttonV),
            ("pillLeading", LoomTheme.Header.pillLeading), ("pillTrailing", LoomTheme.Header.pillTrailing),
            ("pillGap", LoomTheme.Header.pillGap), ("chipMarkGap", LoomTheme.Header.chipMarkGap),
            ("chipRuleAfter", LoomTheme.Header.chipRuleAfter), ("stopPadding", LoomTheme.Header.stopPadding),
            ("stopGap", LoomTheme.Header.stopGap), ("crumbGap", LoomTheme.Header.crumbGap),
            ("backGap", LoomTheme.Header.backGap), ("backTrailing", LoomTheme.Header.backTrailing),
            ("Home.sideInset", LoomTheme.Home.sideInset),
            ("Home.sideCardPadding", LoomTheme.Home.sideCardPadding), ("Home.itemPadding", LoomTheme.Home.itemPadding),
            ("Page.sideInset", LoomTheme.ProjectPage.sideInset), ("Page.columnGap", LoomTheme.ProjectPage.columnGap),
            ("Page.rowPaddingH", LoomTheme.ProjectPage.rowPaddingH), ("Page.rowPaddingTop", LoomTheme.ProjectPage.rowPaddingTop),
            ("Page.cardPadding", LoomTheme.ProjectPage.cardPadding), ("Page.statGap", LoomTheme.ProjectPage.statGap),
            ("Inspector.bodyInset", LoomTheme.Inspector.bodyInset),
            ("Inspector.sectionGap", LoomTheme.Inspector.sectionGap), ("Inspector.sectionTitleGap", LoomTheme.Inspector.sectionTitleGap),
            ("Inspector.agentIndent", LoomTheme.Inspector.agentIndent),
            ("Sidebar.homeRowInset", LoomTheme.Sidebar.homeRowInset), ("Sidebar.homeRowSpacing", LoomTheme.Sidebar.homeRowSpacing),
            ("Sidebar.badgePadding", LoomTheme.Sidebar.badgePadding), ("Sidebar.doorInset", LoomTheme.Sidebar.doorInset),
            ("Sidebar.doorBottom", LoomTheme.Sidebar.doorBottom), ("Sidebar.doorSpacing", LoomTheme.Sidebar.doorSpacing),
            ("Sidebar.headingInset", LoomTheme.Sidebar.headingInset),
            ("Sidebar.headTrailing", LoomTheme.Sidebar.headTrailing), ("Sidebar.headerTrailing", LoomTheme.Sidebar.headerTrailing),
            ("Sidebar.metaSpacing", LoomTheme.Sidebar.metaSpacing),
            ("Chat.columnPadding", LoomTheme.Chat.columnPadding), ("Chat.workRowPaddingH", LoomTheme.Chat.workRowPaddingH),
            ("Chat.blockSpacing", LoomTheme.Chat.blockSpacing),
            ("Composer.dockBottomInset", LoomTheme.Composer.dockBottomInset), ("Composer.dockTopInset", LoomTheme.Composer.dockTopInset),
            ("Composer.textInsetH", LoomTheme.Composer.textInsetH), ("Composer.textTop", LoomTheme.Composer.textTop),
            ("Composer.chipGap", LoomTheme.Composer.chipGap),
            ("Composer.attachmentSpacing", LoomTheme.Composer.attachmentSpacing),
            ("Composer.pickRowPaddingV", LoomTheme.Composer.pickRowPaddingV),
            ("Composer.compactTextTop", LoomTheme.Composer.compactTextTop),
            ("Composer.cardNoteTop", LoomTheme.Composer.cardNoteTop), ("Composer.noticeInset", LoomTheme.Composer.noticeInset),
            ("Pinned.cardPadding", LoomTheme.Pinned.cardPadding), ("Pinned.sectionSpacing", LoomTheme.Pinned.sectionSpacing),
            ("Pinned.buttonSpacing", LoomTheme.Pinned.buttonSpacing), ("Pinned.optionPadding", LoomTheme.Pinned.optionPadding),
        ]
        for (name, value) in moved {
            #expect(value.truncatingRemainder(dividingBy: 4) == 0 || value == 2, "\(name) is \(value)")
        }
    }

    @Test func theShellGeometryIsInks() {
        #expect(LoomTheme.Layout.headerHeight == 52 && LoomTheme.TabStrip.height == 36)
        // The terminal sits flush on the canvas (DESIGN §6 Terminal framing): its text keeps 16 pt, 20 at the leading edge.
        #expect(LoomTheme.Space.terminalInset == 16 && LoomTheme.Space.terminalLeadingInset == 20)
    }
}
