import LoomCore
import SwiftUI

/// The popover and menu host (DESIGN §3 Depth, §6 Controls → Menus and pickers, §6 Motion; the reference's `.pop`, `.mi`, `.mnote`,
/// `.msep`, `.swrow` and `.swt`): one surface for every popover and menu the window opens, and the project menu drawn on it.
extension LoomTheme {
    enum Host {
        // MARK: The surface

        /// The popover level, radius 12 (cards, menus and the window), a hairline ring and the popover's shadow; no arrow.
        static let radius: CGFloat = InkRadius.card
        /// The gap between the control and the popover, on either side of it.
        static let anchorGap: CGFloat = 6
        /// The least the popover keeps from the window's edges.
        static let edgeMargin: CGFloat = 8
        /// The popover's ring: the `0 0 0 1px` layer of `Elevation.popover`, in each appearance.
        static let ringTone = AdaptiveTone(
            dark: Elevation.popover.dark.ring ?? Tone(rgb: whiteRGB, opacity: 0),
            light: Elevation.popover.light.ring ?? Tone(rgb: inkRGB, opacity: 0))
        static let ring = ringTone.color
        static let ringWidth: CGFloat = Line.hairline

        // MARK: Motion

        /// A popover or menu comes in with opacity and a 3 pt rise over 160 ms and leaves at once; under Reduce Motion it is
        /// instant both ways (DESIGN §6 Motion). A popover below its control settles from 3 pt above, as the reference's does.
        static let entranceDuration = 0.16
        static let rise: CGFloat = 3

        /// The entrance as an animation, or nil (instant) under Reduce Motion.
        static func entrance(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: entranceDuration)
        }

        // MARK: The project menu (`pmenu`)

        static let menuWidth: CGFloat = 276
        /// The pill sits 6 inside a menu's edge: this menu, the mode list and the / and @ menus (DESIGN §6 Controls, §11 Menus).
        static let menuInset: CGFloat = 6
        static let rowHeight: CGFloat = InkHeight.sidebarRow
        static let rowRadius: CGFloat = InkRadius.row
        static let rowGap: CGFloat = 10
        static let rowPaddingH: CGFloat = 8
        static let iconColumn: CGFloat = 16
        static let iconFont = Font.system(size: 15)
        static let rowFont = InkType.body.font
        /// A note under a row: 11.5, indented to the labels (8 padding, 16 icon column, 10 gap).
        static let noteFont = Font.system(size: 11.5)
        static let noteIndent: CGFloat = rowPaddingH + iconColumn + rowGap
        static let noteTrailing: CGFloat = 8
        static let noteBottom: CGFloat = 6
        /// A separator is a hairline with 6 above and below, bleeding to the surface's edges.
        static let separatorGap: CGFloat = 6
        /// The project's name over the first row, in label type: 8 above and aside, 7 below.
        static let labelTop: CGFloat = 8
        static let labelBottom: CGFloat = 7
        static let labelAside: CGFloat = 8
        /// The tone's name on the Color row.
        static let toneNameFont = InkType.small.font

        // MARK: The swatch row

        static let swatchSide: CGFloat = 18
        static let swatchRadius: CGFloat = 5
        static let swatchGap: CGFloat = 7
        /// 3 above and 7 below the row, 8 from the trailing edge, the leading edge on the labels.
        static let swatchRowTop: CGFloat = 3
        static let swatchRowBottom: CGFloat = 7
        static let swatchRowTrailing: CGFloat = 8
        static let swatchRowLeading: CGFloat = noteIndent
        /// A swatch is filled with its tone at 24 % (Paper 15 %) and has a 1 pt inset ring of the tone at 46 %.
        static let swatchFill = 0.24
        static let swatchFillLight = 0.15
        static let swatchRingOpacity = 0.46
        static let swatchRingWidth: CGFloat = 1
        /// The current swatch adds a gap ring in the popover's colour and a 3 pt ring in the full tone.
        static let swatchGapRing: CGFloat = 1.5
        static let swatchCurrentRing: CGFloat = 3
        /// None is hollow with a diagonal, 3 from each side and 1 thick (the reference's `left:3px; right:3px; top:8.5px`).
        static let noneDiagonalInset: CGFloat = 3
        static let noneDiagonalWidth: CGFloat = 1
        static let noneEdgeTone = Surface.strongerHairlineTone
        /// A swatch answers over at least 24 × 24 while drawn at 18 × 18 (DESIGN §6 Accessibility, hit areas).
        static let swatchHit: CGFloat = 24

        /// The swatch's fill in each appearance.
        static func swatchFillTone(_ tone: ProjectTone) -> AdaptiveTone {
            AdaptiveTone(dark: Tone(rgb: ProjectColor.baseRGB(tone), opacity: swatchFill),
                         light: Tone(rgb: ProjectColor.lightBaseRGB(tone), opacity: swatchFillLight))
        }

        /// The swatch's inset ring in each appearance.
        static func swatchRingTone(_ tone: ProjectTone) -> AdaptiveTone {
            AdaptiveTone(dark: Tone(rgb: ProjectColor.baseRGB(tone), opacity: swatchRingOpacity),
                         light: Tone(rgb: ProjectColor.lightBaseRGB(tone), opacity: swatchRingOpacity))
        }
    }
}
