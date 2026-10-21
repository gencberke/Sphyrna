import SwiftUI

// The small pieces the inspector's tabs share: a section with a label row.

/// A block of the inspector body: its label in Ink's label type (written in sentence case, drawn in capitals), an optional
/// trailing note in the same quiet voice, then the content.
struct InspectorSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.inspectorOverlays) private var overlays

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Inspector.sectionTitleGap) {
            HStack(spacing: LoomTheme.Space.detailSpacing) {
                Text(title).inspectorType(LoomTheme.Inspector.sectionLabel)
                    .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                    .accessibilityAddTraits(.isHeader)
                if let note {
                    Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                    Text(note).inspectorType(LoomTheme.Inspector.tabCount)
                        .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                        .lineLimit(1)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
