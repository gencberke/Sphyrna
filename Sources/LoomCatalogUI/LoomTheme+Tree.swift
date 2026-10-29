import SwiftUI

/// The subagent tree under a session row (design/DESIGN.md §4 Subagents under a session; A8 in the reference). The branch
/// offsets are the reference's own and stay off the 4 pt grid (§3 Shape and rhythm: "the tree's offsets"). The line is
/// `Surface.tree`; it is structure, so it has no contrast floor.
extension LoomTheme {
    enum Branches {
        /// The first branch's line, from the list's edge: the centre of the session's status column.
        static let column: CGFloat = 22
        /// How much further a subagent's own subagents branch.
        static let step: CGFloat = 19
        static let rowHeight = InkHeight.subagentRow
        /// The turn into a row, and how far its horizontal arm reaches from the line's left edge.
        static let curveRadius: CGFloat = 7
        static let arm: CGFloat = 9
        /// A branch starts this far above its row, so the line leaves the parent's status mark.
        static let overhang: CGFloat = 7
        static let lineWidth: CGFloat = 1
        /// A row's mark starts this far right of its branch's line.
        static let contentGap: CGFloat = 13

        /// In a row: the gap between the mark, the type, the description and the time, and the room to the right.
        static let rowGap: CGFloat = 6
        static let rowTrailing: CGFloat = 8
        /// The hover pill of a row.
        static let pillRadius = InkRadius.group

        /// A running row's type is 12 medium; the other texts are Ink's small (12) and meta (11, mono) roles.
        static let runningType = InkStyle(size: 12, weight: .medium)
        static let text = InkType.small
        static let time = InkType.meta
        static let childName = InkStyle(size: 11.5, weight: .medium)
        static let childModel = InkStyle(size: 10.5, mono: true)
        static let harnessMark: CGFloat = 12
        /// The check on a finished row.
        static let check = Font.system(size: 11)
    }
}
