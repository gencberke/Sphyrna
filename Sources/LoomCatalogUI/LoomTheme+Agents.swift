import SwiftUI

/// Values of the inspector's Agents tab (DESIGN §4 "The Agents tab", V09, V23; the reference's `#review` agents: `.arow2`, `.agh`,
/// `.te`). The list keeps the inspector's 328; an open transcript takes the review width, `Rhythm.inspectorWidthReview`. The text
/// colours are the existing tiers; only the shapes, the type and the spacing live here.
extension LoomTheme {
    enum Agents {
        // MARK: The list

        /// "Running N", then "Finished N": a label with its count right after it, 10 above the cards; the sections 22 apart.
        static let sectionGap: CGFloat = 22
        static let headGap: CGFloat = 10
        static let headCountGap: CGFloat = 8
        /// A row is a card: raised 1, a hairline, radius 10, 6 from the next.
        static let cardGap: CGFloat = 6
        static let cardRadius = InkRadius.activityCard
        static var cardFill: Color { Surface.raised1 }
        static let cardPaddingH: CGFloat = 12
        static let cardPaddingTop: CGFloat = 9
        static let cardPaddingBottom: CGFloat = 10
        /// The tree's status column (14 wide, 16 high), the type and the time; the lines under them 2 apart.
        static let statusColumn: CGFloat = 14
        static let statusHeight: CGFloat = 16
        static let columnGap: CGFloat = 8
        static let lineGap: CGFloat = 2
        /// The type in 12.5 medium primary, the time in mono tertiary, the description in Ink's small, secondary.
        static let type = InkStyle(size: 12.5, weight: .medium)
        static let time = InkType.meta
        static let detail = InkType.small
        static let detailLines = 2
        /// "Waiting for you" (attention text) or "Interrupted" (secondary) under the description.
        static let note = InkStyle(size: 11.5)

        // MARK: An empty list

        /// The art's place over the sentence (DESIGN §17: a small shark swims there once the art is drawn, slice I5).
        static let emptyArtHeight: CGFloat = 70
        static let emptyTop: CGFloat = 10
        static let emptyTextTop: CGFloat = 8
        static let emptyDetailTop: CGFloat = 3
        /// The empty pane's sentence: 13 semibold, primary; a line under it in mono 11, tertiary.
        static let emptyText = InkStyle(size: 13, weight: .semibold)
        static let emptyDetail = InkType.meta

        // MARK: The transcript's header

        static let headerTop: CGFloat = 14
        static let headerBottom: CGFloat = 12
        static let headerInset: CGFloat = 16
        /// "‹ Agents": 24 high, on the hover fill (the selected fill under the pointer), radius 6, 12 medium primary.
        static let backHeight: CGFloat = 24
        static let backLeading: CGFloat = 5
        static let backTrailing: CGFloat = 9
        static let backGap: CGFloat = 2
        static let backRadius = InkRadius.control
        static let backGlyph = Font.system(size: 11, weight: .semibold)
        static let back = InkStyle(size: 12, weight: .medium)
        /// The name, "type · description", in body semibold, 10 under the back row; the notice 8 under it.
        static let name = InkStyle(size: 13, weight: .semibold)
        static let nameTop: CGFloat = 10
        static let nameLines = 2
        static let noticeTop: CGFloat = 8

        // MARK: The transcript (two voices)

        static let streamTop: CGFloat = 14
        static let streamBottom: CGFloat = 22
        static let streamInset: CGFloat = 16
        /// The glyph column (⏺, ⎿, ✻) in mono 12.
        static let glyphColumn: CGFloat = 16
        static let glyph = InkStyle(size: 12, mono: true)
        /// The agent's words in the chat's type: 12.5 on 1.55.
        static let words = InkStyle(size: 12.5, lineHeight: 19.4)
        /// A tool call in mono 11.5, its name semibold.
        static let call = InkStyle(size: 11.5, mono: true)
        static let callName = InkStyle(size: 11.5, weight: .semibold, mono: true)
        static let callLines = 3
        /// Its result after ⎿ in mono 11, one line.
        static let result = InkStyle(size: 11, mono: true)
        /// A result shows its first three lines; the rest of what the parser kept is behind "Show more" (FB6-18). A long line
        /// wraps, to twice that.
        static let resultLines = 3
        static let resultWrapLines = 6
        /// The type the agent's words and its Result are set in as Markdown: the chat's scale at the Agents tab's size.
        static let markdownReading = words.font
        static let markdownLineSpacing: CGFloat = 4
        static let markdownHeading = InkStyle(size: 13, weight: .semibold).font
        static let tooLongText = "(an entry too long to show)"
        /// "Thought for 6s" and the live tail ("Running…") in Ink's small.
        static let thought = InkType.small
        static let tail = InkType.small
        /// "Earlier entries are not shown".
        static let omitted = InkStyle(size: 11.5)
        /// The brief: its label, 6 above it, then the text in Ink's small, secondary, cut at four lines, and a hairline 12 under it.
        static let brief = InkType.small
        static let briefLines = 4
        static let briefLabelGap: CGFloat = 6
        static let briefBottom: CGFloat = 12
        /// The label over a finished agent's last words ("Result"), 5 above them.
        static let resultLabelGap: CGFloat = 5
        /// Above an entry: 11 before the agent's words, a call, a thought and the tail; 2 before a result, which follows its call;
        /// 12 after the brief or the omitted line.
        static let blockGap: CGFloat = 11
        static let resultGap: CGFloat = 2
        static let afterBriefGap: CGFloat = 12
    }
}
