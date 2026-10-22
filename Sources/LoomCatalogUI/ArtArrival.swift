import CoreGraphics
import Foundation

// Remora's arrival on Home and the remora at rest (DESIGN §9 The arrival, §17 The budget, §20; the reference's `Arrival` in
// `design/reference-src/docs/remora/remora.js`): the art's one scripted motion. The band's hammerhead swims in from the right
// with the remora on its flank, lets it go at the brief's start and swims on out to the left; the remora turns up to its
// place, swims in place while Remora reads, and holds still once the brief is written. Plain values, stepped by the view's
// clock; a test steps it by hand.

/// One lane of the remora: the arrival as it plays, or the remora alone at its place.
struct ArtArrival: Sendable {
    /// Where the arrival is.
    enum Stage: Equatable, Sendable {
        /// The host swims in with the remora on its flank (until 1.3 s).
        case swimmingIn
        /// The remora has let go and turns up to its place (until 2.2 s): the 60 fps part.
        case turning
        /// At its place: it settles, swims while Remora reads, then slows (12 fps).
        case inPlace
        /// Still, at its place: one frame and no timer.
        case resting
    }

    private typealias A = LoomTheme.Art

    let size: CGSize
    let metrics: ArtMetrics
    /// The remora's head at rest, in the lane's points (y down).
    let rest: CGPoint
    private(set) var host: ArtShark
    private(set) var rider: ArtShark
    private(set) var time = 0.0
    /// The host has left at the left.
    private(set) var hostGone = false
    /// When it left, on the arrival's clock.
    private var goneAt: Double?
    /// The band may have its hammerhead back: `bandBackDelay` after the host left, on the arrival's own clock (so no timer
    /// runs for it), or at once when the arrival is cut short.
    private(set) var bandReleased = false
    private(set) var stage: Stage
    private var speed = 0.0
    private var dropSpeed = 0.0
    private var path: [(point: CGPoint, s: Double)] = []
    private var pathLength = 0.0
    private var restTrail: [CGPoint] = []
    private var settleFrom: [CGPoint] = []
    /// When the remora stopped having a reason to swim (Remora's sentence came in), once at its place.
    private var quietSince: Double?
    private let x0: Double
    private let x1: Double
    private let y0: Double
    private let y1: Double

    /// A lane of `size` whose remora rests with its head at `rest`. `arriving` plays the arrival from its start; otherwise the
    /// remora is already at its place, still.
    init(size: CGSize, metrics: ArtMetrics, rest: CGPoint, arriving: Bool, seed: UInt64 = 2) {
        self.size = size
        self.metrics = metrics
        self.rest = rest
        var random = ArtRandom(seed: seed)
        host = ArtShark(spec: ArtSharkSpec(kind: .hammerhead, length: A.arrivalHostLength, depth: A.arrivalHostDepth, speed: 0),
                        index: 0, size: size, random: &random)
        rider = ArtShark(spec: ArtSharkSpec(kind: .remora, length: A.remoraLength, depth: 1, speed: 0), index: 1, size: size,
                         random: &random)
        let th = A.remoraRise, r = A.arrivalTurn
        let lane = Double(rest.y) - A.arrivalApproach * sin(th) + r * cos(th) + r
        y1 = lane + host.halfWidth(A.arrivalRideAt) + rider.halfWidth(0.22) * 0.6
        y0 = y1 - 26
        x0 = Double(size.width) + 24
        x1 = Double(rest.x) - A.arrivalApproach * cos(th) - r * sin(th) + A.arrivalLead - A.arrivalRideAt * host.length
        stage = arriving ? .swimmingIn : .resting
        if arriving {
            host.phase = 1.2
            rider.phase = 0.4
            host.speed = 1
            host.pose(x: x0, y: y0, heading: Double.pi, bend: 0)
            Self.ride(host, &rider)
        } else {
            settle()
        }
    }

    /// The surface kind its stage draws at: 60 frames a second while the remora is carried and turns, 12 at its place, then none.
    var kind: ArtSurfaceKind {
        switch stage {
        case .swimmingIn, .turning: .arrival
        case .inPlace: .inPlace
        case .resting: .resting
        }
    }

    /// The sharks drawn now: the pair, then the remora alone once the host has left.
    var sharks: [ArtShark] { hostGone || stage == .resting ? [rider] : [host, rider] }

    func frame(raster: ArtRaster) -> ArtFrame {
        ArtField.build(size: size, metrics: metrics, alpha: A.remoraAlpha, sharks: sharks, plankton: [], wake: [], raster: raster)
    }

