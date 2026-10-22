import CoreGraphics
import Foundation

// The art's engine (DESIGN §17 How they are drawn), ported from the reference's `design/reference-src/shared/engine.js`:
// a shark is a spine that follows its own trail, with a body wave travelling along it; its silhouette (body, hammer,
// fins, tail) is filled into a field of one cell per character (`ArtField`), and each cell's coverage picks a glyph from
// the ramp. Plain values, deterministic for a seed and a time. Coordinates are points, y down, as the reference's canvas.

/// A seeded generator (SplitMix64), so a sea is the same for the same seed.
struct ArtRandom: Sendable, Equatable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// A value in 0..<1 (the reference's `Math.random()`).
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// The cast (DESIGN §17's table; the reference's `KINDS`).
enum ArtKind: String, CaseIterable, Sendable {
    case hammerhead, thresher, whale, remora

    /// A profile point: the half width at `s` along the body (0 the head, 1 the tail's root), as a share of the length.
    struct Width: Sendable, Equatable {
        let s: Double
        let w: Double
    }

    struct Shape: Sendable, Equatable {
        /// How much path the body remembers, as a share of its length.
        let reach: Double
        /// How far the spine runs past the body (the thresher's long tail).
        let ext: Double
        /// Tail beats a second.
        let beat: Double
        /// The alpha of the core's fill, which makes the middle of the body denser.
        let core: Double
        let profile: [Width]
        /// The pectoral fin: its start and end along the body, how far back it sweeps and how far out it reaches.
        let fins: (start: Double, end: Double, back: Double, reach: Double)
        /// The remora's disc over the head: its start and end along the body and its width as a share of the half width.
        let disc: (start: Double, end: Double, width: Double)?
        /// The remora's eyes: where along the body and how far out, as a share of the half width.
        let eye: (s: Double, lateral: Double)?
        /// The remora's ridge: from where to where it runs.
        let ridge: (start: Double, end: Double)?

        static func == (a: Shape, b: Shape) -> Bool {
            a.reach == b.reach && a.ext == b.ext && a.beat == b.beat && a.core == b.core && a.profile == b.profile
        }
    }

    private static func profile(_ pairs: [(Double, Double)]) -> [Width] { pairs.map { Width(s: $0.0, w: $0.1) } }

    var shape: Shape {
        switch self {
        case .hammerhead:
            Shape(reach: 1.3, ext: 1, beat: 0.42, core: 0.3,
                  profile: Self.profile([(0, 0.03), (0.05, 0.046), (0.11, 0.064), (0.19, 0.08), (0.27, 0.085), (0.37, 0.078),
                                         (0.49, 0.062), (0.61, 0.045), (0.73, 0.03), (0.83, 0.02), (0.91, 0.014), (1, 0.009)]),
                  fins: (0.2, 0.33, 0.15, 0.1), disc: nil, eye: nil, ridge: nil)
        case .thresher:
            Shape(reach: 2.1, ext: 1.7, beat: 0.5, core: 0.3,
                  profile: Self.profile([(0, 0.006), (0.03, 0.028), (0.08, 0.048), (0.16, 0.064), (0.26, 0.07), (0.38, 0.064),
                                         (0.5, 0.05), (0.62, 0.035), (0.74, 0.023), (0.84, 0.015), (0.92, 0.011), (1, 0.008)]),
                  fins: (0.19, 0.3, 0.2, 0.17), disc: nil, eye: nil, ridge: nil)
        case .whale:
            Shape(reach: 1.3, ext: 1, beat: 0.22, core: 0.16,
                  profile: Self.profile([(0, 0.068), (0.03, 0.08), (0.08, 0.092), (0.16, 0.102), (0.26, 0.106), (0.38, 0.098),
                                         (0.5, 0.082), (0.62, 0.06), (0.74, 0.04), (0.84, 0.025), (0.92, 0.016), (1, 0.011)]),
                  fins: (0.2, 0.36, 0.13, 0.15), disc: nil, eye: nil, ridge: nil)
        case .remora:
            // A broad, flat head under the disc (the first two fifths), the lower jaw a point in front of it, and a body
            // that tapers behind.
            Shape(reach: 1.3, ext: 1, beat: 0.7, core: 0.18,
                  profile: Self.profile([(0, 0.012), (0.025, 0.046), (0.06, 0.076), (0.12, 0.092), (0.22, 0.096), (0.32, 0.088),
                                         (0.42, 0.07), (0.54, 0.056), (0.66, 0.044), (0.8, 0.031), (0.9, 0.021), (1, 0.015)]),
                  fins: (0.42, 0.52, 0.05, 0.06), disc: (0.03, 0.43, 0.84), eye: (0.09, 0.95), ridge: (0.5, 0.8))
        }
    }

