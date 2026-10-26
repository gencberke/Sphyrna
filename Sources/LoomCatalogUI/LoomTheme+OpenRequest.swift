import SwiftUI

/// The request of a session's agent to open another session (D-40, FB6-24): DESIGN §4 "A session that opens a session" and
/// §6 Callouts, on Ink's pinned-card look. The card is raised 2 with a 1 pt attention edge at 34 % and no wash; what it holds
/// (the message) is raised 1. After an answer the card folds to one line for `foldLinger`. Exempt from the theme guard like
/// every `LoomTheme*.swift`.
extension LoomTheme {
    enum OpenRequest {
        // MARK: Geometry

        static let radius: CGFloat = InkRadius.card
        static let padding: CGFloat = 16
        /// The heading's gap, between the dot, the heading and the trailing meta.
        static let headerGap: CGFloat = 8
        /// The card's own sections: head, the session it will be, the message, the buttons.
        static let sectionSpacing: CGFloat = 12
        static let lineSpacing: CGFloat = 6
        /// The attention dot before the heading.
        static let dot: CGFloat = StatusMark.dot
        static let metaGap: CGFloat = 6
        /// The message inset: raised 1, radius 8, 10 above and below, 12 aside.
        static let messageRadius: CGFloat = InkRadius.row
        static let messagePaddingV: CGFloat = 10
        static let messagePaddingH: CGFloat = 12
        static let messageMaxHeight: CGFloat = 170
        static let buttonSpacing: CGFloat = 8
        /// The spinner that takes the accent button's place while the session starts.
        static let spinnerWidth: CGFloat = 64
        /// The folded line: 32 high, radius 10, 12 aside.
        static let foldRadius: CGFloat = InkRadius.activityCard
        static let foldHeight: CGFloat = 32
        static let foldPaddingH: CGFloat = 12
        static let foldGap: CGFloat = 8

        // MARK: Timing

        /// An answered request stays as a folded line this long.
        static let foldLinger: TimeInterval = 4

        // MARK: Colour

        /// The attention edge of a waiting card (E1).
        static let edgeOpacity = 0.34
        /// Raised 2 for the card, raised 1 for the message, the folded line and what holds a failure.
        static var cardFill: Color { Surface.raised2 }
        static var messageFill: Color { Surface.raised1 }
        static var foldFill: Color { Surface.raised1 }
        static var edge: Color { Status.attention.opacity(edgeOpacity) }
        static var openedMark: Color { Accent.base }
        static var deniedMark: Color { Text.tertiary }

        // MARK: Type

        static let heading = InkType.header.font
        static let title = InkType.header.font
        static let requester = InkType.meta.font
        static let counter = InkType.meta.font
        static let meta = InkType.meta.font
        static let body = Font.system(size: 12.5)
        static let notice = InkType.small.font
        static let fold = InkType.small.font
    }
}
