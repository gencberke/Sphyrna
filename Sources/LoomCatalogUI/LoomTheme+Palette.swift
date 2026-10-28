import SwiftUI

/// Ink's colour additions (DESIGN §3 Accent, status and content colours): the accent ramp, the text variants of the status
/// hues, the content-only success hue and the popover rules.
extension LoomTheme.Accent {
    /// Accent text on raised levels and popovers. In Paper the high step is the deeper one.
    static let highPair = LoomTheme.Adaptive(dark: LoomTheme.RGB(hex: 0xA9B0E3), light: LoomTheme.RGB(hex: 0x3A4491))
    /// Strokes and fills that carry no text.
    static let lowPair = LoomTheme.Adaptive(dark: LoomTheme.RGB(hex: 0x5E68A8), light: LoomTheme.RGB(hex: 0xA3ABDD))
    static let highRGB = highPair.dark
    static let lowRGB = lowPair.dark
    static let high = highPair.color
    static let low = lowPair.color
}

extension LoomTheme.Status {
    /// The text variants write; the dot hues mark. They are the text colours on a wash of the hue and on a popover. The name
    /// `…Light` stays; in Paper the variant is the deeper step.
    static let attentionLightPair = LoomTheme.Adaptive(dark: LoomTheme.RGB(hex: 0xFFB547), light: LoomTheme.RGB(hex: 0x7A3A00))
    static let unviewedLightPair = LoomTheme.Adaptive(dark: LoomTheme.RGB(hex: 0x8FB0FF), light: LoomTheme.RGB(hex: 0x1B43A3))
    static let failureLightPair = LoomTheme.Adaptive(dark: LoomTheme.RGB(hex: 0xFF8A85), light: LoomTheme.RGB(hex: 0x8E1D19))
    static let attentionLightRGB = attentionLightPair.dark
    static let unviewedLightRGB = unviewedLightPair.dark
    static let failureLightRGB = failureLightPair.dark
    static let attentionLight = attentionLightPair.color
    static let unviewedLight = unviewedLightPair.color
    static let failureLight = failureLightPair.color
}

extension LoomTheme {
    /// Success is a content colour: added lines, passing checks, "42 passed". Never a status indicator,
    /// never in the indicator slot (DESIGN §4).
    enum Success {
        static let basePair = Adaptive(dark: RGB(hex: 0x4CC38A), light: RGB(hex: 0x186E43))
        static let lightPair = Adaptive(dark: RGB(hex: 0x7BDBA8), light: RGB(hex: 0x125A36))
        static let baseRGB = basePair.dark
        static let lightRGB = lightPair.dark
        static let base = basePair.color
        static let light = lightPair.color
    }

    /// The text colours to use on a popover or palette surface. On a popover quiet text is secondary (placeholders
    /// included), accent text is the high step, and the unviewed and failure words take their text variants.
    enum OnPopover {
        /// Placeholders are secondary, not faint.
        static let placeholderPair = Text.secondaryPair
        /// Accent text is the high step.
        static let accentPair = Accent.highPair
        static let unviewedPair = Status.unviewedLightPair
        static let failurePair = Status.failureLightPair
        /// Secondary text on a popover row under the pointer or the cursor. Ink's hover fill (5 %) leaves plain secondary at
        /// 4.5:1 or more on every popover (`HighlightTests`), so the lift Night Fleece needed is gone; the API stays.
        static let hoveredSecondaryPair = Text.secondaryPair
        static let hoveredSecondaryRGB = hoveredSecondaryPair.dark
        static let hoveredSecondaryStyle = Text.secondaryStyle

        /// The secondary text of a popover row: `lit` while the row draws the hover fill (the pointer or the cursor is on it).
        static func secondary(lit: Bool) -> ContrastStyle { lit ? hoveredSecondaryStyle : Text.secondaryStyle }

        static let placeholderRGB = placeholderPair.dark
        static let accentRGB = accentPair.dark
        static let unviewedRGB = unviewedPair.dark
        static let failureRGB = failurePair.dark
        static let placeholder = placeholderPair.color
        static let accent = accentPair.color
        static let unviewed = unviewedPair.color
        static let failure = failurePair.color
    }
}

extension LoomTheme {
    /// Ask Remora in the palette (DESIGN §20 ⌘K; the reference's `remora/remora.css` `.palette .prow .sc` and `.palans`): the row's
    /// scope and key caps in 11 mono, the answer padded 12 18 14 with its head line in 12.
    enum PaletteRemora {
        static let rowGap: CGFloat = 10
        /// The leading slot is the indicator slot and 4, as the palette's other rows.
        static let leadingExtra: CGFloat = 4
        static let keyGap: CGFloat = 6
        static let scope = InkStyle(size: 11, mono: true)
        static let capRadius: CGFloat = 4
        static let head = InkStyle(size: 12)
        static let answerPaddingH: CGFloat = 18
        static let answerPaddingTop: CGFloat = 12
        static let answerPaddingBottom: CGFloat = 14
        static let footGap: CGFloat = 14
    }
}