    /// The remora at its place, still (the arrival's end, Animated art off, and every state with no new brief).
    mutating func settle() {
        rider.pose(x: Double(rest.x), y: Double(rest.y), heading: A.remoraRise, bend: A.remoraBend)
        rider.speed = 0
        rider.phase = A.remoraRestPhase
        hostGone = true
        bandReleased = true
        stage = .resting
    }

    /// Moves the arrival on by `dt`. `swimming` says whether the remora has a reason to swim at its place (Remora reads, and
    /// its sentence has not come in yet). Returns true on the step the band may have its hammerhead back.
    @discardableResult
    mutating func step(by dt: Double, swimming: Bool) -> Bool {
        guard stage != .resting else { return false }
        time += dt
        let t = time, tau = Double.pi * 2
        var left = false
        if t < A.arrivalInEnd {
            let u = t / A.arrivalInEnd, a = 0.45, d = x0 - x1, e = a * u + (1 - a) * (2 * u - u * u)
            speed = d / A.arrivalInEnd * (a + (1 - a) * 2 * (1 - u))
            Self.moveHead(&host, x: x0 - d * e, y: y0 + (y1 - y0) * (1 - pow(1 - u, 3)))
            host.phase += dt * tau * (host.shape.beat + speed / 320)
            Self.ride(host, &rider)
            rider.phase += dt * tau * rider.shape.beat * 0.6
            return false
        }
        if path.isEmpty { letGo() }
        if !hostGone {
            let k = min(1, (t - A.arrivalInEnd) / 0.5), v = dropSpeed + (700 - dropSpeed) * k * k * (3 - 2 * k), angle = Double.pi - 0.12 * k
            Self.moveHead(&host, x: host.x + cos(angle) * v * dt, y: host.y + sin(angle) * v * dt)
            host.phase += dt * tau * (host.shape.beat + v / 320)
            if host.x < -host.length * 1.4 {
                hostGone = true
                goneAt = t
            }
        }
        if let goneAt, !bandReleased, t - goneAt >= A.bandBackDelay {
            bandReleased = true
            left = true
        }
        if t < A.arrivalTurnEnd {
            stage = .turning
            let span = A.arrivalTurnEnd - A.arrivalInEnd, u = (t - A.arrivalInEnd) / span, v0 = dropSpeed * span, total = pathLength
            let s = v0 * (u - 2 * u * u + u * u * u) + total * (3 * u * u - 2 * u * u * u)
            let sp = (v0 * (1 - 4 * u + 3 * u * u) + total * (6 * u - 6 * u * u)) / span
            let p = point(at: s)
            rider.speed = 1
            Self.moveHead(&rider, x: Double(p.x), y: Double(p.y))
            rider.phase += dt * tau * (rider.shape.beat + sp / 200)
            return left
        }
        if stage != .inPlace {
            var ideal = rider
            ideal.pose(x: Double(rest.x), y: Double(rest.y), heading: A.remoraRise, bend: A.remoraBend)
            restTrail = ideal.trail
            settleFrom = Self.resample([CGPoint(x: rider.x, y: rider.y)] + rider.trail, step: 4, count: restTrail.count)
            rider.x = Double(rest.x)
            rider.y = Double(rest.y)
            rider.speed = 0
            stage = .inPlace
        }
        let f = min(1, (t - A.arrivalTurnEnd) / A.arrivalSettle), k = f * f * (3 - 2 * f)
        rider.trail = zip(settleFrom, restTrail).map { from, to in
            CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
        }
        let settled = t >= A.arrivalTurnEnd + A.arrivalSettle
        if swimming || !settled {
            quietSince = nil
        } else if quietSince == nil {
            quietSince = t
        }
        let slow = quietSince.map { max(0, 1 - (t - $0) / A.arrivalSlow) } ?? 1
        rider.phase += dt * tau * rider.shape.beat * slow * slow
        if slow <= 0, bandReleased {
            rider.trail = restTrail
            stage = .resting
        }
        return left
    }

    // MARK: The reference's helpers

