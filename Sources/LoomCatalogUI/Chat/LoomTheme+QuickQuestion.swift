import SwiftUI

/// Values of the quick question's panel (V22): a floating card over the bottom of the chat column, at the composer's width.
/// Text is the existing tiers (primary and secondary hold 7:1 and 4.5:1 on the surface, `ThemeAppearanceTests`); only what
/// the panel adds lives here. Like every `LoomTheme*.swift` this file is exempt from the theme guard.
extension LoomTheme {
    enum QuickQuestion {
        // MARK: Card

        /// The panel floats above the stream: a popover level, which follows the tone (computed, never stored).
        static var fill: Color { Surface.popover }
        static func fillRGB(_ appearance: Appearance, tone: PaneTone) -> RGB { Surface.levels(appearance, tone: tone).popover }
        static let stroke = Surface.strongHairline
        static let radius: CGFloat = Radius.xxl
        /// The card is as wide as the composer under it, and sits this far above it.
        static let column: CGFloat = Composer.column
        static let sideInset: CGFloat = Composer.dockSideInset
        static let bottomGap: CGFloat = 8
        static let insetH: CGFloat = 16
        static let insetTop: CGFloat = 12
        static let insetBottom: CGFloat = 10
        static let rowGap: CGFloat = 8

        // MARK: Field and answer

        static let fieldMinimumHeight: CGFloat = 26
        static let fieldMaximumHeight: CGFloat = 110
        /// A long answer scrolls inside the card.
        static let answerMaxHeight: CGFloat = 240
        static let questionFont = Font.system(size: 12.5, weight: .medium)
        static let statusFont = Font.system(size: 12)
        static let hintFont = Font.system(size: 11.5)
        static let closeGlyph = Font.system(size: 10, weight: .semibold)
        static let closeSide: CGFloat = 22
    }
}
