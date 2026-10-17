import SwiftUI

/// Night Fleece 2 colour additions (concept §6.1): the accent ramp, the light text variants of the status
/// hues, the content-only success hue and the popover rules for the four pairs that fall short.
extension LoomTheme.Accent {
    /// Accent text on raised surfaces and popovers (6.3:1 on a popover).
    static let highRGB = LoomTheme.RGB(hex: 0xA9B0E3)
    /// Strokes and fills that carry no text: primary text on it is 4.33:1, so it never carries text.
    static let lowRGB = LoomTheme.RGB(hex: 0x5E68A8)
    static let high = highRGB.color
    static let low = lowRGB.color
}

extension LoomTheme.Status {
    /// The light variants are the text colours on a wash of the hue and on a popover.
    static let attentionLightRGB = LoomTheme.RGB(hex: 0xFFB547)
    static let unviewedLightRGB = LoomTheme.RGB(hex: 0x8FB0FF)
    static let failureLightRGB = LoomTheme.RGB(hex: 0xFF8A85)
    static let attentionLight = attentionLightRGB.color
    static let unviewedLight = unviewedLightRGB.color
    static let failureLight = failureLightRGB.color
}

extension LoomTheme {
    /// Success is a content colour: added lines, passing checks, "42 passed". Never a status indicator,
    /// never in the indicator slot (DESIGN §4).
    enum Success {
        static let baseRGB = RGB(hex: 0x4CC38A)
        static let lightRGB = RGB(hex: 0x7BDBA8)
        static let base = baseRGB.color
        static let light = lightRGB.color
    }

    /// The text colours to use on a popover or palette surface, where four pairs of the plain tokens fall
    /// short (concept §6.1): tertiary 2.36:1 (the floor is 2.5:1), base accent 4.39:1 and the unviewed and
    /// failure hues about 4.2:1 (the floor is 4.5:1). Views on a popover take these.
    enum OnPopover {
        /// Placeholders are secondary, not tertiary.
        static let placeholderRGB = Text.secondaryRGB
        /// Accent text is the high step.
        static let accentRGB = Accent.highRGB
        static let unviewedRGB = Status.unviewedLightRGB
        static let failureRGB = Status.failureLightRGB
        static let placeholder = placeholderRGB.color
        static let accent = accentRGB.color
        static let unviewed = unviewedRGB.color
        static let failure = failureRGB.color
    }
}
