import SwiftUI

/// Sidebar v2 (V04, concept §3): the Home row, the one-line session rows of a project group and the reason
/// line of an Active card. The card, the stripe and the project header keep the values they have in
/// `LoomTheme.Space`, `Layout` and `ProjectColor`; nothing here changes them.
extension LoomTheme {
    enum Sidebar {
        /// The Home row under the search field: 30 high, the search field's radius, a 15 pt symbol column.
        static let homeRowHeight: CGFloat = 30
        static let homeRowInset: CGFloat = 8
        static let homeRowSpacing: CGFloat = 8
        static let homeRowBottom: CGFloat = 4
        static let homeGlyph = Font.system(size: 13)

        /// The count of what needs the user: an attention wash behind the light attention text (the plain
        /// attention colour is 4.3 to 4.4:1 on its own wash), 18 wide at least, 17 high.
        static let badgeMinWidth: CGFloat = 18
        static let badgeHeight: CGFloat = 17
        static let badgePadding: CGFloat = 4
        static let badgeWash = 0.13
        static let badgeFont = Font.system(size: 10.5, weight: .semibold).monospacedDigit()

        /// A project row whose page is open is filled like a selected card; the fill starts this far inside
        /// the row, so the symbol and the buttons keep the places they had.
        static let headerFillInset: CGFloat = 8

        /// A session row in a project group: one line, 28 high, on the card's leading edge so the subagent
        /// guide and the project stripe keep their places.
        static let lineRowHeight: CGFloat = 28
    }
}
