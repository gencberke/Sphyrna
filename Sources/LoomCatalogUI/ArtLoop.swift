import CoreGraphics
import Foundation

// Home's loop (DESIGN §17 Home's loop, D-79; the reference's `shared/band.js`) and the seas the reference draws.

/// Home's band: one hammerhead on one fixed loop of 180 s, a wide flat ellipse, left along the top and back along the
/// bottom, whose turns fall out of sight past the band's edges. No plankton and no wake. A frame is a pure function of
/// the time, so the loop can be drawn live or worked out once (`ArtLoopFrames`).
struct ArtHomeLoop: Sendable {
    /// The loop: its period, and the ellipse's radii and centre as shares of the band (the reference's `LOOP`).
    static let period = 180.0
    static let radii = CGSize(width: 0.64, height: 0.13)
    static let centre = CGPoint(x: 0.5, y: 0.36)
    /// The hammerhead of the band (the reference's spec: 330 long, depth 0.66, speed 13).
    static let spec = ArtSharkSpec(kind: .hammerhead, length: 330, depth: 0.66, speed: 13)
    /// Tail beats in one loop. The reference's 0.42 a second gives 75.6, so its loop jumps at the seam; a whole, even
    /// number (76: the fin's half-rate flap closes too) makes frame 0 follow the last.
    static let beatsPerLoop = 76.0
    /// Where the loop is when its hammerhead comes back after Remora's arrival: its head at the band's left edge on the lower
    /// pass, heading right (the reference's `TH_BACK`, D-80).
    static var backTime: Double {
        let th = Double.pi + acos(Double(centre.x) / Double(radii.width))
        return (th - Double.pi / 2) / (Double.pi * 2) * period
    }

    let size: CGSize
    let metrics: ArtMetrics
    let alpha: Double
    let seed: UInt64
    private let shark: ArtShark

    init(size: CGSize, metrics: ArtMetrics, alpha: Double = LoomTheme.Art.bandAlpha, seed: UInt64 = 1) {
        self.size = size
        self.metrics = metrics
        self.alpha = alpha
        self.seed = seed
        var random = ArtRandom(seed: seed)
        shark = ArtShark(spec: Self.spec, index: 0, size: size, random: &random)
    }

    /// The loop's angle at `t`: it starts at the top's middle, heading left.
    static func angle(at t: Double) -> Double { t / period * Double.pi * 2 + Double.pi / 2 }

    /// The ellipse's point at angle `th`.
    func point(_ th: Double) -> CGPoint {
        CGPoint(x: Double(size.width) * (Double(Self.centre.x) + Double(Self.radii.width) * cos(th)),
                y: Double(size.height) * (Double(Self.centre.y) - Double(Self.radii.height) * sin(th)))
    }

    /// The hammerhead at `t` (any time; the loop repeats): on the ellipse, facing along it, its trail laid back along the
    /// ellipse a point every 4 pt, and its tail beat where the loop's clock has it.
    func shark(at t: Double) -> ArtShark {
        let local = t.truncatingRemainder(dividingBy: Self.period) + (t < 0 ? Self.period : 0)
        var s = shark
        let th = Self.angle(at: local), p = point(th), q = point(th + 0.002)
        s.x = Double(p.x)
        s.y = Double(p.y)
        s.heading = atan2(Double(q.y - p.y), Double(q.x - p.x))
        s.phase = shark.phase + 2 * Double.pi * Self.beatsPerLoop * local / Self.period
        s.trail = [p]
        let w = Double(size.width) * Double(Self.radii.width), h = Double(size.height) * Double(Self.radii.height)
        guard w > 0, h > 0 else { return s }
        var back = th, length = 0.0
        let reach = s.length * s.shape.reach + 24
        while length < reach {
            // A step of the angle that moves 4 pt along the ellipse here.
            let speed = hypot(w * sin(back), h * cos(back))
            back -= 4 / max(speed, 1e-6)
            s.trail.append(point(back))
            length += 4
        }
        return s
    }

    func frame(at t: Double, raster: ArtRaster) -> ArtFrame {
        ArtField.build(size: size, metrics: metrics, alpha: alpha, sharks: [shark(at: t)], plankton: [], wake: [], raster: raster)
    }
}

/// Home's loop worked out once: every frame of the 180 s at `fps`, each the packed list of its lit cells.
struct ArtLoopFrames: Sendable {
    let fps: Double
    let columns: Int
    let rows: Int
    /// Every frame's lit cells one after another, and where each frame starts.
    private let cells: [UInt32]
    private let starts: [Int32]

    init(loop: ArtHomeLoop, fps: Double = LoomTheme.Art.homeLoopFPS) {
        self.fps = fps
        columns = loop.metrics.columns(loop.size)
        rows = loop.metrics.rows(loop.size)
        let raster = ArtRaster()
        let count = Int((ArtHomeLoop.period * fps).rounded())
        var cells: [UInt32] = [], starts: [Int32] = []
        starts.reserveCapacity(count + 1)
        for k in 0..<count {
            starts.append(Int32(cells.count))
            cells += loop.frame(at: Double(k) / fps, raster: raster).packed
        }
        starts.append(Int32(cells.count))
        self.cells = cells
        self.starts = starts
    }

    var frameCount: Int { starts.count - 1 }

    /// The bytes the frames hold.
    var bytes: Int { cells.count * MemoryLayout<UInt32>.stride + starts.count * MemoryLayout<Int32>.stride }

    /// The frame drawn at `t`.
    func cells(at t: Double) -> ArraySlice<UInt32> {
        let local = t.truncatingRemainder(dividingBy: ArtHomeLoop.period) + (t < 0 ? ArtHomeLoop.period : 0)
        let k = min(frameCount - 1, Int((local * fps).rounded(.down)))
        return cells[Int(starts[k])..<Int(starts[k + 1])]
    }
}

/// The seas the reference draws, by surface (`design/reference-src/build.py`, `docs/*/`).
enum ArtScenes {
    /// The new-session page: two hammerheads crossing slowly with a whale shark deep below (DESIGN §8, §17).
    static let draft = [ArtSharkSpec(kind: .hammerhead, length: 420, depth: 0.6, speed: 15),
                        ArtSharkSpec(kind: .hammerhead, length: 270, depth: 0.95, speed: 21),
                        ArtSharkSpec(kind: .whale, length: 760, depth: 0.24, speed: 7)]

    /// One shark of the cast, swimming in place at the middle of its box (the reference's `inPlace`).
    static func inPlace(_ kind: ArtKind, length: Double) -> [ArtSharkSpec] {
        [ArtSharkSpec(kind: kind, length: length, depth: 1, speed: 0, place: CGPoint(x: 0.5, y: 0.5), angle: 0, center: true)]
    }

    /// The school document's cast (`docs/foundations/own.js`): each shark at its own length, in `LoomTheme.Art.castCell`.
    static let castLength: [ArtKind: Double] = [.hammerhead: 230, .thresher: 160, .remora: 170, .whale: 240]
}
