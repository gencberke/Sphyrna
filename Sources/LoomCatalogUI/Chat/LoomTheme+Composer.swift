import LoomCore
import SwiftUI

/// The composer's tokens (CHAT-SPEC → Composer, D-58; design/v2-studio-preview.html `.comp`, `.bar`, `.menu`). Values that
/// exist in the Ink roles are used from there; only what the composer adds lives here. Exempt from the theme guard like
/// every `LoomTheme*.swift`.
extension LoomTheme {
    enum Composer {
        // MARK: Card

        /// The card's width: the chat's reading column (DESIGN §3 Columns; the reference's `.dock-in`).
        static let column: CGFloat = Rhythm.readingColumn
        static let dockSideInset: CGFloat = 24
        static let dockBottomInset: CGFloat = 16
        static let dockTopInset: CGFloat = 8
        static let radius: CGFloat = InkRadius.composer
        /// The card is raised 2; it follows the tone, so computed, never stored.
        static var fill: Color { Surface.raised2 }
        /// The lift of the card: level 2 (a hairline and a small drop, Ink v4 §0.3).
        static let depth = Elevation.lift
        static let textInsetH: CGFloat = 16
        static let textTop: CGFloat = 12
        static let minimumTextHeight: CGFloat = 46
        static let maximumTextHeight: CGFloat = 220

        // MARK: Bar

        static let barHeight: CGFloat = InkHeight.composerBar
        static let barInsetH: CGFloat = 8
        static let barInsetBottom: CGFloat = 8
        /// A chip of the bar and the ring's hit square: 28 high (`.cchip`, `.cring`).
        static let controlSide: CGFloat = InkHeight.sidebarRow
        static let sendSide: CGFloat = InkHeight.field
        static let barSpacing: CGFloat = 2
        static let sendGap: CGFloat = 2
        static let chipGap: CGFloat = 8
        /// The chip's own rhythm (the reference's `.cchip`: 6 between its parts, 9 aside; the model chip 8 and 6): optical
        /// values, off the 4 pt grid and outside `HighlightTests`' list.
        static let chipPartGap: CGFloat = 6
        static let chipPaddingH: CGFloat = 9
        static let modelChipPaddingLeading: CGFloat = 8
        static let modelChipPaddingTrailing: CGFloat = 6
        static let chipRadiusControl: CGFloat = InkRadius.control
        static let barFont = Font.system(size: 12, weight: .medium)
        static let effortWordFont = Font.system(size: 12)
        static let barIcon = Font.system(size: 14)
        static let plusIcon = Font.system(size: 14)
        static let chevron = Typography.chevron
        static let modeColor = Text.secondary
        static let modelColor = Text.secondary
        static let effortColor = Text.tertiary
        static let harnessMark = Layout.harnessMarkHeader

        // MARK: Send (says what Return does)

        static let sendIcon = Font.system(size: 15, weight: .semibold)
        static let stopGlyph: CGFloat = 10
        static let stopRadius: CGFloat = 2.5
        /// The accent disc of a plain send, the faint disc of an off one and the primary disc of Interrupt. The glyph on the
        /// last two is the canvas colour, as in the reference; it follows the tone, so computed.
        static let sendReadyFill = Accent.base
        static let sendOffFill = Text.faint
        static let sendStopFill = Text.primary
        static var sendOnDiscGlyph: Color { Surface.canvas }
        /// The words ("Send Now", "After This Turn", "Update", "Resume") are accent capsules with an icon and a 12.5
        /// semibold word, 10 before the icon and 13 after the word (optical).
        static let sendWordFont = Font.system(size: 12.5, weight: .semibold)
        static let sendWordIcon = Font.system(size: 12, weight: .semibold)
        static let sendWordPaddingLeading: CGFloat = 10
        static let sendWordPaddingTrailing: CGFloat = 13
        static let sendWordGap: CGFloat = 6

        // MARK: Queue strip (a drawer tucked behind the card's top edge)

