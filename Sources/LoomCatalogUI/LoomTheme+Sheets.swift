import SwiftUI

/// Values of the sheet family (DESIGN §6 Sheets, D-78, D-83; the reference's `shared/sheets.css`): the question asked before something
/// changes, on the popover surface over the window's scrim.
extension LoomTheme {
    enum Sheet {
        /// 420 wide, or 480 when the sheet lists files.
        static let width: CGFloat = 420
        static let wideWidth: CGFloat = 480
        /// The popover's surface, radius 12, 20 inside, with the popover's ring and shadow (`Elevation.popover`).
        static let radius = InkRadius.card
        static let padding: CGFloat = 20
        /// The scrim fades in over 160 ms.
        static let fade = 0.16

        /// The question: 14 semibold. The subject sits 8 under it in 13 medium, cut at two lines.
        static let title = InkStyle(size: 14, weight: .semibold)
        static let titleLine: CGFloat = 18.9
        static let subject = InkStyle(size: 13, weight: .medium)
        static let subjectLine: CGFloat = 18.2
        static let subjectTop: CGFloat = 8
        static let subjectLines = 2

        /// The facts: 12.5 on 1.5, 12 under the subject.
        static let text = InkStyle(size: 12.5)
        static let textLine: CGFloat = 18.75
        static let textTop: CGFloat = 12

        /// A list under a label: 14 below the text, the label 6 above its items; an item has a 4 pt dot 13 in and is 2 from the next.
        static let listTop: CGFloat = 14
        static let labelBottom: CGFloat = 6
        static let itemInset: CGFloat = 13
        static let itemGap: CGFloat = 2
        static let dot: CGFloat = 4
        static let dotLeading: CGFloat = 2
        /// The dot sits .66 em down the first line.
        static let dotTop: CGFloat = 8
        /// The count, size and folder in mono 11.5 secondary, 5 below the items.
        static let meta = InkType.metaLarge
        static let metaTop: CGFloat = 5

        /// The buttons: 20 below the facts, 8 apart, at the trailing edge; a way out sits at the leading edge.
        static let buttonsTop: CGFloat = 20
        static let buttonGap: CGFloat = 8

        /// A tinted button: the tone at 14 % and at 24 % under the pointer. The failure tint's hover is the failure hue at 22 %.
        static let tintFill = 0.14
        static let tintHover = 0.24
        static let failureHover = 0.22

        /// A sheet comes down under the window's header: Settings' band is 52.
        static let defaultHeaderOffset = InkHeight.header

        static let titleSpacing = Settings.lineSpacing(size: title.size, lineHeight: titleLine)
        static let subjectSpacing = Settings.lineSpacing(size: subject.size, lineHeight: subjectLine)
        static let textSpacing = Settings.lineSpacing(size: text.size, lineHeight: textLine)
    }
}
