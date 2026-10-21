import SwiftUI

// The small pieces the inspector's tabs share: a section with a label row, and a fact (label and value).

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

/// One row of facts: the label in secondary on a fixed column, the value in primary beside it (selectable, wrapping), in mono
/// when it is what the machine says.
struct InspectorFact: View {
    let name: String
    let value: String
    var mono = false

    init(_ name: String, _ value: String, mono: Bool = false) {
        self.name = name
        self.value = value
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Inspector.factColumnGap) {
            Text(name).inspectorType(LoomTheme.Inspector.factLabel).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(width: LoomTheme.Inspector.factLabelWidth, alignment: .leading)
            Text(verbatim: value).inspectorType(mono ? LoomTheme.Inspector.factMono : LoomTheme.Inspector.factValue)
                .foregroundStyle(LoomTheme.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