        static let queueRowHeight: CGFloat = InkHeight.field
        /// Radius 12 at the strip's top corners only; its bottom is behind the card.
        static let queueRadius: CGFloat = InkRadius.card
        static var queueFill: Color { Surface.raised1 }
        /// The strip's sides sit 14 inside the card's, its bottom 12 behind the card and its padding is 4 / 6 / 18 (the
        /// reference's `.qstrip`): optical values, off the 4 pt grid and outside `HighlightTests`' list.
        static let queueInsetH: CGFloat = 14
        static let queueOverlap: CGFloat = 12
        static let queuePaddingTop: CGFloat = 4
        static let queuePaddingH: CGFloat = 6
        static let queuePaddingBottom: CGFloat = 18
        static let queueRowPaddingLeading: CGFloat = 8
        static let queueRowPaddingTrailing: CGFloat = 3
        static let queueHeadHeight: CGFloat = InkHeight.sidebarRow
        static let queueRowRadius: CGFloat = InkRadius.row
        static let queueEditFill = Accent.wash
        static let queueEditEdge = Accent.base.opacity(0.4)
        static let queueRowSpacing: CGFloat = 2
        /// A paused queue's rows are drawn at 60 %.
        static let queuePausedOpacity = 0.6
        static let queueMaxVisible = 4
        static let queueFont = Font.system(size: 12.5)
        static let queueIcon: CGFloat = 22
        static let queueWaitIcon = Font.system(size: 13)

        // MARK: Attachments (thumbnails and file chips above the text)

        static let attachmentHeight: CGFloat = 42
        static let attachmentRadius: CGFloat = 7
        static let thumbnail = CGSize(width: 56, height: 42)
        static let attachmentSpacing: CGFloat = 8
        /// Between the row and the text: 10 (optical).
        static let attachmentBottom: CGFloat = 10
        static let attachmentFont = Font.system(size: 12)
        static let attachmentSizeFont = InkType.meta.font
        static let attachmentMaxLabelWidth: CGFloat = 180
        static let attachmentIcon = Font.system(size: 15)
        /// A file chip: 9 before the icon, 10 after the size (optical).
        static let attachmentPaddingLeading: CGFloat = 9
        static let attachmentPaddingTrailing: CGFloat = 10
        /// The × badge on a thumbnail: a 15 pt disc of black 60 % with a white cross, 3 from the corner.
        static let badgeSide: CGFloat = 15
        static let badgeInset: CGFloat = 3
        static let badgeGlyph = Font.system(size: 8, weight: .bold)
        static let badgeFill = Color.black.opacity(0.6)
        static let badgeGlyphColor = Color.white

        // MARK: Mention pills (D-96: a session in the chip row)

        /// A pill is a file chip's shape at its height, with the harness mark (12, as on rows) before the title.
        static let mentionHeight: CGFloat = attachmentHeight
        static let mentionMark: CGFloat = Layout.harnessMarkRow
        static let mentionPartGap: CGFloat = attachmentSpacing
        static let mentionPaddingTrailing: CGFloat = attachmentPaddingLeading
        /// The pill sits on a faint wash so it reads as a session, not a file; it follows the tone, so computed.
        static var mentionFill: Color { Surface.raised1 }

        // MARK: Menus (`/` and `@`: the popover family, flat lists)

        static let menuWidth: CGFloat = 420
        static let menuRowHeight: CGFloat = InkHeight.field
        static let menuMaxRows = 8
        static let menuRadius: CGFloat = InkRadius.card
        /// The pill sits 6 inside the menu's edge, as in every popover and menu of the host (DESIGN §6 Controls, §11 Menus).
        static let menuInset: CGFloat = Host.menuInset
        /// The gap above the card is the host's: 6 (the reference's `place`).
        static let menuGap: CGFloat = Host.anchorGap
        static let menuHeadHeight: CGFloat = 28
        static let menuHeadFont = Font.system(size: 11.5, weight: .medium)
        static let menuCommandFont = Font.system(size: 12, design: .monospaced)
        static let menuTitleFont = Font.system(size: 13)
        static let menuDetailFont = InkType.meta.font
        static let menuHintFont = InkType.meta.font
        static let menuIconSlot: CGFloat = 16
        static let menuIconFont = Font.system(size: 13)

        // MARK: Ring popover

        static let ringPopoverWidth: CGFloat = 268
        static let ringHoverDelay: TimeInterval = 0.15
        static let ringBarHeight: CGFloat = 6
        static let ringBarRadius: CGFloat = 3
        /// The popover's padding is 12 aside from the figure and 14 around the text (optical).
        static let ringPopoverPaddingV: CGFloat = 12
        static let ringPopoverPaddingH: CGFloat = 14
        static let ringBarMarginTop: CGFloat = 10
        static let ringBarMarginBottom: CGFloat = 8
        static let ringPopoverTitle = InkType.header.font
        static let ringPopoverNote = Font.system(size: 11.5)
        /// The ring turns red above this share of the window (CHAT-SPEC → The bar).
        static let ringRed = 0.9

        // MARK: Modes (D-63)

