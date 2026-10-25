import SwiftUI

// The small pieces the inspector's tabs share: a section with a label row, and the sentence of an empty or waiting pane.

/// A block of the inspector body: its label in Ink's label type (written in sentence case, drawn in capitals), an optional
/// note in the same quiet voice, then the content. The note sits at the trailing edge, or right after the label when it is the
/// label's count ("Running 2", the Agents tab).
struct InspectorSection<Content: View>: View {
    let title: String
    var note: String?
    var noteFollowsTitle = false
    var titleGap = LoomTheme.Inspector.sectionTitleGap
    @ViewBuilder let content: () -> Content
    @Environment(\.inspectorOverlays) private var overlays

    var body: some View {
        VStack(alignment: .leading, spacing: titleGap) {
            HStack(alignment: .firstTextBaseline,
                   spacing: noteFollowsTitle ? LoomTheme.Agents.headCountGap : LoomTheme.Space.detailSpacing) {
                Text(title).inspectorType(LoomTheme.Inspector.sectionLabel)
                    .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                    .accessibilityAddTraits(.isHeader)
                if let note {
                    if !noteFollowsTitle { Spacer(minLength: LoomTheme.Space.detailMinSpacer) }
                    Text(note).inspectorType(LoomTheme.Inspector.tabCount)
                        .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                        .lineLimit(1)
                }
                if noteFollowsTitle { Spacer(minLength: 0) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An empty or waiting pane of the inspector (DESIGN §13 "Empty and waiting", §4 a stopped session's list): one sentence in 13
/// semibold, and an optional line in mono under it. No art since the rescue (D-100).
struct InspectorEmptyState: View {
    let text: String
    var detail: String?
    @Environment(\.inspectorOverlays) private var overlays

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: text).projectType(LoomTheme.Agents.emptyText).foregroundStyle(LoomTheme.Text.primary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(verbatim: detail).projectType(LoomTheme.Agents.emptyDetail)
                    .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                    .multilineTextAlignment(.center).lineLimit(1).truncationMode(.middle)
                    .padding(.top, LoomTheme.Agents.emptyDetailTop)
            }
        }
        .padding(.top, LoomTheme.Agents.emptyTop)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
