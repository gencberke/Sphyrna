import AppKit
import CoreGraphics
import Foundation

// The density field and the sea (DESIGN §17 How they are drawn; the reference's `Ocean`): sharks are filled into a field of
// one cell per character, a cell's coverage picks a glyph from the ramp, the eyes, spots and the remora's disc are set over
// it, and plankton and a faint wake drift under them.

/// The glyphs a cell can hold, by code (the reference's `GLYPH`).
enum ArtGlyphs {
    /// The density ramp: code 0 is an empty cell, 1 to 9 the ramp's characters.
    static let ramp: [Character] = Array(" .:-=+*#%@")
    static let eye: UInt8 = 10
    static let wakeFar: UInt8 = 11
    static let wakeNear: UInt8 = 12
    static let moteDot: UInt8 = 13
    static let moteMiddle: UInt8 = 14
    static let spot: UInt8 = 15
    /// The remora's plates, a bar across the head: `|`, `/`, `-` and `\`.
    static let barUpright: UInt8 = 16
    static let barRising: UInt8 = 17
    static let barLevel: UInt8 = 18
    static let barFalling: UInt8 = 19

    /// Every code's character.
    static let table: [Character] = ramp + ["o", "-", "~", ".", "\u{00B7}", "\u{00B0}", "|", "/", "-", "\\"]

    /// The code for a coverage of 0...1: the ramp's step, never empty (the reference's `floor(v^0.9 * 10)` in 1...9).
    static func code(coverage v: Double) -> UInt8 { UInt8(min(9, max(1, Int((pow(v, 0.9) * 10).rounded(.down))))) }

    /// The plate's bar for a direction across the head, in radians on the y-down plane: the bar that lies along it.
    static func bar(_ angle: Double) -> UInt8 {
        let half = Double.pi
        let q = ((angle.truncatingRemainder(dividingBy: half) + half).truncatingRemainder(dividingBy: half)) / half * 8
        if q < 1 || q >= 7 { return barLevel }
        if q < 3 { return barFalling }
        if q < 5 { return barUpright }
        return barRising
    }
}

/// The glyph grid of a surface: a cell's width (an `M` of the art's font) and its height.
struct ArtMetrics: Sendable, Equatable {
    let cellWidth: Double
    let cellHeight: Double

    init(cellWidth: Double, cellHeight: Double) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    /// The grid of SF Mono at `cell` points (the reference's `cw` and `ch`).
    @MainActor
    static func mono(cell: CGFloat, weight: NSFont.Weight = .regular) -> ArtMetrics {
        let font = LoomTheme.Art.font(cell: cell, weight: weight)
        let width = NSAttributedString(string: "M", attributes: [.font: font]).size().width
        return ArtMetrics(cellWidth: Double(width > 0 ? width : cell * 0.6), cellHeight: (Double(cell) * LoomTheme.Art.lineFactor).rounded())
    }

    func columns(_ size: CGSize) -> Int { Int((Double(size.width) / cellWidth).rounded(.up)) + 1 }
    func rows(_ size: CGSize) -> Int { Int((Double(size.height) / cellHeight).rounded(.up)) + 1 }
}

/// One drawn moment: a code and an alpha per cell, row by row from the top.
struct ArtFrame: Sendable, Equatable {
    let columns: Int
    let rows: Int
    var codes: [UInt8]
    var alphas: [Float]

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        codes = Array(repeating: 0, count: columns * rows)
        alphas = Array(repeating: 0, count: columns * rows)
    }

    func code(column: Int, row: Int) -> UInt8 { codes[row * columns + column] }

    /// How many cells hold `code`.
    func count(of code: UInt8) -> Int { codes.reduce(0) { $0 + ($1 == code ? 1 : 0) } }

    /// The frame as text, a line per row (an empty cell is a space): what a test reads.
    var text: String {
        (0..<rows).map { row in String((0..<columns).map { ArtGlyphs.table[Int(code(column: $0, row: row))] }) }
            .joined(separator: "\n")
    }

    /// The lit cells packed for drawing: the cell's index, its code and its alpha in steps of 1/40.
    var packed: [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(codes.count / 4)
        for i in codes.indices where codes[i] != 0 {
            let steps = UInt32((Double(alphas[i]) * LoomTheme.Art.alphaSteps).rounded())
            if steps > 0 { out.append(ArtPackedCell.pack(index: i, code: codes[i], steps: steps)) }
        }
        return out
    }
}

