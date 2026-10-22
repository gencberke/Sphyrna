import LoomCore
import SwiftUI

/// The new-session page's look (DESIGN §8; the reference's `.draftpage`, `.ask`, `.pick`, `.folder`, `.keys`, `.seg` and
/// `.pchip`, `design/reference-src/shared/head.css`). The page's rhythm lives in `NewSessionLayout`; this is its type, its
/// colours and the optical values that stay off the 4 pt grid (they are kept out of `HighlightTests`' grid list).
extension LoomTheme {
    enum Draft {
        // MARK: The question

        /// The question: 46 ultralight, tracked −3 %.
        static let question = InkType.display
        /// The space between "in" and the picker (a word space at 46 pt) and between lines of the two-row question.
        static let questionWordGap: CGFloat = 11
        static let questionRowGap: CGFloat = 8
        /// A narrow pane shrinks the first line of the two-row question down to this share instead of wrapping it.
        static let questionShrink: CGFloat = 0.6
        /// The longest a project's name grows before it is cut at its end.
        static let pickMaxWidth: CGFloat = 420
        /// The picker's underline: 2 pt of the project's tone at 85 %, 4 pt under the line box.
        static let underlineThickness: CGFloat = 2
        static let underlineGap: CGFloat = 4
        static let underlineOpacity = 0.85
        /// The chevron: a 20 pt box 4 from the name, its glyph optically 13, set 3 low to sit on the x-height.
        static let chevronBox: CGFloat = 20
        static let chevronGap: CGFloat = 4
        static let chevronFont = Font.system(size: 13, weight: .medium)
        static let chevronDrop: CGFloat = 3

        /// The underline of a project's tone at 85 %, in each appearance and contrast; a project with no tone gets the neutral
        /// one, the tertiary text.
        static func underline(_ tone: ProjectTone?) -> ContrastStyle {
            guard let tone else { return Text.tertiaryStyle }
            return ContrastStyle(
                standard: Tone(rgb: ProjectColor.baseRGB(tone), opacity: underlineOpacity),
                increased: Tone(rgb: ProjectColor.increasedRGB(tone), opacity: underlineOpacity),
                lightStandard: Tone(rgb: ProjectColor.lightBaseRGB(tone), opacity: underlineOpacity),
                lightIncreased: Tone(rgb: ProjectColor.lightIncreasedRGB(tone), opacity: underlineOpacity))
        }

        // MARK: The folder line and the keys

        /// "~/path · branch": mono 12, tertiary, 10 between the pieces.
        static let folder = InkStyle(size: 12, mono: true)
        static let folderGap: CGFloat = 10
        /// The keys line: mono 11 (`InkType.meta`), the key in secondary 500, 18 between the keys.
        static let keys = InkType.meta
        static let keysGap: CGFloat = 18
        static let keyWordsGap: CGFloat = 4

        // MARK: The branch strip

        /// A segment: 12 medium, with a 13 pt glyph 6 from its words.
        static let segment = InkStyle(size: 12, weight: .medium)
        static let segmentGlyph = Font.system(size: 13)
        static let segmentGlyphGap: CGFloat = 6
        /// The name a chosen new-branch segment shows after its words.
        static let segmentName = InkStyle(size: 11.5, mono: true)
        static let segmentNameGap: CGFloat = 6
        static let segmentNameMaxWidth: CGFloat = 160
        /// The most a "Stay on <branch>" segment grows before the branch is cut at its end.
        static let segmentStayMaxWidth: CGFloat = 240
        /// The group is 26 high with 2 inside and 2 between; a segment is 22 high with 10 beside its words.
        static let segmentPadding: CGFloat = 2
        static let segmentGap: CGFloat = 2
        static let segmentPaddingH: CGFloat = 10
        /// The chosen segment's drop (the reference's `0 1px 2px rgba(0,0,0,.22)`).
        static let segmentDrop = Color.black.opacity(0.22)
        static let segmentDropRadius: CGFloat = 1
        static let segmentDropY: CGFloat = 1

        // MARK: The popover of a new choice's name

        static let popoverPadding: CGFloat = 12
        static let popoverGap: CGFloat = 8

        // MARK: Presets

        /// A chip: 26 high, radius 6, 11 beside its words, the canvas at 72 % under a strong-hairline edge.
        static let chipText = InkType.small
        static let chipPaddingH: CGFloat = 11
        static let chipFillOpacity = 0.72
        static let chipMaxWidth: CGFloat = 280
        /// The "Presets" label sits 4 more from the first chip.
        static let labelExtraGap: CGFloat = 4
        /// The quiet line that says where mode and model came from.
        static let note = InkType.meta

        // MARK: Remora's brief (§8, D-80; the reference's `.nrow` and `.ndraft`)

        /// The row: 18 under the presets' line, 12.5 secondary words, the time in mono 11 tertiary, 10 between its pieces.
        static let remoraTop: CGFloat = 18
        static let remoraGap: CGFloat = 10
        static let remoraText = InkStyle(size: 12.5)
        static let remoraMeta = InkType.meta
        /// The line above the composer: 22 under the folder line and 8 above the card, 18 in from the card's edges, "Remora's
        /// draft" in 11.5 medium secondary, then mono 11 tertiary, 10 between its pieces.
        static let originTop: CGFloat = 22
        static let originComposerGap: CGFloat = 8
        static let originInset: CGFloat = 18
        static let originGap: CGFloat = 10
        static let originTitle = InkStyle(size: 11.5, weight: .medium)
        static let originDetail = InkType.meta
    }
}

extension View {
    /// Draws a text in one of Ink's roles: its face, its tracking and, for the label, capitals.
    func draftType(_ style: LoomTheme.InkStyle) -> some View {
        font(style.font).tracking(style.trackingPoints).textCase(style.capitals ? .uppercase : nil)
    }
}
