import LoomCore
import SwiftUI

/// The project's mark (DESIGN §6 Project colour): its initial, the first letter of its name, bold, on a soft square of its
/// tone. Used by the header's chip and the tabs, later by rows and pages. A project without a tone (no project's tone, None, an
/// unknown tone, or Settings → Theme → Project colors off) draws a neutral square with the initial in secondary text. It is
/// hidden from accessibility: the name is written beside it, and the tabs carry it in their label.
struct ProjectMarkView: View {
    let name: String
    let tone: ProjectTone?
    var size: LoomTheme.ProjectMarkStyle.Size = .chip

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius)
        Text(LoomTheme.ProjectMarkStyle.initial(of: name))
            .font(size.font)
            .foregroundStyle(initialStyle)
            .frame(width: size.side, height: size.side)
            .background(shape.fill(square))
            .accessibilityHidden(true)
    }

    private var initialStyle: AnyShapeStyle {
        tone.map { AnyShapeStyle(LoomTheme.ProjectMarkStyle.initialStyle($0)) } ?? AnyShapeStyle(LoomTheme.Text.secondaryStyle)
    }

    private var square: Color {
        tone.map { LoomTheme.ProjectMarkStyle.square($0).color } ?? LoomTheme.ProjectMarkStyle.neutralSquare.color
    }
}