/// A lit cell in 32 bits: 21 for its index, 5 for its code and 6 for its alpha in fortieths.
enum ArtPackedCell {
    static func pack(index: Int, code: UInt8, steps: UInt32) -> UInt32 {
        UInt32(index) << 11 | UInt32(code) << 6 | min(steps, 63)
    }

    static func index(_ cell: UInt32) -> Int { Int(cell >> 11) }
    static func code(_ cell: UInt32) -> UInt8 { UInt8((cell >> 6) & 0x1F) }
    static func steps(_ cell: UInt32) -> UInt32 { cell & 0x3F }
}

/// A drifting mote of plankton (the reference's `mote`).
struct ArtMote: Sendable, Equatable {
    var x, y, vx, vy, f, p, a: Double
    var glyph: UInt8

    init(width: Double, height: Double, fromBelow: Bool, random: inout ArtRandom) {
        x = random.next() * width
        y = fromBelow ? height + 6 : random.next() * height
        vx = (random.next() - 0.5) * 5
        vy = -(1.2 + random.next() * 2.6)
        f = 0.4 + random.next()
        p = random.next() * 6.28
        a = 0.1 + random.next() * 0.16
        glyph = random.next() < 0.75 ? ArtGlyphs.moteDot : ArtGlyphs.moteMiddle
    }
}

/// A grain of a shark's wake, left at its tail and fading over `life`.
struct ArtWakeMote: Sendable, Equatable {
    var x, y, vx, vy: Double
    var age = 0.0
    let life = 2.4
    let a: Double
}

/// The coverage buffer the sharks are filled into: one pixel per cell. A drawing surface keeps one and reuses it.
final class ArtRaster {
    private(set) var columns = 0
    private(set) var rows = 0
    private var metrics: ArtMetrics?
    private var context: CGContext?

    init() {}

    fileprivate func prepare(columns: Int, rows: Int, metrics: ArtMetrics) -> CGContext? {
        if columns != self.columns || rows != self.rows || metrics != self.metrics || context == nil {
            self.columns = columns
            self.rows = rows
            self.metrics = metrics
            context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // Cells are y down from the top (the reference's canvas): the first row of memory is the field's first row.
            context?.translateBy(x: 0, y: CGFloat(rows))
            context?.scaleBy(x: 1 / metrics.cellWidth, y: -1 / metrics.cellHeight)
        }
        return context
    }

    /// The alpha of a cell, 0...255.
    fileprivate func coverage(column: Int, row: Int) -> UInt8 {
        guard let data = context?.data else { return 0 }
        return data.load(fromByteOffset: row * columns * 4 + column * 4 + 3, as: UInt8.self)
    }

    fileprivate func clear(columns c: ClosedRange<Int>, rows r: ClosedRange<Int>) {
        guard let data = context?.data else { return }
        for row in r { memset(data + row * columns * 4 + c.lowerBound * 4, 0, c.count * 4) }
    }
}

