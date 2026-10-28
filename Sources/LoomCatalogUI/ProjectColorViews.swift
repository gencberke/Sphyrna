import AppKit
import LoomCore
import SwiftUI

// The project colour surfaces (D-48; DESIGN §6): the tab tint, the selected session's tint (`RowHighlight`), the detail
// header's project chip (`ProjectBranchChip`), the project's mark (`ProjectMarkView`) and the Color menu. Values are
// `LoomTheme.ProjectColor`'s; whether anything is drawn is decided by `CatalogModel.projectTone(forProject:)`, `projectMark(of:)` and
// `headerProjectMark(of:)`, which answer no tone while the setting is off. There is no stripe in Ink.

/// Project tint values for a session tab (DESIGN §6): the v4 tab draws the 11 % hover wash or 16 % selected wash,
/// with a 1 pt project edge on selection. The tab suppresses the legacy resting wash and stays flat at rest.
/// No tone, no tint: the tab keeps the neutral fills.
struct ProjectTabStyle: Equatable {
    /// The wash in Dark; `washColor` is what the tab draws (the tone's own value in each appearance).
    let wash: LoomTheme.Tone?
    let washColor: Color?
    let stroke: LoomTheme.ContrastStyle?

    init(tone: ProjectTone?, selected: Bool, hovering: Bool) {
        guard let tone else { wash = nil; washColor = nil; stroke = nil; return }
        let rgb = LoomTheme.ProjectColor.baseRGB(tone)
        let opacity = selected ? LoomTheme.ProjectColor.tabWashOpen
            : (hovering ? LoomTheme.ProjectColor.tabWashHover : LoomTheme.ProjectColor.tabWash)
        wash = LoomTheme.Tone(rgb: rgb, opacity: opacity)
        washColor = LoomTheme.ProjectColor.wash(tone, opacity: opacity).color
        stroke = selected ? LoomTheme.ProjectColor.tabEdge(tone) : nil
    }

    /// `washColor` is derived from the tone and the opacity, and a dynamic colour has no identity to compare.
    static func == (lhs: ProjectTabStyle, rhs: ProjectTabStyle) -> Bool {
        lhs.wash == rhs.wash && lhs.stroke == rhs.stroke
    }
}

/// The swatch of the Color menu: a rounded square in the tone, or a hollow one for None. Never a dot.
@MainActor
enum ProjectSwatch {
    private static var cache: [ProjectTone?: NSImage] = [:]

    static func image(for tone: ProjectTone?) -> NSImage {
        if let cached = cache[tone] { return cached }
        let side = LoomTheme.ProjectColor.swatch
        let radius = LoomTheme.ProjectColor.swatchRadius
        let filled = tone != nil
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // The handler runs for each draw, under the menu's appearance: a swatch in a light menu takes the Light tone.
            let appearance = LoomTheme.Appearance(NSAppearance.currentDrawing())
            let rgb = tone.map { LoomTheme.ProjectColor.baseRGB($0, appearance) } ?? LoomTheme.Text.faintPair[appearance]
            let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            if filled {
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            } else {
                color.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                path.lineWidth = LoomTheme.Line.hairline
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        cache[tone] = image
        return image
    }
}

/// "Color" submenu of a project's actions and context menus: the six tones with their names, then None,
/// a checkmark on the current one. A tone this build does not know is checked nowhere. Absent while
/// project colors are off.
struct ProjectColorMenu: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        if model.projectColorsEnabled {
            Menu("Color") {
                ForEach(ProjectTone.allCases, id: \.self) { tone in
                    choice(tone.title, tone: tone, checked: project.tone == tone)
                }
                Divider()
                choice("None", tone: nil, checked: project.colorIsNone)
            }
            .accessibilityLabel("Color of \(project.name)")
        }
    }

    private func choice(_ title: String, tone: ProjectTone?, checked: Bool) -> some View {
        Toggle(isOn: Binding(get: { checked }, set: { _ in
            Task { await model.setProjectTone(project.id, tone) }
        })) {
            Label { Text(title) } icon: { Image(nsImage: ProjectSwatch.image(for: tone)) }
        }
    }
}