    /// The half width at `s`, as a share of the length: the profile eased between its points (smoothstep).
    static func width(_ profile: [Width], at s: Double) -> Double {
        if s <= 0 { return profile[0].w }
        for i in 1..<profile.count where s <= profile[i].s {
            let a = profile[i - 1], b = profile[i], f = (s - a.s) / (b.s - a.s), k = f * f * (3 - 2 * f)
            return a.w + (b.w - a.w) * k
        }
        return profile[profile.count - 1].w
    }
}

/// What a sea is given for one shark (the reference's spec).
struct ArtSharkSpec: Sendable, Equatable {
    var kind: ArtKind = .hammerhead
    var length: Double = 300
    var depth: Double = 0.6
    var speed: Double = 16
    /// A fixed place, as shares of the box; nil for a shark that roams.
    var place: CGPoint?
    var angle: Double = 0
    /// Centred in its box and shortened to fit it (a shark in place).
    var center = false
    /// Where a roaming shark first comes in, as shares of the box, facing `angle` (the first launch's hammerhead, from the right);
    /// after that it roams and comes back from either side.
    var entry: CGPoint?
    /// A shark that keeps to another of the sea (the first launch's remoras): the host's index and its spot by the host's flank,
    /// along and across, as shares of the host's length.
    var host: Int?
    var spot: CGPoint = .zero
    /// A shark that crosses once and rests (About's): it stops at this share of the box's width and swims no further.
    var restsAt: Double?
}

/// A point of the spine: where it is, how far along the body (`s`) and the unit tangent, pointing to the head.
struct ArtSpinePoint: Sendable, Equatable {
    var x: Double
    var y: Double
    var s: Double
    var tx = 0.0
    var ty = 0.0
}

/// A frame on the spine: a place, the tangent (to the head) and the normal.
struct ArtFrameAxis: Sendable, Equatable {
    let x: Double
    let y: Double
    let tx: Double
    let ty: Double
    var nx: Double { -ty }
    var ny: Double { tx }

    /// The point `along` the tangent and `lateral` along the normal from here.
    func point(_ along: Double, _ lateral: Double) -> CGPoint {
        CGPoint(x: x + tx * along + nx * lateral, y: y + ty * along + ny * lateral)
    }
}

/// The silhouette of one shark at one moment (the reference's `geometry()`).
struct ArtGeometry: Sendable {
    struct Disc: Sendable, Equatable {
        let axis: ArtFrameAxis
        /// The half length along the body and the half width across it.
        let a: Double
        let b: Double
    }

    /// Filled together, nonzero: the body, the hammer, the fins and the tail.
    var shapes: [[CGPoint]]
    /// The denser middle of the body.
    var core: [CGPoint]
    /// Ridges stroked along the back.
    var lines: [[CGPoint]]
    var eyes: [CGPoint]
    var spots: [CGPoint]
    var disc: Disc?
    /// The tail's tip and the tangent there, where a wake starts.
    var tail: ArtFrameAxis
    var box: CGRect
}

