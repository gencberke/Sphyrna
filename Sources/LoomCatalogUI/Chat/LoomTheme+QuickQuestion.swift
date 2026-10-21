import SwiftUI

/// Values of the quick question's panel (V22, DESIGN §15; the reference's F1): a floating card over the bottom of the chat
/// column, at the composer's width, in the popover family. Text is the existing tiers (primary and secondary hold 7:1 and 4.5:1
/// on the surface, `ThemeAppearanceTests`); only what the panel adds lives here. Like every `LoomTheme*.swift` this file is
/// exempt from the theme guard.
extension LoomTheme {
    enum QuickQuestion {
        // MARK: Card

        /// The panel floats above the stream: the popover level, which follows the tone (computed, never stored).
        static var fill: Color { Surface.popover }
        static func fillRGB(_ appearance: Appearance, tone: PaneTone) -> RGB { Surface.greys(appearance, tone: tone).popover }
        /// The popover's hairline ring; its 64 pt shadow is `Elevation.popover`.
        static let ring = Surface.hairline
        /// The popover family's radius (the reference draws 14; DESIGN's cards, menus and window are 12).
        static let radius: CGFloat = InkRadius.card
        /// The card is as wide as the composer under it, and sits this far above it.
        static let column: CGFloat = Composer.column
        static let sideInset: CGFloat = Composer.dockSideInset
        static let bottomGap: CGFloat = 8
        static let insetLeading: CGFloat = 16
        static let insetTrailing: CGFloat = 12
        static let insetTop: CGFloat = 12
        static let insetBottom: CGFloat = 10
        static let rowGap: CGFloat = 8
        /// The field row sits 12 under what is above it, under a hairline, with 10 between the line and the field.
        static let fieldTop: CGFloat = 12
        static let fieldPaddingTop: CGFloat = 10
        static let fieldGap: CGFloat = 8
        static let hintTop: CGFloat = 6

        // MARK: Field and answer

        static let fieldMinimumHeight: CGFloat = 26
        static let fieldMaximumHeight: CGFloat = 110
        /// A long answer scrolls inside the card.
        static let answerMaxHeight: CGFloat = 240
        static let questionFont = Font.system(size: 12.5, weight: .medium)
        static let statusFont = Font.system(size: 12)
        static let hintFont = Font.system(size: 11.5)
        /// The close button sits 8 from the card's top and right edges.
        static let closeInset: CGFloat = 8
        /// The question leaves room for it.
        static let closeSide: CGFloat = 22
        /// With no question above it the field starts this far down, under the close button (8 + 22 less the card's 12 padding).
        static let closeClearance: CGFloat = 20
        static let spinnerSlot: CGFloat = 16
    }
}
