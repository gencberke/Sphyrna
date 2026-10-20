import SwiftUI

/// Values of the inspector's Side tab (V22 part 3; concept §5.6, the design preview's `#side`): the thread's header, the empty
/// state, the answer's two actions and the compact composer. The surfaces, the hairline and the text tiers are the existing
/// tokens (the tab sits on the inspector surface, the composer on the composer's card level); the width is
/// `Rhythm.inspectorWidthSide`. Like every `LoomTheme*.swift` this file is exempt from the theme guard.
extension LoomTheme {
    enum Side {
        // MARK: The tab's signal

        /// The dot in the tab bar's count slot while a side chat waits for the user. It is the attention hue, a shape and not
        /// text: 3:1 on the inspector and on a popover (`LoomThemeTests`).
        static let dotSize: CGFloat = 7
        static let dot = Status.attention

        // MARK: Header

        static let headerInsetH: CGFloat = 14
        static let headerInsetV: CGFloat = 10
        static let headerGap: CGFloat = 9
        static let headerGlyph = Font.system(size: 14)
        static let headerTitle = Font.system(size: 12.5, weight: .semibold)
        static let headerNote = Font.system(size: 11.5)
        static let headerNoteGap: CGFloat = 2
        static let headerButtonGap: CGFloat = 4
        static let headerButtonGlyph = Font.system(size: 12)

        // MARK: Earlier side chats

        static let earlierHeight: CGFloat = 28
        static let earlierFont = Font.system(size: 11.5, weight: .medium)
        /// A menu entry shows the first line of the question up to this many characters, then its time.
        static let earlierQuestionLimit = 48

        // MARK: Thread

        /// The stream's side padding (the main chat's is 32 pt in a 700 pt column; this column is 392 pt).
        static let threadInset: CGFloat = 16
        static let statusFont = Font.system(size: 11.5)
        static let statusInsetH: CGFloat = 14

        // MARK: Empty state

        static let emptyInset: CGFloat = 20
        static let emptyFont = Font.system(size: 12.5)
        static let emptyLineSpacing: CGFloat = 3

        // MARK: Answer actions

        static let actionGap: CGFloat = 12
        static let actionGlyph = Font.system(size: 10, weight: .semibold)
        static let actionGlyphGap: CGFloat = 4
        static let sentGlyph = Font.system(size: 10, weight: .semibold)

        // MARK: Composer

        static let composerInset: CGFloat = 12
        static let composerRadius: CGFloat = Radius.xl
        static let composerTextInset: CGFloat = 12
        static let composerTextTop: CGFloat = 8
        static let composerMinimumTextHeight: CGFloat = 38
        static let composerMaximumTextHeight: CGFloat = 140
        static let noticeFont = Font.system(size: 11.5)
        static let noticeInsetBottom: CGFloat = 6
        static let barHeight: CGFloat = 34
        static let barInset: CGFloat = 6
        static let barGap: CGFloat = 4
        static let barFont = Font.system(size: 12, weight: .medium)
        static let barGlyph = Font.system(size: 12)
        static let controlSide: CGFloat = 26
    }
}
