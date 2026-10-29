import CoreGraphics
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// I5's spike, the engine as plain values (DESIGN §17 How they are drawn, Home's loop): the ramp, the eyes, the whale
/// shark's spots, the remora's disc by facing, a sea's determinism for a seed and a time, and Home's loop.
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ArtEngineTests {
    /// Home's band and the new-session page in the reference's 1280 pt window, less its 260 pt sidebar and hairline.
    static let band = CGSize(width: 1019, height: 300)
    static let draft = CGSize(width: 1019, height: 880)

    private func castFrame(_ kind: ArtKind, angle: Double = 0, size: CGSize = CGSize(width: 420, height: 240)) -> ArtFrame {
        let metrics = ArtMetrics.mono(cell: LoomTheme.Art.castCell)
        let spec = ArtSharkSpec(kind: kind, length: ArtScenes.castLength[kind] ?? 200, depth: 1, speed: 0,
                                place: CGPoint(x: 0.5, y: 0.5), angle: angle, center: true)
        let sea = ArtSea(size: size, metrics: metrics, options: .init(alpha: LoomTheme.Art.inPlaceAlpha, plankton: 0, wake: false),
                         specs: [spec], seed: 7)
        return sea.frame(raster: ArtRaster())
    }

    // MARK: The ramp

    @Test func theRampIsTheTenCharactersAndCoverageClimbsIt() {
        #expect(String(ArtGlyphs.ramp) == " .:-=+*#%@")
        #expect(ArtGlyphs.table[0] == " ")
        // A trace of coverage is the faintest mark, full coverage the densest, and half lands in the middle.
        #expect(ArtGlyphs.table[Int(ArtGlyphs.code(coverage: 0.05))] == ".")
        #expect(ArtGlyphs.table[Int(ArtGlyphs.code(coverage: 0.5))] == "+")
        #expect(ArtGlyphs.table[Int(ArtGlyphs.code(coverage: 1))] == "@")
        let codes = stride(from: 0.05, through: 1, by: 0.05).map { ArtGlyphs.code(coverage: $0) }
        #expect(codes == codes.sorted(), "denser coverage never picks a lighter glyph")
        // A shark's body is drawn from the ramp, densest at its core.
        let frame = castFrame(.hammerhead)
        let ramp = (1...9).map { frame.count(of: UInt8($0)) }
        #expect(ramp.reduce(0, +) > 100, "\(ramp)")
        #expect(ramp[8] + ramp[7] > 0, "the core reaches the dense end: \(ramp)")
    }

    // MARK: Eyes and spots

    @Test func everySharkHasItsEyesAndOnlyTheWhaleSharkHasSpots() {
        for kind in ArtKind.allCases {
            let frame = castFrame(kind)
            let eyes = frame.count(of: ArtGlyphs.eye), spots = frame.count(of: ArtGlyphs.spot)
            #expect(ArtGlyphs.table[Int(ArtGlyphs.eye)] == "o")
            // The thresher's eyes sit close on its narrow head and may share a cell.
            if kind == .thresher { #expect((1...2).contains(eyes), "\(kind): \(eyes) eyes") } else { #expect(eyes == 2, "\(kind): \(eyes) eyes") }
            if kind == .whale {
                #expect(ArtGlyphs.table[Int(ArtGlyphs.spot)] == "\u{00B0}")
                #expect(spots >= 10, "the whale shark is known by its spots: \(spots)")
            } else {
                #expect(spots == 0, "\(kind) has no spots")
            }
        }
    }

    @Test func theHammerheadsEyesAreAtTheTipsOfItsHammer() throws {
        let frame = castFrame(.hammerhead)
        let lines = frame.text.split(separator: "\n", omittingEmptySubsequences: false)
        let rows = lines.indices.filter { lines[$0].contains("o") }
        // Facing right, the hammer runs across the body, so the eyes are far apart, one above and one below the head.
        let first = try #require(rows.first), last = try #require(rows.last)
        let span = ArtScenes.castLength[.hammerhead]! * 0.17 * 0.95 * 2
        #expect(Double(last - first) * ArtMetrics.mono(cell: LoomTheme.Art.castCell).cellHeight >= span * 0.7, "\(rows)")
    }

    // MARK: The remora's disc

    @Test func theDiscIsABarAcrossTheHeadWhicheverWayTheRemoraFaces() {
        // The bar for a direction across the head, on the y-down plane.
        #expect(ArtGlyphs.bar(0) == ArtGlyphs.barLevel)
        #expect(ArtGlyphs.bar(Double.pi / 2) == ArtGlyphs.barUpright)
        #expect(ArtGlyphs.bar(Double.pi / 4) == ArtGlyphs.barFalling)
        #expect(ArtGlyphs.bar(3 * Double.pi / 4) == ArtGlyphs.barRising)
        for angle in stride(from: -3.0, through: 3.0, by: 0.37) {
            #expect(ArtGlyphs.bar(angle) == ArtGlyphs.bar(angle + Double.pi), "a bar has no head: \(angle)")
        }
        #expect([16, 17, 18, 19].map { ArtGlyphs.table[$0] } == ["|", "/", "-", "\\"])

        // Facing right the plates stand upright; facing down they lie level; down-right they rise; up-right they fall.
        let facings: [(Double, UInt8)] = [(0, ArtGlyphs.barUpright), (Double.pi / 2, ArtGlyphs.barLevel),
                                          (Double.pi / 4, ArtGlyphs.barRising), (-Double.pi / 4, ArtGlyphs.barFalling)]
        let bars: [UInt8] = [ArtGlyphs.barUpright, ArtGlyphs.barRising, ArtGlyphs.barLevel, ArtGlyphs.barFalling]
        for (angle, expected) in facings {
            let frame = castFrame(.remora, angle: angle, size: CGSize(width: 320, height: 320))
            #expect(frame.count(of: expected) >= 6, "facing \(angle): \(bars.map { frame.count(of: $0) })")
            for other in bars where other != expected {
                #expect(frame.count(of: other) == 0, "facing \(angle) draws no \(ArtGlyphs.table[Int(other)])")
            }
        }
        // No other shark has a disc.
        for kind in ArtKind.allCases where kind != .remora {
            let frame = castFrame(kind)
            #expect(bars.allSatisfy { frame.count(of: $0) == 0 }, "\(kind)")
        }
    }

    // MARK: Determinism

    @Test func aSeaIsTheSameForTheSameSeedAndTime() {
        let metrics = ArtMetrics.mono(cell: LoomTheme.Art.ambientCell)
        func sea(_ seed: UInt64) -> ArtSea {
            ArtSea(size: Self.draft, metrics: metrics, options: .init(alpha: LoomTheme.Art.draftAlpha), specs: ArtScenes.draft, seed: seed)
        }
        var a = sea(42), b = sea(42), c = sea(43)
        // The same 12.5 s in different slices.
        a.advance(by: 12.5)
        for _ in 0..<25 { b.advance(by: 0.5) }
        c.advance(by: 12.5)
        let raster = ArtRaster()
        let fa = a.frame(raster: raster), fb = b.frame(raster: raster), fc = c.frame(raster: raster)
        #expect(fa == fb)
        #expect(fa != fc, "another seed is another sea")
        #expect(fa.count(of: ArtGlyphs.moteDot) + fa.count(of: ArtGlyphs.moteMiddle) > 0, "plankton drifts")
        #expect(fa.count(of: ArtGlyphs.wakeFar) + fa.count(of: ArtGlyphs.wakeNear) > 0, "a faint wake follows")
        // And it moves.
        a.advance(by: 1)
        #expect(a.frame(raster: raster) != fa)
    }

    // MARK: Home's loop

    @Test func homesLoopIsOneHammerheadOnA180SecondEllipseWhoseTurnsAreOutOfSight() {
        let metrics = ArtMetrics.mono(cell: LoomTheme.Art.bandCell)
        let loop = ArtHomeLoop(size: Self.band, metrics: metrics)
        let raster = ArtRaster()
        #expect(ArtHomeLoop.period == 180)
        // The loop repeats.
        #expect(loop.frame(at: 37, raster: raster) == loop.frame(at: 37 + 180, raster: raster))
        #expect(loop.frame(at: 37, raster: raster) != loop.frame(at: 38, raster: raster))
        // Its tail beat closes at the seam: a whole and even number of beats in one loop.
        #expect(ArtHomeLoop.beatsPerLoop.truncatingRemainder(dividingBy: 2) == 0)

        // Left along the top, back along the bottom.
        let top = loop.shark(at: 0), bottom = loop.shark(at: 90)
        #expect(cos(top.heading) < -0.99 && bottom.y > top.y && cos(bottom.heading) > 0.99)
        #expect(loop.frame(at: 0, raster: raster).count(of: ArtGlyphs.eye) == 2)
        #expect(loop.frame(at: 90, raster: raster).count(of: ArtGlyphs.eye) == 2)

        // The turns, a quarter and three quarters round, fall past the band's edges, and so do the eyes there.
        let left = loop.shark(at: 45), right = loop.shark(at: 135)
        #expect(left.x < 0 && right.x > Double(Self.band.width), "\(left.x) \(right.x)")
        #expect(loop.frame(at: 45, raster: raster).count(of: ArtGlyphs.eye) == 0)
        #expect(loop.frame(at: 135, raster: raster).count(of: ArtGlyphs.eye) == 0)

        // No plankton and no wake, anywhere on the loop; and it is always there.
        let quiet: [UInt8] = [ArtGlyphs.moteDot, ArtGlyphs.moteMiddle, ArtGlyphs.wakeFar, ArtGlyphs.wakeNear]
        for t in stride(from: 0.0, to: 180, by: 7.5) {
            let frame = loop.frame(at: t, raster: raster)
            #expect(quiet.allSatisfy { frame.count(of: $0) == 0 }, "t \(t)")
            #expect(frame.codes.contains { (1...9).contains($0) }, "the hammerhead is in the band at \(t)")
        }

        // Worked out once, it is the same frames: 12 a second for 180 s.
        let frames = ArtLoopFrames(loop: loop, fps: 0.5)
        #expect(frames.frameCount == 90)
        #expect(Array(frames.cells(at: 38)) == loop.frame(at: 38, raster: raster).packed)
        #expect(Array(frames.cells(at: 38 + 180)) == loop.frame(at: 38, raster: raster).packed)
        #expect(Int((ArtHomeLoop.period * LoomTheme.Art.homeLoopFPS).rounded()) == 2160)
    }
}
