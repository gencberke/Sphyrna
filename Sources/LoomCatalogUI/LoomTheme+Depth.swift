import SwiftUI

/// Ink's depth (DESIGN §3 Tones → Depth): only lifted things cast a shadow. The values are the reference's `--sh-card`,
/// `--sh-pop`, `--sh-composer` and `--sh-win`, kept as data: a ring, an inset top highlight and the drops, each a colour at
/// an opacity, a CSS blur and a y offset. A CSS blur of B is a SwiftUI radius of about B / 2 (`ShadowLayer.radius`).
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
        /// A 1 pt ring around the surface (the `0 0 0 1px` layer); nil for none.
        let ring: Tone?
        /// A 1 pt highlight along the top inside edge (the `inset 0 1px 0` layer); nil for none.
        let insetHighlight: Tone?
        /// The drops, back to front.
        let drops: [ShadowLayer]
    }

    /// A depth with an Ink and a Paper value.
    struct AdaptiveDepth: Equatable, Sendable {
        let dark: Depth
        let light: Depth

        subscript(appearance: Appearance) -> Depth { appearance == .dark ? dark : light }
    }

    /// The four depths of the reference.
    enum Elevation {
        private static func black(_ opacity: Double) -> Tone { Tone(rgb: RGB(red: 0, green: 0, blue: 0), opacity: opacity) }
        private static func white(_ opacity: Double) -> Tone { Tone(rgb: whiteRGB, opacity: opacity) }
        private static func ink(_ opacity: Double) -> Tone { Tone(rgb: inkRGB, opacity: opacity) }

        /// A card: a 1 pt inner top highlight in Ink and a 1 to 2 pt drop.
        static let card = AdaptiveDepth(
            dark: Depth(ring: nil, insetHighlight: white(0.03), drops: [ShadowLayer(color: black(0.45), blur: 2, y: 1)]),
            light: Depth(ring: nil, insetHighlight: nil, drops: [ShadowLayer(color: ink(0.06), blur: 2, y: 1)]))
        /// A popover: a hairline ring and a 64 pt soft shadow.
        static let popover = AdaptiveDepth(
            dark: Depth(ring: white(0.08), insetHighlight: nil,
                        drops: [ShadowLayer(color: black(0.62), blur: 64, y: 24), ShadowLayer(color: black(0.4), blur: 8, y: 2)]),
            light: Depth(ring: ink(0.10), insetHighlight: nil,
                         drops: [ShadowLayer(color: ink(0.16), blur: 60, y: 24), ShadowLayer(color: ink(0.06), blur: 6, y: 2)]))
        /// The composer: a 12 % hairline ring and a 90 pt soft shadow.
        static let composer = AdaptiveDepth(
            dark: Depth(ring: white(0.12), insetHighlight: white(0.045), drops: [ShadowLayer(color: black(0.6), blur: 90, y: 30)]),
            light: Depth(ring: ink(0.12), insetHighlight: nil, drops: [ShadowLayer(color: ink(0.13), blur: 70, y: 24)]))
        /// The window: a hairline ring and a deep soft shadow.
        static let window = AdaptiveDepth(
            dark: Depth(ring: white(0.085), insetHighlight: nil, drops: [ShadowLayer(color: black(0.72), blur: 140, y: 50)]),
            light: Depth(ring: ink(0.13), insetHighlight: nil, drops: [ShadowLayer(color: ink(0.22), blur: 120, y: 50)]))
    }
}

extension View {
    /// Draws a depth's drops under this view (the ring and the highlight are strokes the view draws itself).
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