/// One shark in a sea (the reference's `Shark`).
struct ArtShark: Sendable, Equatable {
    let spec: ArtSharkSpec
    let shape: ArtKind.Shape
    var length: Double
    var speed: Double
    var phase: Double
    let seed: Double
    var wakeTime = 0.0
    var x = 0.0
    var y = 0.0
    var heading = 0.0
    /// The path behind the head, newest first.
    var trail: [CGPoint] = []

    var kind: ArtKind { spec.kind }
    var depth: Double { spec.depth }

    init(spec: ArtSharkSpec, index: Int, size: CGSize, random: inout ArtRandom) {
        self.spec = spec
        shape = spec.kind.shape
        length = spec.length
        speed = spec.speed
        phase = random.next() * 6.28
        seed = random.next() * 100
        spawn(initial: true, index: index, size: size, random: &random)
    }

    /// The half width at `s`, in points.
    func halfWidth(_ s: Double) -> Double { ArtKind.width(shape.profile, at: s) * length }

    /// Lays a shark that crosses once where it rests, still (About with Animated art off, or once it has crossed).
    mutating func layAtRest(size: CGSize) {
        guard let rest = spec.restsAt else { return }
        x = Double(size.width) * rest
        speed = 0
        layStraightTrail()
    }

    /// Whether a shark that crosses once has come to rest.
    var hasRested: Bool { spec.restsAt != nil && speed == 0 }

    /// Lays the shark at its start: a fixed place, or (roaming) a side, a height and a heading, with a straight trail.
    mutating func spawn(initial: Bool, index: Int, size: CGSize, random: inout ArtRandom) {
        let w = Double(size.width), h = Double(size.height)
        if initial, let entry = spec.entry {
            x = w * Double(entry.x)
            y = h * Double(entry.y)
            heading = spec.angle
        } else if let place = spec.place {
            if spec.center { length = min(spec.length, w * 0.82 / (shape.ext + 0.2)) }
            x = spec.center ? w / 2 + length * (shape.ext * 0.5 + 0.05) : w * Double(place.x)
            y = h * Double(place.y)
            heading = spec.angle
        } else {
            let right = initial ? index % 2 == 0 : random.next() < 0.5
            heading = (right ? 0 : Double.pi) + (random.next() - 0.5) * 0.5
            y = h * (0.2 + random.next() * 0.6)
            let jitter = random.next()
            x = initial ? w * (0.18 + (Double(index) * 0.37).truncatingRemainder(dividingBy: 0.7) + jitter * 0.1)
                : (right ? -length * 0.25 : w + length * 0.25)
        }
        layStraightTrail()
    }

    /// Lays the shark still at a pose: its head at (`x`, `y`) facing `heading`, its trail curving back by `bend` (the
    /// reference's `poseShark`).
    mutating func pose(x: Double, y: Double, heading: Double, bend: Double) {
        self.x = x
        self.y = y
        self.heading = heading
        trail = []
        let d = 4.0, n = Int((length * shape.reach / d).rounded(.up))
        var px = x, py = y, a = heading
        for _ in 0...n {
            trail.append(CGPoint(x: px, y: py))
            a += bend * d / length
            px -= cos(a) * d
            py -= sin(a) * d
        }
    }

    /// The spot by `host`'s flank this shark keeps to at time `t`, with a little drift (the reference's `follow`).
    func spot(by host: ArtShark, at t: Double) -> CGPoint {
        let c = cos(host.heading), s = sin(host.heading), drift = sin(t * 0.6 + seed) * 0.05
        let along = Double(spec.spot.x) + drift, across = Double(spec.spot.y)
        return CGPoint(x: host.x + c * along * host.length - s * across * host.length,
                       y: host.y + s * along * host.length + c * across * host.length)
    }

    /// Joins `host` at `point`: facing as it does, with a straight trail.
    mutating func join(_ point: CGPoint, host: ArtShark) {
        x = Double(point.x)
        y = Double(point.y)
        heading = host.heading
        layStraightTrail()
    }