        /// The colour of a permission mode: soft tones that rise from cool to warm as the mode lets Claude do more, so the
        /// bar says how much a session may do without being loud. Each is at least 4.5:1 on raised 2, the popover and the
        /// canvas, also under the hover fill (`ThemeAppearanceTests`). A mode of the CLI that Loom does not offer, and a mode
        /// not known yet, take the neutral tone.
        enum ModeTone {
            static let askPair = Adaptive(dark: RGB(hex: 0x7FC8D8), light: RGB(hex: 0x0E6B7A))
            static let askBeforeEditsPair = Accent.highPair
            static let acceptEditsPair = Adaptive(dark: RGB(hex: 0x86D3A4), light: RGB(hex: 0x1B6B3F))
            static let autoPair = Adaptive(dark: RGB(hex: 0xD9C677), light: RGB(hex: 0x745B00))
            static let fullAccessPair = Adaptive(dark: RGB(hex: 0xEF9C70), light: RGB(hex: 0x9E4108))
            static let planPair = Adaptive(dark: RGB(hex: 0xB9A0E6), light: RGB(hex: 0x6B46B0))
            static let neutralPair = Text.secondaryPair

            static let askRGB = askPair.dark
            static let askBeforeEditsRGB = askBeforeEditsPair.dark
            static let acceptEditsRGB = acceptEditsPair.dark
            static let autoRGB = autoPair.dark
            static let fullAccessRGB = fullAccessPair.dark
            static let planRGB = planPair.dark
            static let neutralRGB = neutralPair.dark

            /// `raw` is the mode as Loom stores it (`ClaudePermissionMode.rawValue`).
            static func pair(forRaw raw: String?) -> Adaptive {
                switch raw.flatMap(ClaudePermissionMode.init(rawValue:)) {
                case .ask?: askPair
                case .askBeforeEdits?: askBeforeEditsPair
                case .acceptEdits?: acceptEditsPair
                case .auto?: autoPair
                case .fullAccess?: fullAccessPair
                case .plan?: planPair
                case nil: neutralPair
                }
            }

            /// The Dark tone.
            static func rgb(forRaw raw: String?) -> RGB { pair(forRaw: raw).dark }

            static func color(forRaw raw: String?) -> Color { pair(forRaw: raw).color }
        }

        // MARK: Pickers (the mode list, D-63, after Codex's)

        /// The mode popover is 312 wide (`pr2` rows: 16 | name | check, a 12 pt line under the name).
        static let pickWidth: CGFloat = 312
        /// The pill sits 6 inside the list's edge (DESIGN §6 Controls, §11 Menus).
        static let pickInset: CGFloat = Host.menuInset
        static let pickRowRadius: CGFloat = Highlight.radius
        static let pickRowPaddingV: CGFloat = 8
        /// A mode row's own padding: 10 aside, 7 above and 8 below (optical, off the grid).
        static let pickRowInsetH: CGFloat = 10
        static let pickRowTop: CGFloat = 7
        static let pickRowBottom: CGFloat = 8
        static let pickRowSpacing: CGFloat = 1
        static let pickIconSide: CGFloat = 18
        static let pickHeaderHeight: CGFloat = 28
        static let pickMaxHeight: CGFloat = 300
        static let pickHeaderFont = Font.system(size: 11.5, weight: .medium)
        static let pickTitleFont = Font.system(size: 13, weight: .medium)
        static let pickSubtitleFont = Font.system(size: 12)
        static let pickCheck = Font.system(size: 11.5, weight: .semibold)
        static let pickIcon = Font.system(size: 15)
        static let pickDivider = Surface.hairline
        /// The chip's hover pill is a control's: radius 6.
        static let chipRadius: CGFloat = InkRadius.control

        // MARK: The model popover (D-75): the models by harness, then the effort

        static let modelPopoverWidth: CGFloat = 332
        /// The + popover is 300 wide.
        static let plusPopoverWidth: CGFloat = 300
        /// Rows sit 6 inside the popover's edge, radius 8 (DESIGN §6 Controls).
        static let modelPopoverInset: CGFloat = 6
        static let modelRowRadius: CGFloat = InkRadius.row
        static let modelRowHeight: CGFloat = InkHeight.field
        static let modelRowPaddingH: CGFloat = 10
        /// The name column: the longest name in the list ("Sonnet 5.5") fits, and the notes line up.
        static let modelNameColumn: CGFloat = 86
        static let modelColumnGap: CGFloat = 10
        static let modelNameFont = Font.system(size: 13, weight: .medium)
        static let modelDimmedNameFont = Font.system(size: 13)
        static let modelNoteFont = Font.system(size: 12)
        static let modelCheck = Font.system(size: 11, weight: .semibold)
        static let modelCheckSlot: CGFloat = 14
        static let groupHeadHeight: CGFloat = InkHeight.sidebarRow
        static let groupHeadGap: CGFloat = 7
        static let groupHeadPaddingH: CGFloat = 10
        static let groupNameFont = Font.system(size: 11.5, weight: .semibold)
        static let groupDimmedNameFont = Font.system(size: 11.5, weight: .medium)
        static let groupNoteFont = Font.system(size: 10.5, design: .monospaced)
        /// Between two groups: 5 above the hairline and 5 under it (optical).
        static let groupSeparation: CGFloat = 5

