import SwiftUI

/// Values of the view tabs (DESIGN §6 Tabs; the reference's `.itabs`, `.ptabs` and `.itab`): underlined text on a 36 pt bar with a
/// hairline, 18 apart, no pill. The open tab has a 1.5 pt accent underline on the hairline; a count follows the label in mono 10.5.
/// The project page draws them (`ViewTabs`); the inspector keeps its own bar (`LoomTheme.Inspector`).
extension LoomTheme {
    enum ViewTabs {
        static let barHeight = InkHeight.tabRow
        static let gap: CGFloat = 18
        /// Between a label and its count.
        static let contentGap: CGFloat = 6
        static let underline: CGFloat = 1.5
        /// The keyboard focus ring hugs the label: it stands this far off it sideways and is inset from the bar's edges.
        static let focusOutset: CGFloat = 4
        static let focusInset: CGFloat = 6
        static let label = InkType.button
        static let count = InkStyle(size: 10.5, mono: true)
    }
}
