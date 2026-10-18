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
        static let dockBottomInset: CGFloat = 14
        static let dockTopInset: CGFloat = 6
        static let radius: CGFloat = Radius.xxl
        static let fill = Surface.card
        static let stroke = Surface.strongHairline
        static let textInsetH: CGFloat = 18
        static let textTop: CGFloat = 10
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
        static let chipGap: CGFloat = 6
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
        static let queueFill = Color.white.opacity(0.05)
        static let queueEditFill = Accent.base.opacity(0.16)
        static let queueMargin: CGFloat = 10
        static let queueRowSpacing: CGFloat = 2
        static let queueMaxVisible = 4
        static let queueFont = Font.system(size: 12)
        static let queueIcon: CGFloat = 22

        // MARK: Attachments

        static let attachmentHeight: CGFloat = 30
        static let attachmentRadius: CGFloat = Radius.sm + 1
        static let attachmentFill = Color.white.opacity(0.07)
        static let thumbnail = CGSize(width: 30, height: 22)
        static let attachmentSpacing: CGFloat = 6
        static let attachmentFont = Font.system(size: 11.5, weight: .medium)
        static let attachmentMaxLabelWidth: CGFloat = 180

        // MARK: Menus

        static let menuRowHeight: CGFloat = 30
        static let menuMaxRows = 8
        static let menuRadius: CGFloat = Radius.xl - 2
        static let menuInset: CGFloat = 6
        static let menuGap: CGFloat = 8
        static let menuSelectedFill = Accent.base.opacity(0.16)
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
            static let askRGB = RGB(hex: 0x7FC8D8)
            static let askBeforeEditsRGB = Accent.highRGB
            static let acceptEditsRGB = RGB(hex: 0x86D3A4)
            static let autoRGB = RGB(hex: 0xD9C677)
            static let fullAccessRGB = RGB(hex: 0xEE9A6E)
            static let planRGB = RGB(hex: 0xB9A0E6)
            static let neutralRGB = Text.secondaryRGB

            /// `raw` is the mode as Loom stores it (`ClaudePermissionMode.rawValue`).
            static func rgb(forRaw raw: String?) -> RGB {
                switch raw.flatMap(ClaudePermissionMode.init(rawValue:)) {
                case .ask?: askRGB
                case .askBeforeEdits?: askBeforeEditsRGB
                case .acceptEdits?: acceptEditsRGB
                case .auto?: autoRGB
                case .fullAccess?: fullAccessRGB
                case .plan?: planRGB
                case nil: neutralRGB
                }
            }

            static func color(forRaw raw: String?) -> Color { rgb(forRaw: raw).color }
        }

        // MARK: Pickers (the mode list, the model list and the effort slider; D-63, after Codex's)

        static let pickWidth: CGFloat = 272
        static let pickInset: CGFloat = 6
        static let pickRowRadius: CGFloat = Radius.lg
        static let pickRowPaddingH: CGFloat = 10
        static let pickRowPaddingV: CGFloat = 7
        static let pickRowSpacing: CGFloat = 1
        static let pickIconSide: CGFloat = 18
        static let pickHeaderHeight: CGFloat = 30
        static let pickMaxHeight: CGFloat = 300
        static let pickHeaderFont = Font.system(size: 12.5)
        static let pickTitleFont = Font.system(size: 13, weight: .medium)
        static let pickSubtitleFont = Font.system(size: 11.5)
        static let pickCheck = Font.system(size: 11.5, weight: .semibold)
        static let pickIcon = Font.system(size: 13)
        static let pickHoverFill = Color.white.opacity(Surface.controlHoverOpacity)
        static let pickDivider = Surface.hairline
        /// The chip's two parts take a rounded fill under the pointer.
        static let chipRadius: CGFloat = Radius.md
        static let chipHoverFill = Color.white.opacity(Surface.controlOpacity)

        static let effortWidth: CGFloat = 296
        static let effortPadding: CGFloat = 14
        static let effortSpacing: CGFloat = 8
        static let effortTrackHeight: CGFloat = 30
        static let effortThumb: CGFloat = 26
        static let effortDot: CGFloat = 4
        static let effortTrackInset: CGFloat = 3
        static let effortTrack = Color.white.opacity(Surface.controlOpacity + 0.02)
        static let effortFill = Accent.base
        static let effortThumbFill = Color.white
        static let effortDotOnFill = Color.white.opacity(0.55)
        static let effortDotOffFill = Color.white.opacity(0.22)
        static let effortThumbShadow = Color.black.opacity(0.35)
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
        static let compactTextTop: CGFloat = 6
        static let compactDockBottomInset: CGFloat = 8
        static let compactDockTopInset: CGFloat = 0
        static let compactBarHeight: CGFloat = 34

        // MARK: Notices and hints

        static let noticeFont = Font.system(size: 11.5)
        /// The line above the field that says its text goes with the card above (V18).
        static let cardNoteFont = Font.system(size: 11.5, weight: .medium)
        static let cardNoteIcon = Font.system(size: 10.5, weight: .semibold)
        static let cardNoteColor = Status.attention
        static let cardNoteTop: CGFloat = 10
        static let noticeInset: CGFloat = 18
        static let hintFont = Font.system(size: 10.5)
    }
}
