import SwiftUI

/// Pinned cards (V18, DESIGN §12, the reference's E1–E4): approvals, questions and plans above the composer. Geometry, type and
/// the timings the spec names. Colours come from the Ink roles (`Surface`, `Text`, `Accent`, `Status`); the card is raised 2 and
/// what it holds raised 1. Exempt from the theme guard like every `LoomTheme*.swift`.
extension LoomTheme {
    enum Pinned {
        // MARK: Geometry

        static let cardRadius: CGFloat = InkRadius.card
        static let cardPadding: CGFloat = 16
        static let sectionSpacing: CGFloat = 12
        static let stackSpacing: CGFloat = 8
        static let stackPaddingH: CGFloat = 20
        static let stackPaddingBottom: CGFloat = 8
        /// The card stack never takes more than this share of the chat pane (stream, cards and composer): past it the stack
        /// scrolls, so the composer stays on screen.
        static let stackMaxHeightFraction: CGFloat = 0.55
        /// With a card shown the composer is compact (`LoomTheme.Composer.compactTextHeight`), so the stack may take more.
        static let compactStackMaxHeightFraction: CGFloat = 0.68
        /// The heading: the mark, the request in Sphyrna's words, the kind in mono and the counter, 8 apart.
        static let headerGap: CGFloat = 8
        /// The glyph that leads a question's or a plan's heading (an approval has the attention dot).
        static let headerGlyphSize: CGFloat = 15
        static let headerDot: CGFloat = StatusMark.dot
        /// The ‹ › that step between waiting cards: small icon buttons beside the counter.
        static let stepGap: CGFloat = 2
        static let stepButton = CGSize(width: 22, height: 22)
        static let buttonHeight: CGFloat = InkHeight.control
        static let buttonRadius: CGFloat = InkRadius.control
        static let buttonPaddingH: CGFloat = 10
        static let buttonSpacing: CGFloat = 8
        /// The folded, held and ended-run lines: 32 pt, radius 10.
        static let lineHeight: CGFloat = 32
        static let lineRadius: CGFloat = InkRadius.activityCard
        static let linePaddingH: CGFloat = 12
        static let lineGap: CGFloat = 8
        static let lineIcon: CGFloat = 13
        static let lineGlyph = Font.system(size: lineIcon, weight: .semibold)
        static let optionRadius: CGFloat = InkRadius.row
        /// The option's padding is the reference's own, 8 above, 12 after, 9 below and 9 before (optical values, off the 4 pt
        /// grid): `optionPadding` is the 12 that is on it.
        static let optionPadding: CGFloat = 12
        static let optionPaddingTop: CGFloat = 8
        static let optionPaddingBottom: CGFloat = 9
        static let optionPaddingLeading: CGFloat = 9
        static let optionGap: CGFloat = 10
        static let optionSpacing: CGFloat = 6
        /// The number box before an option: 20 × 19, radius 4.
        static let optionNumber = CGSize(width: 20, height: 19)
        static let optionNumberRadius: CGFloat = InkRadius.key
        /// A command or a diff: 8 above and below, 12 aside, 19 pt lines, five lines before it scrolls (111 pt).
        static let codeRadius: CGFloat = InkRadius.row
        static let codePaddingV: CGFloat = 8
        static let codePaddingH: CGFloat = 12
        static let codeLines = 5
        static let codeLineHeight: CGFloat = 19
        /// The plan's text box: a code box in reading type.
        static let planPadding: CGFloat = 8
        static let planBodyMaxHeight: CGFloat = 170
        /// In a short window the plan's text gives way, so the buttons below it stay on screen: it never takes less than
        /// this, and the rest of the card (title, note field, two button rows, padding) is counted as the allowance.
        static let planBodyMinHeight: CGFloat = 64
        static let planChromeAllowance: CGFloat = 245
        static let optionsMaxHeight: CGFloat = 210
        /// The plan's build-mode segments: a 26 pt group of radius 7 with 22 pt segments of radius 5 inside (DESIGN §6 Tabs).
        static let segmentGroupRadius: CGFloat = InkRadius.group
        static let segmentHeight: CGFloat = InkHeight.chip
        static let segmentRadius: CGFloat = InkRadius.groupInner
        static let segmentPaddingH: CGFloat = 10
        static let segmentGap: CGFloat = 6
        static let segmentInset: CGFloat = 2

