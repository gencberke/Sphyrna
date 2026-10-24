import AppKit
import SwiftUI

/// The art's values (DESIGN §17, §3 Colour's Art row; the reference's `shared/engine.js`, `shared/band.js` and the seas of
/// `docs/*/`). The engine (`ArtEngine.swift`) holds the sharks' shapes; this holds what a surface draws them with: the
/// glyph grid, the colour, each surface's alpha and mask, and the frame-rate budget.
extension LoomTheme {
    enum Art {
        // MARK: The colour

        /// The sharks' colour, `#ECECF0` in Ink and `#161518` in Paper, drawn at each cell's alpha (`Surface.artPair`).
        static let colorPair = Surface.artPair

        // MARK: The grid of glyphs

        /// A cell is one character of SF Mono at the surface's cell size: as wide as an `M` and `lineFactor` of the size
        /// high, rounded (the reference's `cw` and `ch`).
        static let lineFactor = 1.22

        /// The art's font: SF Mono at the cell size. The resting remora draws semibold (DESIGN §17 Quiet).
        static func font(cell: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: cell, weight: weight)
        }

        /// The cell size of each surface (the reference's `cell`).
        static let ambientCell: CGFloat = 11
        static let bandCell: CGFloat = 11
        static let inPlaceCell: CGFloat = 6
        /// The school document's cast of four, each shark in place in its own box.
        static let castCell: CGFloat = 8

        // MARK: Each surface's alpha (DESIGN §17 Quiet; the reference's numbers)

        /// The new-session page: about 0.5.
        static let draftAlpha = 0.5
        /// Home's band: about 0.4 (the reference draws 0.36).
        static let bandAlpha = 0.36
        /// A small shark in a pane, swimming in place: about 0.7 (the reference draws 0.72).
        static let inPlaceAlpha = 0.72

        // MARK: The masks over the art (the reference's `.ocean.calm` and `.ocean.band`)

        /// The new-session page's calm mask: an ellipse of 40 % by 30 % of the box at 50 % by 40 %, keeping `calmCentre`
        /// of the art at its middle and all of it from `calmOpaque` of the radius out, so the question reads clear.
        static let calmCentrePoint = CGPoint(x: 0.5, y: 0.4)
        static let calmRadii = CGSize(width: 0.4, height: 0.3)
        static let calmCentre = 0.22
        static let calmOpaque = 0.85
        /// Home's band: the art is whole to `bandOpaque` of the band's height and fades to nothing at its foot.
        static let bandOpaque = 0.45

        // MARK: The budget (DESIGN §17 The budget)

        /// Ambient art: at most 24 frames a second.
        static let ambientFPS = 24.0
        /// A shark in place and Home's loop: at most 12.
        static let inPlaceFPS = 12.0
        static let homeLoopFPS = 12.0
        /// The longest step the art takes after a late frame (the reference's 0.1 s clamp), so a pause does not jump.
        static let longestStep = 0.1
        /// Alphas are drawn in steps of 1/`alphaSteps` (the reference's buckets).
        static let alphaSteps = 40.0

        // MARK: The new-session page (the reference's `ocean-draft`)

        static let draftPlankton = 26

        // MARK: The first launch (the reference's `school()` in `docs/edges/edge.js`, `#ocean-first`)

        static let firstCell: CGFloat = 10
        /// About 0.45 (the reference draws 0.44).
        static let firstAlpha = 0.44
        static let firstPlankton = 14
        /// The hammerhead comes in from the right: its head at the right edge, 30 % down, facing left.
        static let firstEntry = CGPoint(x: 1, y: 0.3)
        /// Fainter in the message's middle: an ellipse of 42 % by 36 % at 51 % by 47 %, keeping 0.14 of the art at its middle,
        /// 0.26 at 70 % of the radius and all of it at the edge.
        static let firstMaskCentrePoint = CGPoint(x: 0.51, y: 0.47)
        static let firstMaskRadii = CGSize(width: 0.42, height: 0.36)
        static let firstMaskCentre = 0.14
        static let firstMaskInner = 0.26
        static let firstMaskInnerAt = 0.7
        /// The remoras keep to the big two: their length, depth, speed, host (0 the hammerhead, 1 the whale shark) and their
        /// spot by its flank (along and across, as shares of the host's length).
        static let firstRemoras: [(length: Double, depth: Double, host: Int, spot: CGPoint)] = [
            (84, 0.85, 1, CGPoint(x: -0.22, y: 0.15)), (72, 0.75, 1, CGPoint(x: -0.4, y: -0.14)),
            (78, 0.8, 0, CGPoint(x: -0.3, y: 0.2)), (66, 0.7, 1, CGPoint(x: -0.05, y: -0.17))]
        static let firstRemoraSpeed = 18.0

        // MARK: About (the reference's `aboutSea()` in `docs/settings/settings.js`)

        static let aboutCell: CGFloat = 9
        static let aboutAlpha = 0.5
        static let aboutPlankton = 10
        /// The art's height from the top of the page, behind the icon.
        static let aboutHeight: CGFloat = 250
        /// It starts 30 % of the width left of the page, 30 % down, crosses at 72 pt a second and rests at 88 % of the width.
        static let aboutStart = CGPoint(x: -0.3, y: 0.3)
        static let aboutSpeed = 72.0
        static let aboutLength = 170.0
        static let aboutRest = 0.88

        // MARK: The small sharks in panes (the reference's `inPlace` in `docs/foundations/own.js` and `docs/review/review.js`)

        static let waitingLength = 100.0
        static let emptyAgentsLength = 130.0
        static let emptyChangesLength = 92.0
        static let emptySideLength = 210.0
        static let emptyProjectLength = 120.0
        /// The art's box: the empty Side tab's (the reference's `.empty canvas`) and the empty project's (`.pempty canvas`).
        static let sideBoxHeight: CGFloat = 80
        static let sideBoxTop: CGFloat = 56
        static let projectBoxHeight: CGFloat = 110
        static let projectLineTop: CGFloat = 6

        // MARK: Remora's face on Home

        /// A new brief fades Remora's face in over this long (instantly under Reduce Motion).
        static let remoraFadeIn = 0.6
    }
}
