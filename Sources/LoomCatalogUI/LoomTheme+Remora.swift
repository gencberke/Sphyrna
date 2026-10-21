import LoomCore
import SwiftUI

/// Values of Remora on Home (DESIGN §9 and §20; the reference's `design/reference-src/docs/remora/base.css` and `remora.css`: `.brief`,
/// `.bhead`, `.bline`, `.tile`, `.rquiet`, `.rprop`, `.askr`, `.bfoot`, `.rfold`, `.rans`, `.rchip`, `.dpop`, `.rpop`). Colours, hairlines
/// and text tones are the existing tokens. Several sizes are the reference's own optical values (14.5, 13.5, 12.5 …) and sit off the
/// 4 pt grid on purpose; `HighlightTests` pins only the grid ones.
extension LoomTheme {
    enum Remora {
        // MARK: The brief

        /// The brief's column is Home's (1,000 less the side insets); it has 58 above and 26 below, and its blocks are 14 apart.
        static let top: CGFloat = 58
        static let bottom: CGFloat = 26
        static let blockGap: CGFloat = 14

        /// "Where you left off": SF Pro Display 34 at weight 200, tracking -0.025 em, line 1.15; the date line after it in mono.
        static let heading = InkStyle(size: 34, weight: .ultraLight, display: true, tracking: -0.025, lineHeight: 39.1)
        static let when = InkStyle(size: 11, mono: true)
        static let headGap: CGFloat = 14

        /// The remora's place (136 wide, empty for now) and the sentence, 14 apart and 12 under the heading. The sentence is 14.5 on a
        /// 1.55 line, at most 780 wide, and keeps two lines' room.
        static let placeWidth: CGFloat = 136
        static let placeGap: CGFloat = 14
        static let lineTop: CGFloat = 12
        static let sentenceMaxWidth: CGFloat = 780
        static let sentence = InkStyle(size: 14.5, lineHeight: 22.475)
        static let sentenceLineSpacing: CGFloat = 5
        static let sentenceRoom: CGFloat = 2 * 1.55 * 14.5
        static let readingLine = InkStyle(size: 12, mono: true)
        static let readingGap: CGFloat = 8

        // MARK: Tiles

        /// Three columns 14 apart, 18 under the sentence. A tile: raised 1, radius 12, hairline and card depth, padding 13 16 12.
        static let tilesTop: CGFloat = 18
        static let tileGap: CGFloat = 14
        static let tileColumns = 3
        static let tilePaddingTop: CGFloat = 13
        static let tilePaddingH: CGFloat = 16
        static let tilePaddingBottom: CGFloat = 12
        static let tileHead = InkStyle(size: 11, mono: true)
        static let tileHeadGap: CGFloat = 7
        static let tileTitle = InkStyle(size: 13, weight: .semibold)
        static let tileTitleTop: CGFloat = 10
        static let tileTitleGap: CGFloat = 8
        static let tileState = InkStyle(size: 12)
        static let tileStateTop: CGFloat = 4
        static let tileStateGap: CGFloat = 7
        static let tileNext = InkStyle(size: 12)
        static let tileNextBold = InkStyle(size: 12, weight: .medium)
        static let tileNextTop: CGFloat = 8
        static let tileNextLineSpacing: CGFloat = 2
        static let tileActionsTop: CGFloat = 12
        static let tileActionsGap: CGFloat = 6
        /// "In its composer, not sent" and its Open link: 22 high, 12 under.
        static let placedHeight: CGFloat = 22
        static let placedGap: CGFloat = 8
        static let placed = InkStyle(size: 12)
        static let placedBold = InkStyle(size: 12, weight: .medium)

        // MARK: Quiet projects, the proposal

        static let quietTop: CGFloat = 12
        static let quietGap: CGFloat = 8
        static let quiet = InkStyle(size: 12.5)
        static let quietMeta = InkStyle(size: 11, mono: true)
        static let chevron: CGFloat = 12
        /// The glyphs of the small chevrons, the check, the tick and the document mark.
        static let chevronGlyph = InkStyle(size: 9, weight: .medium)
        static let scopeChevronGlyph = InkStyle(size: 11, weight: .medium)
        static let arrowGlyph = InkStyle(size: 9.6, weight: .medium)
        static let checkGlyph = InkStyle(size: 13)
        static let tickGlyph = InkStyle(size: 12, weight: .semibold)
        static let docGlyph = InkStyle(size: 13)
        static let proposalTop: CGFloat = 10
        static let proposalGap: CGFloat = 10
        static let proposalMinHeight: CGFloat = 28
        static let proposal = InkStyle(size: 12.5)
        static let proposalFact = InkStyle(size: 12.5, weight: .medium)
        static let proposalActionsGap: CGFloat = 6

