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
