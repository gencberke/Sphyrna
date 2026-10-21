import LoomCore
import SwiftUI

/// The sidebar in Ink (DESIGN §2 items 1, 3, 4 and 5, §6 Rows and Project colour; A1 and A2 of the reference): the header row,
/// the search door, the Home and New session rows, the list's heading, the project head, the session line and the activity card,
/// and the footer. Colours, hairlines and text tones are the shared tokens; the pill is `LoomTheme.Highlight`.
extension LoomTheme {
    enum Sidebar {
        // MARK: Header (52 pt): the window buttons' clearance and the sidebar toggle

        /// The toggle sits at the trailing end, as in the reference.
        static let headerTrailing: CGFloat = 12

        // MARK: The search door (30 pt, radius 8, a hairline box)

        static let doorHeight = InkHeight.field
        static let doorRadius = InkRadius.row
        /// The door's distance from the sidebar's edges, and below it.
        static let doorInset: CGFloat = 12
        static let doorBottom: CGFloat = 8
        static let doorPaddingLeading: CGFloat = 8
        static let doorPaddingTrailing: CGFloat = 6
        static let doorSpacing: CGFloat = 8
        static let doorGlyph = Font.system(size: 13)
        static let doorLabel = InkType.body.font

        /// The key cap: ⌘K in mono at the door's trailing end.
        static let keyCapFont = InkStyle(size: 10.5, mono: true).font
        static let keyCapPaddingH: CGFloat = 4
        static let keyCapRadius = InkRadius.key

        // MARK: Home and New session (28 pt, radius 8)

        static let homeRowHeight = InkHeight.sidebarRow
        static let homeRowInset: CGFloat = 8
        static let homeRowSpacing: CGFloat = 8
        static let homeRowBottom: CGFloat = 2
        static let homeGlyph = Font.system(size: 13)
        /// The New session row's `+` (15 pt in the same 16 pt column) and its tint: secondary, primary under the pointer.
        static let newSessionGlyph = Font.system(size: 15)
        /// The glyph column, so Home and New session start their words at the same place.
        static let homeGlyphColumn: CGFloat = 16

        /// The count of what needs the user: the attention wash behind the attention text, in mono, 18 wide at least, 17 high.
        static let badgeMinWidth: CGFloat = 18
        static let badgeHeight: CGFloat = 17
        static let badgePadding: CGFloat = 4
        static let badgeFont = InkStyle(size: 10.5, weight: .semibold, mono: true).font

        // MARK: The list's heading: the view's name, and the switch "projects · activity"

        static let headingInset: CGFloat = 16
        static let headingTop: CGFloat = 16
        /// 8 under the label in both views (the reference's `side-sec`); the first project head adds `firstHeadTop`.
        static let headingBottom: CGFloat = 8
        static let headingLabel = InkType.label
        static let switchGap: CGFloat = 4
        static let switchFont = InkType.meta.font
        static let switchFontChosen = Font.system(size: 11, weight: .medium, design: .monospaced)

        // MARK: A project head (28 pt): its mark, its name, the attention dot; chevron, + and ⋯ on hover

        /// The head's content starts 14 pt in, so the mark's centre sits over the sessions' status column.
        static let headLeading: CGFloat = 14
        static let headTrailing: CGFloat = 4
        static let headSpacing: CGFloat = 6
        /// The gap above a project head (and the "Sessions" head) that follows a group: the reference's `.pgroup` pads 8 below
        /// and 2 above. The list puts no gap between its entries (`listSpacing`).
        static let groupGap: CGFloat = 10
        /// The first head sits 2 under the label's gap.
        static let firstHeadTop: CGFloat = 2
        /// The attention dot at rest sits this far from the head's trailing edge; with the controls shown it sits just before them.
        static let headDotTrailing: CGFloat = 12
        static let headName = Font.system(size: 12.5, weight: .medium)

        // MARK: A session row (project view, 28 pt) and an activity card (radius 10)

        static let lineRowHeight = InkHeight.sidebarRow
        /// The list stacks its rows, heads and cards with no gap (the reference's `.alist`, `.pgroup`).
        static let listSpacing: CGFloat = 0
        /// An activity card pads 5 above and 6 below (`.scard`).
        static let cardTop: CGFloat = 5
        static let cardBottom: CGFloat = 6
        /// A session row's, an activity card's and a draft row's leading inset: it puts the status column's centre 22 pt
        /// from the list's edge, where the subagent branches leave it (`Branches.column`). The trailing inset is `Space.cardH`.
        static let rowLeading: CGFloat = 16
        static let lineTitle = InkType.body.font
        static let lineTitleSelected = Font.system(size: 13, weight: .medium)
        /// The time at a row's trailing end: mono 11.
        static let timeFont = InkType.meta.font
        /// The reason line (11.5, secondary), a command in mono, and the card's fixed bottom row (11, tertiary).
        static let reasonFont = Font.system(size: 11.5)
        static let reasonMonoFont = Font.system(size: 11.5, design: .monospaced)
        static let metaFont = Font.system(size: 11)
        static let metaMonoFont = InkType.meta.font
        static let metaGlyph = Font.system(size: 10)
        static let metaSpacing: CGFloat = 4
        /// The harness mark's box is trimmed 2 pt on the left and 1 pt on the right (`.srow .hm`, `.scard .c1 .hm`).
        static let markTrimLeading: CGFloat = 2
        static let markTrimTrailing: CGFloat = 1
        /// Where a title starts, from the row's leading inset: the status slot, the trimmed mark and two gaps (37).
        static var titleIndent: CGFloat {
            Layout.indicatorSlot.width + Layout.harnessMarkRow - markTrimLeading - markTrimTrailing + 2 * Space.cardSpacing
        }
        /// Lines 2 and 3 of a card start under the title.
        static var cardTextIndent: CGFloat { titleIndent }

        /// Section headings (Drafts, Active, the days): 11.5 medium tertiary, the count in mono, 6 apart. They start on the
        /// status column's left edge (`rowLeading` inside the list's inset), pad 12 above (none for the list's first) and 5 below.
        static let sectionFont = Font.system(size: 11.5, weight: .medium)
        static let sectionCountFont = InkType.meta.font
        static let activityHeadingTop: CGFloat = 12
        static let activityHeadingBottom: CGFloat = 5
        static let activityHeadingSpacing: CGFloat = 6

        /// A draft row: italic, secondary.
        static let draftFont = InkType.body.font

        // MARK: Footer (46 pt, a hairline above)

        static let footerHeight: CGFloat = 46
        static let footerInset: CGFloat = 10
        static let footerSpacing: CGFloat = 4
        static let chipFont = InkType.meta.font
        static let chipMeter = CGSize(width: 40, height: 4)
        static let chipHeight: CGFloat = InkHeight.control
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

extension View {
    /// Draws a text in one of Ink's roles: its face, its tracking and, for the label, capitals.
    func sidebarType(_ style: LoomTheme.InkStyle) -> some View {
        font(style.font).tracking(style.trackingPoints).textCase(style.capitals ? .uppercase : nil)
    }
}