/// Fills a field from sharks, plankton and wake (the reference's `draw()` and `stamp()`).
enum ArtField {
    static func build(size: CGSize, metrics: ArtMetrics, alpha: Double, sharks: [ArtShark], plankton: [ArtMote],
                      wake: [ArtWakeMote], raster: ArtRaster) -> ArtFrame {
        var frame = ArtFrame(columns: metrics.columns(size), rows: metrics.rows(size))
        for m in plankton { put(&frame, metrics, x: m.x, y: m.y, code: m.glyph, alpha: m.a * alpha * 1.4) }
        for p in wake {
            let k = 1 - p.age / p.life
            put(&frame, metrics, x: p.x, y: p.y, code: k > 0.55 ? ArtGlyphs.wakeNear : ArtGlyphs.wakeFar, alpha: k * 0.55 * p.a * alpha)
        }
        // The deeper first, so a nearer shark is drawn over it.
        let order = sharks.indices.sorted { sharks[$0].depth != sharks[$1].depth ? sharks[$0].depth < sharks[$1].depth : $0 < $1 }
        for i in order { stamp(&frame, sharks[i], metrics: metrics, alpha: alpha, raster: raster) }
        return frame
    }

    private static func put(_ frame: inout ArtFrame, _ metrics: ArtMetrics, x: Double, y: Double, code: UInt8, alpha: Double) {
        let c = Int((x / metrics.cellWidth).rounded(.down)), r = Int((y / metrics.cellHeight).rounded(.down))
        guard c >= 0, r >= 0, c < frame.columns, r < frame.rows else { return }
        let i = r * frame.columns + c
        if Float(alpha) > frame.alphas[i] {
            frame.alphas[i] = Float(alpha)
            frame.codes[i] = code
        }
    }

    private static func path(_ poly: [CGPoint], into path: CGMutablePath) {
        guard let first = poly.first else { return }
        path.move(to: first)
        for q in poly.dropFirst() { path.addLine(to: q) }
        path.closeSubpath()
    }

    private static func stamp(_ frame: inout ArtFrame, _ shark: ArtShark, metrics: ArtMetrics, alpha: Double, raster: ArtRaster) {
        let geo = shark.geometry(), A = alpha * shark.depth, cw = metrics.cellWidth, ch = metrics.cellHeight
        let c0 = max(0, Int((Double(geo.box.minX) / cw).rounded(.down)) - 1)
        let r0 = max(0, Int((Double(geo.box.minY) / ch).rounded(.down)) - 1)
        let c1 = min(frame.columns - 1, Int((Double(geo.box.maxX) / cw).rounded(.up)) + 1)
        let r1 = min(frame.rows - 1, Int((Double(geo.box.maxY) / ch).rounded(.up)) + 1)
        if c1 >= c0, r1 >= r0, let context = raster.prepare(columns: frame.columns, rows: frame.rows, metrics: metrics) {
            raster.clear(columns: c0...c1, rows: r0...r1)
            context.setBlendMode(.plusLighter)
            let body = CGMutablePath()
            for poly in geo.shapes { path(poly, into: body) }
            context.addPath(body)
            context.setFillColor(gray: 1, alpha: 0.5)
            context.fillPath(using: .winding)
            let core = CGMutablePath()
            path(geo.core, into: core)
            context.addPath(core)
            context.setFillColor(gray: 1, alpha: shark.shape.core)
            context.fillPath(using: .winding)
            context.setStrokeColor(gray: 1, alpha: 0.22)
            context.setLineWidth(shark.length * (shark.kind == .whale ? 0.012 : 0.022))
            context.setLineCap(.round)
            for line in geo.lines where line.count > 1 {
                context.addLines(between: line)
                context.strokePath()
            }
            for r in r0...r1 {
                for c in c0...c1 {
                    let v = Double(raster.coverage(column: c, row: r)) / 255
                    if v < 0.05 { continue }
                    let i = r * frame.columns + c
                    frame.codes[i] = ArtGlyphs.code(coverage: v)
                    frame.alphas[i] = Float(A * (0.3 + 0.7 * v))
                }
            }
        }
        if let disc = geo.disc { plates(&frame, disc, metrics: metrics, alpha: A) }
        // Spots only on the body; eyes always, since a hammer's tips are thin.
        over(&frame, geo.spots, code: ArtGlyphs.spot, alpha: A * 0.95, always: false, metrics: metrics)
        over(&frame, geo.eyes, code: ArtGlyphs.eye, alpha: A, always: true, metrics: metrics)
    }

