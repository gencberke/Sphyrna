import AppKit
import LoomTerminal
import SwiftUI

/// The one source of visual values for `LoomCatalogUI` (design/DESIGN.md §3).
/// Views use these tokens and no color literal, `.system(size:)` or literal
/// corner radius of their own; `scripts/check-theme-literals.sh` enforces it.
/// Terminal colors stay in `LoomTerminal.TerminalTheme` (that target sits
/// below this one); `Surface.panel` reads from it.
enum LoomTheme {
    /// A color kept as data so tests can compute contrast ratios; `color` is the
    /// SwiftUI value views use.
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }

        /// WCAG 2.x relative luminance.
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG contrast ratio, 1...21.
        func contrast(with other: RGB) -> Double {
            let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
            return (high + 0.05) / (low + 0.05)
        }

        /// This color drawn at `opacity` over an opaque backdrop.
        func composited(over backdrop: RGB, opacity: Double) -> RGB {
            RGB(red: red * opacity + backdrop.red * (1 - opacity),
                green: green * opacity + backdrop.green * (1 - opacity),
                blue: blue * opacity + backdrop.blue * (1 - opacity))
        }
    }

    // MARK: Color

    enum Surface {
        static let sidebarRGB = RGB(red: 0.043, green: 0.055, blue: 0.086)
        static let sidebar = sidebarRGB.color
        /// The opaque color behind the detail panel (the sidebar tone).
        static let backdrop = sidebar
        /// The dark tone dominates the sidebar; the material only adds a slight
        /// depth (a lower value let a blue wallpaper glow through).
        static let sidebarTintOpacity = 0.86
        /// The panel and the terminal share one background (TerminalTheme is the source).
        static let panelNS = TerminalTheme.background
        static let panel = Color(nsColor: panelNS)
        static var panelRGB: RGB {
            let c = panelNS.usingColorSpace(.sRGB) ?? panelNS
            return RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }

        // White overlays on the sidebar and the panel.
        static let hairlineOpacity = 0.10
        static let selectedOpacity = 0.07
        static let controlOpacity = 0.06
        static let controlHoverOpacity = 0.09
        static let controlPressedOpacity = 0.14
        static let hairline = Color.white.opacity(hairlineOpacity)
        static let selected = Color.white.opacity(selectedOpacity)
        static let control = Color.white.opacity(controlOpacity)
        static let controlSelected = selected
        static let controlHover = Color.white.opacity(controlHoverOpacity)
        static let controlPressed = Color.white.opacity(controlPressedOpacity)
        static let focusRing = Accent.base

        /// Hairlines and the selected stroke are white at 10 %; Increase Contrast raises them to 30 %.
        static let hairlineIncreasedOpacity = 0.30
        static func hairlineOpacity(for contrast: ColorSchemeContrast) -> Double {
            contrast == .increased ? hairlineIncreasedOpacity : hairlineOpacity
        }
        /// The hairline as a style that resolves against the environment's contrast setting.
        static let hairlineStyle = ContrastStyle(
            standard: Tone(rgb: RGB(red: 1, green: 1, blue: 1), opacity: hairlineOpacity),
            increased: Tone(rgb: RGB(red: 1, green: 1, blue: 1), opacity: hairlineIncreasedOpacity))

        /// One hourly cell of the five-hour activity block: the primary text tone at an
        /// intensity from `activityCellFloor` (no activity) to `activityCellCeiling` (the busiest hour).
        static func activityCell(_ fraction: Double) -> Color {
            let clamped = min(max(fraction, 0), 1)
            return Text.primary.opacity(Opacity.activityCellFloor
                + (Opacity.activityCellCeiling - Opacity.activityCellFloor) * clamped)
        }
    }

    enum Text {
        static let primaryRGB = RGB(red: 0.88, green: 0.86, blue: 0.92)
        static let secondaryRGB = RGB(hex: 0x828799)
        static let primary = primaryRGB.color
        static let secondary = secondaryRGB.color
        /// Placeholders, disabled items and decoration only (about 2.6:1, below AA).
        static let tertiaryRGB = RGB(hex: 0x5A5F70)
        static let tertiary = tertiaryRGB.color
        /// Increase Contrast lifts secondary text toward primary (at least 7:1 on every surface).
        static let secondaryIncreasedRGB = RGB(hex: 0xA9AEBF)
        static func secondaryRGB(for contrast: ColorSchemeContrast) -> RGB {
            contrast == .increased ? secondaryIncreasedRGB : secondaryRGB
        }
        /// Secondary text as a style that resolves against the environment's contrast setting.
        static let secondaryStyle = ContrastStyle(
            standard: Tone(rgb: secondaryRGB, opacity: 1), increased: Tone(rgb: secondaryIncreasedRGB, opacity: 1))
    }

    /// The one brand color (the fleece of the mark). Fills carry dark text, never light text.
    enum Accent {
        static let baseRGB = RGB(hex: 0x8791CF)
        static let base = baseRGB.color
        /// Text and symbols on an accent fill (6.4:1; light text there is 2.2 to 3.0:1).
        static let onAccentRGB = Surface.sidebarRGB
        static let onAccent = onAccentRGB.color
    }

    enum Status {
        static let attentionRGB = RGB(red: 1.0, green: 0.62, blue: 0.04)
        static let unviewedRGB = RGB(red: 0.36, green: 0.55, blue: 1.0)
        static let failureRGB = RGB(red: 0.95, green: 0.38, blue: 0.36)
        static let attention = attentionRGB.color
        static let unviewed = unviewedRGB.color
        static let failure = failureRGB.color
        /// The working chase is drawn in the primary text color.
        static let working = Text.primary
        static let workingNS = NSColor(Text.primary)
        /// Fill opacity of a callout tinted with a status color.
        static let tintOpacity = 0.10
    }

    enum Opacity {
        static let disabled = 0.4
        static let accentPressed = 0.8
        static let accentTint = 0.14
        static let accentTintPressed = 0.24
        /// A pressed row button (a project header).
        static let rowPressed = 0.7
        static let activityCellFloor = 0.10
        static let activityCellCeiling = 0.90
    }

    // MARK: Shape

    enum Radius {
        static let panel: CGFloat = 10
        static let card: CGFloat = 10
        static let control: CGFloat = 6
        static let search: CGFloat = 8
        static let callout: CGFloat = 8
        /// Usage bars and activity cells.
        static let bar: CGFloat = 4
        static let barSlim: CGFloat = 2
    }

    enum Line {
        static let hairline: CGFloat = 1
        static let focusRing: CGFloat = 1.5
        /// The focus ring is thicker under Increase Contrast.
        static let focusRingIncreased: CGFloat = 2.5
        static func focusRing(for contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? focusRingIncreased : focusRing
        }
        static let indicatorRing: CGFloat = 1.5
    }

    // MARK: Type

    /// Fixed-size fonts by role (the `Type` namespace of the identity proposal;
    /// `Type` itself cannot be a nested type name in Swift).
    enum Typography {
        static let caption = Font.system(size: 11)
        static let statusLabel = Font.system(size: 11, weight: .medium)
        static let dayHeading = Font.system(size: 11, weight: .semibold)
        static let small = Font.system(size: 12)
        static let smallMedium = Font.system(size: 12, weight: .medium)
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let footerIcon = Font.system(size: 14)
        static let title = Font.system(size: 15, weight: .semibold)
        /// The Usage headline figure.
        static let display = Font.system(size: 32, weight: .semibold)
        /// Paths in Settings.
        static let mono = Font.system(size: 12, design: .monospaced)
        /// A `Message` title and the conversation record's title.
        static let heading = Font.system(size: 20, weight: .semibold)
        static let heroSymbol = Font.system(size: 28)
        static let chevron = Font.system(size: 9, weight: .semibold)
        /// The pin glyph in a pinned conversation's card (second row).
        static let pinGlyph = Font.system(size: 10)

        static func cardTitle(selected: Bool) -> Font { .system(size: 13, weight: selected ? .semibold : .medium) }
    }

    // MARK: Space

    enum Space {
        // Sidebar header, search, footer.
        static let headerSpacing: CGFloat = 4
        static let headerInset: CGFloat = 10
        static let searchInset: CGFloat = 12
        static let searchBottom: CGFloat = 8
        static let searchSpacing: CGFloat = 6
        static let searchPadding: CGFloat = 10
        static let footerInset: CGFloat = 10
        static let footerSpacing: CGFloat = 8
        static let chipInset: CGFloat = 8
        // List.
        static let listInset: CGFloat = 6
        static let listBottom: CGFloat = 8
        static let sectionInset: CGFloat = 12
        static let sectionTop: CGFloat = 14
        static let sectionBottom: CGFloat = 4
        static let sectionSpacing: CGFloat = 8
        /// How far a focused row's ring sits outside its content.
        static let rowFocusOutset: CGFloat = 3
        static let emptyNoteInset: CGFloat = 14
        static let emptyNoteVertical: CGFloat = 6
        static let loadingPadding: CGFloat = 8
        static let hintSpacing: CGFloat = 6
        static let hintTop: CGFloat = 40
        // Cards.
        static let cardGap: CGFloat = 2
        static let cardH: CGFloat = 10
        static let cardV: CGFloat = 8
        static let cardSpacing: CGFloat = 8
        static let cardLineSpacing: CGFloat = 3
        static let cardRowSpacing: CGFloat = 6
        static let cardIndicatorTop: CGFloat = 1
        // Detail panel.
        static let panelInset: CGFloat = 8
        static let detailInset: CGFloat = 14
        static let detailSpacing: CGFloat = 8
        static let detailMinSpacer: CGFloat = 8
        static let bannerSpacing: CGFloat = 6
        static let bannerBottom: CGFloat = 8
        static let bannerRowSpacing: CGFloat = 8
        static let emptyStateSpacing: CGFloat = 12
        static let messageSpacing: CGFloat = 8
        static let messagePadding: CGFloat = 24
        static let detailPadding: CGFloat = 24
        static let detailSectionSpacing: CGFloat = 18
        static let detailTitleSpacing: CGFloat = 12
        static let detailLineSpacing: CGFloat = 3
        static let factColumnSpacing: CGFloat = 16
        static let factRowSpacing: CGFloat = 8
        static let actionsSpacing: CGFloat = 10
        // Requests and notices.
        static let requestListSpacing: CGFloat = 6
        static let requestSpacing: CGFloat = 10
        static let requestLineSpacing: CGFloat = 3
        static let requestPadding: CGFloat = 10
        static let noticeSpacing: CGFloat = 10
        static let noticeLineSpacing: CGFloat = 3
        static let noticePadding: CGFloat = 12
        // Accent buttons.
        static let buttonH: CGFloat = 12
        static let buttonV: CGFloat = 3
        // Sheet.
        static let sheetSpacing: CGFloat = 12
        static let sheetPadding: CGFloat = 20
        // Terminal host.
        static let terminalInset: CGFloat = 6
        // Settings.
        static let settingsInset: CGFloat = 32
        static let settingsFooterInset: CGFloat = 24
        static let settingsSectionGap: CGFloat = 20
        static let settingsRowInset: CGFloat = 16
        static let settingsRowV: CGFloat = 10
        static let settingsSegmentH: CGFloat = 12
        static let settingsTrack: CGFloat = 2
        static let usageColumnGap: CGFloat = 32
        static let usageTotalsGap: CGFloat = 16
        static let usageNoteTop: CGFloat = 6
        static let usageBarGap: CGFloat = 16
        static let usageBarGapSlim: CGFloat = 2
        static let usageCellGap: CGFloat = 4
        static let usageCellLabelTop: CGFloat = 4
        static let usageShareGap: CGFloat = 8
        static let aboutHeadTop: CGFloat = 28
        static let aboutHeadBottom: CGFloat = 24
        static let aboutHeadSpacing: CGFloat = 4
    }

    // MARK: Layout

    enum Layout {
        // Header geometry. The unified toolbar centers the native window buttons
        // 26 pt below the window top (x 19...79), which is also the center of the
        // 52 pt sidebar header row and of the detail header row.
        static let headerHeight: CGFloat = 52
        static let detailRowHeight: CGFloat = 36
        /// Sidebar header: space before the toggle so it clears the native buttons.
        static let sidebarButtonsGap: CGFloat = 76
        /// Detail header (collapsed sidebar): space reserved for the native buttons.
        static let detailButtonsGap: CGFloat = 66
        static let searchHeight: CGFloat = 30
        static let footerHeight: CGFloat = 38
        static let chromeButton = CGSize(width: 26, height: 24)
        static let footerButton = CGSize(width: 28, height: 26)
        static let projectMenuButton = CGSize(width: 22, height: 20)
        /// Every control answers a click within at least this area, whatever it draws.
        static let minimumHitTarget = CGSize(width: 24, height: 24)
        static let providerIconCard: CGFloat = 14
        static let providerIconHeader: CGFloat = 16
        static let providerIconDefault: CGFloat = 15
        static let providerIconDetail: CGFloat = 34
        static let messageMaxWidth: CGFloat = 420
        static let detailMaxWidth: CGFloat = 640
        static let sheetWidth: CGFloat = 420
        /// The Settings window keeps one size for every section.
        static let settingsWidth: CGFloat = 680
        static let settingsHeight: CGFloat = 520
        static let settingsTopHeight: CGFloat = 52
        static let settingsFooterHeight: CGFloat = 32
        static let settingsSegmentHeight: CGFloat = 24
        static let settingsRowMinHeight: CGFloat = 44
        static let usageControlHeight: CGFloat = 28
        static let usageBarsHeight: CGFloat = 72
        static let usageCellHeight: CGFloat = 28
        static let usageHeaderRowHeight: CGFloat = 24
        static let usageRowHeight: CGFloat = 28
        static let usageShareBar = CGSize(width: 48, height: 3)
        static let usageEmptyHeight: CGFloat = 360
        static let aboutMark: CGFloat = 64
        /// Widest per-row result text in Settings → Conversations.
        static let cleanupResultMaxWidth: CGFloat = 260
        static let footerChipHeight: CGFloat = 24
        // Indicators.
        static let indicatorSlot = CGSize(width: 12, height: 16)
        static let chaseSide: CGFloat = 12
        static let chaseInset: CGFloat = 1.6
        static let chaseDotRadius: CGFloat = 1.45
        static let pip: CGFloat = 8
        static let projectDot: CGFloat = 8
    }

    // MARK: Tab strip

    /// The conversation tab strip (design/run1-surfaces-preview.html, surface 3).
    enum TabStrip {
        static let height: CGFloat = 32
        static let tabHeight: CGFloat = 24
        static let minTabWidth: CGFloat = 112
        static let maxTabWidth: CGFloat = 200
        static let gap: CGFloat = 4
        static let inset: CGFloat = 8
        /// Space inside a tab before the indicator, and after the title when no close button is shown.
        static let tabInset: CGFloat = 8
        /// Space between a tab's indicator and title.
        static let tabSpacing: CGFloat = 6
        /// The selected tab's trailing padding around its reserved close slot.
        static let selectedTrailing: CGFloat = 4
        static let close: CGFloat = 16
        /// The hover close button sits this far from the top and trailing edge of an unselected tab.
        static let hoverCloseInset: CGFloat = 3
        static let overflowWidth: CGFloat = 28
        /// Trailing fade of the scrolling list.
        static let fadeWidth: CGFloat = 28
        /// The chevron's attention dot.
        static let overflowDot: CGFloat = 6
        static let overflowDotInset: CGFloat = 3
        static let menuMinWidth: CGFloat = 220
    }

    // MARK: Motion

    enum Motion {
        /// Stepped, low-rate animation (not display-rate).
        static let chaseFramesPerSecond = 10.0
        static let chaseDotCount = 8
        /// Opacity by distance behind the head.
        static let chaseTrail: [Double] = [1, 0.8, 0.55, 0.35]
        static let chaseRest = 0.16

        /// One-shot transitions (design/DESIGN.md §6): ease-out, at most 200 ms.
        static let selectionDuration = 0.12
        static let bannerDuration = 0.20

        enum Transition { case selection, banner }

        static func duration(of transition: Transition) -> Double {
            switch transition {
            case .selection: selectionDuration
            case .banner: bannerDuration
            }
        }

        /// The animation of a transition, or nil (instant) under Reduce Motion. The working chase
        /// is persistent motion and is not gated here.
        static func animation(_ transition: Transition, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: duration(of: transition))
        }
    }

    // MARK: Contrast

    /// A color at an opacity, kept as data so tests can read it.
    struct Tone: Equatable, Sendable {
        let rgb: RGB
        let opacity: Double
        var color: Color { rgb.color.opacity(opacity) }
    }

    /// A tone with a standard and an Increase Contrast value. As a `ShapeStyle` it resolves
    /// against `colorSchemeContrast`, so a view needs no environment property of its own.
    struct ContrastStyle: ShapeStyle, Equatable, Sendable {
        let standard: Tone
        let increased: Tone

        func tone(for contrast: ColorSchemeContrast) -> Tone { contrast == .increased ? increased : standard }

        func resolve(in environment: EnvironmentValues) -> Color {
            tone(for: environment.colorSchemeContrast).color
        }
    }
}

extension LoomTheme.RGB {
    /// An sRGB color from 0xRRGGBB, the form the design documents use.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
