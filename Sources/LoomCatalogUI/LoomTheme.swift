import AppKit
import LoomCore
import LoomTerminal
import SwiftUI

/// The one source of visual values for `LoomCatalogUI` (design/DESIGN.md §3). Night Fleece 2: today's
/// tokens are here, the tokens added for v2 are in `LoomTheme+Surfaces`, `+Palette` and `+Shape`.
/// Views use these tokens and no color literal, `.system(size:)` or literal
/// corner radius of their own; `scripts/check-theme-literals.sh` enforces it for every file but `LoomTheme*.swift`.
/// Terminal colors stay in `LoomTerminal.TerminalTheme` (that target sits
/// below this one); the terminal face's background is the dark tone's panel (`Surface.levels`).
/// Colour tokens are appearance-aware (D-63): see `LoomTheme+Appearance.swift`.
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
        /// The sidebar tone (a dark navy; in Light a warm sand), the colour behind the detail panel, and the tint over
        /// the sidebar material.
        static let sidebarPair = Adaptive(dark: RGB(red: 0.043, green: 0.055, blue: 0.086), light: RGB(hex: 0xEFE9DF))
        static let sidebarRGB = sidebarPair.dark
        static let sidebarLightRGB = sidebarPair.light
        static let sidebar = sidebarPair.color
        /// The opaque color behind the detail panel (the sidebar tone).
        static let backdrop = sidebar
        /// The dark tone over the sidebar material: low enough that the glass reads (the user's
        /// choice after the Liquid Glass trial, 12 Oct 2026; 0.86 before looked matte).
        static let sidebarTintOpacity = 0.6
        /// The panel of the current tone: the terminal's background in Dark, its light counterpart in Light
        /// (the Chat face, Home, a project page, Settings). Reading it in a view body subscribes the view to the tone.
        static var panelNS: NSColor { current.panelNS }
        static var panel: Color { current.panel }
        /// Today's panel (Night fleece, Dark), the default tone's terminal background.
        static var panelRGB: RGB { terminalRGB }

        // Overlays on the sidebar and the panel: white in Dark, the warm ink in Light.
        static let hairlineOpacity = 0.08
        static let selectedOpacity = 0.07
        static let controlOpacity = 0.06
        static let controlHoverOpacity = 0.09
        static let controlPressedOpacity = 0.14
        /// The same fills in Light, where an ink overlay of the dark theme's opacity would read heavier.
        static let hairlineLightOpacity = 0.10
        static let selectedLightOpacity = 0.07
        static let controlLightOpacity = 0.05
        static let controlHoverLightOpacity = 0.08
        static let controlPressedLightOpacity = 0.12
        static let hairlineTone = overlay(dark: hairlineOpacity, light: hairlineLightOpacity)
        static let selectedTone = overlay(dark: selectedOpacity, light: selectedLightOpacity)
        static let controlTone = overlay(dark: controlOpacity, light: controlLightOpacity)
        static let controlHoverTone = overlay(dark: controlHoverOpacity, light: controlHoverLightOpacity)
        static let controlPressedTone = overlay(dark: controlPressedOpacity, light: controlPressedLightOpacity)
        static let hairline = hairlineTone.color
        static let selected = selectedTone.color
        static let control = controlTone.color
        static let controlSelected = selected
        static let controlHover = controlHoverTone.color
        static let controlPressed = controlPressedTone.color
        /// The footer usage chip's meter track: white at 10 % (ink at 10 % in Light).
        static let chipMeterTrackOpacity = 0.10
        static let chipMeterTrackTone = overlay(dark: chipMeterTrackOpacity, light: 0.10)
        static let chipMeterTrack = chipMeterTrackTone.color
        static let focusRing = Accent.base

        /// Hairlines and the selected stroke are white at 8 %; Increase Contrast raises them to 30 % (ink at 45 % in Light).
        static let hairlineIncreasedOpacity = 0.30
        static let hairlineIncreasedLightOpacity = 0.45
        static func hairlineOpacity(for contrast: ColorSchemeContrast) -> Double {
            contrast == .increased ? hairlineIncreasedOpacity : hairlineOpacity
        }
        /// The hairline as a style that resolves against the environment's contrast setting.
        static let hairlineStyle = ContrastStyle(
            standard: Tone(rgb: whiteRGB, opacity: hairlineOpacity),
            increased: Tone(rgb: whiteRGB, opacity: hairlineIncreasedOpacity),
            lightStandard: Tone(rgb: inkRGB, opacity: hairlineLightOpacity),
            lightIncreased: Tone(rgb: inkRGB, opacity: hairlineIncreasedLightOpacity))

        /// One hourly cell of the five-hour activity block: the primary text tone at an
        /// intensity from `activityCellFloor` (no activity) to `activityCellCeiling` (the busiest hour).
        static func activityCell(_ fraction: Double) -> Color {
            let clamped = min(max(fraction, 0), 1)
            return Text.primary.opacity(Opacity.activityCellFloor
                + (Opacity.activityCellCeiling - Opacity.activityCellFloor) * clamped)
        }
    }

    enum Text {
        static let primaryPair = Adaptive(dark: RGB(hex: 0xECE8F4), light: inkRGB)
        static let secondaryPair = Adaptive(dark: RGB(hex: 0x9A9EB0), light: RGB(hex: 0x5E5853))
        static let primaryRGB = primaryPair.dark
        static let secondaryRGB = secondaryPair.dark
        static let primary = primaryPair.color
        static let secondary = secondaryPair.color
        /// Placeholders, disabled items and decoration only (2.4 to 3.4:1, below AA); not on a popover (`OnPopover`).
        static let tertiaryPair = Adaptive(dark: RGB(hex: 0x636779), light: RGB(hex: 0x8C857E))
        static let tertiaryRGB = tertiaryPair.dark
        static let tertiary = tertiaryPair.color
        /// Increase Contrast lifts secondary text toward primary (at least 7:1 on every surface).
        static let secondaryIncreasedPair = Adaptive(dark: RGB(hex: 0xBCC0D0), light: RGB(hex: 0x47423E))
        static let secondaryIncreasedRGB = secondaryIncreasedPair.dark
        static let secondaryIncreased = secondaryIncreasedPair.color
        static func secondaryRGB(for contrast: ColorSchemeContrast) -> RGB {
            contrast == .increased ? secondaryIncreasedRGB : secondaryRGB
        }
        /// Secondary text as a style that resolves against the environment's contrast setting.
        static let secondaryStyle = ContrastStyle(
            standard: Tone(rgb: secondaryRGB, opacity: 1), increased: Tone(rgb: secondaryIncreasedRGB, opacity: 1),
            lightStandard: Tone(rgb: secondaryPair.light, opacity: 1),
            lightIncreased: Tone(rgb: secondaryIncreasedPair.light, opacity: 1))
        /// Secondary text and the close glyph on a tab washed with a project tone (at least 4.5:1 on a
        /// resting tab, 3:1 for the glyph on the open tab). Before Night Fleece 2 plain secondary fell
        /// short there and this was a lifted tone; the lifted secondary of Night Fleece 2 holds it, so the
        /// name stays for the call sites and the value is secondary.
        static let secondaryOnTintPair = secondaryPair
        static let secondaryOnTintRGB = secondaryOnTintPair.dark
        static let secondaryOnTint = secondaryOnTintPair.color
        /// `secondaryOnTint` as a style: Increase Contrast takes the lifted secondary of that tier.
        static let secondaryOnTintStyle = secondaryStyle
        /// Secondary text on a Usage card (the 6 % control tone over the panel): 5.4:1 in secondary.
        static let secondaryOnCardRGB = secondaryOnTintRGB
        static let secondaryOnCardStyle = secondaryOnTintStyle
    }

    /// The one brand color (the fleece of the mark). Fills carry dark text, never light text.
    enum Accent {
        /// In Light the accent is a deeper step of the same hue: the dark theme's periwinkle is 2.9:1 on a light panel.
        static let basePair = Adaptive(dark: RGB(hex: 0x8791CF), light: RGB(hex: 0x4B56A8))
        static let baseRGB = basePair.dark
        static let base = basePair.color
        /// Text and symbols on an accent fill (6.4:1; light text there is 2.2 to 3.0:1). In Light the fill is deep
        /// and the text a warm paper white.
        static let onAccentPair = Adaptive(dark: Surface.sidebarRGB, light: RGB(hex: 0xFBF8F2))
        static let onAccentRGB = onAccentPair.dark
        static let onAccent = onAccentPair.color
    }

    enum Status {
        /// The three status hues, deeper in Light (the dark theme's are 2.2 to 3.0:1 on a light panel).
        static let attentionPair = Adaptive(dark: RGB(hex: 0xFF9E0A), light: RGB(hex: 0x974700))
        static let unviewedPair = Adaptive(dark: RGB(hex: 0x5C8CFF), light: RGB(hex: 0x2557CC))
        static let failurePair = Adaptive(dark: RGB(hex: 0xF2615C), light: RGB(hex: 0xB22722))
        static let attentionRGB = attentionPair.dark
        static let unviewedRGB = unviewedPair.dark
        static let failureRGB = failurePair.dark
        static let attention = attentionPair.color
        static let unviewed = unviewedPair.color
        static let failure = failurePair.color
        /// The working chase is drawn in the primary text color.
        static let working = Text.primary
        /// The chase's colour for layers, which cannot see the SwiftUI environment: a dynamic colour the layer's
        /// owner resolves again in `viewDidChangeEffectiveAppearance`.
        static let workingNS = Text.primaryPair.nsColor
        /// Fill opacity of a callout tinted with a status color.
        static let tintOpacity = 0.10
    }

    /// The project colour class (D-48): six soft tones besides the accent and the three status hues. Used
    /// only for the sidebar stripe, the tab tint and the header chip's stripe and wash; never a dot, never in the
    /// indicator slot, never a text colour, never inside the terminal (DESIGN §6). The base colour is
    /// the stripe colour and the tint source; Increase Contrast swaps in a lighter stripe colour.
    /// Each base is at least 3:1 on the sidebar's worst case (`sidebarOverWhite`) and at least 30 degrees
    /// of hue from attention, unviewed, failure and the accent (`LoomThemeTests`).
    enum ProjectColor {
        static func baseRGB(_ tone: ProjectTone) -> RGB {
            switch tone {
            case .rose: RGB(hex: 0xE68EBA)
            case .orchid: RGB(hex: 0xD194E6)
            case .aqua: RGB(hex: 0x80D5DB)
            case .mint: RGB(hex: 0x83D8B0)
            case .sage: RGB(hex: 0x92C186)
            case .lemon: RGB(hex: 0xCCE07B)
            }
        }

        static func increasedRGB(_ tone: ProjectTone) -> RGB {
            switch tone {
            case .rose: RGB(hex: 0xF5B2D4)
            case .orchid: RGB(hex: 0xE6B7F5)
            case .aqua: RGB(hex: 0xA0E9EE)
            case .mint: RGB(hex: 0xA2ECC9)
            case .sage: RGB(hex: 0xAADB9E)
            case .lemon: RGB(hex: 0xE0F29C)
            }
        }

        /// The Light tones: the same six hues, deep enough to hold as a 3 pt stripe on the light sidebar (at least 3:1
        /// on its worst case). Increase Contrast goes deeper still, where the dark theme goes lighter.
        static func lightBaseRGB(_ tone: ProjectTone) -> RGB {
            switch tone {
            case .rose: RGB(hex: 0xB03F78)
            case .orchid: RGB(hex: 0x8A42AC)
            case .aqua: RGB(hex: 0x10747E)
            case .mint: RGB(hex: 0x1A7A51)
            case .sage: RGB(hex: 0x557A28)
            case .lemon: RGB(hex: 0x6F7500)
            }
        }

        static func lightIncreasedRGB(_ tone: ProjectTone) -> RGB {
            switch tone {
            case .rose: RGB(hex: 0x962A60)
            case .orchid: RGB(hex: 0x742E94)
            case .aqua: RGB(hex: 0x0A5C65)
            case .mint: RGB(hex: 0x12603C)
            case .sage: RGB(hex: 0x435F1D)
            case .lemon: RGB(hex: 0x555A00)
            }
        }

        static func baseRGB(_ tone: ProjectTone, _ appearance: Appearance) -> RGB {
            appearance == .dark ? baseRGB(tone) : lightBaseRGB(tone)
        }

        static func increasedRGB(_ tone: ProjectTone, _ appearance: Appearance) -> RGB {
            appearance == .dark ? increasedRGB(tone) : lightIncreasedRGB(tone)
        }

        static func stripeRGB(_ tone: ProjectTone, for contrast: ColorSchemeContrast) -> RGB {
            contrast == .increased ? increasedRGB(tone) : baseRGB(tone)
        }

        /// The stripe colour as a style that resolves against the environment's contrast setting.
        static func stripe(_ tone: ProjectTone) -> ContrastStyle {
            ContrastStyle(standard: Tone(rgb: baseRGB(tone), opacity: 1),
                          increased: Tone(rgb: increasedRGB(tone), opacity: 1),
                          lightStandard: Tone(rgb: lightBaseRGB(tone), opacity: 1),
                          lightIncreased: Tone(rgb: lightIncreasedRGB(tone), opacity: 1))
        }

        /// A wash of the tone, in the appearance's own tone value.
        static func wash(_ tone: ProjectTone, opacity: Double) -> AdaptiveTone {
            AdaptiveTone(dark: Tone(rgb: baseRGB(tone), opacity: opacity),
                         light: Tone(rgb: lightBaseRGB(tone), opacity: opacity))
        }

        // The stripe: 3 pt, 4 pt under Increase Contrast. In the sidebar it sits in the list gutter,
        // `stripeOutset` left of the leading edge of a project header and of each of its cards, so the
        // header and its cards read as one rail; the header's stripe starts below the row's top padding.
        static let stripeWidth: CGFloat = 3
        static let stripeWidthIncreased: CGFloat = 4
        static let stripeRadius: CGFloat = 2
        static let stripeOutset: CGFloat = 4
        static let headerStripeTop: CGFloat = 11
        static let headerStripeBottom: CGFloat = 1
        static func stripeWidth(for contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? stripeWidthIncreased : stripeWidth
        }

        // Tab tint (T5): a wash of the tone on every tab, a step stronger on hover; on the open tab a
        // stronger wash over the selection fill and a 1 pt stroke of the tone. Increase Contrast draws
        // that stroke in the lighter stripe colour at a higher opacity; the washes stay as they are.
        // The open tab's wash is the strongest that keeps primary text at 7:1 on every tone (the
        // preview drew 18 %, which takes Lemon, Aqua, Mint and Sage under it); secondary text on a
        // washed tab is `Text.secondaryOnTint`.
        static let tabWash = 0.10
        static let tabWashHover = 0.15
        static let tabWashOpen = 0.15
        static let tabStrokeOpen = 0.36
        static let tabStrokeOpenIncreased = 0.75

        /// The menu swatch: a rounded square, never a dot.
        static let swatch: CGFloat = 12
        static let swatchRadius: CGFloat = 3
    }

    /// The detail header row (FB3-2, D-53; design/feedback-3-preview.html, "Chosen: A with the branch"):
    /// the title on the left; at fixed places on the right a state pill, a project chip ending with the
    /// branch, a hairline and one control group of a Stop segment and a ⋯ segment.
    enum Header {
        // State pill: a capsule with the indicator and the label. Working sits on a light white wash in
        // primary text, the other neutral states on a fainter one in lifted secondary text; attention,
        // failure and the unviewed finish take a low wash of their own colour and a lighter label of
        // it (the plain status colours are 4.3 to 4.4:1 on their wash for failure and unviewed).
        static let pillHeight: CGFloat = 22
        static let pillLeading: CGFloat = 7
        static let pillTrailing: CGFloat = 9
        static let pillGap: CGFloat = 6
        static let pillWorkingWash = 0.07
        static let pillNeutralWash = 0.05
        static let pillStatusWash = 0.15
        static let attentionLabelRGB = Status.attentionLightRGB
        static let failureLabelRGB = Status.failureLightRGB
        static let unviewedLabelRGB = Status.unviewedLightRGB
        static let attentionLabelPair = Status.attentionLightPair
        static let failureLabelPair = Status.failureLightPair
        static let unviewedLabelPair = Status.unviewedLightPair

        // Project chip: the tone stripe (full height), the project name, a hairline, the branch.
        static let chipHeight: CGFloat = 22
        /// Space after the stripe; a chip without a stripe insets its text `chipInset` instead.
        static let chipStripeGap: CGFloat = 7
        static let chipInset: CGFloat = 8
        static let chipRuleGap: CGFloat = 8
        static let chipRuleAfter: CGFloat = 7
        static let chipRuleHeight: CGFloat = 14
        static let chipBranchGap: CGFloat = 4
        /// The glyph before the branch name.
        static let chipGlyph = Font.system(size: 11)
        /// A longer branch name ends in an ellipsis; 320 pt holds names like "release/2026-10/hotfix-PAY-142".
        static let branchMaxWidth: CGFloat = 320
        /// The neutral chip (no project, None, colours off): a white wash.
        static let chipNeutralWash = 0.07
        static let chipNeutralTone = overlay(dark: chipNeutralWash, light: 0.06)
        static let chipNeutral = chipNeutralTone.color

        // The hairline before the control group, and the group.
        static let ruleHeight: CGFloat = 16
        static let ruleMargin: CGFloat = 2
        static let groupHeight: CGFloat = 24
        static let groupWash = 0.07
        static let groupTone = overlay(dark: groupWash, light: 0.06)
        static let group = groupTone.color
        /// The state pill's washes in Light: working and neutral are ink overlays, a status wash is its own hue.
        static let pillWorkingLightWash = 0.07
        static let pillNeutralLightWash = 0.05
        static let stopGlyph: CGFloat = 8
        static let stopGlyphRadius: CGFloat = 1.5
        static let stopPadding: CGFloat = 10
        static let stopGap: CGFloat = 6
        static let menuSegmentWidth: CGFloat = 28

        // The subagent panel's header (FB4-5): the crumb, and the Session control with its Esc key cap.
        static let crumbGap: CGFloat = 6
        static let crumbGlyph = Font.system(size: 12)
        static let backGap: CGFloat = 6
        static let backLeading: CGFloat = 8
        static let backTrailing: CGFloat = 10
        static let keyCapPadding: CGFloat = 4

        // Narrow rows: the title gives way down to this width, then the branch goes, then the project
        // name shortens (never below the floor).
        static let titleMinWidth: CGFloat = 100
        static let chipFloorWidth: CGFloat = 56
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
        /// A subagent row under a card (D-39): the agent type, and the elapsed time or duration.
        static let subagentType = Font.system(size: 11, weight: .medium)
        static let subagentTime = Font.system(size: 10.5).monospacedDigit()
        static let subagentGlyph = Font.system(size: 10)
        /// The subagent panel's transcript (FB4-5): the terminal's face at the size of the mock.
        static let transcript = Font.system(size: 12, design: .monospaced)
        static let transcriptStrong = Font.system(size: 12, weight: .bold, design: .monospaced)

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
        /// The usage chip: the least space between tokens and limit, and between limit name, meter and percent.
        static let chipSplitGap: CGFloat = 6
        static let chipLimitGap: CGFloat = 5
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
        // Subagents under a card (D-39): a hairline guide under the card's indicator column.
        /// The guide's distance from the list edge (the center of the card's indicator slot).
        static let subagentGuideInset: CGFloat = 15
        /// Space between the guide and the rows, and a row's own leading and trailing padding.
        static let subagentGuidePad: CGFloat = 9
        static let subagentRowLeading: CGFloat = 4
        static let subagentRowTrailing: CGFloat = 10
        static let subagentColumnGap: CGFloat = 6
        static let subagentTextGap: CGFloat = 5
        /// One step of nesting for a subagent a subagent started.
        static let subagentIndent: CGFloat = 10
        static let subagentTreeBottom: CGFloat = 2
        // The subagent panel's transcript (FB4-5).
        static let transcriptInset: CGFloat = 14
        static let transcriptRowGap: CGFloat = 8
        /// The text after the glyph column (⏺, ⎿ and ✻ take this width).
        static let transcriptGlyphColumn: CGFloat = 18
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
        static let usageTotalsGap: CGFloat = 16
        static let usageBarGap: CGFloat = 16
        static let usageBarGapSlim: CGFloat = 2
        static let usageCellGap: CGFloat = 4
        static let usageCellLabelTop: CGFloat = 4
        static let usageShareGap: CGFloat = 8
        /// The Usage page's cards: the gap between them, the padding inside, and the header's gap to the body.
        static let usageCardGap: CGFloat = 12
        static let usageCardTop: CGFloat = 12
        static let usageCardBottom: CGFloat = 14
        static let usageCardHeaderBottom: CGFloat = 10
        /// The period card's two columns, and the local-hours row (rule above and below, gap between its parts).
        static let usageCardColumnGap: CGFloat = 24
        static let usageRuleTop: CGFloat = 12
        static let usageRuleBottom: CGFloat = 10
        static let usageLocalGap: CGFloat = 10
        static let aboutHeadTop: CGFloat = 28
        static let aboutHeadBottom: CGFloat = 24
        static let aboutHeadSpacing: CGFloat = 4
        /// Settings → Theme: the gap between the main pane row's parts.
        static let toneRowGap: CGFloat = 10
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
        /// The request box for an agent's "open a session": its label column, and the scroll area of the full message.
        static let requestLabelWidth: CGFloat = 52
        static let requestMessageMaxHeight: CGFloat = 160
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
        /// A cell of the local-hours row.
        static let usageCellHeight: CGFloat = 12
        static let usageHeaderRowHeight: CGFloat = 24
        static let usageRowHeight: CGFloat = 28
        static let usageShareBar = CGSize(width: 48, height: 3)
        /// A plan limit's used-share bar, and the label and reset columns beside it.
        static let planLimitBarHeight: CGFloat = 4
        static let planLimitLabelWidth: CGFloat = 56
        static let planLimitResetWidth: CGFloat = 132
        static let planLimitUsedWidth: CGFloat = 72
        /// The period card: the total's column, and a token kind's row, label and value.
        static let usageSummaryWidth: CGFloat = 200
        static let usageKindRowHeight: CGFloat = 22
        static let usageKindLabelWidth: CGFloat = 76
        static let usageKindValueWidth: CGFloat = 48
        /// The local-hours row: its label and its total.
        static let usageLocalLabelWidth: CGFloat = 120
        static let usageLocalTotalWidth: CGFloat = 48
        static let usageEmptyHeight: CGFloat = 360
        static let aboutMark: CGFloat = 64
        /// Widest per-row result text in Settings → Conversations.
        static let cleanupResultMaxWidth: CGFloat = 260
        static let footerChipHeight: CGFloat = 24
        /// The usage chip's remaining-share meter (radius `Radius.barSlim`).
        static let chipMeter = CGSize(width: 34, height: 4)
        // Indicators.
        static let indicatorSlot = CGSize(width: 12, height: 16)
        static let chaseSide: CGFloat = 12
        static let chaseInset: CGFloat = 1.6
        static let chaseDotRadius: CGFloat = 1.45
        static let pip: CGFloat = 8
        static let projectDot: CGFloat = 8
        /// A subagent row: its height, and the scale of the working chase in its 12 pt slot.
        static let subagentRowHeight: CGFloat = 22
        static let subagentChaseScale: CGFloat = 0.75
    }

    // MARK: Menu bar item

    /// The menu bar item and its menu (D-49, D-52; design/menu-bar-preview.html). Lengths are points in the
    /// mark's own box (18 pt wide, the 408 x 376 box of `Loom-menubar.svg`), which sits in a square canvas
    /// so the badge may reach past its lower right corner.
    enum MenuBar {
        static let canvas = CGSize(width: 20, height: 20)
        static let markWidth: CGFloat = 18
        /// The mark's place in the canvas.
        static let markOrigin = CGPoint(x: 1, y: 1.7)
        /// The box of the SVG that the mark is fitted to (user space of the 512 x 512 viewBox).
        static let markBox = CGRect(x: 104, y: 136, width: 408, height: 376)
        static var markSize: CGSize { CGSize(width: markWidth, height: markWidth * markBox.height / markBox.width) }

        // The badge slot, lower right. Working: the sidebar chase at 0.8 scale. Needs you: one dot.
        // The mark is cut away around the badge so it sits on the bar. Coordinates are in the mark's box.
        static let chaseScale: CGFloat = 0.8
        static let chaseOrigin = CGPoint(x: 9.4, y: 8)
        static let chaseCutoutCenter = CGPoint(x: 14.2, y: 12.8)
        static let chaseCutoutRadius: CGFloat = 7
        static let dotDiameter: CGFloat = 7
        static let dotCenter = CGPoint(x: 15.2, y: 13.8)
        static let dotCutoutRadius: CGFloat = 5.2
        /// Increase Contrast: a larger dot.
        static let dotDiameterIncreased: CGFloat = 8
        static let dotCenterIncreased = CGPoint(x: 14.8, y: 13.4)
        static let dotCutoutRadiusIncreased: CGFloat = 6

        /// The mark and the chase: white on a dark bar, black on a light one.
        static let markOnDarkRGB = RGB(red: 1, green: 1, blue: 1)
        static let markOnLightRGB = RGB(red: 0, green: 0, blue: 0)
        static func markRGB(darkBar: Bool) -> RGB { darkBar ? markOnDarkRGB : markOnLightRGB }

        /// Increase Contrast lifts the trail's floor from 16 % to 45 %.
        static let chaseTrailIncreased: [Double] = [1, 0.85, 0.7, 0.55]
        static let chaseRestIncreased = 0.45

        /// The dot's colour. A dark bar takes the theme's status values; a light bar darker ones (the
        /// brand hues are 1.4 to 2.2:1 on it); Increase Contrast a stronger hue, lighter on a dark bar
        /// and darker on a light one.
        static func dotRGB(_ attention: ProjectAttention, darkBar: Bool, increasedContrast: Bool) -> RGB {
            switch (darkBar, increasedContrast) {
            case (true, false):
                switch attention {
                case .failure: Status.failureRGB
                case .attention: Status.attentionRGB
                case .unviewed: Status.unviewedRGB
                }
            case (true, true):
                switch attention {
                case .failure: RGB(hex: 0xFF8A86)
                case .attention: RGB(hex: 0xFFB84D)
                case .unviewed: RGB(hex: 0x8FB0FF)
                }
            case (false, false):
                switch attention {
                case .failure: RGB(hex: 0xC9332E)
                case .attention: RGB(hex: 0xB05A00)
                case .unviewed: RGB(hex: 0x2A5FD6)
                }
            case (false, true):
                switch attention {
                case .failure: RGB(hex: 0xA8231F)
                case .attention: RGB(hex: 0x8A4700)
                case .unviewed: RGB(hex: 0x1D4BB5)
                }
            }
        }

        /// The bar behind the evidence pictures (`screenshot-menubar`), and its height.
        static let barHeight: CGFloat = 24
        static let barWidth: CGFloat = 36
        static let barDarkRGB = RGB(hex: 0x2E2A44)
        static let barLightRGB = RGB(hex: 0xE2DDEE)

        // The menu. A session row: a 12 pt glyph, the title, and the project at the right edge.
        static let rowGlyph: CGFloat = 12
        static let rowDot: CGFloat = 8
        static let titleFontSize: CGFloat = 13
        static let projectFontSize: CGFloat = 12
        /// The width of the title and project text together; the project keeps up to `projectMaxWidth`.
        static let rowTextWidth: CGFloat = 264
        static let projectMaxWidth: CGFloat = 112
        static let titleProjectGap: CGFloat = 8
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
        /// The Light values; a style that gives none draws its dark values in both appearances.
        let lightStandard: Tone
        let lightIncreased: Tone

        init(standard: Tone, increased: Tone, lightStandard: Tone? = nil, lightIncreased: Tone? = nil) {
            self.standard = standard
            self.increased = increased
            self.lightStandard = lightStandard ?? standard
            self.lightIncreased = lightIncreased ?? increased
        }

        func tone(for contrast: ColorSchemeContrast, appearance: Appearance = .dark) -> Tone {
            switch (appearance, contrast) {
            case (.dark, .increased): increased
            case (.dark, _): standard
            case (.light, .increased): lightIncreased
            case (.light, _): lightStandard
            }
        }

        func resolve(in environment: EnvironmentValues) -> Color {
            tone(for: environment.colorSchemeContrast, appearance: Appearance(environment.colorScheme)).color
        }
    }
}

extension LoomTheme.RGB {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// An sRGB color from 0xRRGGBB, the form the design documents use.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