        /// "Jump to Latest" floats this far above what sits under the stream (the banner, the cards, the composer).
        static let jumpPillGap: CGFloat = 12

        // MARK: Timing

        /// A card that arrives while the composer was typed in within this long waits as a one-line notice.
        static let typingHold: TimeInterval = 1.5
        /// A single-select pick moves to the next question after this long.
        static let questionAdvance: TimeInterval = 0.2
        /// An answered card stays as a folded line in the stack this long.
        static let foldedLinger: TimeInterval = 4
        /// How often a held stack looks at the composer again.
        static let holdPoll: TimeInterval = 0.25

        // MARK: Colour

        /// The attention edge of a waiting card, a held line and a banner that limits Sphyrna (E1).
        static let edgeOpacity = 0.34
        /// The card is raised 2 and what it holds (the command, the plan's text) raised 1; both follow the tone, so computed,
        /// never stored.
        static var cardFill: Color { Surface.raised2 }
        static var codeFill: Color { Surface.raised1 }
        static var lineFill: Color { Surface.raised1 }
        /// A card's lift: an inner top highlight in Ink and a 1 to 2 pt drop (`Elevation.card`).
        static let depth = Elevation.card
        static let optionHoverFill = Surface.hoverTone.color
        static let optionSelectedFill = Accent.wash
        static let optionSelectedEdge = Accent.base.opacity(0.55)
        static let optionNumberFill = Accent.base
        /// The chosen segment's 1 pt drop.
        static let segmentDrop = Color.black.opacity(0.22)
        /// A cut-off card keeps its text but not its force: 92 %.
        static let cutOffOpacity = 0.92

        // MARK: Type

        static let title = InkType.header.font
        static let kind = InkType.metaLarge.font
        static let counter = InkType.meta.font
        static let hint = InkType.meta.font
        static let body = Font.system(size: 12.5)
        static let bodyStrong = Font.system(size: 12.5, weight: .medium)
        static let detail = InkType.small.font
        /// A command and a diff line: mono 12 on 19 pt lines.
        static let mono = Font.system(size: 12, design: .monospaced)
        static let question = Font.system(size: 13)
        static let questionLineHeight: CGFloat = 19.5
        static let optionLabel = Font.system(size: 13, weight: .medium)
        static let optionNumberFont = InkType.meta.font
        static let segment = Font.system(size: 12, weight: .medium)
        static let segmentIcon = Font.system(size: 11)
        static let stepChevron = Font.system(size: 9, weight: .semibold)
        static let headerGlyph = Font.system(size: headerGlyphSize)
        static let ellipsis = Font.system(size: 16)
        /// Claude's words on why it asks: 12.5 on 1.5 lines; the optional reason under it is 12 on the tertiary.
        static let saysLabel = Font.system(size: 12.5, weight: .semibold)
        static let saysLineHeight: CGFloat = 18.75
        static let optionDetailLineHeight: CGFloat = 17.4
    }

    /// The chat's banner (DESIGN §19 Banners, the family's box): raised 2, radius 12 and a 1 pt edge in the tone's colour, 36
    /// high at least, in the cards' column.
    enum ChatBanner {
        static let radius: CGFloat = InkRadius.card
        static let minHeight: CGFloat = 36
        static let gap: CGFloat = 10
        static let stackGap: CGFloat = 6
        static let paddingLeading: CGFloat = 12
        static let paddingTrailing: CGFloat = 6
        static let symbol = Font.system(size: 14)
        static let symbolSlot: CGFloat = 16
        static let text = Font.system(size: 12.5)
        static let peek = InkType.meta.font
        static let peekPadding: CGFloat = 4
        static let peekHeight: CGFloat = 24
    }
}