    /// The rider under the host's flank, at `arrivalRideAt` of its length: its spine is the host's from there, moved out.
    private static func ride(_ host: ArtShark, _ rider: inout ArtShark) {
        let n = Int((34 * host.shape.ext).rounded()), spine = host.spine(n)
        let i0 = min(n - 1, Int((A.arrivalRideAt / host.shape.ext * Double(n - 1)).rounded()))
        let g = host.halfWidth(A.arrivalRideAt) + rider.halfWidth(0.22) * 0.6
        let points = spine[i0...].map { CGPoint(x: $0.x - $0.ty * g, y: $0.y + $0.tx * g) }
        guard let first = points.first else { return }
        rider.x = Double(first.x)
        rider.y = Double(first.y)
        rider.trail = Array(points.dropFirst())
    }

    private static func moveHead(_ shark: inout ArtShark, x: Double, y: Double) {
        shark.x = x
        shark.y = y
        shark.follow()
    }

    /// `count` points `step` apart along `poly`.
    private static func resample(_ poly: [CGPoint], step: Double, count: Int) -> [CGPoint] {
        guard var a = poly.first, count > 0 else { return [] }
        var out = [a], i = 0, left = step
        while out.count < count {
            guard i + 1 < poly.count else {
                out.append(out[out.count - 1])
                continue
            }
            let b = poly[i + 1], d = ArtShark.distance(a, b)
            if d >= left {
                let f = left / d
                a = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                out.append(a)
                left = step
            } else {
                left -= d
                a = b
                i += 1
            }
        }
        return out
    }

    /// The remora's way from where it lets go up to its place: down to the turn's foot, round the turn, then straight in.
    private mutating func letGo() {
        let r = A.arrivalTurn, th = A.remoraRise, approach = A.arrivalApproach
        let end = CGPoint(x: Double(rest.x) - approach * cos(th), y: Double(rest.y) - approach * sin(th))
        let c = CGPoint(x: Double(end.x) - r * sin(th), y: Double(end.y) + r * cos(th))
        let foot = CGPoint(x: c.x, y: c.y + r)
        var points = [CGPoint(x: rider.x, y: rider.y)]
        let n1 = max(1, Int((ArtShark.distance(points[0], foot) / 2).rounded(.up)))
        for i in 1...n1 {
            let f = Double(i) / Double(n1)
            points.append(CGPoint(x: rider.x + (Double(foot.x) - rider.x) * f, y: rider.y + (Double(foot.y) - rider.y) * f))
        }
        for i in 1...48 {
            let f = Double.pi + (Double.pi + th) * Double(i) / 48
            points.append(CGPoint(x: Double(c.x) + r * sin(f), y: Double(c.y) - r * cos(f)))
        }
        let n3 = max(1, Int((approach / 2).rounded(.up)))
        for i in 1...n3 {
            let f = Double(i) / Double(n3)
            points.append(CGPoint(x: end.x + (rest.x - end.x) * f, y: end.y + (rest.y - end.y) * f))
        }
        var s = 0.0
        path = [(points[0], 0)]
        for i in 1..<points.count {
            s += ArtShark.distance(points[i], points[i - 1])
            path.append((points[i], s))
        }
        pathLength = s
        dropSpeed = speed
    }

    private func point(at s: Double) -> CGPoint {
        let s = max(0, min(pathLength, s))
        var lo = 0, hi = path.count - 1
        while hi - lo > 1 {
            let m = (lo + hi) >> 1
            if path[m].s < s { lo = m } else { hi = m }
        }
        let a = path[lo], b = path[hi], f = b.s > a.s ? (s - a.s) / (b.s - a.s) : 0
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f)
    }
}

/// The remora at the start of the folded brief's line (DESIGN §9 Later): level, 72 long, still, in its 84 × 30 slot.
enum ArtFoldRemora {
    static func shark(size: CGSize) -> ArtShark {
        typealias A = LoomTheme.Art
        var random = ArtRandom(seed: 4)
        var shark = ArtShark(spec: ArtSharkSpec(kind: .remora, length: A.foldLength, depth: 1, speed: 0), index: 0, size: size,
                             random: &random)
        let reach = A.foldLength * 0.47
        shark.pose(x: Double(size.width) / 2 + reach * cos(A.foldHeading), y: Double(size.height) / 2 + reach * sin(A.foldHeading),
                   heading: A.foldHeading, bend: A.foldBend)
        shark.phase = A.remoraRestPhase
        return shark
    }

    static func frame(size: CGSize, metrics: ArtMetrics, raster: ArtRaster) -> ArtFrame {
        ArtField.build(size: size, metrics: metrics, alpha: LoomTheme.Art.foldAlpha, sharks: [shark(size: size)], plankton: [],
                       wake: [], raster: raster)
    }
}
