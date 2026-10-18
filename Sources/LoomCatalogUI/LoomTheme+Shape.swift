import SwiftUI

/// Night Fleece 2 shape, type, rhythm and shadows (concept §6.1). New names beside today's roles in
/// `Radius`, `Typography` and `Layout`; nothing here replaces a value a surface draws with today.
extension LoomTheme.Radius {
    /// The radius scale: 4 · 6 · 8 · 10 · 14 · 18.
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 14
    static let xxl: CGFloat = 18
    /// Pinned cards and Home blocks; a floating surface is not nested in its panel's corner (concept §6.5).
    static let block: CGFloat = 12
    /// The composer and the palette.
    static let floating = xl
}

extension LoomTheme {
    /// The v2 type scale: Display 24 · Title 17 · Reading 14/22 · Body 13 · Small 12 · Label 11 medium ·
    /// Mono 12 · Terminal 14. Reading is adjustable 13–15 in Settings later; these are the defaults.
    enum TypeScale {
        static let display = Font.system(size: 24, weight: .semibold)
        static let title = Font.system(size: 17, weight: .semibold)
        static let readingSize: CGFloat = 14
        static let readingLineHeight: CGFloat = 22
        static let reading = Font.system(size: readingSize)
        static let body = Font.system(size: 13)
        static let small = Font.system(size: 12)
        static let label = Font.system(size: 11, weight: .medium)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let terminalSize: CGFloat = 14
    }

    /// Rhythm: a 4 pt grid, the reading column, the session card row and the inspector.
    enum Rhythm {
        static let grid: CGFloat = 4
        static let readingColumn: CGFloat = 700
        static let sessionCardRow: CGFloat = 46
        static let inspectorWidth: CGFloat = 328
        static let inspectorWidthReview: CGFloat = 556
    }

    /// One layer of a shadow: black at `opacity`, `blur` points soft, `y` points down.
    struct ShadowLayer: Equatable, Sendable {
        let opacity: Double
        let blur: CGFloat
        let y: CGFloat
    }

    /// A surface's depth. Card: an inset top highlight and a 2 pt drop. Raised: 28 pt soft. Popover: 64 pt
    /// soft with a hairline ring.
    struct Depth: Equatable, Sendable {
        /// White at this opacity along the top inside edge; zero for none.
        let topHighlight: Double
        let shadow: ShadowLayer
        /// A hairline ring (white at this opacity) around the surface; zero for none.
        let ring: Double

        static let card = Depth(topHighlight: 0.03, shadow: ShadowLayer(opacity: 0.25, blur: 2, y: 1), ring: 0)
        static let raised = Depth(topHighlight: 0, shadow: ShadowLayer(opacity: 0.32, blur: 28, y: 10), ring: 0)
        static let popover = Depth(topHighlight: 0, shadow: ShadowLayer(opacity: 0.55, blur: 64, y: 24), ring: 0.08)

        /// A shadow's colour: black at the layer's opacity in Dark, the warm ink at 45 % of it in Light, where the same
        /// black would read as a stain on paper.
        static func shadowColor(_ opacity: Double) -> Color {
            AdaptiveTone(dark: Tone(rgb: RGB(red: 0, green: 0, blue: 0), opacity: opacity),
                         light: Tone(rgb: inkRGB, opacity: opacity * 0.45)).color
        }
    }
}
