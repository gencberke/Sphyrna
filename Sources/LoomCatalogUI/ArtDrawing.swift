import AppKit
import CoreText
import SwiftUI

// Drawing the art (DESIGN §17 Quiet, Accessibility): a frame's glyphs in the art colour at each cell's alpha, under the
// surface's mask, over the faint grid (`CanvasGrid`). Two drawings were built for the spike, a layer-backed AppKit view
// that draws with Core Text (`ArtLayerView`) and a SwiftUI `Canvas` that draws resolved text (`ArtCanvasView`); the
// spike's measurement chose between them. Both are hidden from VoiceOver.

/// The mask over a surface's art (the reference's `.ocean.calm` and `.ocean.band`), as a factor per cell.
enum ArtMask: Sendable, Equatable {
    case none
    /// The new-session page: faint at the middle, where the question is.
    case calm
    /// Home's band: whole at the top, fading to nothing at its foot.
    case band

    /// Each cell's factor, by the cell's middle, for a box of `size`; nil when nothing is masked.
    func factors(columns: Int, rows: Int, metrics: ArtMetrics, size: CGSize) -> [Float]? {
        let w = Double(size.width), h = Double(size.height)
        guard self != .none, w > 0, h > 0 else { return nil }
        typealias A = LoomTheme.Art
        var out = [Float](repeating: 1, count: columns * rows)
        for r in 0..<rows {
            let y = (Double(r) + 0.5) * metrics.cellHeight
            for c in 0..<columns {
                let x = (Double(c) + 0.5) * metrics.cellWidth
                let factor: Double
                switch self {
                case .none: factor = 1
                case .calm:
                    let dx = (x - w * Double(A.calmCentrePoint.x)) / (w * Double(A.calmRadii.width))
                    let dy = (y - h * Double(A.calmCentrePoint.y)) / (h * Double(A.calmRadii.height))
                    let d = hypot(dx, dy)
                    factor = d >= A.calmOpaque ? 1 : A.calmCentre + (1 - A.calmCentre) * d / A.calmOpaque
                case .band:
                    let f = y / h
                    factor = f <= A.bandOpaque ? 1 : max(0, 1 - (f - A.bandOpaque) / (1 - A.bandOpaque))
                }
                out[r * columns + c] = Float(factor)
            }
        }
        return out
    }
}

/// Draws packed cells with Core Text: one call per alpha step, every glyph of that step in it.
@MainActor
final class ArtPainter {
    let font: NSFont
    let metrics: ArtMetrics
    private let glyphs: [CGGlyph]
    private var bucketGlyphs: [[CGGlyph]]
    private var bucketPositions: [[CGPoint]]

    init(cell: CGFloat, weight: NSFont.Weight = .regular) {
        font = LoomTheme.Art.font(cell: cell, weight: weight)
        metrics = ArtMetrics.mono(cell: cell, weight: weight)
        var characters = ArtGlyphs.table.map { UniChar(String($0).utf16.first ?? 32) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count)
        self.glyphs = glyphs
        bucketGlyphs = Array(repeating: [], count: 64)
        bucketPositions = Array(repeating: [], count: 64)
    }

    /// The codes whose glyph the font lacks (none, for SF Mono).
    var missingCodes: [Int] { (1..<glyphs.count).filter { glyphs[$0] == 0 } }

    /// Draws `cells` into `context`, whose user space is the view's points with y up and `height` high.
    func paint<Cells: Sequence>(_ cells: Cells, columns: Int, height: CGFloat, mask: [Float]?, color: LoomTheme.RGB,
                                in context: CGContext) where Cells.Element == UInt32 {
        for i in bucketGlyphs.indices {
            bucketGlyphs[i].removeAll(keepingCapacity: true)
            bucketPositions[i].removeAll(keepingCapacity: true)
        }
        let ascent = Double(font.ascender), cw = metrics.cellWidth, ch = metrics.cellHeight, top = Double(height)
        for cell in cells {
            let index = ArtPackedCell.index(cell)
            var steps = Int(ArtPackedCell.steps(cell))
            if let mask { steps = Int((Float(steps) * mask[index]).rounded()) }
            guard steps > 0 else { continue }
            let column = index % columns, row = index / columns
            bucketGlyphs[steps].append(glyphs[Int(ArtPackedCell.code(cell))])
            bucketPositions[steps].append(CGPoint(x: Double(column) * cw, y: top - (Double(row) * ch + ascent)))
        }
        context.saveGState()
        context.textMatrix = .identity
        for steps in 1..<bucketGlyphs.count where !bucketGlyphs[steps].isEmpty {
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue,
                                         alpha: Double(steps) / LoomTheme.Art.alphaSteps))
            bucketGlyphs[steps].withUnsafeBufferPointer { g in
                bucketPositions[steps].withUnsafeBufferPointer { p in
                    CTFontDrawGlyphs(font as CTFont, g.baseAddress!, p.baseAddress!, g.count, context)
                }
            }
        }
        context.restoreGState()
    }
}

