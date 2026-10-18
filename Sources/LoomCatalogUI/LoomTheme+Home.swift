import SwiftUI

/// Values of the Home screen (V05; design preview `v2-studio-preview`, Home). Colours, hairlines and text
/// tones are the existing tokens.
extension LoomTheme {
    enum Home {
        /// The widest the content grows; a wider panel keeps it centred.
        static let maxWidth: CGFloat = 1_000
        static let sideInset: CGFloat = 34
        static let top: CGFloat = 26
        static let bottom: CGFloat = 32
        /// The width of the column beside the lists (plan limits, Today, Continue).
        static let sideColumn: CGFloat = 340
        /// The content width from which that column sits beside the lists; below it, under them.
        static let wideFrom: CGFloat = 820
        static let columnGap: CGFloat = 24
        static let blockGap: CGFloat = 18
        static let headingGap: CGFloat = 8
        static let itemPadding: CGFloat = 12
        /// A block of the side column pads two points more than a list row.
        static let sideCardPadding: CGFloat = 14
        static let itemGap: CGFloat = 6
        static let pip: CGFloat = 7
        static let toneStripe = CGSize(width: 3, height: 12)
        static let limitGap: CGFloat = 14
        /// The sessions Continue lists before "Show more".
        static let continueShown = 5

        // Today: the figures, and the bars of today's tokens by kind under them.
        static let todayBarsHeight: CGFloat = 36
        /// The room under the bars for their labels.
        static let todayBarsLabel: CGFloat = 18
        static let todayBarGap: CGFloat = 3
        static let todayBarRadius: CGFloat = 2
        static let todayBarMinHeight: CGFloat = 2
        static let todayBarsTop: CGFloat = 4
    }
}
