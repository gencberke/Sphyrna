import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
@testable import LoomCatalogUITestRigs

// The pinned cards, the chat banner and the asides in Ink (I6p, DESIGN §12, §15, §16, §19; the reference's E1–E4 and F1–F3): the
// values of the card, the banner's order by tone, the words a button says, the contrast of the card's pairs and the live row's
// "Waiting for you". No window and no process; every view here is hosted offscreen or not at all.

struct PinnedInkTests: PinnedInkFixtures {
    // MARK: The card's values

    @Test func theCardKeepsTheReferencesSizes() {
        #expect(Pinned.cardRadius == 12 && Pinned.cardPadding == 16 && Pinned.sectionSpacing == 12 && Pinned.buttonSpacing == 8)
        #expect(Pinned.edgeOpacity == 0.34, "a 1 pt attention edge at 34 %")
        #expect(Pinned.buttonHeight == 26 && Pinned.buttonRadius == 6, "the control family's button")
        #expect(Pinned.lineHeight == 32 && Pinned.lineRadius == 10, "the folded and the held line")
        // Five lines of 19, 8 above and below: the command's box is 111 high.
        #expect(CGFloat(Pinned.codeLines) * Pinned.codeLineHeight + 2 * Pinned.codePaddingV == 111)
        #expect(Pinned.codeRadius == 8 && Pinned.codePaddingH == 12)
        #expect(Pinned.optionRadius == 8 && Pinned.optionPaddingTop == 8 && Pinned.optionPadding == 12
            && Pinned.optionPaddingBottom == 9 && Pinned.optionPaddingLeading == 9)
        #expect(Pinned.optionNumber == CGSize(width: 20, height: 19) && Pinned.optionNumberRadius == 4)
        #expect(Pinned.segmentGroupRadius == 7 && Pinned.segmentRadius == 5 && Pinned.segmentHeight == 22)
        #expect(Pinned.stackMaxHeightFraction == 0.55 && Pinned.compactStackMaxHeightFraction == 0.68)
    }

    @Test func theCardIsRaisedTwoAndWhatItHoldsRaisedOne() {
        #expect(Pinned.cardFill == LoomTheme.Surface.raised2)
        #expect(Pinned.codeFill == LoomTheme.Surface.raised1 && Pinned.lineFill == LoomTheme.Surface.raised1)
        #expect(Pinned.depth == LoomTheme.Elevation.card)
    }

    @Test func theBannerIsTheChatsBox() {
        typealias Banner = LoomTheme.ChatBanner
        #expect(Banner.radius == 12 && Banner.minHeight == 36)
        #expect(Pinned.edgeOpacity == 0.34)
    }

    @Test func theAsidesAreThePopoverAndTheCardFamilies() {
        #expect(LoomTheme.QuickQuestion.radius == 12, "the popover family; the reference's 14 gives way to DESIGN")
        #expect(LoomTheme.QuickQuestion.fill == LoomTheme.Surface.popover)
        #expect(LoomTheme.Side.composerRadius == 12 && LoomTheme.Side.composerFill == LoomTheme.Surface.raised1)
        #expect(LoomTheme.Control.switchSize == CGSize(width: 32, height: 18) && LoomTheme.Control.switchThumb == 14)
        #expect(LoomTheme.Side.controlSide == 24, "the side bar's ⋯ is the reference's 24 pt icon button")
    }

    // MARK: Contrast

    /// Everything a card says holds its tier on the card (raised 2) and on what it holds (raised 1), in both appearances and every
    /// tone; the selected option's number reads on the accent; the live row's attention text reads on the canvas.
    @Test func theCardsTextHoldsItsFloorsInEveryAppearanceAndTone() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let greys = LoomTheme.Surface.greys(appearance, tone: tone)
                let id = "\(appearance) \(tone)"
                for (name, back) in [("raised 2", greys.raised2), ("raised 1", greys.raised1)] {
                    #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: back) >= 7, "primary on \(name), \(id)")
                    #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: back) >= 4.5, "secondary on \(name), \(id)")
                    #expect(LoomTheme.Text.tertiaryPair[appearance].contrast(with: back) >= 4.5, "tertiary on \(name), \(id)")
                    #expect(LoomTheme.Success.lightPair[appearance].contrast(with: back) >= 4.5, "the folded line's check on \(name), \(id)")
                }
                #expect(LoomTheme.Status.attentionLightPair[appearance].contrast(with: greys.canvas) >= 4.5, "Waiting for you on \(id)")
                #expect(LoomTheme.Accent.onAccentPair[appearance].contrast(with: LoomTheme.Accent.basePair[appearance]) >= 4.5,
                        "the picked option's number on the accent, \(id)")
            }
        }
    }

    // MARK: The banner

    @Test func eachToneHasItsOwnSymbolSoColourIsNeverAlone() {
        #expect(Set(ChatBannerTone.allCases.map(\.symbol)).count == 3)
        #expect(ChatBannerTone.failure.symbol == "exclamationmark.triangle", "the failure tone is the triangle")
    }

    // MARK: Drawn offscreen

    // MARK: The live row says Waiting for you
}
