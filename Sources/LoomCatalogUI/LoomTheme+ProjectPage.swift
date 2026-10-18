import SwiftUI

/// Values of the project page (V08; design preview `v2-studio-preview`: `.proj`, `.srow`, `.ptabs`, `.side-card`).
/// Colours, hairlines and text tones are the existing tokens.
extension LoomTheme {
    enum ProjectPage {
        // The page: a column with the preview's 30 pt side inset (20 pt below `wideBreakpoint`).
        static let sideInset: CGFloat = 30
        static let sideInsetNarrow: CGFloat = 20
        static let top: CGFloat = 24
        static let bottom: CGFloat = 32
        /// The pane width from which the side column sits beside the sessions.
        static let wideBreakpoint: CGFloat = 760
        static let sideColumn: CGFloat = 300
        static let columnGap: CGFloat = 20
        /// The instructions text reads in a column, like the chat.
        static let instructionsMaxWidth: CGFloat = 700

        // Header.
        static let stripe = CGSize(width: 4, height: 30)
        static let headerGap: CGFloat = 12
        static let statsGap: CGFloat = 18
        /// Between a figure and its noun in the stats line ("18" "sessions").
        static let figureGap: CGFloat = 4
        static let statsTop: CGFloat = 12
        static let statsBottom: CGFloat = 16
        static let name = Font.system(size: 22, weight: .semibold)
        static let pathFont = Font.system(size: 12, design: .monospaced)

        // Tabs: a 32 pt bar with a 2 pt accent underline on the open one.
        static let tabHeight: CGFloat = 32
        static let tabInset: CGFloat = 12
        static let tabUnderline: CGFloat = 2
        static let tabGap: CGFloat = 2
        static let tabsBottom: CGFloat = 12
        static let tabFont = Font.system(size: 12.5, weight: .medium)

        // A session row: indicator, title with the last line, branch, time.
        static let rowPaddingH: CGFloat = 12
        static let rowPaddingV: CGFloat = 10
        static let rowColumnGap: CGFloat = 12
        static let rowRadius: CGFloat = 9
        static let rowLineGap: CGFloat = 2
        static let rowBranchWidth: CGFloat = 170
        static let rowTimeWidth: CGFloat = 44
        static let rowTitle = Font.system(size: 13, weight: .medium)
        static let rowLine = Font.system(size: 12)
        static let rowBranch = Font.system(size: 11.5, design: .monospaced)
        static let rowTime = Font.system(size: 11.5)
        static let branchGlyph = Font.system(size: 10)
        /// Below this list width the branch column drops out.
        static let rowBranchBreakpoint: CGFloat = 460

        // A side card: presets, this week.
        static let cardPadding: CGFloat = 14
        static let cardGap: CGFloat = 12
        static let cardTitle = Font.system(size: 12.5, weight: .semibold)
        static let cardRowHeight: CGFloat = 28
        static let cardRowGlyph = Font.system(size: 12)
        static let statFigure = Font.system(size: 18, weight: .semibold)
        static let statGap: CGFloat = 14
        /// Between a usage figure and its label.
        static let statLabelGap: CGFloat = 4

        // Branches and instructions.
        static let branchRowHeight: CGFloat = 34
        static let branchNameFont = Font.system(size: 12.5, design: .monospaced)
        static let noticePadding: CGFloat = 12
        static let instructionsPadding: CGFloat = 18
    }
}
