import SwiftUI

/// Values of the inspector (DESIGN §6 Tabs, view tabs; the reference's `.itabs`, `.ihead`, `.facts`). The surface, hairline and
/// text colours are the existing tokens; the width is `Rhythm.inspectorWidth`. The type is Ink's (`InkType`).
extension LoomTheme {
    enum Inspector {
        /// The content keeps at least this much width beside the inspector column (the detail pane's own
        /// minimum); in a narrower pane the inspector is drawn over the content instead of squeezing it.
        static let minimumContent: CGFloat = 480
        /// The overlaid inspector's shadow falls to its left, over the content, not downwards.
        static let overlayShadowX: CGFloat = -12

        // View tabs (DESIGN §6 Tabs): underlined text on the 36 pt bar, 18 apart. The open tab has a 1.5 pt accent underline
        // that sits on the bar's hairline; a count (or the Side tab's dot) follows the label.
        static let tabBarHeight = InkHeight.tabRow
        static let tabBarInset: CGFloat = 16
        static let tabGap: CGFloat = 18
        static let tabContentGap: CGFloat = 6
        static let tabUnderline: CGFloat = 1.5
        /// The keyboard focus ring hugs the label: it stands this far off it sideways and is inset from the bar's edges.
        static let tabFocusOutset: CGFloat = 4
        static let tabFocusInset: CGFloat = 6
        static let tabLabel = InkType.button
        static let tabCount = InkStyle(size: 10.5, mono: true)

        // Body and sections: a label in Ink's label type over rows of facts.
        static let bodyInset: CGFloat = 16
        static let sectionGap: CGFloat = 20
        static let sectionTitleGap: CGFloat = 12
        static let sectionLabel = InkType.label
        static let factLabel = InkType.small
        static let factValue = InkType.small
        static let rowGap: CGFloat = 8

        /// The quiet voice (counts, section labels, the context's tokens): tertiary, and secondary on a popover, where the
        /// inspector sits when it overlays the content (DESIGN §3 Text).
        static func quiet(overlays: Bool) -> ContrastStyle { overlays ? Text.secondaryStyle : Text.tertiaryStyle }

        // The Agents tab's list and transcript are `LoomTheme.Agents`. A subagent a subagent started is indented one step per level.
        static let agentIndent: CGFloat = 8
        static let agentMaxIndent = 2
        // No longer drawn (the I6b Agents rows are `LoomTheme.Agents`); kept while `HighlightTests`' grid list names them.
        static let agentPaddingV: CGFloat = 8
        static let agentColumnGap: CGFloat = 8
        static let agentLineGap: CGFloat = 4
    }
}

extension View {
    /// Draws a text in one of Ink's roles: its face, its tracking and, for the label, capitals.
    func inspectorType(_ style: LoomTheme.InkStyle) -> some View {
        font(style.font).tracking(style.trackingPoints).textCase(style.capitals ? .uppercase : nil)
    }
}

private struct InspectorOverlaysKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The inspector is drawn over the content, on the popover surface (`InspectorContainer.overlays`).
    var inspectorOverlays: Bool {
        get { self[InspectorOverlaysKey.self] }
        set { self[InspectorOverlaysKey.self] = newValue }
    }
}
