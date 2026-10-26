import AppKit
import SwiftUI

/// Ink's six greys (design/DESIGN.md §3 Surfaces, Tones): canvas, raised 1, raised 2, popover, segment on and tree, in
/// both appearances and the three tones (Neutral, Warm, Cool). Values are `RGB` data first so the contrast tests can
/// compute them; the `Color` is derived. The Night Fleece names (`sidebar`, `backdrop`, `inspector`, `panel`, `card`, ...)
/// stay as aliases by role below, so a view that was not redrawn yet draws Ink.
extension LoomTheme.Surface {
    /// The six greys of one appearance and tone.
    struct Greys: Equatable, Sendable {
        /// The window: sidebar, main pane, inspector, header and tab row; the terminal face's whole pane.
        let canvas: LoomTheme.RGB
        /// Cards: Home's lists and side cards, Settings' groups, code cards.
        let raised1: LoomTheme.RGB
        /// The composer.
        let raised2: LoomTheme.RGB
        /// Menus, pickers, the palette, the overlaid inspector, the quick question.
        let popover: LoomTheme.RGB
        /// The chosen segment of a segmented control.
        let segmentOn: LoomTheme.RGB
        /// The subagent branches; opaque, so crossing lines never brighten.
        let tree: LoomTheme.RGB

        /// The levels text sits on, back to front.
        var levels: [LoomTheme.RGB] { [canvas, raised1, raised2, popover] }
    }