    private static func over(_ frame: inout ArtFrame, _ points: [CGPoint], code: UInt8, alpha: Double, always: Bool,
                             metrics: ArtMetrics) {
        for e in points {
            let c = Int((Double(e.x) / metrics.cellWidth).rounded(.down)), r = Int((Double(e.y) / metrics.cellHeight).rounded(.down))
            guard c >= 0, r >= 0, c < frame.columns, r < frame.rows else { continue }
            let i = r * frame.columns + c
            if always || frame.codes[i] > 3 {
                frame.codes[i] = code
                frame.alphas[i] = Float(alpha)
            }
        }
    }

    /// The remora's disc: an oval of plates across its head, each cell a bar drawn across the head, whichever way the fish
    /// faces. A large remora, four rows of plates or more, shows the ridge that splits them, as bars along the head.
    private static func plates(_ frame: inout ArtFrame, _ d: ArtGeometry.Disc, metrics: ArtMetrics, alpha: Double) {
        let cw = metrics.cellWidth, ch = metrics.cellHeight, f = d.axis, R = max(d.a, d.b) + cw + ch
        let across = ArtGlyphs.bar(atan2(f.ny, f.nx)), along = ArtGlyphs.bar(atan2(f.ty, f.tx)), ridge = 2 * d.b >= 4 * ch
        let c0 = max(0, Int(((f.x - R) / cw).rounded(.down))), c1 = min(frame.columns - 1, Int(((f.x + R) / cw).rounded(.up)))
        let r0 = max(0, Int(((f.y - R) / ch).rounded(.down))), r1 = min(frame.rows - 1, Int(((f.y + R) / ch).rounded(.up)))
        guard c1 >= c0, r1 >= r0 else { return }
        for r in r0...r1 {
            for c in c0...c1 {
                let x = (Double(c) + 0.5) * cw - f.x, y = (Double(r) + 0.5) * ch - f.y
                let u = x * f.tx + y * f.ty, v = x * f.nx + y * f.ny
                if (u / d.a) * (u / d.a) + (v / d.b) * (v / d.b) > 1 { continue }
                let i = r * frame.columns + c
                frame.codes[i] = ridge && abs(v) < ch * 0.5 ? along : across
                frame.alphas[i] = Float(alpha)
            }
        }
    }
}

/// A sea: its sharks, plankton and wake, stepped on a fixed clock so that the same seed and the same time give the same
/// frame (the reference's `Ocean`, without its canvas).
struct ArtSea: Sendable {
    struct Options: Sendable, Equatable {
        /// The surface's alpha (DESIGN §17 Quiet).
        var alpha: Double
        var plankton = 26
        var wake = true
        /// A shark with an entry comes in by it; false (Animated art off) lays it as any other roaming shark.
        var entering = true
        /// A shark that crosses once starts where it rests (Animated art off).
        var atRest = false
    }

    /// The sea steps every 1/`stepRate` of a second, whatever rate it is drawn at.
    static let stepRate = 24.0

    private(set) var size: CGSize
    let metrics: ArtMetrics
    let options: Options
    private(set) var sharks: [ArtShark]
    private(set) var plankton: [ArtMote]
    private(set) var wake: [ArtWakeMote] = []
    /// The sea's own time, which starts after its 2 s of warming up.
    private(set) var time = 0.0
    private var steps = 0
    private var clock = 0.0
    private var random: ArtRandom

    init(size: CGSize, metrics: ArtMetrics, options: Options, specs: [ArtSharkSpec], seed: UInt64) {
        self.size = size
        self.metrics = metrics
        self.options = options
        var random = ArtRandom(seed: seed)
        let laid = options.entering ? specs : specs.map { spec in
            var spec = spec
            spec.entry = nil
            return spec
        }
        var sharks = laid.enumerated().map { ArtShark(spec: $0.element, index: $0.offset, size: size, random: &random) }
        for i in sharks.indices {
            if let host = Self.host(of: i, in: sharks) { sharks[i].join(sharks[i].spot(by: sharks[host], at: 0), host: sharks[host]) }
            if options.atRest { sharks[i].layAtRest(size: size) }
        }
        self.sharks = sharks
        plankton = (0..<options.plankton).map { _ in
            ArtMote(width: Double(size.width), height: Double(size.height), fromBelow: false, random: &random)
        }
        self.random = random
        // The reference warms a sea up before its first frame: 40 steps of 0.05 s.
        for _ in 0..<40 { simulate(0.05) }
    }

