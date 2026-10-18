import SwiftUI

/// Night Fleece 2 colour additions (concept §6.1): the accent ramp, the light text variants of the status
/// hues, the content-only success hue and the popover rules for the four pairs that fall short.
extension LoomTheme.Accent {
    /// Accent text on raised surfaces and popovers (6.3:1 on a popover). In Light the high step is the deeper one.
    static let highPair = LoomTheme.Adaptive(dark: LoomTheme.RGB(hex: 0xA9B0E3), light: LoomTheme.RGB(hex: 0x3A4491))
    /// Strokes and fills that carry no text: primary text on it is 4.33:1, so it never carries text.
    static let lowPair = LoomTheme.Adaptive(dark: LoomTheme.RGB(hex: 0x5E68A8), light: LoomTheme.RGB(hex: 0xA3ABDD))
    static let highRGB = highPair.dark
    static let lowRGB = lowPair.dark
    static let high = highPair.color
    static let low = lowPair.color
}

extension LoomTheme.Status {
    /// The light variants are the text colours on a wash of the hue and on a popover. The name stays in Light, where
    /// the variant is the deeper step.
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

    /// The text colours to use on a popover or palette surface, where four pairs of the plain tokens fall
    /// short (concept §6.1): tertiary 2.36:1 (the floor is 2.5:1), base accent 4.39:1 and the unviewed and
    /// failure hues about 4.2:1 (the floor is 4.5:1). Views on a popover take these.
    enum OnPopover {
        /// Placeholders are secondary, not tertiary.
        static let placeholderPair = Text.secondaryPair
        /// Accent text is the high step.
        static let accentPair = Accent.highPair
        static let unviewedPair = Status.unviewedLightPair
        static let failurePair = Status.failureLightPair
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