    /// One step of a shark that keeps to `host`: far from its spot it turns to it and hurries; close by it swims with the host.
    mutating func step(following host: ArtShark, dt: Double, time t: Double, size: CGSize) {
        phase += dt * Double.pi * 2 * shape.beat
        let target = spot(by: host, at: t), dx = Double(target.x) - x, dy = Double(target.y) - y, d = hypot(dx, dy)
        if d > Double(size.width) * 0.6 {
            join(target, host: host)
            return
        }
        let near = min(1, d / (length * 1.5))
        func turn(_ a: Double) -> Double { atan2(sin(a - heading), cos(a - heading)) }
        let aim = near * turn(atan2(dy, dx)) + (1 - near) * turn(host.heading)
        heading += max(-2 * dt, min(2 * dt, aim))
        let v = max(4, host.speed) * (0.9 + 1.4 * near) * (1 + 0.1 * sin(phase))
        x += cos(heading) * v * dt
        y += sin(heading) * v * dt
        follow()
    }

    mutating func layStraightTrail() {
        trail = []
        var d = 0.0
        while d <= length * shape.reach {
            trail.append(CGPoint(x: x - cos(heading) * d, y: y - sin(heading) * d))
            d += 4
        }
    }

    /// One step of a roaming shark: the tail beats, the heading wanders and keeps off the top and bottom, the head moves
    /// and the trail follows it; a shark past the box's edge comes back from a side.
    mutating func step(dt: Double, time t: Double, size: CGSize, random: inout ArtRandom) {
        phase += dt * Double.pi * 2 * shape.beat
        guard speed != 0 else { return }
        let w = Double(size.width), h = Double(size.height)
        // A shark that crosses once (About's) keeps its line behind the icon; the others wander.
        if spec.restsAt == nil {
            let n = sin(t * 0.13 + seed) * 0.6 + sin(t * 0.071 + seed * 1.7) * 0.4
            heading += n * 0.12 * dt
        }
        let c: Double = cos(heading) < 0 ? -1 : 1, m = h * 0.14
        if y < m { heading += 0.3 * dt * c }
        if y > h - m { heading -= 0.3 * dt * c }
        let v = speed * (1 + 0.14 * sin(phase))
        x += cos(heading) * v * dt
        y += sin(heading) * v * dt
        follow()
        if let rest = spec.restsAt, x > w * rest {
            speed = 0
            return
        }
        let pad = length * (shape.ext + 0.3)
        if x < -pad || x > w + pad || y < -pad || y > h + pad { spawn(initial: false, index: 0, size: size, random: &random) }
    }

