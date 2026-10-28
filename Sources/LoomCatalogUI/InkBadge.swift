import SwiftUI

/// An 18 pt caption badge. Status badges use the caller's status wash and text; ordinary badges use muted and secondary.
struct InkBadge: View {
    enum Kind {
        case neutral
        case outline
        case status(fill: Color, text: Color)
    }

    let text: String
    var kind: Kind = .neutral

    var body: some View {
        let shape = Capsule()
        Text(text).projectType(LoomTheme.InkType.caption)
            .foregroundStyle(textColor)
            .padding(.horizontal, LoomTheme.Control.badgePaddingH)
            .frame(minWidth: LoomTheme.Control.badgeHeight, minHeight: LoomTheme.Control.badgeHeight)
            .background(shape.fill(fill))
            .overlay { if case .outline = kind { shape.strokeBorder(LoomTheme.Surface.inputEdge, lineWidth: LoomTheme.Line.hairline) } }
    }

    private var fill: Color {
        switch kind {
        case .neutral: LoomTheme.Surface.muted
        case .outline: .clear
        case let .status(fill, _): fill
        }
    }

    private var textColor: Color {
        switch kind {
        case .neutral, .outline: LoomTheme.Text.secondary
        case let .status(_, text): text
        }
    }
}
