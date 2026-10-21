import SwiftUI

/// Values of the project page (DESIGN §10; the reference's `.ppage`, `.pcol`, `.phead`, `.pstats`, `.ptabs`, `.sr`, `.sc`,
/// `.pset`, `.wk`, `.brw`, `.ihd` and `.mdc`, `design/reference-src/shared/project.css`). Colours, hairlines and text tones are the
/// existing tokens; the type is Ink's (`InkType`). Several sizes here are the reference's own optical values (14, 9, 11.5, 3, 18 …)
/// and sit off the 4 pt grid on purpose; `HighlightTests` pins only the grid ones.
extension LoomTheme {
    enum ProjectPage {
        // MARK: The column

        /// A column of at most 1,000 on the canvas, 32 side inset (20 below `wideBreakpoint` of pane width) and 32 below.
        static let maxWidth: CGFloat = 1_000
        static let sideInset: CGFloat = 32
        static let sideInsetNarrow: CGFloat = 20
        static let bottom: CGFloat = 32
        /// The pane width from which the side column sits beside the sessions.
        static let wideBreakpoint: CGFloat = 760
        static let sideColumn: CGFloat = 300
        static let columnGap: CGFloat = 20
        /// The side cards, and the list when the cards stack around it, are this far apart.
        static let blockGap: CGFloat = 14
        /// A tab's panel starts this far under the tab bar.
        static let panelTop: CGFloat = 10
        /// Branches and Instructions read in a column of at most 700.
        static let instructionsMaxWidth: CGFloat = 700

        // MARK: The head

        /// The head is the page's first line, as tall as the header (52): the mark, the name and the folder on its centre line.
        static let headHeight = InkHeight.header
        static let headGap: CGFloat = 10
        static let name = InkType.title
        /// The folder: mono 12 tertiary, set 2 off the name.
        static let path = InkStyle(size: 12, mono: true)
        static let pathLeading: CGFloat = 2
        /// ⋯ and New session, 8 apart at the trailing edge; New session's compose glyph is 15, 6 from its words.
        static let endGap: CGFloat = 8
        static let newSessionGlyph = Font.system(size: 15)
        static let newSessionGlyphGap: CGFloat = 6

        // MARK: The stats line

        /// 2 under the head; 14 between the figures and 4 between lines when they wrap; the tabs follow 14 below.
        static let statsTop: CGFloat = 2
        static let statsGap: CGFloat = 14
        static let statsLineGap: CGFloat = 4
        static let statsBottom: CGFloat = 14
        /// Between a figure and its noun ("18" "sessions").
        static let figureGap: CGFloat = 4
        static let stats = InkType.small
        static let statsFigure = InkStyle(size: 12, weight: .semibold)
        /// The branch: a 12 glyph and the name in mono 11.5, 4 apart.
        static let statsBranch = InkType.metaLarge
        static let statsBranchGlyph = Font.system(size: 12)
        static let statsBranchGap: CGFloat = 4

        // MARK: A session row

        /// The row's columns: the status slot, the harness's mark (12), the title with its last line, the branch, the time; 10 apart.
        static let rowColumnGap: CGFloat = 10
        static let rowPaddingH: CGFloat = 12
        static let rowPaddingTop: CGFloat = 8
        static let rowPaddingBottom: CGFloat = 9
        /// Rows lie flat on the canvas between hairlines; the pill (radius 8) sits 2 inside them.
        static let rowRadius = InkRadius.row
        static let rowPillGap: CGFloat = 2
        /// The status slot (16 high) and the harness's mark (12) sit on the title's 18 pt line.
        static let rowIndicatorTop: CGFloat = 1
        static let rowMarkTop: CGFloat = 3
        static let rowTitle = InkStyle(size: 13, weight: .medium)
        static let rowTitleHeight: CGFloat = 18
        /// The last line: 12 on 17, 1 under the title; a command or a path in mono 11.5 primary.
        static let rowLine = InkType.small
        static let rowLineMono = InkType.metaLarge
        static let rowLineHeight: CGFloat = 17
        static let rowLineTop: CGFloat = 1
        /// The branch (a 12 glyph, 5 from the name, mono 11.5 secondary) is 170 wide; the time is mono 11.5 tertiary, 44 wide.
        static let rowBranch = InkType.metaLarge
        static let rowBranchGlyph = Font.system(size: 12)
        static let rowBranchGap: CGFloat = 5
        static let rowBranchWidth: CGFloat = 170
        static let rowTime = InkType.metaLarge
        static let rowTimeWidth: CGFloat = 44
        static let rowMetaHeight: CGFloat = 18
        /// Below this list width the branch column drops out.
        static let rowBranchBreakpoint: CGFloat = 460

