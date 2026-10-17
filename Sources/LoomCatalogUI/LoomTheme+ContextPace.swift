import SwiftUI

/// Night Fleece 2 values of the context ring and the plan pace line (design preview `v2-studio-preview`:
/// the composer's `.ring`, the Home plan card's `.lim` and `.meter`). Built from the existing surface,
/// text and status tokens; only sizes are new.
extension LoomTheme {
    /// The context ring: a 16 pt ring in a 30 pt hit area, a hairline track and an arc in secondary text.
    enum ContextRing {
        static let hitSide: CGFloat = 30
        static let diameter: CGFloat = 16
        /// The preview's 16 pt disc with an 11 pt hole.
        static let lineWidth: CGFloat = 2.5
        /// From here on the arc takes the attention colour: the context is nearly full.
        static let nearlyFull = 0.9
        static let labelGap: CGFloat = 6
        static let track = Surface.chipMeterTrack
        static let arc = Text.secondary
        static let arcFull = Status.attention
    }

    /// The plan pace line: the window name and what is left, a meter with a tick where an even pace
    /// would stand, and one sentence about whether the limit lasts.
    enum PlanPaceLine {
        static let meterHeight: CGFloat = 6
        static let meterRadius: CGFloat = 3
        static let tickWidth: CGFloat = 2
        static let tickOverhang: CGFloat = 2
        static let titleGap: CGFloat = 6
        static let track = Surface.hairline
        static let fill = Text.primary
        static let fillOver = Status.attention
        static let tick = Text.secondary
        static let lasts = Success.light
        static let runsOut = Status.attentionLight
    }
}
