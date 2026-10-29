import LoomCore
import SwiftUI

/// Ink v4's sidebar (DESIGN §0.5): the search door, nav, headings, project heads and cards.
extension LoomTheme {
    enum Sidebar {
        // MARK: Header (52 pt): the window buttons' clearance and the sidebar toggle

        /// The toggle sits at the trailing end, as in the reference.
        static let headerTrailing: CGFloat = 12

        // MARK: The search door (32 pt, radius 8)

        static let doorHeight = InkHeight.standard
        static let doorRadius = InkRadius.row
        /// The door's distance from the sidebar's edges, and below it.
        static let doorInset: CGFloat = 10
        static let doorTop: CGFloat = 10
        static let doorBottom: CGFloat = 8
        static let doorPaddingLeading: CGFloat = 10
        static let doorPaddingTrailing: CGFloat = 8
        static let doorSpacing: CGFloat = 8
        static let navGlyphBox: CGFloat = 15
        static let doorGlyph = Font.system(size: navGlyphBox)
        static let doorLabel = InkType.body.font

        // MARK: Home and New session (28 pt, radius 8)

        static let homeRowHeight = InkHeight.sidebarRow
        static let homeRowInset: CGFloat = 8
        static let homeRowSpacing: CGFloat = 8
        static let homeRowBottom: CGFloat = 2
        static let homeGlyph = Font.system(size: navGlyphBox)
        /// The New session row's `+` (15 pt in the same 16 pt column) and its tint: secondary, primary under the pointer.
        static let newSessionGlyph = Font.system(size: 15)
        /// The glyph column, so Home and New session start their words at the same place.
        static let homeGlyphColumn: CGFloat = 16

        // MARK: The list's heading: the view's name and its action, and the view picker (RESCUE C3)

        static let headingInset: CGFloat = 18
        static let headingTrailing: CGFloat = 8
        static let headingTop: CGFloat = 6
        static let headingBottom: CGFloat = 2
        static let headingLabel = Font.system(size: 12, weight: .medium)
        /// The heading's action and view toggle use the small icon-button size.
        static let headingButton = CGSize(width: 24, height: 24)
        static let headingGlyph = Font.system(size: 14)
        static let headingActionGap: CGFloat = 2

        // MARK: A project head (28 pt): its mark, its name, the attention dot; chevron, + and ⋯ on hover

        /// The head's mark begins 10 pt from the list's edge.
        static let headLeading: CGFloat = 10
        static let headTrailing: CGFloat = 4
        static let headSpacing: CGFloat = 6
        /// The gap above a project head (and the "Sessions" head) that follows a group: the reference's `.pgroup` pads 8 below
        /// and 2 above. The list puts no gap between its entries (`listSpacing`).
        // MARK: The live reorder (A1, FEEDBACK-7 FB7-3)

        /// How far the pointer moves before a held project head becomes a drag, so a click and a right click still work.
        static let reorderStartDistance: CGFloat = ProjectReorder.startDistance
        /// The slide of the blocks between the dragged head's place and its gap (DESIGN-V4 §4: 150 ms; none under Reduce Motion).
        static let reorderSlide: Double = 0.15
        /// The lifted head reads as held: a little opacity over the list.
        static let reorderLiftOpacity: Double = 0.96
        /// The lifted head is a card on elevation 2 (`Elevation.lift`): raised 1, a hairline, and the small 0 1 2 drop.
        static var reorderLiftFill: Color { Surface.raised1 }

        static let groupGap: CGFloat = 10
        /// The first head sits 2 under the label's gap.
        static let firstHeadTop: CGFloat = 2
        /// The attention dot at rest sits this far from the head's trailing edge; with the controls shown it sits just before them.
        static let headDotTrailing: CGFloat = 12
        static let headNameSize: CGFloat = 13
        static let headName = Font.system(size: headNameSize, weight: .medium)

        // MARK: Draft rows and session cards