/// What a drawing shows.
enum ArtScene: Sendable, Equatable {
    /// A sea of sharks (the new-session page, the first launch, a shark in place).
    case sea(specs: [ArtSharkSpec], options: ArtSea.Options, seed: UInt64)
    /// Home's loop, drawn live or from its frames worked out once.
    case homeLoop(precomputed: Bool, seed: UInt64)
}

/// The art in a layer-backed view: it works a frame out on each tick of its clock and draws it with Core Text. It ticks
/// only as `ArtClock` says, so off screen, in the background or under a hidden or occluded window it has no timer.
@MainActor
final class ArtLayerView: NSView {
    enum Source {
        case sea(ArtSea)
        case loop(ArtHomeLoop)
        case frames(ArtLoopFrames, ArtHomeLoop)
    }

    let scene: ArtScene
    let painter: ArtPainter
    let mask: ArtMask
    var kind: ArtSurfaceKind { didSet { reclock() } }
    var animatedArt = true { didSet { if animatedArt != oldValue { reclock() } } }
    private(set) var source: Source?
    /// Home's loop's clock.
    private(set) var loopTime = 0.0
    private let raster = ArtRaster()
    private var maskFactors: [Float]?
    private lazy var ticker = ArtTicker(view: self) { [weak self] dt in self?.advance(by: dt) }
    private weak var observedWindow: NSWindow?
    /// A time to show once the view has its size (a render's still); nil in the app.
    var requestedTime: Double? {
        didSet { if let requestedTime, source != nil { seek(to: requestedTime) } }
    }

    init(scene: ArtScene, cell: CGFloat, kind: ArtSurfaceKind, mask: ArtMask = .none) {
        self.scene = scene
        painter = ArtPainter(cell: cell)
        self.kind = kind
        self.mask = mask
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(environmentChanged), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: The clock

    var clockInput: ArtClockInput {
        let window = window
        return ArtClockInput(
            viewOnScreen: window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty,
            windowVisible: window?.isVisible == true && window?.isMiniaturized == false,
            windowUnoccluded: window?.occlusionState.contains(.visible) == true,
            appActive: NSApp?.isActive == true && NSApp?.isHidden == false,
            animatedArt: animatedArt, kind: kind)
    }

    /// The ticker's state, for a test.
    var tickerRate: Double? { ticker.rate }
    var tickerRunning: Bool { ticker.isRunning }

    func reclock() {
        let tick = ArtClock.tick(clockInput)
        ticker.apply(tick)
        if tick == .still { needsDisplay = true }
    }

    @objc private func environmentChanged() { reclock() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        if let old = observedWindow {
            for name in Self.windowNotifications { center.removeObserver(self, name: name, object: old) }
        }
        observedWindow = window
        if let window {
            for name in Self.windowNotifications {
                center.addObserver(self, selector: #selector(environmentChanged), name: name, object: window)
            }
        }
        reclock()
    }

    private static let windowNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]

    override func viewDidHide() {
        super.viewDidHide()
        reclock()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reclock()
    }

    // MARK: The frames

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard newSize != old, newSize.width > 0, newSize.height > 0 else { return }
        layOut(for: newSize)
        if let requestedTime { seek(to: requestedTime) }
        reclock()
        needsDisplay = true
    }

    private func layOut(for size: CGSize) {
        let metrics = painter.metrics
        maskFactors = mask.factors(columns: metrics.columns(size), rows: metrics.rows(size), metrics: metrics, size: size)
        switch (scene, source) {
        case (.sea(_, _, _), .sea(var sea)?):
            sea.resize(to: size)
            source = .sea(sea)
        case (.sea(let specs, let options, let seed), _):
            source = .sea(ArtSea(size: size, metrics: metrics, options: options, specs: specs, seed: seed))
        case (.homeLoop(let precomputed, let seed), _):
            let loop = ArtHomeLoop(size: size, metrics: metrics, seed: seed)
            source = precomputed ? .frames(ArtLoopFrames(loop: loop), loop) : .loop(loop)
        }
    }

