import SwiftUI

/// Values of Settings → Remora and of Remora's memory sheet (DESIGN §20; the reference's `settings.css` "the Remora tab" block and
/// `remora.css` "the memory sheet"). Colours, hairlines and text tones are the existing tokens; the type is Ink's.
extension LoomTheme {
    /// Settings → Remora.
    enum RemoraTab {
        /// What the switch turns off is drawn at 38 % and answers nothing (`[data-dim].dim`).
        static let dimmed = Opacity.disabled

        /// The projects it reads: a wrapping row of checks, 10 below the help; a check is 26 high with radius 7, a strong-hairline edge,
        /// 8 in on the left and 10 on the right, the mark and the name 8 apart; 8 between the checks.
        static let projectsTop: CGFloat = 10
        static let projectGap: CGFloat = 8
        static let projectHeight = InkHeight.control
        static let projectRadius = InkRadius.group
        static let projectPaddingLeading: CGFloat = 8
        static let projectPaddingTrailing: CGFloat = 10
        static let projectFont = InkStyle(size: 12.5)
        /// A project left out is drawn in the tertiary tone with its mark grey.
        static let projectOffMark = 0.6

        /// The facts in a row's line (what the memory holds, what was used): mono 11.5.
        static let fact = InkType.metaLarge

        /// The last line: 11.5 on 1.55, tertiary, at most 560 wide, 10 under the cards and 2 in.
        static let note = InkStyle(size: 11.5)
        static let noteLine: CGFloat = 17.8
        static let noteTop: CGFloat = 10
        static let noteInset: CGFloat = 2
        static let noteMaxWidth: CGFloat = 560
        static let noteSpacing = Settings.lineSpacing(size: 11.5, lineHeight: noteLine)

        /// The threshold stepper steps by 1 % from 0 % (the brief never waits) to 50 %.
        static let thresholdRange = 0...50
    }

    /// Remora's memory sheet (560 wide, `Sheet.memoryWidth`).
    enum MemorySheet {
        /// The head's line under the title: 12.5 secondary, 8 below.
        static let lineTop: CGFloat = 8
        /// The tabs (a segment) 14 below the line; the pane 12 below the tabs, up to 404 high, then it scrolls.
        static let tabsTop: CGFloat = 14
        static let paneTop: CGFloat = 12
        static let paneMaxHeight: CGFloat = 404
        /// The sheet keeps this much of the window under it, so it never touches the window's edge.
        static let windowBottom: CGFloat = 16

        /// A journal day: 12 under the one before; its label 4 above the first line.
        static let dayGap: CGFloat = 12
        static let dayLabelBottom: CGFloat = 4
        /// A line: columns of 44 (the time), flexible and 22 (the ×), 8 apart; 5 above and below, 8 in on the left and 6 on the right;
        /// radius 7; the text 12.5 on 1.5, the time mono 11 on 19; the × is 20×20 with radius 5 and an 11 pt glyph, shown on hover.
        static let lineTimeWidth: CGFloat = 44
        static let lineRemoveColumn: CGFloat = 22
        static let lineGap: CGFloat = 8
        static let linePaddingV: CGFloat = 5
        static let linePaddingLeading: CGFloat = 8
        static let linePaddingTrailing: CGFloat = 6
        static let lineRadius = InkRadius.group
        static let lineText = InkStyle(size: 12.5)
        static let lineTextHeight: CGFloat = 18.75
        static let lineTime = InkType.meta
        static let lineTimeHeight: CGFloat = 19
        static let removeSide: CGFloat = 20
        static let removeRadius: CGFloat = 5
        static let removeGlyph = Font.system(size: 11, weight: .medium)

        /// A project's note: 12 under the one before; raised 1 with radius 10, 10 above, 12 at the sides and below. The head is 12.5
        /// medium with the mark 8 before the name and the size in mono 11 tertiary at the end; the body is 8 below, 12.5 on 1.55 secondary,
        /// radius 7, 6 and 8 inside and 8 wider than the card's text on each side; while it is edited it is on the canvas with an accent
        /// edge and a 3 pt wash. The buttons are 8 below, 6 apart.
        static let noteGap: CGFloat = 12
        static let noteRadius = InkRadius.activityCard
        static let notePaddingTop: CGFloat = 10
        static let notePaddingH: CGFloat = 12
        static let notePaddingBottom: CGFloat = 12
        static let noteHead = InkStyle(size: 12.5, weight: .medium)
        static let noteHeadGap: CGFloat = 8
        static let noteMeta = InkType.meta
        static let noteBodyTop: CGFloat = 8
        static let noteBody = InkStyle(size: 12.5)
        static let noteBodyHeight: CGFloat = 19.4
        static let noteBodyRadius = InkRadius.group
        static let noteBodyPaddingV: CGFloat = 6
        static let noteBodyPaddingH: CGFloat = 8
        /// The editor's own text inset, taken back so that the text stays where it was.
        static let editorInset: CGFloat = 5
        static let noteEditEdge: CGFloat = 1
        static let noteEditWash: CGFloat = 3
        static let noteButtonsTop: CGFloat = 8
        static let noteButtonsGap: CGFloat = 6
        /// A removed note's line: 12.5 secondary with Undo at the end.
        static let removedText = InkStyle(size: 12.5)

        /// Remora.md: a raised 1 card of radius 10 with mono 12 on 1.55 inside (10 and 14 in, 12 below); its path is mono 11.5 tertiary,
        /// 10 below the card, with the button at the end; the honesty line is 12 secondary, 10 below.
        static let noteFileText = InkStyle(size: 12, mono: true)
        static let noteFileLine: CGFloat = 18.6
        static let noteFilePaddingTop: CGFloat = 10
        static let noteFilePaddingH: CGFloat = 14
        static let noteFilePaddingBottom: CGFloat = 12
        static let pathTop: CGFloat = 10
        static let pathGap: CGFloat = 8
        static let pathText = InkType.metaLarge
        static let honestyText = InkStyle(size: 12)
        static let honestyTop: CGFloat = 10

        /// A pane with nothing in it.
        static let emptyText = InkStyle(size: 12.5)
        static let emptyTop: CGFloat = 8

        static let lineSpacing = Settings.lineSpacing(size: lineText.size, lineHeight: lineTextHeight)
        static let timeSpacing = Settings.lineSpacing(size: lineTime.size, mono: true, lineHeight: lineTimeHeight)
        static let noteBodySpacing = Settings.lineSpacing(size: noteBody.size, lineHeight: noteBodyHeight)
        static let noteFileSpacing = Settings.lineSpacing(size: noteFileText.size, mono: true, lineHeight: noteFileLine)
    }
}