        // MARK: The field

        /// 46 high, radius 15, raised 2 with the composer's depth; padding 0 7 0 18; the input 14; Send 30; Stop 26 high at radius 7.
        static let fieldTop: CGFloat = 16
        static let fieldHeight: CGFloat = 46
        static let fieldRadius: CGFloat = 15
        static let fieldLeading: CGFloat = 18
        static let fieldTrailing: CGFloat = 7
        static let fieldGap: CGFloat = 8
        static let fieldText = InkStyle(size: 14)
        static let sendSide: CGFloat = 30
        static let sendGlyph = InkStyle(size: 14, weight: .semibold)
        static let stopHeight: CGFloat = 26
        static let stopRadius: CGFloat = 7
        static let stopPadding: CGFloat = 10
        static let stopGap: CGFloat = 7
        static let stopSquare: CGFloat = 8
        static let stopSquareRadius: CGFloat = 1.5
        static let stopText = InkStyle(size: 12, weight: .medium)
        static let scopeText = InkStyle(size: 12.5)
        static let scopeChevron: CGFloat = 11
        static let scopeGap: CGFloat = 6
        /// The chip is a pill: 26 high, radius 6, 8 aside.
        static let scopeHeight: CGFloat = 26
        static let scopePadding: CGFloat = 8

        // MARK: The footer

        static let footTop: CGFloat = 10
        static let footGap: CGFloat = 16
        static let foot = InkStyle(size: 11, mono: true)
        static let footLink = InkStyle(size: 11, mono: true)

        // MARK: The fold

        /// 34 above, 18 below; the head line 13 secondary, 12 apart; the remora's slot 84 × 30 at its start (empty for now).
        static let foldTop: CGFloat = 34
        static let foldBottom: CGFloat = 18
        static let foldHeadGap: CGFloat = 12
        static let foldHead = InkStyle(size: 13)
        static let foldHeadBold = InkStyle(size: 13, weight: .medium)
        static let foldLink = InkStyle(size: 12.5)
        static let foldSlot = CGSize(width: 84, height: 30)
        /// The card of lines: 12 under the head, padding 4, a line is 34 high with the columns 18 | 132 | flex | auto, 10 apart.
        static let foldLinesTop: CGFloat = 12
        static let foldLinesPadding: CGFloat = 4
        static let foldLineHeight: CGFloat = 34
        static let foldTick: CGFloat = 18
        static let foldProject: CGFloat = 132
        static let foldColumnGap: CGFloat = 10
        static let foldPaddingLeading: CGFloat = 16
        static let foldPaddingTrailing: CGFloat = 14
        static let foldText = InkStyle(size: 12.5)
        static let foldMeta = InkStyle(size: 11, mono: true)
        static let foldWhatGap: CGFloat = 8
        static let foldStateGap: CGFloat = 6
        static let foldRing: CGFloat = 9
        static let foldRingWidth: CGFloat = 1.3
        static let foldFieldTop: CGFloat = 14

        // MARK: The art's places (I5 draws in them; they stay empty and hidden from VoiceOver)

        /// The arrival lane over the brief: the reference's 320 high canvas.
        static let arrivalHeight: CGFloat = 320

        // MARK: Answers