        // MARK: The side cards

        /// A card: raised 1, radius 12, a hairline edge and the card's depth, 16 padded. The title is header type, the note mono 11.
        static let cardPadding: CGFloat = 16
        static let cardRadius = InkRadius.card
        static let cardTitle = InkType.header
        static let cardNote = InkType.meta
        /// Where a card's content starts under its title: the presets 10, the figures 12, a line of text 8.
        static let presetsTop: CGFloat = 10
        static let figuresTop: CGFloat = 12
        static let textTop: CGFloat = 8
        /// A card's line of text: 12 secondary on 1.5.
        static let cardText = InkType.small
        static let cardTextSpacing: CGFloat = 4

        /// A preset row: 28 high with the pill (radius 8) reaching 8 past the card's padding; the mode's icon (14) in its tone, the
        /// name, an "all" tag and the model (mono 11 tertiary) after its harness's mark (12); 9 between the parts.
        static let presetHeight = InkHeight.sidebarRow
        static let presetGap: CGFloat = 9
        static let presetBleed: CGFloat = 8
        static let presetModeBox: CGFloat = 14
        static let presetModeGlyph = Font.system(size: 14)
        static let presetName = InkType.body
        static let presetModel = InkType.meta
        static let presetModelGap: CGFloat = 5
        static let presetAll = InkStyle(size: 10, mono: true)
        static let presetAllPadding: CGFloat = 4
        static let presetAllRadius = InkRadius.key

        /// Past 7 days: three equal columns 8 apart; a figure (18 semibold, tabular digits) over a label (11.5 secondary), 1 under it.
        static let statGap: CGFloat = 8
        static let statFigure = InkStyle(size: 18, weight: .semibold)
        static let statLabel = InkStyle(size: 11.5)
        static let statLabelGap: CGFloat = 1

        // MARK: Branches and Instructions

        /// A branch row: 34 high between hairlines, 12 in; the glyph's box (12), the name in mono 12.5, "current" in the accent, the
        /// worktree's words and folder, then the count of listed sessions and the time at the trailing end; 10 apart.
        static let branchRowHeight: CGFloat = 34
        static let branchGap: CGFloat = 10
        static let branchGlyphBox: CGFloat = 12
        static let branchGlyph = Font.system(size: 12)
        static let branchName = InkStyle(size: 12.5, mono: true)
        static let branchCurrent = InkStyle(size: 11, weight: .medium)
        static let branchWorktree = InkStyle(size: 11.5)
        static let branchWorktreeFolder = InkType.meta
        static let branchSessions = InkStyle(size: 11.5)
        static let branchTime = InkType.metaLarge
        static let branchTimeWidth: CGFloat = 44
        /// A note in place of a list: 12.5 on 1.5, 10 above and below, 12 in.
        static let note = InkStyle(size: 12.5)
        static let notePaddingV: CGFloat = 10
        static let notePaddingH: CGFloat = 12
        static let noteSpacing: CGFloat = 5
        /// "Only the first N branches are listed" and the CLAUDE.md cut note: 12, 10 under the list.
        static let cutNote = InkType.small
        static let cutNoteTop: CGFloat = 10

        /// The Instructions line: 30 high, 8 between the book (14), `CLAUDE.md` (mono 12.5 primary), its lines and age (11.5 tertiary).
        static let instructionsLineHeight = InkHeight.field
        static let instructionsGap: CGFloat = 8
        static let instructionsGlyph = Font.system(size: 14)
        static let instructionsName = InkStyle(size: 12.5, mono: true)
        static let instructionsMeta = InkStyle(size: 11.5)
        /// The CLAUDE.md card sits 6 under the line; 18 above, 22 at the sides and 20 below its text.
        static let instructionsCardTop: CGFloat = 6
        static let instructionsPaddingTop: CGFloat = 18
        static let instructionsPaddingH: CGFloat = 22
        static let instructionsPaddingBottom: CGFloat = 20

        // MARK: An empty project

        /// One line in 12.5 secondary where the list would be, 18 under the top and 8 above the bottom of its place. A later slice
        /// draws a small hammerhead over it (§17).
        static let emptyLine = InkStyle(size: 12.5)
        static let emptyTop: CGFloat = 18
        static let emptyBottom: CGFloat = 8
    }
}

extension View {
    /// Draws a text in one of Ink's roles: its face and its tracking.
    func projectType(_ style: LoomTheme.InkStyle) -> some View {
        font(style.font).tracking(style.trackingPoints)
    }
}
