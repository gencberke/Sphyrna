import SwiftUI

/// Values of Rewind files (V21): the action in a message's hover footer, the confirmation sheet and the stream marker with
/// its Undo. Colours, type and spacing are the existing tokens; only what the sheet adds lives here. Like every
/// `LoomTheme*.swift` this file is exempt from the theme guard.
extension LoomTheme {
    enum Rewind {
        // MARK: The footer action

        static let actionGlyph = Font.system(size: 10, weight: .semibold)
        static let actionGap: CGFloat = 4

        // MARK: The sheet

        /// Paths and marks need more room than the 420 pt of a plain confirmation.
        static let sheetWidth: CGFloat = 480
        static let fileListMaxHeight: CGFloat = 156
        /// More files than this scroll inside their box.
        static let scrollAbove = 6
        static let fileRowGap: CGFloat = 8
        static let fileRowPadding: CGFloat = 3
        static let listRadius: CGFloat = Radius.md
        static let listInset: CGFloat = 8
        static let noteGap: CGFloat = 8

        // MARK: The marker

        static let markerGap: CGFloat = 8
    }
}
