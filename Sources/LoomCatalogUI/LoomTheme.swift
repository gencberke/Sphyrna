import AppKit
import LoomCore
import LoomTerminal
import SwiftUI

/// The one source of visual values for `LoomCatalogUI` (design/DESIGN.md §3). Ink: the colour roles are here and in
/// `LoomTheme+Surfaces` (the greys by tone), `+Palette`, `+Depth`, `+Scale` (Ink's type, radii and heights) and `+Shape`.
/// Views use these tokens and no color literal, `.system(size:)` or literal
/// corner radius of their own; `scripts/check-theme-literals.sh` enforces it for every file but `LoomTheme*.swift`.
/// Terminal colors stay in `LoomTerminal.TerminalTheme` (that target sits
/// below this one); the terminal face's background is the tone's Ink canvas (`Surface.greys`).
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
        /// The tint over the sidebar material in Glass: the canvas at 0.8 over the behind-window material (DESIGN §2 item 2);
        /// Solid is opaque (`sidebarTintOpacity(for:)`). The tint's colour is the tone's canvas (`LoomTheme+Surfaces`).
        static let sidebarTintOpacity = 0.8

        // Lines, white in Ink and the ink `#1E1C1A` in Paper (DESIGN §3 Surfaces, lines and fills).
        static let hairlineOpacity = 0.075
        static let hairlineLightOpacity = 0.085
        /// The edges of controls, fields and chips.
        static let strongHairlineOpacity = 0.115
        static let strongHairlineLightOpacity = 0.13
        /// A hovered edge.
        static let strongerHairlineOpacity = 0.20
        static let strongerHairlineLightOpacity = 0.24
        /// Increase Contrast raises the hairline to 30 % (ink 45 % in Paper).
        static let hairlineIncreasedOpacity = 0.30
        static let hairlineIncreasedLightOpacity = 0.45
        static let hairlineTone = overlay(dark: hairlineOpacity, light: hairlineLightOpacity)
        static let strongHairlineTone = overlay(dark: strongHairlineOpacity, light: strongHairlineLightOpacity)
        static let strongerHairlineTone = overlay(dark: strongerHairlineOpacity, light: strongerHairlineLightOpacity)
        static let hairline = hairlineTone.color
        static let strongHairline = strongHairlineTone.color
        static let strongerHairline = strongerHairlineTone.color

        // The pill's fills: hover, selected, pressed (DESIGN §3 The pill).
        static let hoverOpacity = 0.05
        static let selectedOpacity = 0.08
        static let pressedOpacity = 0.12
        static let hoverLightOpacity = 0.045
        static let selectedLightOpacity = 0.07
        static let pressedLightOpacity = 0.10
        static let hoverTone = overlay(dark: hoverOpacity, light: hoverLightOpacity)
        static let selectedTone = overlay(dark: selectedOpacity, light: selectedLightOpacity)
        static let pressedTone = overlay(dark: pressedOpacity, light: pressedLightOpacity)
        static let hover = hoverTone.color
        static let selected = selectedTone.color
        static let pressed = pressedTone.color

        // The Night Fleece control names, kept as aliases by role: a control's resting fill is the hover fill (Ink's segmented
        // control and chips rest on it), a control under the pointer is the selected fill, a pressed one the pressed fill.
        static let controlOpacity = hoverOpacity
        static let controlLightOpacity = hoverLightOpacity
        static let controlHoverOpacity = selectedOpacity
        static let controlHoverLightOpacity = selectedLightOpacity
        static let controlPressedOpacity = pressedOpacity
        static let controlPressedLightOpacity = pressedLightOpacity
        static let controlTone = hoverTone
        static let controlHoverTone = selectedTone
        static let controlPressedTone = pressedTone
        static let control = controlTone.color
        static let controlSelected = selected
        static let controlHover = controlHoverTone.color
        static let controlPressed = controlPressedTone.color

        /// The grid of an empty canvas: white 3.4 %, ink 6 %.
        static let gridTone = overlay(dark: 0.034, light: 0.06)
        static let grid = gridTone.color
        /// The sharks' colour, drawn at the art's alpha.
        static let artPair = Adaptive(dark: RGB(hex: 0xECECF0), light: RGB(hex: 0x161518))
        static let art = artPair.color
        /// Behind the palette and sheets: black 40 % in Ink, the ink at 22 % in Paper.
        static let scrimTone = AdaptiveTone(dark: Tone(rgb: RGB(red: 0, green: 0, blue: 0), opacity: 0.40),
                                            light: Tone(rgb: inkRGB, opacity: 0.22))
        static let scrim = scrimTone.color
        /// The footer usage chip's meter track and the plan meters' track: the strong hairline.
        static let chipMeterTrackTone = strongHairlineTone
        static let chipMeterTrack = chipMeterTrackTone.color
        static let focusRing = Accent.base

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

    /// The four text tiers (DESIGN §3 Text). Primary 7:1; secondary and tertiary 4.5:1 on the canvas and both raised levels;
    /// faint is for what you never need to read (2.5:1).
    enum Text {
        static let primaryPair = Adaptive(dark: RGB(hex: 0xECECEF), light: RGB(hex: 0x19181B))
        static let secondaryPair = Adaptive(dark: RGB(hex: 0x9E9EA8), light: RGB(hex: 0x5F5D63))
        static let primaryRGB = primaryPair.dark
        static let secondaryRGB = secondaryPair.dark
        static let primary = primaryPair.color
        static let secondary = secondaryPair.color
        /// The quiet voice: labels, meta, key hints, counts and line numbers. On a popover quiet text is secondary.
        static let tertiaryPair = Adaptive(dark: RGB(hex: 0x868690), light: RGB(hex: 0x67656B))
        static let tertiaryRGB = tertiaryPair.dark
        static let tertiary = tertiaryPair.color
        /// Placeholders, disabled items and decorative marks, never text you need.
        static let faintPair = Adaptive(dark: RGB(hex: 0x6B6B75), light: RGB(hex: 0x8E8B91))
        static let faintRGB = faintPair.dark
        static let faint = faintPair.color
        /// Increase Contrast lifts secondary text toward primary (at least 7:1 on every level).
        static let secondaryIncreasedPair = Adaptive(dark: RGB(hex: 0xBDBDC6), light: RGB(hex: 0x47454B))
        static let secondaryIncreasedRGB = secondaryIncreasedPair.dark
        static let secondaryIncreased = secondaryIncreasedPair.color
        /// Under Increase Contrast tertiary takes secondary's normal value.
        static let tertiaryIncreasedPair = secondaryPair
        static func secondaryRGB(for contrast: ColorSchemeContrast) -> RGB {
            contrast == .increased ? secondaryIncreasedRGB : secondaryRGB
        }
        /// Secondary text as a style that resolves against the environment's contrast setting.
        static let secondaryStyle = ContrastStyle(
            standard: Tone(rgb: secondaryRGB, opacity: 1), increased: Tone(rgb: secondaryIncreasedRGB, opacity: 1),
            lightStandard: Tone(rgb: secondaryPair.light, opacity: 1),
            lightIncreased: Tone(rgb: secondaryIncreasedPair.light, opacity: 1))
        /// Tertiary text as a style: Increase Contrast gives it secondary's normal value.
        static let tertiaryStyle = ContrastStyle(
            standard: Tone(rgb: tertiaryRGB, opacity: 1), increased: Tone(rgb: tertiaryIncreasedPair.dark, opacity: 1),
            lightStandard: Tone(rgb: tertiaryPair.light, opacity: 1),
            lightIncreased: Tone(rgb: tertiaryIncreasedPair.light, opacity: 1))
        /// Secondary text and the close glyph on a tab washed with a project tone (at least 4.5:1 on a
        /// resting tab, 3:1 for the glyph on the open tab). The name stays for the call sites; the value is secondary.
        static let secondaryOnTintPair = secondaryPair
        static let secondaryOnTintRGB = secondaryOnTintPair.dark
        static let secondaryOnTint = secondaryOnTintPair.color
        /// `secondaryOnTint` as a style: Increase Contrast takes the lifted secondary of that tier.
        static let secondaryOnTintStyle = secondaryStyle
        /// Secondary text on a Usage card.
        static let secondaryOnCardRGB = secondaryOnTintRGB
        static let secondaryOnCardStyle = secondaryOnTintStyle
    }

    /// The one brand color (periwinkle). Fills carry the on-accent text, never light text in Ink.
    enum Accent {
        /// In Paper the accent is a deeper step of the same hue.
        static let basePair = Adaptive(dark: RGB(hex: 0x8791CF), light: RGB(hex: 0x4B56A8))
        static let baseRGB = basePair.dark
        static let base = basePair.color
        /// Text and symbols on an accent fill: `#0B0E16` on the Ink fill (light text there is 3.0:1), a warm paper white
        /// on the Paper fill.
        static let onAccentPair = Adaptive(dark: RGB(hex: 0x0B0E16), light: RGB(hex: 0xFBF8F2))
        static let onAccentRGB = onAccentPair.dark
        static let onAccent = onAccentPair.color
        /// A field's focus halo and a comment box: the base at 16 % in Ink, 11 % in Paper.
        static let washTone = AdaptiveTone(dark: Tone(rgb: basePair.dark, opacity: 0.16),
                                           light: Tone(rgb: basePair.light, opacity: 0.11))
        static let wash = washTone.color
    }

    enum Status {
        /// The three status dots; Paper's attention and failure dots are the lighter `#C46A00` and `#C8322C`.
        static let attentionPair = Adaptive(dark: RGB(hex: 0xFF9E0A), light: RGB(hex: 0xC46A00))
        static let unviewedPair = Adaptive(dark: RGB(hex: 0x5C8CFF), light: RGB(hex: 0x2557CC))
        static let failurePair = Adaptive(dark: RGB(hex: 0xF2615C), light: RGB(hex: 0xC8322C))
        static let attentionRGB = attentionPair.dark
        static let unviewedRGB = unviewedPair.dark
        static let failureRGB = failurePair.dark
        static let attention = attentionPair.color
        static let unviewed = unviewedPair.color
        static let failure = failurePair.color
        /// The wash behind a status: 13 % in Ink; 11 % (attention) and 10 % (unviewed, failure) in Paper.
        static let attentionWashTone = AdaptiveTone(dark: Tone(rgb: attentionPair.dark, opacity: 0.13),
                                                    light: Tone(rgb: attentionPair.light, opacity: 0.11))
        static let unviewedWashTone = AdaptiveTone(dark: Tone(rgb: unviewedPair.dark, opacity: 0.13),
                                                   light: Tone(rgb: unviewedPair.light, opacity: 0.10))
        static let failureWashTone = AdaptiveTone(dark: Tone(rgb: failurePair.dark, opacity: 0.13),
                                                  light: Tone(rgb: failurePair.light, opacity: 0.10))
        static let attentionWash = attentionWashTone.color
        static let unviewedWash = unviewedWashTone.color
        static let failureWash = failureWashTone.color
        /// Fill opacity of a callout tinted with a status color (the Ink wash, Ink's value).
        static let tintOpacity = 0.13
    }

    /// The project colour class (D-48): six soft tones besides the accent and the three status hues. Used
    /// only for the project's mark, the tab tint, the selected session's tint and the header chip's wash and edge; never a
    /// dot, never in the indicator slot, never a text colour, never a stripe, never inside the terminal (DESIGN §6). The
    /// base colour is the tint source; Increase Contrast swaps in a lighter tone for the edges and the mark's initial.
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

        /// The tone as a style that resolves against the environment's contrast setting: the bars beside a project's name and
        /// the mark's initial.
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

        /// The small bars other surfaces still draw beside a project's name (Home's rows, the project page, the draft page).
        static let stripeRadius: CGFloat = 2

        // The selected session (DESIGN §6 Project colour): its row or card takes 14 % of the project's tone with a 1 pt edge of
        // the tone at 34 %, 75 % under Increase Contrast. No tone: the neutral selected fill and its hairline.
        static let selectionWash = 0.14
        static let selectionEdge = 0.34
        static let selectionEdgeIncreased = 0.75

        // Tab tint (DESIGN §6 Project colour): a wash of the tone on every tab, 6 % at rest, 11 % under the pointer and 16 %
        // on the open tab with a 1 pt edge of the tone at 42 %. Increase Contrast draws that edge in the lighter tone at
        // 75 %; the washes stay as they are. Primary text holds 7:1 and secondary 4.5:1 on every tint (`ProjectColorUITests`).
        static let tabWash = 0.06
        static let tabWashHover = 0.11
        static let tabWashOpen = 0.16
        static let tabStrokeOpen = 0.42
        static let tabStrokeOpenIncreased = 0.75
        /// The header chip: 10 % with a 1 pt edge of the tone at 32 % (75 % under Increase Contrast).
        static let chipWash = 0.10
        static let chipEdgeOpacity = 0.32
        static let chipEdgeIncreasedOpacity = 0.75

        /// The menu swatch: a rounded square, never a dot.
        static let swatch: CGFloat = 12
        static let swatchRadius: CGFloat = 3
    }

    /// The session header (DESIGN §6 Header; A3 and A4 of the reference): 52 pt on the canvas with a hairline under it. From
    /// the left the harness's mark, the title and right after it the state pill; at the trailing edge, 8 apart, the project
    /// chip, the model segment, a hairline, the inspector toggle and the control group.
    enum Header {
        /// The row's content insets: the terminal's text starts at the same 20 pt.
        static let leadingInset: CGFloat = 20
        static let trailingInset: CGFloat = 12
        /// The title: 13 semibold, one line.
        static let titleFont = InkType.header.font

        // State pill: a 22 pt capsule with the mark and the label in 11.5 medium. Working sits on the selected fill in
        // primary text, Ready, Idle, Stale and State unknown on the hover fill in secondary text with no mark; attention,
        // failure and the unviewed finish take a low wash of their own colour behind the text variant (DESIGN §4).
        static let pillHeight: CGFloat = InkHeight.chip
        static let pillLeading: CGFloat = 8
        static let pillTrailing: CGFloat = 8
        static let pillGap: CGFloat = 4
        static let pillFont = Font.system(size: 11.5, weight: .medium)
        static let pillWorkingWash = Surface.selectedOpacity
        static let pillNeutralWash = Surface.hoverOpacity
        static let pillStatusWash = 0.13
        static let attentionLabelRGB = Status.attentionLightRGB
        static let failureLabelRGB = Status.failureLightRGB
        static let unviewedLabelRGB = Status.unviewedLightRGB
        static let attentionLabelPair = Status.attentionLightPair
        static let failureLabelPair = Status.failureLightPair
        static let unviewedLabelPair = Status.unviewedLightPair

        // Project chip: 22 pt, radius 6; the project's mark 4 pt from the edge, the name in 12 primary, a 1 x 12 hairline, the
        // branch glyph and the branch in mono 11.5 secondary. The tint is the project's (10 % with a 32 % edge); without a
        // tone the chip is neutral (the selected fill with the strong hairline).
        static let chipHeight: CGFloat = InkHeight.chip
        static let chipRadius: CGFloat = InkRadius.control
        static let chipMarkInset: CGFloat = 4
        /// Space after the mark; a chip without a mark (no project) insets its text `chipInset` instead.
        static let chipMarkGap: CGFloat = 8
        static let chipInset: CGFloat = 8
        static let chipRuleGap: CGFloat = 8
        static let chipRuleAfter: CGFloat = 8
        static let chipRuleHeight: CGFloat = 12
        static let chipBranchGap: CGFloat = 4
        /// The glyph before the branch name.
        static let chipGlyph = Font.system(size: 11)
        static let chipNameFont = InkType.small.font
        static let chipBranchFont = InkType.metaLarge.font
        /// A longer branch name ends in an ellipsis; 320 pt holds names like "release/2026-10/hotfix-PAY-142".
        static let branchMaxWidth: CGFloat = 320
        /// The neutral chip (no project, None, colours off): the selected fill.
        static let chipNeutralWash = Surface.selectedOpacity
        static let chipNeutralTone = Surface.selectedTone
        static let chipNeutral = chipNeutralTone.color

        // The model segment after the chip: the ring (or a token count) and the model's name, plain text.
        static let modelGap: CGFloat = 6

        // The hairline before the inspector toggle, the toggle and the control group.
        static let ruleHeight: CGFloat = 16
        static let ruleMargin: CGFloat = 2
        static let toggleSize: CGFloat = InkHeight.control
        /// The control group: 26 high, radius 7, the strong hairline for an edge; it rests on no fill.
        static let groupHeight: CGFloat = InkHeight.control
        static let groupRadius: CGFloat = InkRadius.group
        static let groupWash = Surface.selectedOpacity
        static let groupTone = Surface.selectedTone
        static let group = groupTone.color
        /// The state pill's washes in Paper: working and neutral are ink overlays, a status wash is its own hue.
        static let pillWorkingLightWash = Surface.selectedLightOpacity
        static let pillNeutralLightWash = Surface.hoverLightOpacity
        /// The Stop segment: an 8 x 8 square with radius 1.5 and "Stop" in 12 medium; the ⋯ segment is 30 wide.
        static let stopGlyph: CGFloat = 8
        static let stopGlyphRadius: CGFloat = 1.5
        static let stopPadding: CGFloat = 8
        static let stopGap: CGFloat = 8
        static let stopFont = Font.system(size: 12, weight: .medium)
        static let menuSegmentWidth: CGFloat = 30

        // The subagent panel's header (FB4-5): the crumb, and the Session control with its Esc key cap.
        static let crumbGap: CGFloat = 8
        static let crumbGlyph = Font.system(size: 12)
        static let backGap: CGFloat = 8
        static let backLeading: CGFloat = 8
        static let backTrailing: CGFloat = 8
        static let keyCapPadding: CGFloat = 4

        // Narrow rows: the title gives way down to this width, then the model segment goes, then the chip gives up its
        // branch, then the project name shortens (never below the floor).
        static let titleMinWidth: CGFloat = 100
        static let chipFloorWidth: CGFloat = 56
    }

    enum Opacity {
        /// A disabled control is drawn at 38 % (DESIGN §6 Controls).
        static let disabled = 0.38
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
        /// Sphyrna's focus ring: the accent, 2 pt wide, 2 pt outside the control (`focusRingOffset`); 2.5 under Increase Contrast.
        static let focusRing: CGFloat = 2
        static let focusRingOffset: CGFloat = 2
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
        // Sidebar header and footer chip.
        static let headerSpacing: CGFloat = 4
        static let headerInset: CGFloat = 8
        static let footerSpacing: CGFloat = 8
        static let chipInset: CGFloat = 8
        /// The usage chip: the least space between tokens and limit, and between limit name, meter and percent.
        static let chipSplitGap: CGFloat = 8
        static let chipLimitGap: CGFloat = 4
        // List.
        static let listInset: CGFloat = 8
        static let listBottom: CGFloat = 8
        static let sectionInset: CGFloat = 8
        /// How far a focused row's ring sits outside its content.
        static let rowFocusOutset: CGFloat = 4
        static let emptyNoteInset: CGFloat = 16
        static let emptyNoteVertical: CGFloat = 8
        static let loadingPadding: CGFloat = 8
        static let hintSpacing: CGFloat = 8
        static let hintTop: CGFloat = 40
        // Cards.
        static let cardGap: CGFloat = 2
        static let cardH: CGFloat = 8
        static let cardV: CGFloat = 8
        static let cardSpacing: CGFloat = 8
        static let cardLineSpacing: CGFloat = 4
        static let cardIndicatorTop: CGFloat = 1
        /// The gap between a subagent's type and description in the inspector's Agents list.
        static let subagentTextGap: CGFloat = 4
        // The subagent panel's transcript (FB4-5).
        static let transcriptInset: CGFloat = 16
        // Detail pane.
        static let detailInset: CGFloat = 16
        static let detailSpacing: CGFloat = 8
        static let detailMinSpacer: CGFloat = 8
        static let bannerBottom: CGFloat = 8
        static let bannerRowSpacing: CGFloat = 8
        static let emptyStateSpacing: CGFloat = 12
        static let messageSpacing: CGFloat = 8
        static let messagePadding: CGFloat = 24
        // Requests.
        static let requestListSpacing: CGFloat = 8
        static let requestSpacing: CGFloat = 8
        static let requestLineSpacing: CGFloat = 4
        static let requestPadding: CGFloat = 12
        // Accent buttons.
        static let buttonH: CGFloat = 12
        static let buttonV: CGFloat = 4
        // Sheet.
        static let sheetSpacing: CGFloat = 12
        static let sheetPadding: CGFloat = 20
        // Terminal host: the text keeps 16 pt of canvas around it, 20 at the leading edge (DESIGN §6 Terminal framing).
        static let terminalInset: CGFloat = 16
        static let terminalLeadingInset: CGFloat = 20
        // The older segmented control and text button the Changes tab still draws with (`SegmentButtonStyle`, `SettingsButtonStyle`).
        // Settings itself is `LoomTheme.Settings` (`LoomTheme+Settings.swift`).
        static let settingsSegmentH: CGFloat = 12
    }

    // MARK: Layout

    enum Layout {
        // Header geometry. The unified toolbar centers the native window buttons
        // 26 pt below the window top (x 19...79), which is also the center of the
        // 52 pt sidebar header row and of the detail header row.
        static let headerHeight: CGFloat = 52
        /// Sidebar header: space before the toggle so it clears the native buttons.
        static let sidebarButtonsGap: CGFloat = 76
        /// Detail header (collapsed sidebar): space reserved for the native buttons.
        static let detailButtonsGap: CGFloat = 66
        /// An icon button: 26 pt, radius 6, a 16 pt glyph (DESIGN §6 Controls).
        static let chromeButton = CGSize(width: 26, height: 26)
        static let projectMenuButton = CGSize(width: 22, height: 20)
        /// Every control answers a click within at least this area, whatever it draws.
        static let minimumHitTarget = CGSize(width: 24, height: 24)
        /// The harness's mark (DESIGN §6 Iconography): 12 on rows, cards and tabs, 13 in the header and on the model chip, 14 in menus.
        static let harnessMarkRow: CGFloat = 12
        static let harnessMarkHeader: CGFloat = 13
        static let harnessMarkMenu: CGFloat = 14
        static let providerIconHeader: CGFloat = harnessMarkHeader
        static let providerIconDefault: CGFloat = 15
        static let messageMaxWidth: CGFloat = 420
        /// The request box for an agent's "open a session": its label column, and the scroll area of the full message.
        static let requestLabelWidth: CGFloat = 52
        static let requestMessageMaxHeight: CGFloat = 160
        /// The older segment's and button's height (see `Space.settingsSegmentH`).
        static let settingsSegmentHeight: CGFloat = 24
        // Indicators.
        static let indicatorSlot = CGSize(width: 12, height: 16)
        /// The Loom mark over the first-run Home (D-69): its width; the height follows the mark's box.
        static let heroMarkWidth: CGFloat = 36
        /// The failure mark under "Differentiate without color" (the identity proposal's diamond, corner to corner).
        static let failureDiamond: CGFloat = 7
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

        // The badge slot, lower right. Working: the braille spinner. Needs you: one dot.
        // The mark is cut away around the badge so it sits on the bar. Coordinates are in the mark's box.
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
        static let rowDot: CGFloat = 7
        static let titleFontSize: CGFloat = 13
        static let projectFontSize: CGFloat = 12
        /// The width of the title and project text together; the project keeps up to `projectMaxWidth`.
        static let rowTextWidth: CGFloat = 264
        static let projectMaxWidth: CGFloat = 112
        static let titleProjectGap: CGFloat = 8
    }

    // MARK: Tab strip

    /// The session tab row (DESIGN §6 Tabs): 36 pt under the header with a hairline under it. A tab is a 26 pt pill of radius 7,
    /// 4 apart and 8 from the row's edge, at most 230 wide, tinted with its project's tone.
    enum TabStrip {
        static let height: CGFloat = InkHeight.tabRow
        static let tabHeight: CGFloat = InkHeight.control
        static let tabRadius: CGFloat = InkRadius.group
        static let minTabWidth: CGFloat = 112
        static let maxTabWidth: CGFloat = 230
        static let gap: CGFloat = 4
        static let inset: CGFloat = 8
        /// Space inside a tab before the project's mark and after its end slot.
        static let tabInset: CGFloat = 6
        /// Space between a tab's parts: the mark, the status slot, the title and the end slot.
        static let tabSpacing: CGFloat = 7
        /// Where a tab's status slot ends: the project's mark (14), a gap, then the slot.
        static var indicatorEnd: CGFloat { tabInset + ProjectMarkStyle.Size.chip.side + tabSpacing + Layout.indicatorSlot.width }
        /// The title: 12.5, secondary; primary on hover and when open.
        static let titleFont = Font.system(size: 12.5)
        /// The end slot: the harness's mark (12) until the pointer is on the tab, then the close button, 16 either way.
        static let close: CGFloat = 16
        static let closeRadius: CGFloat = InkRadius.key
        static let closeGlyph = Font.system(size: 9, weight: .semibold)
        /// The "+" icon button that ends the row.
        static let plus: CGFloat = 24
        static let plusGlyph = Font.system(size: 14)
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
