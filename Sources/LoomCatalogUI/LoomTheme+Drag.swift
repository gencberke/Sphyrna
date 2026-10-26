import SwiftUI

/// What a drag in the app shows (FB6-5, DESIGN "Drag"): three looks, one for each kind of target. Like every `LoomTheme*.swift`
/// this file is exempt from the theme guard.
extension LoomTheme {
    enum Drag {
        // MARK: Insertion line: an ordered list (the project heads, the tab strip)

        /// The line is 2 pt of the accent.
        static let lineWidth: CGFloat = 2

        // MARK: Target wash: "drop onto this" (the composer, the terminal)

        /// The accent at 13 % over the target, with a 1 pt edge at 32 %.
        static let washOpacity = 0.13
        static let edgeOpacity = 0.32
        static let edgeWidth: CGFloat = 1
        static let washRadius: CGFloat = 10
        static let washTone = AdaptiveTone(
            dark: Tone(rgb: Accent.basePair.dark, opacity: washOpacity),
            light: Tone(rgb: Accent.basePair.light, opacity: washOpacity))
        static let edgeTone = AdaptiveTone(
            dark: Tone(rgb: Accent.basePair.dark, opacity: edgeOpacity),
            light: Tone(rgb: Accent.basePair.light, opacity: edgeOpacity))
        static let wash = washTone.color
        static let edge = edgeTone.color
        static let washNS = washTone.nsColor
        static let edgeNS = edgeTone.nsColor

        // MARK: Refusal: no highlight, the dragged source dimmed

        /// The source of a drag while the pointer is over nothing that takes it.
        static let sourceOpacity = 0.45
    }
}
