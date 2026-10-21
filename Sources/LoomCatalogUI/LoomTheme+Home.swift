import SwiftUI

/// Values of the Home screen (DESIGN §9; the reference's `.home`, `.hero`, `.hcols`, `.card`, `.lc`, `.hrow`, `.sc`, `.notice` and
/// `.firstrun`, `design/reference-src/shared/head.css` and `docs/edges/edge.css`). Colours, hairlines and text tones are the
/// existing tokens. Several sizes here are the reference's own optical values (14, 9, 11, 3.5 …) and sit off the 4 pt grid on
/// purpose; `HighlightTests` pins only the grid ones.
extension LoomTheme {
    enum Home {
        // MARK: The column

        /// The widest the content grows; a wider panel keeps it centred.
        static let maxWidth: CGFloat = 1_000
        static let sideInset: CGFloat = 32
        static let bottom: CGFloat = 32
        /// The width of the column beside the lists (plan limits, Today).
        static let sideColumn: CGFloat = 316
        /// The content width from which that column sits beside the lists; below it, under them.
        static let wideFrom: CGFloat = 820
        static let columnGap: CGFloat = 24
        /// Blocks, and the list cards, are this far apart.
        static let blockGap: CGFloat = 14

        // MARK: The band

        /// Above the sentence, and below the counts line.
        static let bandAbove: CGFloat = 84
        static let bandBelow: CGFloat = 34
        /// The date line sits this far above the sentence, and the counts line this far below it.
        static let eyebrowGap: CGFloat = 14
        static let countsGap: CGFloat = 12

        static let eyebrow = InkStyle(size: 11, mono: true, tracking: 0.04)
        static let counts = InkStyle(size: 13)
        static let countsFigure = InkStyle(size: 13, weight: .medium)

        // MARK: List cards

        /// A list card's heading row: the status dot, the title, the count; 16 from the edge, 9 apart.
        static let headHeight: CGFloat = 42
        static let headGap: CGFloat = 9
        static let pip: CGFloat = 7
        static let headTitle = InkType.header
        static let headCount = InkType.meta
        /// The text of every row keeps this far from the card's edge.
        static let itemPadding: CGFloat = 16

        // MARK: Rows

        /// A row: padding 11 above and 12 below (a one-line row, Continue's, 9 both), the status column (12) and the columns'
        /// gap (10), and 3 between its two lines.
        static let rowTop: CGFloat = 11
        static let rowBottom: CGFloat = 12
        static let rowOneLine: CGFloat = 9
        static let statusColumn: CGFloat = 12
        static let rowColumnGap: CGFloat = 10
        static let rowLineGap: CGFloat = 3
        /// The project's mark and its name.
        static let projectGap: CGFloat = 6
        static let rowActionsGap: CGFloat = 8
        static let rowTitle = InkStyle(size: 13, weight: .medium)
        static let rowMeta = InkType.meta
        static let reason = InkType.small
        static let reasonMono = InkType.metaLarge

        /// The empty Needs you card's one row.
        static let blankTop: CGFloat = 12
        static let blankBottom: CGFloat = 14
        static let blank = InkStyle(size: 12.5)

        /// Continue's lead line sits 6 under the heading's own 42, and 10 above the first row.
        static let leadLift: CGFloat = 6
        static let leadBottom: CGFloat = 10
        static let lead = InkType.small
        /// "Show N More" after the fifth row.
        static let moreTop: CGFloat = 8
        static let moreBottom: CGFloat = 10
        /// The sessions Continue lists before "Show more".
        static let continueShown = 5

        // MARK: Side cards

        /// A block of the side column pads 16; its title and note sit on one line, 4 above the content.
        static let sideCardPadding: CGFloat = 16
        static let sideHeadGap: CGFloat = 4
        /// A plan window's block is 14 under the one above it (and under the heading's 4).
        static let paceGap: CGFloat = 14
        /// Today's line is 8 under the heading.
        static let todayTop: CGFloat = 8
        static let sideTitle = InkType.header
        static let sideNote = InkType.meta
        static let today = InkStyle(size: 12.5)
        static let todayGap: CGFloat = 4

        // MARK: The no-Claude notice over sessions

        /// 14 by 16 inside, the symbol column (20) and the text 10 apart, the symbol 16, the title and text 4 apart.
        static let noticePaddingV: CGFloat = 14
        static let noticePaddingH: CGFloat = 16
        static let noticeColumn: CGFloat = 20
        static let noticeGap: CGFloat = 10
        static let noticeTextGap: CGFloat = 4
        static let noticeSymbol = InkStyle(size: 16)
        static let noticeTitle = InkType.header
        static let noticeText = InkStyle(size: 12.5)

        // MARK: The first run and the missing Claude

        /// The app icon at 84 (the attention triangle at 40 in a 44 box), then the title 20 below, the text 8 below that and
        /// the actions 22 below that, 10 apart; the whole message is lifted by 40.
        static let iconSide: CGFloat = 84
        static let symbolBox: CGFloat = 44
        static let symbol = InkStyle(size: 40, weight: .light)
        static let titleTop: CGFloat = 20
        static let textTop: CGFloat = 8
        static let textWidth: CGFloat = 420
        /// 13 on a 1.5 line: the extra space between lines.
        static let textLineSpacing: CGFloat = 3.5
        static let actionsTop: CGFloat = 22
        static let firstActionsGap: CGFloat = 10
        static let lift: CGFloat = 40
        static let firstText = InkType.body
        static let codexNoteGap: CGFloat = 6
        static let codexNote = InkStyle(size: 11)

        /// The icon's drop: `0 12px 30px` at 40 % black, in both appearances.
        static let iconDepth: AdaptiveDepth = {
            let depth = Depth(ring: nil, insetHighlight: nil,
                              drops: [ShadowLayer(color: Tone(rgb: RGB(red: 0, green: 0, blue: 0), opacity: 0.4), blur: 30, y: 12)])
            return AdaptiveDepth(dark: depth, light: depth)
        }()
    }
}

extension View {
    /// Draws a text in one of Ink's roles: its face and its tracking.
    func homeType(_ style: LoomTheme.InkStyle) -> some View {
        font(style.font).tracking(style.trackingPoints)
    }
}
