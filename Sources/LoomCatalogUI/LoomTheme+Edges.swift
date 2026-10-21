import SwiftUI

/// Values of the edges (I4c, DESIGN §19; the reference's `edge.css` and `chat.css:294-301`): the ended line, the record and the
/// top banner stack. The family's box itself is `LoomTheme.ChatBanner`; the surfaces, the hairline and the text tiers are the
/// existing tokens. Like every `LoomTheme*.swift` this file is exempt from the theme guard.
extension LoomTheme {
    enum Edges {
        // MARK: The ended line

        /// One line above the last screen: 40 high with a hairline under it.
        static let endedHeight: CGFloat = 40
        static let endedPaddingLeading: CGFloat = 20
        static let endedPaddingTrailing: CGFloat = 12
        static let endedGap: CGFloat = 8
        static let endedText = Font.system(size: 12.5)
        /// After a banner stack the line gets this much above it, and a hairline.
        static let endedAfterStackTop: CGFloat = 8
        /// The spinner's slot in front of "Resuming…".
        static let spinnerSlot: CGFloat = 12

        // MARK: The record

        /// A centred column of at most 620.
        static let recordColumn: CGFloat = 620
        static let recordPaddingTop: CGFloat = 34
        static let recordPaddingH: CGFloat = 32
        static let recordPaddingBottom: CGFloat = 40

        /// The notice: the state pill's long form (grid 18 + 10, radius 12, the tone's wash at 10 % and its edge at 30 %).
        static let noticeSymbolSlot: CGFloat = 18
        static let noticeGap: CGFloat = 10
        static let noticeRowGap: CGFloat = 3
        static let noticePaddingTop: CGFloat = 13
        static let noticePaddingH: CGFloat = 16
        static let noticePaddingBottom: CGFloat = 14
        static let noticeRadius: CGFloat = InkRadius.card
        static let noticeWashOpacity = 0.10
        static let noticeEdgeOpacity = 0.30
        static let noticeSymbol = Font.system(size: 15)
        static let noticeTitle = InkType.header.font
        static let noticeText = Font.system(size: 12.5)
        static let noticeBottom: CGFloat = 22

        /// "Not running", what Resume does, the buttons.
        static let stateHeading = Font.system(size: 15, weight: .semibold)
        static let stateText = Font.system(size: 12.5)
        static let stateTextTop: CGFloat = 6
        static let stateActionsTop: CGFloat = 14
        static let stateActionsGap: CGFloat = 8
        static let stateHeadingGap: CGFloat = 8

        /// The facts card, raised 1 at radius 12.
        static let factsTop: CGFloat = 26
        static let factsRadius: CGFloat = InkRadius.card
        static let factRowPaddingV: CGFloat = 9
        static let factRowPaddingH: CGFloat = 16
        static let factLabelWidth: CGFloat = 150
        static let factGap: CGFloat = 12
        static let factValueGap: CGFloat = 7
        static let factFont = Font.system(size: 12.5)
        static let factMono = InkType.metaLarge.font

        // MARK: The top banner stack

        /// Padding 8 12 0, rows 6 apart; one box shows and the rest wait behind "+N".
        static let stackPaddingTop: CGFloat = 8
        static let stackPaddingH: CGFloat = 12
        static let stackGap: CGFloat = 6
        /// A long message wraps: the text keeps 9 above and below it inside the box's 36.
        static let textInsetV: CGFloat = 9
        /// A box that carries a second line and buttons aligns to the top: the symbol 11 down, the buttons 7.
        static let tallSymbolTop: CGFloat = 11
        static let tallActionsTop: CGFloat = 7
        static let detailTop: CGFloat = 2
        static let detail = InkType.metaLarge.font
        static let actionGap: CGFloat = 6
    }
}
