import SwiftUI

/// Values of the inspector's Side tab (V22 part 3, DESIGN §16; the reference's F2 and F3): the thread's header, the empty state,
/// the answer's two actions and the compact composer. The surfaces, the hairline and the text tiers are the existing tokens (the
/// tab sits on the inspector surface, the composer on raised 1); the width is `Rhythm.inspectorWidthSide`. Like every
/// `LoomTheme*.swift` this file is exempt from the theme guard.
extension LoomTheme {
    enum Side {
        // MARK: The tab's signal

        /// The dot in the tab bar's count slot while a side chat waits for the user. It is the attention hue, a shape and not
        /// text: 3:1 on the inspector and on a popover (`LoomThemeTests`).
        static let dotSize: CGFloat = 7
        static let dot = Status.attention

        // MARK: Header

        /// The tab's column: the header, the earlier menu and the composer sit 16 from the edge, as the thread does.
        static let headerInsetH: CGFloat = 16
        static let headerInsetV: CGFloat = 12
        static let headerGap: CGFloat = 8
        static let headerTitle = InkType.header.font
        static let headerNote = Font.system(size: 11.5)
        /// Between the title and its note: 3 (optical).
        static let headerNoteGap: CGFloat = 3
        static let headerButtonGap: CGFloat = 4

        // MARK: Earlier side chats

        static let earlierHeight: CGFloat = 28
        static let earlierTop: CGFloat = 12
        static let earlierFont = InkType.small.font
        static let earlierGlyph = Font.system(size: 12)
        static let earlierChevron = Font.system(size: 9, weight: .semibold)
        static let earlierGap: CGFloat = 6
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

        /// Copy and Send to Main as a Note: secondary small buttons 6 apart (the reference's `.acts`).
        static let actionGap: CGFloat = 6
        static let actionGlyph = Font.system(size: 11, weight: .medium)
        static let actionGlyphGap: CGFloat = 6
        static let sentGlyph = Font.system(size: 10, weight: .semibold)

        // MARK: Composer

        /// The compact composer (the reference's `.minic`): raised 1, radius 12, the strong hairline for an edge.
        static let composerInsetH: CGFloat = 16
        static let composerInsetBottom: CGFloat = 12
        static let composerRadius: CGFloat = InkRadius.card
        static var composerFill: Color { Surface.raised1 }
        static let composerEdge = Surface.strongHairline
        static let composerTextInset: CGFloat = 12
        static let composerTextTop: CGFloat = 8
        static let composerMinimumTextHeight: CGFloat = 38
        static let composerMaximumTextHeight: CGFloat = 140
        static let noticeFont = Font.system(size: 11.5)
        static let noticeInsetBottom: CGFloat = 6
        static let barHeight: CGFloat = 34
        static let barInset: CGFloat = 6
        static let barGap: CGFloat = 4
        /// The model's label and "Allow edits": 11.5 secondary with 6 aside; the mark is 12.
        static let barFont = Font.system(size: 11.5)
        static let barLabelPadding: CGFloat = 6
        static let barMarkSize: CGFloat = Layout.harnessMarkRow
        static let controlSide: CGFloat = 24
        /// The switch (DESIGN §6 Controls): 28 × 16, a 12 pt knob 2 in, accent when on.
        static let switchWidth: CGFloat = 28
        static let switchHeight: CGFloat = 16
        static let switchKnob: CGFloat = 12
        static let switchInset: CGFloat = 2
        static let switchGap: CGFloat = 6
        static let switchOffFill = Surface.strongerHairline
        static let switchOnFill = Accent.base
        static let switchKnobFill = Color.white
        static let switchKnobShadow = Color.black.opacity(0.35)
    }
}
