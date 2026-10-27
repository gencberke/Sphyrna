import SwiftUI

/// Ink v4's depth (DESIGN §0.3, Elevation): three levels and no fourth. Only lifted things cast a shadow: a level 1 surface is a
/// hairline, a level 2 one a hairline and a small drop, and a level 3 one floats. The values are the reference's `--sh-lift`
/// and `--sh-pop`, kept as data: a ring and each drop, a colour at an opacity, a CSS blur and a y offset. A CSS blur of B is a
/// SwiftUI radius of about B / 2 (`ShadowLayer.radius`). The hairline is drawn by the view, not by the depth.
extension LoomTheme {
    /// One drop of a shadow.
    struct ShadowLayer: Equatable, Sendable {
        let color: Tone
        /// The CSS blur; SwiftUI's radius is about half of it.
        let blur: CGFloat
        let y: CGFloat

        var radius: CGFloat { blur / 2 }
    }

    /// A surface's depth in one appearance.
    struct Depth: Equatable, Sendable {
        /// A 1 pt ring around the surface (the `0 0 0 1px` layer of a floating surface); nil for none.
        let ring: Tone?
        /// The drops, back to front.
        let drops: [ShadowLayer]
    }

    /// A depth with an Ink and a Paper value.
    struct AdaptiveDepth: Equatable, Sendable {
        let dark: Depth
        let light: Depth

        subscript(appearance: Appearance) -> Depth { appearance == .dark ? dark : light }
    }

    /// The three elevations of Ink v4 (DESIGN §0.3).
    enum Elevation {
        private static func black(_ opacity: Double) -> Tone { Tone(rgb: RGB(red: 0, green: 0, blue: 0), opacity: opacity) }
        private static func white(_ opacity: Double) -> Tone { Tone(rgb: whiteRGB, opacity: opacity) }
        private static func ink(_ opacity: Double) -> Tone { Tone(rgb: inkRGB, opacity: opacity) }

        /// 1. A hairline and no drop: almost everything, cards included. Its hairline is the view's own.
        static let card = AdaptiveDepth(
            dark: Depth(ring: nil, drops: []),
            light: Depth(ring: nil, drops: []))
        /// 2. A hairline and a small drop (`0 1 2`, black 20 % in Ink, ink 6 % in Paper): outline buttons, the selected segment, the
        /// selected session card and the composer.
        static let lift = AdaptiveDepth(
            dark: Depth(ring: nil, drops: [ShadowLayer(color: black(0.20), blur: 2, y: 1)]),
            light: Depth(ring: nil, drops: [ShadowLayer(color: ink(0.06), blur: 2, y: 1)]))
        /// 3. Floating: a hairline and a `0 10 24` drop (black 35 % in Ink, ink 14 % in Paper): popovers, menus, the palette, the
        /// model panel and sheets.
        static let popover = AdaptiveDepth(
            dark: Depth(ring: white(0.08), drops: [ShadowLayer(color: black(0.35), blur: 24, y: 10)]),
            light: Depth(ring: ink(0.10), drops: [ShadowLayer(color: ink(0.14), blur: 24, y: 10)]))
    }
}

extension View {
    /// Draws a depth's drops under this view (the ring is a stroke the view draws itself).
    func depth(_ depth: LoomTheme.AdaptiveDepth, x: CGFloat = 0) -> some View {
        modifier(DepthShadow(depth: depth, x: x))
    }
}

private struct DepthShadow: ViewModifier {
    let depth: LoomTheme.AdaptiveDepth
    let x: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        depth[LoomTheme.Appearance(scheme)].drops.reduce(AnyView(content)) { view, drop in
            AnyView(view.shadow(color: drop.color.color, radius: drop.radius, x: x, y: drop.y))
        }
    }
}
