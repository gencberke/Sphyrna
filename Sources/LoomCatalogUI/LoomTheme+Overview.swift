import SwiftUI

/// Values of the inspector's Overview (the reference's `.isec`, `.ihead`, `.facts`, `.ctx`, `.mini` and `.arow`). The type is
/// Ink's (`InkType`), the colours the text, status and mode tones; the section label, the quiet voice and the body inset are
/// `LoomTheme.Inspector`'s. Only what the Overview adds is here.
extension LoomTheme {
    enum Overview {
        // MARK: Facts

        /// The label column of a fact, and the gap before its value.
        static let labelWidth: CGFloat = 62
        static let columnGap: CGFloat = 10
        static let rowGap: CGFloat = 7
        /// A glyph or a mark, and the text after it, in a value.
        static let valueGap: CGFloat = 8
        /// The value's icons: the mode's shield, the harness's mark.
        static let glyph = Font.system(size: 13)
        static let harnessMark: CGFloat = LoomTheme.Layout.harnessMarkHeader
        /// The model's effort after its name: "· high".
        static let effort = InkType.metaLarge
        static let machine = InkType.metaLarge
        static let value = InkType.small
        /// The copy button after the folder: 20 pt, with a 13 pt glyph (its hit area grows to 24).
        static let copySide: CGFloat = 20
        static let copyGlyph = Font.system(size: 13)

        // MARK: Section head

        /// The head's "Open ›" link.
        static let link = InkType.smallButton
        static let linkGlyph = Font.system(size: 10, weight: .semibold)
        static let linkGap: CGFloat = 2
        /// The line the link keeps in the head (its 11.5 pt label's), however tall its hit area is.
        static let linkLine: CGFloat = 14

        // MARK: Context

        /// The ring: a 30 pt box around a 24 pt circle, a 2.4 pt round-capped arc on a track.
        static let ringBox: CGFloat = 30
        static let ringDiameter: CGFloat = 24
        static let ringLine: CGFloat = 2.4
        static let ringGap: CGFloat = 12
        static let headline = InkStyle(size: 13, weight: .medium)
        static let caption = InkType.meta
        static let captionGap: CGFloat = 2

        // MARK: Lists

        /// A changed file: 24 high, the base name in mono and the counts at the end.
        static let fileHeight: CGFloat = InkHeight.subagentRow
        static let fileGap: CGFloat = 8
        static let fileName = InkType.metaLarge
        /// A subagent: 26 high, a 12 pt status slot, the type in 12 medium, the description, the time in mono.
        static let agentHeight: CGFloat = InkHeight.control
        static let agentGap: CGFloat = 8
        static let agentType = InkStyle(size: 12, weight: .medium)
        static let agentTime = InkType.meta
        static let agentCheck = Font.system(size: 9, weight: .semibold)
        // MARK: Sections

        /// Cards on the inspector canvas, matching the session-window reference.
        static let cardListInset: CGFloat = 14
        static let cardGap: CGFloat = 10
        static let cardPaddingH: CGFloat = 13
        static let cardPaddingTop: CGFloat = 11
        static let cardPaddingBottom: CGFloat = 12
        static let cardRadius = InkRadius.card
        static let cardHeadGap: CGFloat = 9
        /// The head's headline ("38%", "~$1.23", "4 files +120 −8", "2 running"), in mono.
        static let headlineType = InkType.metaLarge
        /// The Usage block's three rows: the name's column, and the gap above "Details".
        static let usageNameWidth: CGFloat = 72
        static let detailsTop: CGFloat = 8

        /// The lists stop here; "N more" says what is not shown.
        static let maxFiles = 6
        static let maxAgents = 5
    }
}
