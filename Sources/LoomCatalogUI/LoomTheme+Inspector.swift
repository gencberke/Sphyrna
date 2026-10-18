import SwiftUI

/// Values of the inspector (concept §6.2, design preview `v2-studio-preview`: `.itabs`, `.ibody`, `.isec`,
/// `.kv`, `.agent`). The surface, hairline and text colours are the existing tokens; the width is
/// `Rhythm.inspectorWidth`.
extension LoomTheme {
    enum Inspector {
        /// The content keeps at least this much width beside the inspector column (the detail pane's own
        /// minimum); in a narrower pane the inspector is drawn over the content instead of squeezing it.
        static let minimumContent: CGFloat = 480
        /// The overlaid inspector's shadow falls to its left, over the content, not downwards.
        static let overlayShadowX: CGFloat = -12

        // Tabs: a 40 pt bar; the open tab shows its name, the others their symbol and count.
        static let tabBarHeight: CGFloat = 40
        static let tabBarInset: CGFloat = 8
        static let tabGap: CGFloat = 2
        static let tabHeight: CGFloat = 26
        static let tabInset: CGFloat = 8
        static let tabInsetCompact: CGFloat = 7
        static let tabContentGap: CGFloat = 5
        static let tabGlyph = Font.system(size: 12)

        // Body and sections.
        static let bodyInset: CGFloat = 14
        static let sectionGap: CGFloat = 18
        static let sectionTitleGap: CGFloat = 9
        static let factLabelWidth: CGFloat = 92
        static let factRowGap: CGFloat = 7
        static let factColumnGap: CGFloat = 8
        static let rowGap: CGFloat = 8

        // An agent row: a card with a 22 pt mark, the type and description, and the time.
        static let agentPaddingH: CGFloat = 12
        static let agentPaddingV: CGFloat = 10
        static let agentMark: CGFloat = 22
        static let agentMarkRadius: CGFloat = 6
        static let agentMarkGlyph = Font.system(size: 12)
        static let agentColumnGap: CGFloat = 10
        static let agentLineGap: CGFloat = 3
        static let agentIndent: CGFloat = 10
        static let agentMaxIndent = 2
        static let agentMarkWash = Opacity.accentTint
        static let agentHover = Surface.raised

        // The drill-down header over a transcript.
        static let detailHeaderGap: CGFloat = 8
        static let backGap: CGFloat = 4
        static let backGlyph = Font.system(size: 11, weight: .semibold)

        /// The header toggle: one 24 pt segment in a group of its own, 2 pt before the control group. The
        /// header row keeps its title at 100 pt down to the narrowest detail pane, so the toggle takes 26 pt.
        static let toggleWidth: CGFloat = 24
        static let toggleGap: CGFloat = 2
    }
}