        static let answerTop: CGFloat = 12
        static let answerPaddingV: CGFloat = 12
        static let answerPaddingH: CGFloat = 16
        static let askedGap: CGFloat = 10
        static let asked = InkStyle(size: 12)
        static let askedQuestion = InkStyle(size: 12.5, weight: .medium)
        static let closeSide: CGFloat = 22
        static let closeGlyph = InkStyle(size: 11, weight: .medium)
        static let workingTop: CGFloat = 8
        static let working = InkStyle(size: 12, mono: true)
        static let answerTextTop: CGFloat = 8
        static let answerMaxWidth: CGFloat = 820
        static let answerText = InkStyle(size: 13.5)
        static let answerLineSpacing: CGFloat = 4.3
        static let chipsTop: CGFloat = 10
        static let chipsGap: CGFloat = 8
        static let answerFootTop: CGFloat = 10
        static let earlierTop: CGFloat = 10
        static let earlierGap: CGFloat = 8
        static let earlier = InkStyle(size: 12)
        static let earlierQuestion = InkStyle(size: 12, weight: .medium)
        static let earlierTime = InkStyle(size: 11, mono: true)
        static let stoppedTop: CGFloat = 8

        // MARK: A session chip

        /// 26 high, radius 7, padding 0 6 0 7, 7 apart; its fill is the project's tone at 8 % and its edge at 26 %.
        static let chipHeight: CGFloat = 26
        static let chipRadius: CGFloat = 7
        static let chipPaddingLeading: CGFloat = 7
        static let chipPaddingTrailing: CGFloat = 6
        static let chipGap: CGFloat = 7
        static let chipText = InkStyle(size: 12.5)
        static let chipWhen = InkStyle(size: 11, mono: true)
        static let chipArrow: CGFloat = 12
        static let chipFill = 0.08
        static let chipFillHover = 0.14
        static let chipEdge = 0.26

        static func chipFillTone(_ tone: ProjectTone, hovering: Bool) -> AdaptiveTone {
            let opacity = hovering ? chipFillHover : chipFill
            return AdaptiveTone(dark: Tone(rgb: ProjectColor.baseRGB(tone), opacity: opacity),
                                light: Tone(rgb: ProjectColor.lightBaseRGB(tone), opacity: opacity))
        }

        static func chipEdgeTone(_ tone: ProjectTone) -> AdaptiveTone {
            AdaptiveTone(dark: Tone(rgb: ProjectColor.baseRGB(tone), opacity: chipEdge),
                         light: Tone(rgb: ProjectColor.lightBaseRGB(tone), opacity: chipEdge))
        }

        // MARK: Popovers

        /// Sources: 340 wide; a label above each list; rows 28 high with the mark (16), the title and the age in mono, 9 apart.
        static let sourcesWidth: CGFloat = 340
        static let sourcesInset: CGFloat = 6
        static let sourcesLabelAside: CGFloat = 8
        static let sourcesLabelTop: CGFloat = 8
        static let sourcesLabelBottom: CGFloat = 6
        static let sourcesRowHeight: CGFloat = 28
        static let sourcesRowGap: CGFloat = 9
        static let sourcesRowPadding: CGFloat = 8
        static let sourcesText = InkStyle(size: 12.5)
        static let sourcesMeta = InkStyle(size: 11, mono: true)
        static let sourcesMarkColumn: CGFloat = 16
        static let sourcesFootV: CGFloat = 8
        static let sourcesFootH: CGFloat = 14
        static let sourcesFootTop: CGFloat = 6
        /// Put in Draft's hover: 330 wide, padding 12 14; its line in a raised 2 box (padding 8 10, radius 8).
        static let draftHoverWidth: CGFloat = 330
        static let draftHoverPaddingV: CGFloat = 12
        static let draftHoverPaddingH: CGFloat = 14
        static let draftHoverWhere = InkStyle(size: 11, weight: .medium, mono: true, tracking: 0.02)
        static let draftHoverLine = InkStyle(size: 12.5)
        static let draftHoverBoxV: CGFloat = 8
        static let draftHoverBoxH: CGFloat = 10
        static let draftHoverBoxRadius: CGFloat = 8
        static let draftHoverGap: CGFloat = 6
        static let draftHoverKeyTop: CGFloat = 8
        static let draftHoverKey = InkStyle(size: 11, mono: true)
        /// The scope menu is at least 210 wide, the ⋯ menu 200.
        static let scopeMenuWidth: CGFloat = 210
        static let moreMenuWidth: CGFloat = 200
        static let menuCheck: CGFloat = 13

        // MARK: Before any session

        /// 13 secondary, 10 under the band's sentence.
        static let noneTop: CGFloat = 10
        static let none = InkStyle(size: 13)
    }
}
