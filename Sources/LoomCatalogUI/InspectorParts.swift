import SwiftUI

// The small pieces the inspector's tabs share: a section with a title row, and a fact (label and value).

/// A titled block of the inspector body: the title in the day-heading type, an optional trailing note in
/// the tertiary-free secondary tone, then the content.
struct InspectorSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Inspector.sectionTitleGap) {
            HStack(spacing: LoomTheme.Space.detailSpacing) {
                Text(title).font(LoomTheme.Typography.dayHeading).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .accessibilityAddTraits(.isHeader)
                if let note {
                    Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                    Text(note).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .lineLimit(1)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of facts: the label on a fixed column, the value beside it (selectable, wrapping).
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
            Text(name).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(width: LoomTheme.Inspector.factLabelWidth, alignment: .leading)
            Text(verbatim: value).font(mono ? LoomTheme.Typography.mono : LoomTheme.Typography.small)
                .foregroundStyle(LoomTheme.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
