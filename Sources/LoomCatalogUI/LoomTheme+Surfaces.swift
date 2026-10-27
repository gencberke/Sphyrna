import AppKit
import SwiftUI

/// Ink's greys (design/DESIGN.md §0.1, Ink v4, and §3 Tones): canvas, sidebar, card (raised 1), raised (raised 2), popover, muted,
/// segment on and tree, in both appearances and the three tones (Neutral, Warm, Cool). Values are `RGB` data first so the contrast
/// tests can compute them; the `Color` is derived. The Night Fleece names (`backdrop`, `inspector`, `panel`, `card`, ...) stay as
/// aliases by role below, so a view that was not redrawn yet draws Ink.
extension LoomTheme.Surface {
    /// The eight greys of one appearance and tone.
    struct Greys: Equatable, Sendable {
        /// The window: the main pane, the inspector, the header and the tab row; the terminal face's whole pane.
        let canvas: LoomTheme.RGB
        /// The sidebar plane, one step from the content (Ink v4's Sidebar; the sidebar's "Raised" fill).
        let sidebar: LoomTheme.RGB
        /// Cards: Home's lists and side cards, Settings' groups, the inspector's sections (Ink v4's Card).
        let raised1: LoomTheme.RGB
        /// The composer, the selected session card (Ink v4's Raised).
        let raised2: LoomTheme.RGB
        /// Menus, pickers, the palette, the overlaid inspector, the quick question.
        let popover: LoomTheme.RGB
        /// Secondary buttons, a segmented control's track, badges and the status bar's meter track.
        let muted: LoomTheme.RGB
        /// The chosen segment of a segmented control: the canvas in Ink, white in Paper.
        let segmentOn: LoomTheme.RGB
        /// The subagent branches; opaque, so crossing lines never brighten.
        let tree: LoomTheme.RGB

        /// The levels text sits on, back to front.
        var levels: [LoomTheme.RGB] { [canvas, raised1, raised2, popover] }
    }

    /// The table of DESIGN §0.1 (Ink v4): Neutral is Ink's own greys, Warm and Cool are casts over them. The casts are the
    /// reference's v4 blocks (`design/reference-src/shared/head.css`), which recompute the greys from v4's neutrals. The tree keeps
    /// v3's value, as §0.1 does not name it.
    static func greys(_ appearance: LoomTheme.Appearance, tone: PaneTone) -> Greys {
        func make(_ values: [UInt32]) -> Greys {
            Greys(canvas: LoomTheme.RGB(hex: values[0]), sidebar: LoomTheme.RGB(hex: values[1]),
                  raised1: LoomTheme.RGB(hex: values[2]), raised2: LoomTheme.RGB(hex: values[3]),
                  popover: LoomTheme.RGB(hex: values[4]), muted: LoomTheme.RGB(hex: values[5]),
                  segmentOn: LoomTheme.RGB(hex: values[6]), tree: LoomTheme.RGB(hex: values[7]))
        }
        switch (appearance, tone) {
        case (.dark, .neutral): return make([0x0A0A0A, 0x161616, 0x171717, 0x1E1E1E, 0x1C1C1C, 0x262626, 0x0A0A0A, 0x3B3B41])
        case (.light, .neutral): return make([0xFFFFFF, 0xF7F7F7, 0xFFFFFF, 0xFAFAFA, 0xFFFFFF, 0xF4F4F5, 0xFFFFFF, 0xC4C2BE])
        case (.dark, .warm): return make([0x0C0A08, 0x181512, 0x191613, 0x201A16, 0x1E1915, 0x2A231C, 0x0C0A08, 0x433C34])
        case (.light, .warm): return make([0xFFFDF9, 0xFAF5EF, 0xFFFFFF, 0xFDF8F2, 0xFFFFFF, 0xF7F1E9, 0xFFFFFF, 0xCFC4B3])
        case (.dark, .cool): return make([0x080A0C, 0x121619, 0x131719, 0x191D24, 0x171B21, 0x20262E, 0x080A0C, 0x363E4C])
        case (.light, .cool): return make([0xFFFFFF, 0xF3F5F8, 0xFFFFFF, 0xF8FAFC, 0xFFFFFF, 0xF0F3F6, 0xFFFFFF, 0xBCC2CB])
        }
    }

    /// The terminal face's background: the tone's Ink canvas in both appearances (the face is dark in Paper too).
    static func terminalBackground(tone: PaneTone) -> LoomTheme.RGB { greys(.dark, tone: tone).canvas }

    /// The greys of one tone as colours, built once. Each resolves per appearance.
    struct GreyColors {
        let canvas: Color
        let sidebar: Color
        let raised1: Color
        let raised2: Color
        let popover: Color
        let muted: Color
        let segmentOn: Color
        let tree: Color
        let canvasNS: NSColor

        init(tone: PaneTone) {
            let dark = LoomTheme.Surface.greys(.dark, tone: tone), light = LoomTheme.Surface.greys(.light, tone: tone)
            func pair(_ path: KeyPath<Greys, LoomTheme.RGB>) -> LoomTheme.Adaptive {
                LoomTheme.Adaptive(dark: dark[keyPath: path], light: light[keyPath: path])
            }
            canvas = pair(\.canvas).color
            sidebar = pair(\.sidebar).color
            raised1 = pair(\.raised1).color
            raised2 = pair(\.raised2).color
            popover = pair(\.popover).color
            muted = pair(\.muted).color
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
    static var sidebar: Color { current.sidebar }
    static var raised1: Color { current.raised1 }
    static var raised2: Color { current.raised2 }
    static var popover: Color { current.popover }
    static var muted: Color { current.muted }
    static var segmentOn: Color { current.segmentOn }
    static var tree: Color { current.tree }

    // MARK: Night Fleece names kept as aliases, by role

    /// The backdrop behind the detail pane and the main pane are the canvas (one surface).
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

    /// A sidebar fill as data, for each appearance and tone: Canvas is the canvas, Raised is the sidebar plane (Ink v4's Sidebar,
    /// one step lighter than the content) and Deep is the canvas mixed toward black or the ink.
    static func sidebarFillRGB(_ fill: SidebarFill, appearance: LoomTheme.Appearance, tone: PaneTone) -> LoomTheme.RGB {
        let greys = greys(appearance, tone: tone)
        switch fill {
        case .canvas: return greys.canvas
        case .raised: return greys.sidebar
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