    /// Moves the art on by `dt` seconds and asks for a frame.
    func advance(by dt: Double) {
        switch source {
        case .sea(var sea)?:
            sea.advance(by: dt)
            source = .sea(sea)
        case .loop?, .frames?:
            loopTime = (loopTime + dt).truncatingRemainder(dividingBy: ArtHomeLoop.period)
        case nil: break
        }
        needsDisplay = true
    }

    /// The lit cells of the frame now.
    func currentCells() -> [UInt32] {
        switch source {
        case .sea(let sea)?: sea.frame(raster: raster).packed
        case .loop(let loop)?: loop.frame(at: loopTime, raster: raster).packed
        case .frames(let frames, _)?: Array(frames.cells(at: loopTime))
        case nil: []
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, source != nil else { return }
        let color = LoomTheme.Art.colorPair[LoomTheme.Appearance(effectiveAppearance)]
        let columns = painter.metrics.columns(bounds.size)
        if case .frames(let frames, _)? = source {
            painter.paint(frames.cells(at: loopTime), columns: columns, height: bounds.height, mask: maskFactors, color: color,
                          in: context)
        } else {
            painter.paint(currentCells(), columns: columns, height: bounds.height, mask: maskFactors, color: color, in: context)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Accessibility: the art carries nothing to read (DESIGN §17).

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The art as a SwiftUI `Canvas` drawing resolved text, one alpha step at a time: the spike's other drawing.
struct ArtCanvasView: View {
    let cells: [UInt32]
    let columns: Int
    let cell: CGFloat
    let metrics: ArtMetrics
    var mask: [Float]?

    var body: some View {
        Canvas { context, _ in
            let font = Font(LoomTheme.Art.font(cell: cell) as CTFont)
            var resolved: [UInt8: GraphicsContext.ResolvedText] = [:]
            var buckets = [[(UInt8, CGPoint)]](repeating: [], count: 64)
            for packed in cells {
                let index = ArtPackedCell.index(packed)
                var steps = Int(ArtPackedCell.steps(packed))
                if let mask { steps = Int((Float(steps) * mask[index]).rounded()) }
                guard steps > 0 else { continue }
                let point = CGPoint(x: Double(index % columns) * metrics.cellWidth, y: Double(index / columns) * metrics.cellHeight)
                buckets[steps].append((ArtPackedCell.code(packed), point))
            }
            for steps in 1..<buckets.count where !buckets[steps].isEmpty {
                context.opacity = Double(steps) / LoomTheme.Art.alphaSteps
                for (code, point) in buckets[steps] {
                    let text: GraphicsContext.ResolvedText
                    if let known = resolved[code] {
                        text = known
                    } else {
                        text = context.resolve(Text(String(ArtGlyphs.table[Int(code)])).font(font)
                            .foregroundStyle(LoomTheme.Art.colorPair.color))
                        resolved[code] = text
                    }
                    context.draw(text, at: point, anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The layer-backed art in SwiftUI.
struct ArtSurface: NSViewRepresentable {
    let scene: ArtScene
    let cell: CGFloat
    let kind: ArtSurfaceKind
    var mask: ArtMask = .none
    var animatedArt = true
    /// A time to show (a render's still); nil to start at the beginning.
    var time: Double?

    func makeNSView(context: Context) -> ArtLayerView {
        ArtLayerView(scene: scene, cell: cell, kind: kind, mask: mask)
    }

    func updateNSView(_ view: ArtLayerView, context: Context) {
        view.animatedArt = animatedArt
        if let time, view.requestedTime != time { view.requestedTime = time }
    }
}

extension ArtLayerView {
    /// Shows the art at `t` seconds from its start.
    func seek(to t: Double) {
        switch source {
        case .sea(var sea)?:
            sea.advance(by: max(0, t - (sea.time - 2)))
            source = .sea(sea)
        case .loop?, .frames?:
            loopTime = t
        case nil: break
        }
        needsDisplay = true
    }
}

/// A surface's art over its faint grid: what the new-session page and Home's band will put behind their content. It never
/// takes a click and is hidden from VoiceOver.
struct ArtBackdrop: View {
    let scene: ArtScene
    let cell: CGFloat
    let kind: ArtSurfaceKind
    var mask: ArtMask = .none
    var grid: LoomTheme.Canvas.Mask = .radial
    var animatedArt = true
    var time: Double?

    var body: some View {
        ZStack(alignment: .top) {
            CanvasGrid(mask: grid)
            ArtSurface(scene: scene, cell: cell, kind: kind, mask: mask, animatedArt: animatedArt, time: time)
                .frame(maxWidth: .infinity, maxHeight: grid == .band ? LoomTheme.Canvas.bandHeight : .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
