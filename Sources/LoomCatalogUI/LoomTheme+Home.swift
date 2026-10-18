import SwiftUI

/// Values of the Home screen (V05; design preview `v2-studio-preview`, Home). Colours, hairlines and text
/// tones are the existing tokens.
extension LoomTheme {
    enum Home {
        /// The widest the content grows; a wider panel keeps it centred.
        static let maxWidth: CGFloat = 1_000
        static let sideInset: CGFloat = 32
        static let top: CGFloat = 26
        static let bottom: CGFloat = 32
        /// The width of the column beside the lists (plan limits, Today, Continue).
        static let sideColumn: CGFloat = 340
        /// The content width from which that column sits beside the lists; below it, under them.
        static let wideFrom: CGFloat = 820
        static let columnGap: CGFloat = 24
        static let blockGap: CGFloat = 16
        static let headingGap: CGFloat = 8
        static let itemPadding: CGFloat = 16
        static let itemPaddingV: CGFloat = 12
        /// The pill of a list row sits this far inside the hairline above and below it.
        static let rowPillGap: CGFloat = 4
        /// A block of the side column pads two points more than a list row.
        static let sideCardPadding: CGFloat = 16
        static let itemGap: CGFloat = 8
        static let pip: CGFloat = 7
        static let toneStripe = CGSize(width: 3, height: 12)
        static let limitGap: CGFloat = 12
        /// The sessions Continue lists before "Show more".
        static let continueShown = 5

        // Usage: one card, a row of plan limits (a button) and a row of today's figures.
        static let usageRowGap: CGFloat = 8
        static let usageRowHeight: CGFloat = 32
        static let limitsPopoverWidth: CGFloat = 296
    }
}