        // MARK: Effort (under the model list)

        /// The effort block: 10 aside and above, 4 below, 5 under the list (optical).
        static let effortSectionTop: CGFloat = 10
        static let effortSectionH: CGFloat = 10
        static let effortSectionBottom: CGFloat = 4
        static let effortSectionGap: CGFloat = 5
        static let effortHeadGap: CGFloat = 8
        static let effortLabelFont = Font.system(size: 11.5, weight: .medium)
        static let effortNameFont = InkType.header.font
        static let effortNoneFont = Font.system(size: 12)
        static let effortLevelFont = Font.system(size: 10.5, design: .monospaced)
        /// The slider: a 6 pt track, a 14 pt thumb and 4 pt dots in a 22 pt line (a 24 pt hit area), 14 under the head and 2
        /// above the names.
        static let effortTrackThickness: CGFloat = 6
        static let effortTrackHeight: CGFloat = 24
        static let effortThumb: CGFloat = 14
        static let effortDot: CGFloat = 4
        static let effortSliderTop: CGFloat = 14
        static let effortLevelsTop: CGFloat = 4
        static let effortTrackTone = Surface.strongHairlineTone
        static let effortTrack = effortTrackTone.color
        static let effortFill = Accent.base
        static let effortThumbPair = Adaptive(dark: whiteRGB, light: Accent.onAccentPair.light)
        static let effortThumbFill = effortThumbPair.color
        static let effortDotOnTone = AdaptiveTone(dark: Tone(rgb: whiteRGB, opacity: 0.55), light: Tone(rgb: Accent.onAccentPair.light, opacity: 0.7))
        static let effortDotOnFill = effortDotOnTone.color
        static let effortDotOffTone = overlay(dark: 0.22, light: 0.22)
        static let effortDotOffFill = effortDotOffTone.color
        static let effortThumbShadowTone = AdaptiveTone(dark: Tone(rgb: RGB(red: 0, green: 0, blue: 0), opacity: 0.35), light: Tone(rgb: inkRGB, opacity: 0.30))
        static let effortThumbShadow = effortThumbShadowTone.color
        static let effortThumbShadowRadius: CGFloat = 2
        /// The keys line under the effort: mono 10.5, 14 between keys, a hairline above it (optical).
        static let keysLineFont = Font.system(size: 10.5, design: .monospaced)
        static let keysLineGap: CGFloat = 14
        static let keysLineTop: CGFloat = 6
        static let keysLinePaddingTop: CGFloat = 7
        static let keysLinePaddingBottom: CGFloat = 3

        // MARK: Compact (a card waits above the composer)

        /// While a card waits the composer shrinks to one line and a bar, so the card's buttons stay on screen in a short
        /// window (the V18 checkpoint's 780x500 finding).
        static let compactTextHeight: CGFloat = 28
        static let compactMaximumTextHeight: CGFloat = 84
        static let compactTextTop: CGFloat = 8
        static let compactDockBottomInset: CGFloat = 8
        static let compactDockTopInset: CGFloat = 0

        // MARK: Notices and hints

        static let noticeFont = Font.system(size: 11.5)
        /// The line above the field that says its text goes with the card above (V18).
        static let cardNoteSize: CGFloat = 11.5
        static let cardNoteFont = Font.system(size: cardNoteSize)
        static let cardNoteIcon = Font.system(size: 12)
        /// Quiet: the note is tertiary with an arrow, and the orange stays on the card's edge (E4).
        static let cardNoteColor = Text.tertiary
        static let cardNoteGap: CGFloat = 6
        static let cardNoteTop: CGFloat = 12
        static let noticeInset: CGFloat = 16
        /// The keys line under the card: mono 11, 16 between the keys, the key in secondary, 8 below the card and 16 in (E3).
        static let hintFont = InkType.meta.font
        static let hintGap: CGFloat = 16
        static let hintRowGap: CGFloat = 4
        static let hintKeyGap: CGFloat = 4
        static let hintInset: CGFloat = 16
        /// Between the card and the keys line (8), and under the card's note (7: the reference's `.cnote`).
        static let hintTop: CGFloat = 8
        static let cardNoteBottom: CGFloat = 7
    }
}