    /// The trail takes the head's new place once it has moved 3 points, and keeps only as much as the body remembers.
    mutating func follow() {
        let head = CGPoint(x: x, y: y)
        if trail.isEmpty || Self.distance(head, trail[0]) >= 3 { trail.insert(head, at: 0) }
        var acc = Self.distance(head, trail[0])
        for k in 1..<max(1, trail.count) {
            acc += Self.distance(trail[k], trail[k - 1])
            if acc > length * shape.reach { trail.removeSubrange((k + 1)...); break }
        }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

    private static func tangents(_ pts: inout [ArtSpinePoint]) {
        let n = pts.count
        var out = pts
        for i in 0..<n {
            let a = pts[max(0, i - 1)], b = pts[min(n - 1, i + 1)]
            let dx = a.x - b.x, dy = a.y - b.y, l = hypot(dx, dy)
            let len = l == 0 ? 1 : l
            out[i].tx = dx / len
            out[i].ty = dy / len
        }
        pts = out
    }

    /// `count` points along the spine from the head, laid on the trail, with the body wave across them.
    func spine(_ count: Int) -> [ArtSpinePoint] {
        let ext = shape.ext
        var poly = [CGPoint(x: x, y: y)] + trail
        if poly.count < 2 { poly.append(poly[0]) }
        var pts: [ArtSpinePoint] = []
        pts.reserveCapacity(count)
        var seg = 0, acc = 0.0, segLength = Self.distance(poly[0], poly[1])
        for i in 0..<count {
            let s = Double(i) / Double(count - 1) * ext, d = s * length
            while seg < poly.count - 2 && acc + segLength < d {
                acc += segLength
                seg += 1
                segLength = Self.distance(poly[seg], poly[seg + 1])
            }
            let a = poly[seg], b = poly[seg + 1]
            let f = segLength > 0 ? min(1, max(0, (d - acc) / segLength)) : 0
            pts.append(ArtSpinePoint(x: Double(a.x) + Double(b.x - a.x) * f, y: Double(a.y) + Double(b.y - a.y) * f, s: s))
        }
        Self.tangents(&pts)
        let swim = speed != 0 ? 1.0 : 0.6, calm = kind == .whale ? 0.7 : 1.0
        for i in pts.indices {
            let p = pts[i]
            let amp = length * 0.042 * swim * calm * (0.1 + pow(min(p.s, 1.25), 1.6))
            let off = amp * sin(p.s * 5.3 - phase)
            pts[i].x += -p.ty * off
            pts[i].y += p.tx * off
        }
        Self.tangents(&pts)
        return pts
    }

    /// The silhouette now: the body's outline, the kind's own parts (the hammer and its eyes, the thresher's tail, the
    /// whale shark's spots, the remora's disc), the fins, the tail, the core and the ridges.
    func geometry() -> ArtGeometry {
        let L = length, ext = shape.ext, N = Int((34 * ext).rounded()), sp = spine(N)
        func axis(_ p: ArtSpinePoint) -> ArtFrameAxis { ArtFrameAxis(x: p.x, y: p.y, tx: p.tx, ty: p.ty) }
        func at(_ s: Double) -> ArtFrameAxis {
            let f = max(0, min(1, s / ext)) * Double(N - 1), i = min(N - 2, Int(f.rounded(.down))), k = f - Double(i)
            let a = sp[i], b = sp[i + 1]
            let tx = a.tx + (b.tx - a.tx) * k, ty = a.ty + (b.ty - a.ty) * k, l = hypot(tx, ty)
            let len = l == 0 ? 1 : l
            return ArtFrameAxis(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, tx: tx / len, ty: ty / len)
        }
        let hw = halfWidth
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<N {
            let s = Double(i) / Double(N - 1) * ext
            if s > 0.93 { break }
            let f = axis(sp[i])
            left.append(f.point(0, hw(s)))
            right.append(f.point(0, -hw(s)))
        }
        var shapes = [left + right.reversed()], eyes: [CGPoint] = [], spots: [CGPoint] = [], lines: [[CGPoint]] = []
        let head = axis(sp[0])
        switch kind {
        case .hammerhead:
            let span = L * 0.17
            var front: [CGPoint] = [], back: [CGPoint] = []
            for k in 0...16 {
                let u = -1 + Double(k) / 8, along = L * (0.014 - 0.032 * u * u), chord = L * 0.066 * (1 - 0.4 * u * u)
                front.append(head.point(along + chord * 0.5, u * span))
                back.append(head.point(along - chord * 0.5, u * span))
            }
            shapes.append(front + back.reversed())
            eyes += [head.point(-L * 0.016, span * 0.95), head.point(-L * 0.016, -span * 0.95)]
        case .thresher:
            let e = at(0.07)
            eyes += [e.point(0, hw(0.07) * 0.7), e.point(0, -hw(0.07) * 0.7)]
        case .remora:
            let eye = shape.eye ?? (0.09, 0.95), e = at(eye.s)
            eyes += [e.point(0, hw(eye.s) * eye.lateral), e.point(0, -hw(eye.s) * eye.lateral)]
        case .whale:
            let e = at(0.035)
            eyes += [e.point(0, hw(0.035) * 0.9), e.point(0, -hw(0.035) * 0.9)]
            var s = 0.08, row = 0
            while s < 0.8 {
                var q = -0.7 + Double(row % 2) * 0.175
                while q <= 0.71 {
                    spots.append(at(s).point(0, q * hw(s)))
                    q += 0.35
                }
                s += 0.055
                row += 1
            }
        }
        let flap = 1 + 0.07 * sin(phase * 0.5)
        let fin = shape.fins
        for side in [1.0, -1.0] {
            let pm = (fin.start + fin.end) / 2
            shapes.append([at(fin.start).point(0, side * hw(fin.start) * 0.9),
                           at(pm).point(-L * fin.back, side * (hw(pm) + L * fin.reach * flap)),
                           at(fin.end).point(0, side * hw(fin.end) * 0.9)])
            shapes.append([at(0.6).point(0, side * hw(0.6) * 0.9), at(0.62).point(-L * 0.05, side * (hw(0.62) + L * 0.035)),
                           at(0.66).point(0, side * hw(0.66) * 0.9)])
        }
        let root = at(0.88), end = at(1)
        let tip: CGPoint
        if kind == .thresher {
            shapes.append([root.point(0, -hw(0.88)), end.point(-L * 0.07, -L * 0.05), end.point(-L * 0.01, 0)])
            var bl: [CGPoint] = [], br: [CGPoint] = []
            for i in 0..<N {
                let s = Double(i) / Double(N - 1) * ext
                if s < 0.86 { continue }
                let f = axis(sp[i]), k = (s - 0.86) / (ext - 0.86), w = L * (0.016 * pow(1 - k, 0.9) + 0.002)
                bl.append(f.point(0, w))
                br.append(f.point(0, -w))
            }
            shapes.append(bl + br.reversed())
            tip = CGPoint(x: sp[N - 1].x, y: sp[N - 1].y)
        } else {
            let lobe = kind == .whale ? [0.14, 0.13, 0.14, -0.13] : [0.16, 0.11, 0.09, -0.075]
            shapes.append([root.point(0, hw(0.88)), end.point(-L * lobe[0], L * lobe[1]), end.point(-L * 0.045, 0),
                           end.point(-L * lobe[2], L * lobe[3]), root.point(0, -hw(0.88))])
            tip = end.point(-L * 0.06, 0)
        }
        var cl: [CGPoint] = [], cr: [CGPoint] = []
        for i in 1..<N {
            let s = Double(i) / Double(N - 1) * ext
            if s > 0.74 { break }
            let f = axis(sp[i]), w = hw(s) * 0.45
            cl.append(f.point(0, w))
            cr.append(f.point(0, -w))
        }
        func ridge(_ q: Double, _ a: Double, _ b: Double) -> [CGPoint] {
            var pts: [CGPoint] = [], s = a
            while s <= b + 1e-6 {
                pts.append(at(s).point(0, q * hw(s)))
                s += 0.03
            }
            return pts
        }
        switch kind {
        case .whale: lines += [ridge(0, 0.12, 0.8), ridge(0.5, 0.14, 0.7), ridge(-0.5, 0.14, 0.7)]
        case .remora:
            let r = shape.ridge ?? (0.5, 0.8)
            lines.append(ridge(0, r.start, r.end))
        default: lines.append(ridge(0, 0.27, 0.45))
        }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for poly in shapes {
            for q in poly {
                x0 = min(x0, Double(q.x)); y0 = min(y0, Double(q.y)); x1 = max(x1, Double(q.x)); y1 = max(y1, Double(q.y))
            }
        }
        let tailAxis = axis(sp[N - 1])
        var disc: ArtGeometry.Disc?
        if let d = shape.disc {
            let dm = (d.start + d.end) / 2
            disc = ArtGeometry.Disc(axis: at(dm), a: L * (d.end - d.start) / 2, b: d.width * hw(dm))
        }
        return ArtGeometry(shapes: shapes, core: cl + cr.reversed(), lines: lines, eyes: eyes, spots: spots, disc: disc,
                           tail: ArtFrameAxis(x: Double(tip.x), y: Double(tip.y), tx: tailAxis.tx, ty: tailAxis.ty),
                           box: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }
}
