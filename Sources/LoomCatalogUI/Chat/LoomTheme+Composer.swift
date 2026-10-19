import LoomCore
import SwiftUI

/// The composer's tokens (CHAT-SPEC → Composer, D-58; design/v2-studio-preview.html `.comp`, `.bar`, `.menu`). Values that
/// exist in Night Fleece 2 are used from there; only what the composer adds lives here. Exempt from the theme guard like
/// every `LoomTheme*.swift`.
extension LoomTheme {
    enum Composer {
        // MARK: Card

        /// The card's width: the reading column less the dock's side space (the prototype's `--col - 20`).
        static let column: CGFloat = Rhythm.readingColumn - 20
        static let dockSideInset: CGFloat = 24
        static let dockBottomInset: CGFloat = 16
        static let dockTopInset: CGFloat = 8
        static let radius: CGFloat = Radius.xxl
        /// The card's fill is a panel level, so it follows the tone: computed, never stored.
        static var fill: Color { Surface.card }
        static let stroke = Surface.strongHairline
        static let textInsetH: CGFloat = 16
        static let textTop: CGFloat = 12
        static let minimumTextHeight: CGFloat = 46
        static let maximumTextHeight: CGFloat = 220

        // MARK: Bar

        static let barHeight: CGFloat = 38
        static let barInsetH: CGFloat = 8
        static let barInsetBottom: CGFloat = 8
        static let controlSide: CGFloat = 30
        static let sendSide: CGFloat = 30
        static let barSpacing: CGFloat = 2
        static let sendGap: CGFloat = 4
        static let chipGap: CGFloat = 8
        static let barFont = Font.system(size: 12.5, weight: .medium)
        static let barIcon = Font.system(size: 13)
        static let plusIcon = Font.system(size: 17)
        static let chevron = Typography.chevron
        static let modeColor = Text.secondary
        static let modelColor = Text.primary
        static let effortColor = Text.tertiary
        static let sendFill = Text.primary
        static let sendIcon = Font.system(size: 15, weight: .semibold)
        static let stopGlyph: CGFloat = 10
        static let stopRadius: CGFloat = 2.5

        // MARK: Queue strip

        static let queueRowHeight: CGFloat = 30
        static let queueRadius: CGFloat = Radius.lg + 2
        static let queueFill = overlay(dark: 0.05, light: 0.045).color
        static let queueEditFill = Accent.base.opacity(0.16)
        static let queueMargin: CGFloat = 12
        static let queueRowSpacing: CGFloat = 2
        static let queueMaxVisible = 4
        static let queueFont = Font.system(size: 12)
        static let queueIcon: CGFloat = 22

        // MARK: Attachments

        static let attachmentHeight: CGFloat = 30
        static let attachmentRadius: CGFloat = Radius.sm + 1
        static let attachmentFill = overlay(dark: 0.07, light: 0.06).color
        static let thumbnail = CGSize(width: 30, height: 22)
        static let attachmentSpacing: CGFloat = 8
        static let attachmentFont = Font.system(size: 11.5, weight: .medium)
        static let attachmentMaxLabelWidth: CGFloat = 180

        // MARK: Menus

        static let menuRowHeight: CGFloat = 30
        static let menuMaxRows = 8
        static let menuRadius: CGFloat = Radius.xl - 2
        static let menuInset: CGFloat = Highlight.inset
        static let menuGap: CGFloat = 8
        static let menuCommandFont = Font.system(size: 12.5, weight: .medium, design: .monospaced)
        static let menuTitleFont = Font.system(size: 12.5, weight: .medium)
        static let menuDetailFont = Font.system(size: 12)
        static let menuHintFont = Font.system(size: 11)
        static let menuNameColumn: CGFloat = 150
        static let menuFooterHeight: CGFloat = 28

        // MARK: Ring popover

        static let ringPopoverWidth: CGFloat = 260
        static let ringHoverDelay: TimeInterval = 0.15
        static let ringBarHeight: CGFloat = 6
        static let ringBarRadius: CGFloat = 3
        /// The ring turns red above this share of the window (CHAT-SPEC → The bar).
        static let ringRed = 0.9

        // MARK: Modes (D-63)

        /// The colour of a permission mode: soft tones that rise from cool to warm as the mode lets Claude do more, so the
        /// bar says how much a session may do without being loud. Each is at least 4.5:1 on a popover and on the card
        /// (`LoomThemeTests`). A mode of the CLI that Loom does not offer, and a mode not known yet, take the neutral tone.
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

        // MARK: Pickers (the mode list, the model list and the effort slider; D-63, after Codex's)

        static let pickWidth: CGFloat = 272
        static let pickInset: CGFloat = Highlight.inset
        static let pickRowRadius: CGFloat = Highlight.radius
        static let pickRowPaddingH: CGFloat = 12
        static let pickRowPaddingV: CGFloat = 8
        static let pickRowSpacing: CGFloat = 1
        static let pickIconSide: CGFloat = 18
        static let pickHeaderHeight: CGFloat = 30
        static let pickMaxHeight: CGFloat = 300
        static let pickHeaderFont = Font.system(size: 12.5)
        static let pickTitleFont = Font.system(size: 13, weight: .medium)
        static let pickSubtitleFont = Font.system(size: 11.5)
        static let pickCheck = Font.system(size: 11.5, weight: .semibold)
        static let pickIcon = Font.system(size: 13)
        static let pickDivider = Surface.hairline
        /// The chip's two parts take a rounded fill under the pointer.
        static let chipRadius: CGFloat = Radius.md

        static let effortWidth: CGFloat = 296
        static let effortPadding: CGFloat = 16
        static let effortSpacing: CGFloat = 8
        static let effortTrackHeight: CGFloat = 30
        static let effortThumb: CGFloat = 26
        static let effortDot: CGFloat = 4
        static let effortTrackInset: CGFloat = 3
        static let effortTrackTone = overlay(dark: Surface.controlOpacity + 0.02, light: Surface.controlLightOpacity + 0.02)
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
        static let effortNameFont = Font.system(size: 15, weight: .medium)
        static let effortNameColor = OnPopover.accent
        static let effortModelFont = Font.system(size: 12)
        static let effortResetIcon = Font.system(size: 13, weight: .medium)
        static let effortResetSide: CGFloat = 26

        // MARK: Compact (a card waits above the composer)

        /// While a card waits the composer shrinks to one line and a bar, so the card's buttons stay on screen in a short
        /// window (the V18 checkpoint's 780x500 finding).
        static let compactTextHeight: CGFloat = 28
        static let compactMaximumTextHeight: CGFloat = 84
        static let compactTextTop: CGFloat = 8
        static let compactDockBottomInset: CGFloat = 8
        static let compactDockTopInset: CGFloat = 0
        static let compactBarHeight: CGFloat = 34

        // MARK: Notices and hints

        static let noticeFont = Font.system(size: 11.5)
        /// The line above the field that says its text goes with the card above (V18).
        static let cardNoteSize: CGFloat = 11.5
        static let cardNoteFont = Font.system(size: cardNoteSize, weight: .medium)
        static let cardNoteIcon = Font.system(size: 10.5, weight: .semibold)
        static let cardNoteColor = Status.attention
        static let cardNoteTop: CGFloat = 12
        static let noticeInset: CGFloat = 16
        static let hintFont = Font.system(size: 10.5)
    }
}
