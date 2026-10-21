import SwiftUI

/// Values of the pages' top line and of the empty canvas (DESIGN §3 Colour's Grid row, §8 Header, §9 Column; the reference's
/// `.artbg`, `.dhead` and `.crumb`, `design/reference-src/shared/head.css`). `CanvasGrid` and `DraftHeaderLine` read these.
extension LoomTheme {
    /// The faint grid of an empty canvas: 1 pt lines every 28 pt, the pattern centred in the box, under a mask. The colour is
    /// `Surface.grid` (white 3.4 % on Ink, ink 6 % on Paper).
    enum Canvas {
        /// Which mask the grid fades under.
        enum Mask: Equatable, Sendable {
            /// The new-session page's: an ellipse of 78 % by 74 % of the box at 50 % by 46 %, opaque to 38 % of its radius.
            case radial
            /// Home's band: `bandHeight` high, opaque to 30 % of its height, then fading to nothing at its foot.
            case band
        }

        /// The grid's cell, and the width of a line.
        static let cell: CGFloat = 28
        static let line: CGFloat = 1

        /// The radial mask: the ellipse's centre as a share of the box, its radii as shares of the width and the height, and
        /// the share of the radius that stays opaque.
        static let radialCentre = CGPoint(x: 0.5, y: 0.46)
        static let radialRadii = CGSize(width: 0.78, height: 0.74)
        static let radialOpaque = 0.38

        /// The band: its height and the share of it that stays opaque.
        static let bandHeight: CGFloat = 300
        static let bandOpaque = 0.30

        /// What a mask keeps (opaque) and drops (clear); only the alpha counts.
        static let maskKeeps = Color.black
        static let maskDrops = Color.clear

        /// Where the lines of one axis sit in a box of `length`: the pattern is centred, so a cell's edge is at
        /// `(length - cell) / 2` and every `cell` from it; the first line is the one nearest the origin.
        static func lineOffsets(length: CGFloat) -> [CGFloat] {
            guard length > 0 else { return [] }
            var first = ((length - cell) / 2).truncatingRemainder(dividingBy: cell)
            if first < 0 { first += cell }
            return Array(stride(from: first, to: length, by: cell))
        }
    }

    /// The draft page's header line (DESIGN §8 Header): the crumb in mono 12, and a small ghost button with the clock glyph at
    /// the trailing end.
    enum DraftHeader {
        static let crumbFont = InkStyle(size: 12, mono: true).font
        /// The clock glyph and its gap from the words (the reference's `.btn` gap).
        static let glyph = Font.system(size: 12)
        static let glyphGap: CGFloat = 6
    }
}

private struct DetailLeadingClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far from the detail pane's leading edge a page keeps its content on the 26 pt centre line (the top 52 pt), so
    /// that the window's buttons and "Show Sidebar" over a page without a header row stay clear and usable. 0 while the
    /// sidebar is open (the buttons are in the sidebar then), or when the route draws its own header row. A page that puts
    /// content on that line uses `max(its own inset, detailLeadingClearance)` for its leading edge.
    var detailLeadingClearance: CGFloat {
        get { self[DetailLeadingClearanceKey.self] }
        set { self[DetailLeadingClearanceKey.self] = newValue }
    }
}
