import SwiftUI

/// Values of the inspector's Changes tab (V20; concept §3 "Review changes", the design preview's `#review`): the scope
/// control, the file list, the unified diff in a code card, the inline comment box and the footer. The surfaces, the
/// hairline and the text colours are the existing tokens; the width is `Rhythm.inspectorWidthReview`.
extension LoomTheme {
    enum Changes {
        // MARK: Body

        static let bodyInset: CGFloat = 14
        static let sectionGap: CGFloat = 10
        static let noteGap: CGFloat = 8
        static let controlGap: CGFloat = 8

        // MARK: Scope control

        static let segmentSpacing: CGFloat = 2
        static let segmentPadding: CGFloat = 2

        // MARK: File list

        static let fileRowHeight: CGFloat = 28
        static let fileRowGap: CGFloat = 8
        static let fileRowInset: CGFloat = 8
        static let fileIndent: CGFloat = 14
        static let fileGlyph = Font.system(size: 11)
        static let fileGlyphWidth: CGFloat = 14
        /// The slot at the end of a file row for its "Open in editor" button (shown under the pointer and on the open file).
        static let openSlot: CGFloat = 24
        static let fileName = Font.system(size: 12, design: .monospaced)
        static let fileListMaxHeight: CGFloat = 168
        static let commentBadgeGap: CGFloat = 4

        // MARK: The diff card

        static let cardRadius: CGFloat = Radius.md
        /// The code card is raised 1 (it follows the tone, so computed, never stored).
        static var cardFill: Color { Surface.raised1 }
        static let cardHeaderHeight: CGFloat = 30
        static let cardHeaderInset: CGFloat = 10
        static let hunkHeaderHeight: CGFloat = 22
        static let hunkHeaderFont = Font.system(size: 10.5, design: .monospaced)
        static let diffFont = Font.system(size: 11.5, design: .monospaced)
        static let gutterFont = Font.system(size: 10.5, design: .monospaced)
        static let rowMinHeight: CGFloat = 18
        static let numberWidth: CGFloat = 34
        static let signWidth: CGFloat = 14
        static let textInset: CGFloat = 4
        /// The "+" that opens a comment sits in the gutter of the row under the pointer.
        static let addButtonSize: CGFloat = 16
        static let addGlyph = Font.system(size: 9, weight: .bold)
        static let addButtonRadius: CGFloat = 4
        /// The code card shows at most this many diff lines; a file over it is "too large to show here".
        static let maxDiffLines = 2_000

        // MARK: Bands

        /// A changed line is a band of the success or failure hue at low opacity (a diff is content, DESIGN §3): 9 % in Ink,
        /// 8 % in Paper. The text on it is primary, and the line numbers tertiary; `ChangesInspectorTests` holds both
        /// contrasts in both appearances.
        static let addedBandTone = AdaptiveTone(dark: Tone(rgb: Success.basePair.dark, opacity: 0.09),
                                                light: Tone(rgb: Success.basePair.light, opacity: 0.08))
        static let removedBandTone = AdaptiveTone(dark: Tone(rgb: Status.failurePair.dark, opacity: 0.09),
                                                  light: Tone(rgb: Status.failurePair.light, opacity: 0.08))
        static let addedBand = addedBandTone.color
        static let removedBand = removedBandTone.color
        /// The sign of a changed line, in the light step of its hue.
        static let addedSign = Success.light
        static let removedSign = Status.failureLight

        static func bandRGB(added: Bool, _ appearance: Appearance) -> RGB {
            added ? Success.basePair[appearance] : Status.failurePair[appearance]
        }

        static func bandOpacity(added: Bool, _ appearance: Appearance) -> Double {
            (added ? addedBandTone : removedBandTone)[appearance].opacity
        }

        // MARK: Comments

        static let commentRadius: CGFloat = Radius.callout
        static let commentInset: CGFloat = 10
        static let commentGap: CGFloat = 6
        static let commentOuterV: CGFloat = 6
        static let commentFill = Accent.wash
        static let commentStroke = Accent.base.opacity(0.4)
        static let commentGlyph = Font.system(size: 11)
        static let commentLines = 6

        // MARK: Footer

        static let footerRadius: CGFloat = Radius.panel
        static let footerInset: CGFloat = 12
        static let footerHeight: CGFloat = 44
        static let footerGlyph = Font.system(size: 13)

        // MARK: States

        static let stateGap: CGFloat = 6
        static let stateTop: CGFloat = 20
    }
}
