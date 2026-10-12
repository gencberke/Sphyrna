import AppKit
import LoomCore
import SwiftUI

// The project colour surfaces (D-48; DESIGN §6): the sidebar stripe, the tab tint, the detail header's
// mark and the Color menu. Values are `LoomTheme.ProjectColor`'s; whether anything is drawn is decided
// by `CatalogModel.projectTone(forProject:)` and `projectMark(of:)`, which answer nil while the
// setting is off.

/// The 3 pt stripe (4 pt under Increase Contrast) of a project header or one of its cards. The caller
/// places it `stripeOutset` left of the row's leading edge; it never takes a click or a VoiceOver stop.
struct ProjectStripe: View {
    let tone: ProjectTone
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: LoomTheme.ProjectColor.stripeRadius)
            .fill(LoomTheme.ProjectColor.stripe(tone))
            .frame(width: LoomTheme.ProjectColor.stripeWidth(for: contrast))
            .offset(x: -LoomTheme.ProjectColor.stripeOutset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The project's stripe in the list gutter, over the full height of the row; a header trims it
    /// with `top` and `bottom`.
    func projectStripe(_ tone: ProjectTone?, top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        overlay(alignment: .leading) {
            if let tone { ProjectStripe(tone: tone).padding(.top, top).padding(.bottom, bottom) }
        }
    }
}

/// How a conversation tab is tinted by its project (T5): a wash of the tone on every tab, stronger on
/// hover and on the open tab, and on the open tab a stroke of the tone in place of the hairline.
/// No tone, no tint: the tab keeps today's fill and stroke.
struct ProjectTabStyle: Equatable {
    let wash: LoomTheme.Tone?
    let stroke: LoomTheme.ContrastStyle?

    init(tone: ProjectTone?, selected: Bool, hovering: Bool) {
        guard let tone else { wash = nil; stroke = nil; return }
        let rgb = LoomTheme.ProjectColor.baseRGB(tone)
        let opacity = selected ? LoomTheme.ProjectColor.tabWashOpen
            : (hovering ? LoomTheme.ProjectColor.tabWashHover : LoomTheme.ProjectColor.tabWash)
        wash = LoomTheme.Tone(rgb: rgb, opacity: opacity)
        stroke = selected ? LoomTheme.ContrastStyle(
            standard: LoomTheme.Tone(rgb: rgb, opacity: LoomTheme.ProjectColor.tabStrokeOpen),
            increased: LoomTheme.Tone(rgb: LoomTheme.ProjectColor.increasedRGB(tone),
                                      opacity: LoomTheme.ProjectColor.tabStrokeOpenIncreased)) : nil
    }
}

/// The detail header's project mark, after the status label: a stripe in the tone (none for a project
/// set to None) and the project name in secondary text.
struct ProjectHeaderMark: View {
    let mark: ProjectMark
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: LoomTheme.ProjectColor.headerGap) {
            if let tone = mark.tone {
                RoundedRectangle(cornerRadius: LoomTheme.ProjectColor.stripeRadius)
                    .fill(LoomTheme.ProjectColor.stripe(tone))
                    .frame(width: LoomTheme.ProjectColor.stripeWidth(for: contrast),
                           height: LoomTheme.ProjectColor.headerStripeHeight)
                    .accessibilityHidden(true)
            }
            Text(mark.name).font(LoomTheme.Typography.statusLabel)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project: \(mark.name)")
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
        let rgb = tone.map(LoomTheme.ProjectColor.baseRGB) ?? LoomTheme.Text.tertiaryRGB
        let filled = tone != nil
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
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