        static let lineRowHeight = InkHeight.sidebarRow
        /// The list stacks its rows, heads and cards with no gap (the reference's `.alist`, `.pgroup`).
        static let listSpacing: CGFloat = 0
        /// Cards pad 10 vertically and 12 horizontally; both views use the same geometry.
        static let cardTop: CGFloat = 10
        static let cardBottom: CGFloat = 10
        static let cardInset: CGFloat = 12
        static let cardTopHeight: CGFloat = 18
        static let cardTitleHeight: CGFloat = 20
        static let cardMetaHeight: CGFloat = 16
        static let cardGap: CGFloat = 1
        static let cardChildrenGap: CGFloat = 3
        static let cardHarnessMark: CGFloat = 11
        /// The activity footer keeps room for its reason/branch beside the main model.
        static let activityModelMaxWidth: CGFloat = 120
        static let cardMarkSide: CGFloat = ProjectMarkStyle.Size.chip.side
        static let cardMarkGap: CGFloat = 5
        static let cardStatusSpacing: CGFloat = 4
        static let cardStatusFont = Font.system(size: 10.5)
        static var cardSelectedFill: Color { Surface.raised2 }
        /// The tree's fixed column is shifted to the centre of the card's leading mark.
        static var cardBranchOffset: CGFloat {
            cardInset + cardMarkSide / 2 - Branches.column - Branches.lineWidth / 2
        }
        /// Activity section headings' leading inset.
        static let rowLeading: CGFloat = 16
        static let lineTitle = InkType.body.font
        static let lineTitleSelected = Font.system(size: 13, weight: .medium)
        /// A resting time and a working elapsed time, as in the status line of the reference card.
        static let timeFont = Font.system(size: 10.5, design: .monospaced)
        static let elapsedFont = Font.system(size: 10, design: .monospaced)
        /// The reason line (11.5, secondary), a command in mono, and the card's fixed bottom row (11, tertiary).
        static let reasonFont = Font.system(size: 11.5)
        static let reasonMonoFont = Font.system(size: 10.5, design: .monospaced)
        static let metaFont = Font.system(size: 11)
        static let metaMonoFont = Font.system(size: 10.5, design: .monospaced)
        static let metaSpacing: CGFloat = 6
        /// Section headings (Drafts, Active, the days): 11.5 medium tertiary, the count in mono, 6 apart. They start on the
        /// `rowLeading` inside the list's inset, pad 12 above (none for the list's first) and 5 below.
        static let sectionFont = Font.system(size: 11.5, weight: .medium)
        static let sectionCountFont = InkType.meta.font
        static let activityHeadingTop: CGFloat = 12
        static let activityHeadingBottom: CGFloat = 5
        static let activityHeadingSpacing: CGFloat = 6
        static let dayHeight: CGFloat = 23
        static let dayInset: CGFloat = 10
        static let dayGap: CGFloat = 8
        static let dayFont = Font.system(size: 10.5, design: .monospaced)

        /// A draft row: italic, secondary.
        static let draftFont = InkType.body.font

        // MARK: Footer (46 pt, a hairline above)

        static let footerHeight: CGFloat = 46
        static let footerInset: CGFloat = 10
        static let footerSpacing: CGFloat = 4
        static let chipFont = InkType.meta.font
        static let chipMeter = CGSize(width: 40, height: 4)
        static let chipHeight: CGFloat = InkHeight.control
        /// A chip with a line per harness (FB6-3): each line is this high, the chip adds this above and below the lines, and the
        /// footer keeps this much around the chip. Two lines fit the 46 pt footer; a third grows it by one line.
        static let chipLineHeight: CGFloat = 14
        static let chipLinesPadding: CGFloat = 6
        static let footerChipRoom: CGFloat = 12
        static let chipHarnessMark: CGFloat = 12
        static let chipMaxLines = 3

        /// The chip's height for `lines` lines of harnesses: the single line keeps today's.
        static func chipHeight(lines: Int) -> CGFloat {
            lines <= 1 ? chipHeight : CGFloat(min(lines, chipMaxLines)) * chipLineHeight + chipLinesPadding
        }

        /// The footer's height: 46, or more when the chip's lines do not fit with the room around them.
        static func footerHeight(lines: Int) -> CGFloat { max(footerHeight, chipHeight(lines: lines) + footerChipRoom) }
    }
}

extension LoomTheme.ProjectColor {
    /// The selected session's fill (14 % of the tone, in the appearance's own value).
    static func selectionWashTone(_ tone: ProjectTone) -> LoomTheme.AdaptiveTone { wash(tone, opacity: selectionWash) }

    /// The selected session's edge: 34 %, 75 % under Increase Contrast.
    static func selectionEdgeStyle(_ tone: ProjectTone) -> LoomTheme.ContrastStyle {
        edge(tone, opacity: selectionEdge, increasedOpacity: selectionEdgeIncreased)
    }
}
