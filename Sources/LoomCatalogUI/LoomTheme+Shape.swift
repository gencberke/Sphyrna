import SwiftUI

/// The scale of radii, the type scale and the rhythm (concept §6.1) that views draw with today. Ink's own scale is in
/// `LoomTheme+Scale.swift`; the shadows are `LoomTheme+Depth.swift`.
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
        /// The Side tab (V22): the preview's 392 pt, wide enough for a chat column and its composer.
        static let inspectorWidthSide: CGFloat = 392
    }
}