    /// The table of DESIGN §3: Neutral is Ink's own greys, Warm and Cool are casts over them.
    static func greys(_ appearance: LoomTheme.Appearance, tone: PaneTone) -> Greys {
        func make(_ values: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)) -> Greys {
            Greys(canvas: LoomTheme.RGB(hex: values.0), raised1: LoomTheme.RGB(hex: values.1),
                  raised2: LoomTheme.RGB(hex: values.2), popover: LoomTheme.RGB(hex: values.3),
                  segmentOn: LoomTheme.RGB(hex: values.4), tree: LoomTheme.RGB(hex: values.5))
        }
        switch (appearance, tone) {
        case (.dark, .neutral): return make((0x0C0C0E, 0x121215, 0x17171B, 0x1C1C21, 0x26262C, 0x3B3B41))
        case (.light, .neutral): return make((0xF7F6F3, 0xFBFAF8, 0xFEFDFC, 0xFFFFFF, 0xFFFFFF, 0xC4C2BE))
        case (.dark, .warm): return make((0x0E0C0A, 0x15120F, 0x1A1714, 0x201C18, 0x2C2721, 0x433C34))
        case (.light, .warm): return make((0xF8F2E8, 0xFCF8F1, 0xFEFCF8, 0xFFFDF9, 0xFFFDF9, 0xCFC4B3))
        case (.dark, .cool): return make((0x0A0C10, 0x0F1217, 0x14171D, 0x191D24, 0x232833, 0x363E4C))
        case (.light, .cool): return make((0xF1F3F6, 0xF8F9FB, 0xFCFDFE, 0xFFFFFF, 0xFFFFFF, 0xBCC2CB))
        }
    }

    /// The terminal face's background: the tone's Ink canvas in both appearances (the face is dark in Paper too).
    static func terminalBackground(tone: PaneTone) -> LoomTheme.RGB { greys(.dark, tone: tone).canvas }

    /// The greys of one tone as colours, built once. Each resolves per appearance.
    struct GreyColors {
        let canvas: Color
        let raised1: Color
        let raised2: Color
        let popover: Color
        let segmentOn: Color
        let tree: Color
        let canvasNS: NSColor

        init(tone: PaneTone) {
            let dark = LoomTheme.Surface.greys(.dark, tone: tone), light = LoomTheme.Surface.greys(.light, tone: tone)
            func pair(_ path: KeyPath<Greys, LoomTheme.RGB>) -> LoomTheme.Adaptive {
                LoomTheme.Adaptive(dark: dark[keyPath: path], light: light[keyPath: path])
            }
            canvas = pair(\.canvas).color
            raised1 = pair(\.raised1).color
            raised2 = pair(\.raised2).color
            popover = pair(\.popover).color
            segmentOn = pair(\.segmentOn).color
            tree = pair(\.tree).color
            canvasNS = pair(\.canvas).nsColor
        }
    }

    private static let greyColors: [PaneTone: GreyColors] = Dictionary(
        uniqueKeysWithValues: PaneTone.allCases.map { ($0, GreyColors(tone: $0)) })

    static func colors(for tone: PaneTone) -> GreyColors { greyColors[tone] ?? GreyColors(tone: .neutral) }
    /// The greys of the current tone. Reading it inside a view body subscribes the view to the tone.
    static var current: GreyColors { colors(for: LoomTheme.ThemeState.shared.tone) }

    // MARK: Ink roles (each a `static var`: it follows the tone)

    static var canvas: Color { current.canvas }
    static var canvasNS: NSColor { current.canvasNS }
    static var raised1: Color { current.raised1 }
    static var raised2: Color { current.raised2 }
    static var popover: Color { current.popover }
    static var segmentOn: Color { current.segmentOn }
    static var tree: Color { current.tree }

    // MARK: Night Fleece names kept as aliases, by role

    /// The sidebar, the backdrop behind the detail pane, the inspector and the main pane are the canvas (one surface).
    static var sidebar: Color { canvas }
    static var backdrop: Color { canvas }
    static var inspector: Color { canvas }
    static var panel: Color { canvas }
    static var panelNS: NSColor { canvasNS }
    /// A card is raised 1.
    static var card: Color { raised1 }

    // MARK: The sidebar's fill and opacity (FB6-6, D-57)

    /// How far Deep sits from the canvas: 30 % toward black in Ink and 4 % toward the ink in Paper, so it is one step darker
    /// in both appearances and keeps the tone's cast.
    static let sidebarDeepInkShare = 0.30
    static let sidebarDeepPaperShare = 0.04

    /// A sidebar fill as data, for each appearance and tone: Canvas is the canvas, Raised is raised 1 (one step lighter, as
    /// the Claude desktop app's sidebar) and Deep is the canvas mixed toward black or the ink.
    static func sidebarFillRGB(_ fill: SidebarFill, appearance: LoomTheme.Appearance, tone: PaneTone) -> LoomTheme.RGB {
        let greys = greys(appearance, tone: tone)
        switch fill {
        case .canvas: return greys.canvas
        case .raised: return greys.raised1
        case .deep:
            return appearance == .dark
                ? greys.canvas.mixed(with: LoomTheme.blackRGB, share: sidebarDeepInkShare)
                : greys.canvas.mixed(with: LoomTheme.inkRGB, share: sidebarDeepPaperShare)
        }
    }

    /// A sidebar fill as a colour. Reading it in a view body subscribes that view to the tone.
    static func sidebarFillColor(_ fill: SidebarFill) -> Color {
        let tone = LoomTheme.ThemeState.shared.tone
        return LoomTheme.Adaptive(dark: sidebarFillRGB(fill, appearance: .dark, tone: tone),
                                  light: sidebarFillRGB(fill, appearance: .light, tone: tone)).color
    }

    /// The sidebar's opacity for a step (FB6-6): Solid is opaque; 90, 80 and 65 % draw the fill over what is behind the window.
    /// 80 % is the step 1.7.0 called Transparent (`sidebarTintOpacity`, RESCUE C3).
    static func sidebarTintOpacity(for opacity: SidebarOpacity) -> Double {
        switch opacity {
        case .solid: 1
        case .ninety: sidebarTintNinety
        case .eighty: sidebarTintOpacity
        case .sixtyFive: sidebarTintSixtyFive
        }
    }
}