    /// Moves the sea on by `dt` seconds of its clock, in its fixed steps.
    mutating func advance(by dt: Double) {
        clock += max(0, dt)
        while Double(steps + 1) / Self.stepRate <= clock + 1e-9 {
            simulate(1 / Self.stepRate)
            steps += 1
        }
    }

    /// A new size: a sea first laid out before it had one seeds again; otherwise only the sharks in place recentre.
    mutating func resize(to newSize: CGSize) {
        let old = size
        size = newSize
        if old.width < 50 || old.height < 50 {
            for i in sharks.indices { sharks[i].spawn(initial: true, index: i, size: newSize, random: &random) }
            for i in sharks.indices {
                if let host = Self.host(of: i, in: sharks) { sharks[i].join(sharks[i].spot(by: sharks[host], at: time), host: sharks[host]) }
                if options.atRest { sharks[i].layAtRest(size: newSize) }
            }
            plankton = plankton.map { _ in ArtMote(width: Double(newSize.width), height: Double(newSize.height), fromBelow: false, random: &random) }
        } else {
            for i in sharks.indices where sharks[i].spec.center { sharks[i].spawn(initial: true, index: i, size: newSize, random: &random) }
        }
    }

    /// The shark `i` keeps to, when it keeps to one that is not itself.
    private static func host(of i: Int, in sharks: [ArtShark]) -> Int? {
        guard let host = sharks[i].spec.host, host != i, sharks.indices.contains(host) else { return nil }
        return host
    }

    /// Every shark that crosses once has come to rest (About's hammerhead): the sea has nothing left to move but tails.
    var hasRested: Bool { sharks.contains { $0.spec.restsAt != nil } && sharks.allSatisfy { $0.spec.restsAt == nil || $0.hasRested } }

    private mutating func simulate(_ dt: Double) {
        time += dt
        for i in sharks.indices {
            if let host = Self.host(of: i, in: sharks) {
                sharks[i].step(following: sharks[host], dt: dt, time: time, size: size)
            } else {
                sharks[i].step(dt: dt, time: time, size: size, random: &random)
            }
        }
        let w = Double(size.width), h = Double(size.height)
        for i in plankton.indices {
            plankton[i].x += plankton[i].vx * dt + sin(time * plankton[i].f + plankton[i].p) * 3 * dt
            plankton[i].y += plankton[i].vy * dt
            let m = plankton[i]
            if m.y < -8 || m.x < -8 || m.x > w + 8 { plankton[i] = ArtMote(width: w, height: h, fromBelow: true, random: &random) }
        }
        guard options.wake else { return }
        for i in sharks.indices {
            sharks[i].wakeTime += dt
            // A grain every 0.3 s at the tail; its tip is worked out only then.
            if sharks[i].speed != 0 && sharks[i].wakeTime > 0.3 {
                sharks[i].wakeTime = 0
                let tail = sharks[i].geometry().tail
                wake.append(ArtWakeMote(x: tail.x, y: tail.y, vx: -tail.tx * 5, vy: -tail.ty * 5, a: sharks[i].depth))
            }
        }
        for i in wake.indices {
            wake[i].age += dt
            wake[i].x += wake[i].vx * dt
            wake[i].y += wake[i].vy * dt
        }
        wake.removeAll { $0.age >= $0.life }
    }

    func frame(raster: ArtRaster) -> ArtFrame {
        ArtField.build(size: size, metrics: metrics, alpha: options.alpha, sharks: sharks, plankton: plankton, wake: wake, raster: raster)
    }
}
