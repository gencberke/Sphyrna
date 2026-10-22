import AppKit
import CoreText
import SwiftUI

// Drawing the art (DESIGN §17 Quiet, Accessibility): a frame's glyphs in the art colour at each cell's alpha, under the
// surface's mask, over the faint grid (`CanvasGrid`). A layer-backed AppKit view draws them with Core Text (`ArtLayerView`;
// the spike chose it over a SwiftUI `Canvas`, `evidence/ink/i5/spike.md`), ticking only as `ArtClock` says. It is hidden
// from VoiceOver and never takes a click.

/// The mask over a surface's art (the reference's `.ocean.calm` and `.ocean.band`), as a factor per cell.
enum ArtMask: Sendable, Equatable {
    case none
    /// The new-session page: faint at the middle, where the question is.
    case calm
    /// Home's band: whole at the top, fading to nothing at its foot.
    case band
    /// The first launch: faint in the message's middle.
    case firstLaunch

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
                case .firstLaunch:
                    let dx = (x - w * Double(A.firstMaskCentrePoint.x)) / (w * Double(A.firstMaskRadii.width))
                    let dy = (y - h * Double(A.firstMaskCentrePoint.y)) / (h * Double(A.firstMaskRadii.height))
                    let d = min(1, hypot(dx, dy))
                    factor = d <= A.firstMaskInnerAt
                        ? A.firstMaskCentre + (A.firstMaskInner - A.firstMaskCentre) * d / A.firstMaskInnerAt
                        : A.firstMaskInner + (1 - A.firstMaskInner) * (d - A.firstMaskInnerAt) / (1 - A.firstMaskInnerAt)
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
    /// A sea of sharks (the new-session page, the first launch, About, a shark in place).
    case sea(specs: [ArtSharkSpec], options: ArtSea.Options, seed: UInt64)
    /// Home's loop, drawn live or from its frames worked out once.
    case homeLoop(precomputed: Bool, seed: UInt64)
    /// Home's Remora section: the arrival, then the remora at rest beside its sentence (`ArtRemoraCue` places it).
    case remoraLane
    /// The remora at the start of the folded brief's line.
    case remoraFold
}

/// What Home's Remora section tells its lane.
struct ArtRemoraCue: Equatable, Sendable {
    /// The remora's head at rest, in the lane's points (y down); nil while the brief's place is not laid out, and then nothing
    /// is drawn.
    var rest: CGPoint?
    /// An arrival is asked for (a new brief: the first Home of the day, Catch Me Up): it plays from its start once the lane has
    /// its size and the remora its place, and the lane reports `.started` so the section can drop the ask.
    var arrive = false
    /// Remora reads and its sentence has not come in: the remora swims in place. Otherwise it holds still.
    var swimming = false
}

/// What the lane tells the Remora section.
enum ArtLaneEvent: Equatable, Sendable {
    /// The arrival began (or, with Animated art off, the remora took its place at once).
    case started
    /// The band may have its hammerhead back: `bandBackDelay` after the host left at the left, or at once when the arrival
    /// was cut short.
    case bandBack
}

/// What the Remora section tells the band's loop: the arrival took its hammerhead, and how many times it came back.
struct ArtBandCue: Equatable, Sendable {
    var away = false
    var backs = 0
}

extension EnvironmentValues {
    /// Settings → Theme → Animated art (DESIGN §17, D-79): on, the art moves (under Reduce Motion too); off, every drawing stands
    /// still on one frame. The window sets it from `CatalogModel.animatedArt`.
    @Entry var animatedArt = true
}

/// The art in a layer-backed view: it works a frame out on each tick of its clock and draws it with Core Text. It ticks
/// only as `ArtClock` says, so off screen, in the background or under a hidden or occluded window it has no timer.
@MainActor
final class ArtLayerView: NSView {
    enum Source {
        case sea(ArtSea)
        case loop(ArtHomeLoop)
        case frames(ArtLoopFrames, ArtHomeLoop)
        case lane(ArtArrival)
        case fold
    }

    let scene: ArtScene
    let painter: ArtPainter
    let mask: ArtMask
    /// The place's rate kind; what it draws at now is `drawnKind` (a rested crossing, the lane's stage, the band given up).
    var kind: ArtSurfaceKind { didSet { reclock() } }
    var animatedArt: Bool {
        didSet {
            guard animatedArt != oldValue else { return }
            // Off mid-arrival: the remora takes its place at once.
            if !animatedArt, case .lane(var lane)? = source, lane.stage != .resting {
                lane.settle()
                source = .lane(lane)
                onLaneEvent?(.bandBack)
            }
            reclock()
            needsDisplay = true
        }
    }
    /// A crossing comes back to its start each time its window shows again (About).
    var replaysWhenShown = false
    var remora = ArtRemoraCue() { didSet { if remora != oldValue { remoraChanged(from: oldValue) } } }
    var band = ArtBandCue() { didSet { if band != oldValue { bandChanged(from: oldValue) } } }
    /// The lane's events (`ArtLaneEvent`).
    var onLaneEvent: (@MainActor (ArtLaneEvent) -> Void)?
    private(set) var source: Source?
    /// Home's loop's clock.
    private(set) var loopTime = 0.0
    private let raster = ArtRaster()
    private var maskFactors: [Float]?
    private lazy var ticker = ArtTicker(view: self) { [weak self] dt in self?.advance(by: dt) }
    private weak var observedWindow: NSWindow?
    private var arrivalWaits = false
    private var wasSeen = false
    private var seenOnce = false
    /// A time to show once the view has its size (a render's still); nil in the app.
    var requestedTime: Double? {
        didSet { if let requestedTime, source != nil { seek(to: requestedTime) } }
    }

    init(scene: ArtScene, cell: CGFloat, weight: NSFont.Weight = .regular, kind: ArtSurfaceKind, mask: ArtMask = .none,
         animatedArt: Bool = true) {
        self.scene = scene
        painter = ArtPainter(cell: cell, weight: weight)
        self.kind = kind
        self.mask = mask
        self.animatedArt = animatedArt
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

    /// The kind it draws at now: a crossing that rested, the folded remora and a band whose hammerhead the arrival took stand
    /// still; the lane follows its stage.
    var drawnKind: ArtSurfaceKind {
        switch source {
        case .lane(let lane)?: return lane.kind
        case .fold?: return .resting
        case .sea(let sea)? where sea.hasRested: return .resting
        case .loop?, .frames?: return band.away ? .resting : kind
        default: return kind
        }
    }

    var clockInput: ArtClockInput {
        let window = window
        return ArtClockInput(
            viewOnScreen: window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty,
            windowVisible: window?.isVisible == true && window?.isMiniaturized == false,
            windowUnoccluded: window?.occlusionState.contains(.visible) == true,
            appActive: NSApp?.isActive == true && NSApp?.isHidden == false,
            animatedArt: animatedArt, kind: drawnKind)
    }

    /// The ticker's state, for a test.
    var tickerRate: Double? { ticker.rate }
    var tickerRunning: Bool { ticker.isRunning }

    func reclock() {
        let input = clockInput
        let seen = input.viewOnScreen && input.windowVisible && input.windowUnoccluded
        // About: each time its window shows again, the hammerhead crosses again.
        if replaysWhenShown, seen, !wasSeen, seenOnce, bounds.width > 0, bounds.height > 0 {
            source = nil
            layOut(for: bounds.size)
        }
        if seen { seenOnce = true }
        wasSeen = seen
        let tick = ArtClock.tick(input)
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
        case (.sea(let specs, var options, let seed), _):
            // Animated art off: no entry and no crossing, so the one frame shows the sharks where they swim or rest.
            options.entering = animatedArt
            options.atRest = !animatedArt
            source = .sea(ArtSea(size: size, metrics: metrics, options: options, specs: specs, seed: seed))
        case (.homeLoop(let precomputed, let seed), _):
            let loop = ArtHomeLoop(size: size, metrics: metrics, seed: seed)
            source = precomputed ? .frames(ArtLoopFrames(loop: loop), loop) : .loop(loop)
        case (.remoraLane, _):
            // A new size settles the remora at its place, even mid-arrival: an arrival cut short gives the band its hammerhead back.
            if case .lane(let lane)? = source, lane.stage != .resting { onLaneEvent?(.bandBack) }
            source = remora.rest.map { .lane(ArtArrival(size: size, metrics: metrics, rest: $0, arriving: false)) }
            if arrivalWaits { startArrival() }
        case (.remoraFold, _):
            source = .fold
        }
    }

    private func remoraChanged(from old: ArtRemoraCue) {
        guard case .remoraLane = scene else { return }
        if remora.rest != old.rest, bounds.width > 0, bounds.height > 0 {
            if case .lane(let lane)? = source, lane.stage != .resting {
                // The arrival plays to the place it started for; a resize settles it.
            } else {
                source = remora.rest.map { .lane(ArtArrival(size: bounds.size, metrics: painter.metrics, rest: $0, arriving: false)) }
                needsDisplay = true
            }
        }
        if remora.arrive, !old.arrive || arrivalWaits { startArrival() }
        reclock()
    }

    /// Plays the arrival from its start, once the lane has its size and the remora its place; with Animated art off the remora
    /// is at its place at once (the section fades it in).
    private func startArrival() {
        guard let rest = remora.rest, bounds.width > 0, bounds.height > 0 else {
            arrivalWaits = true
            return
        }
        arrivalWaits = false
        source = .lane(ArtArrival(size: bounds.size, metrics: painter.metrics, rest: rest, arriving: animatedArt))
        reclock()
        needsDisplay = true
        onLaneEvent?(.started)
    }

    private func bandChanged(from old: ArtBandCue) {
        // The hammerhead comes back in from the left along the loop's lower pass.
        if band.backs > old.backs { loopTime = ArtHomeLoop.backTime }
        reclock()
        needsDisplay = true
    }

    /// Moves the art on by `dt` seconds and asks for a frame.
    func advance(by dt: Double) {
        let before = drawnKind
        switch source {
        case .sea(var sea)?:
            sea.advance(by: dt)
            source = .sea(sea)
        case .loop?, .frames?:
            loopTime = (loopTime + dt).truncatingRemainder(dividingBy: ArtHomeLoop.period)
        case .lane(var lane)?:
            let left = lane.step(by: dt, swimming: remora.swimming)
            source = .lane(lane)
            if left { onLaneEvent?(.bandBack) }
        case .fold?, nil: break
        }
        if drawnKind != before { reclock() }
        needsDisplay = true
    }

    /// The lit cells of the frame now.
    func currentCells() -> [UInt32] {
        switch source {
        case .sea(let sea)?: sea.frame(raster: raster).packed
        case .loop(let loop)?: band.away ? [] : loop.frame(at: loopTime, raster: raster).packed
        case .frames(let frames, _)?: band.away ? [] : Array(frames.cells(at: loopTime))
        case .lane(let lane)?: lane.frame(raster: raster).packed
        case .fold?: ArtFoldRemora.frame(size: bounds.size, metrics: painter.metrics, raster: raster).packed
        case nil: []
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, source != nil else { return }
        let color = LoomTheme.Art.colorPair[LoomTheme.Appearance(effectiveAppearance)]
        let columns = painter.metrics.columns(bounds.size)
        if case .frames(let frames, _)? = source {
            guard !band.away else { return }
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

extension ArtLayerView {
    /// Shows the art at `t` seconds from its start.
    func seek(to t: Double) {
        switch source {
        case .sea(var sea)?:
            sea.advance(by: max(0, t - (sea.time - 2)))
            source = .sea(sea)
        case .loop?, .frames?:
            loopTime = t
        case .lane(var lane)?:
            while lane.time < t, lane.stage != .resting { lane.step(by: 1 / LoomTheme.Art.arrivalFPS, swimming: remora.swimming) }
            source = .lane(lane)
        case .fold?, nil: break
        }
        needsDisplay = true
    }
}

/// The layer-backed art in SwiftUI. It reads Animated art from the environment.
struct ArtSurface: NSViewRepresentable {
    let scene: ArtScene
    let cell: CGFloat
    var weight: NSFont.Weight = .regular
    let kind: ArtSurfaceKind
    var mask: ArtMask = .none
    var replaysWhenShown = false
    var remora: ArtRemoraCue?
    var band: ArtBandCue?
    var onLaneEvent: (@MainActor (ArtLaneEvent) -> Void)?
    /// A time to show (a render's still); nil to start at the beginning.
    var time: Double?

    init(scene: ArtScene, cell: CGFloat, weight: NSFont.Weight = .regular, kind: ArtSurfaceKind, mask: ArtMask = .none,
         time: Double? = nil) {
        self.scene = scene
        self.cell = cell
        self.weight = weight
        self.kind = kind
        self.mask = mask
        self.time = time
    }

    /// The art of one of the app's places (`ArtPlace`).
    init(place: ArtPlace, remora: ArtRemoraCue? = nil, band: ArtBandCue? = nil,
         onLaneEvent: (@MainActor (ArtLaneEvent) -> Void)? = nil, time: Double? = nil) {
        self.init(scene: place.scene, cell: place.cell, weight: place.weight, kind: place.kind, mask: place.mask, time: time)
        replaysWhenShown = place.replaysWhenShown
        self.remora = remora
        self.band = band
        self.onLaneEvent = onLaneEvent
    }

    func makeNSView(context: Context) -> ArtLayerView {
        let view = ArtLayerView(scene: scene, cell: cell, weight: weight, kind: kind, mask: mask,
                                animatedArt: context.environment.animatedArt)
        view.replaysWhenShown = replaysWhenShown
        return view
    }

    func updateNSView(_ view: ArtLayerView, context: Context) {
        view.animatedArt = context.environment.animatedArt
        view.onLaneEvent = onLaneEvent
        if let remora { view.remora = remora }
        if let band { view.band = band }
        if let time, view.requestedTime != time { view.requestedTime = time }
    }
}

/// A surface's art over its faint grid: what the new-session page, Home's band and the first launch put behind their content.
/// It never takes a click and is hidden from VoiceOver.
struct ArtBackdrop: View {
    let scene: ArtScene
    let cell: CGFloat
    let kind: ArtSurfaceKind
    var mask: ArtMask = .none
    var grid: LoomTheme.Canvas.Mask = .radial
    var band: ArtBandCue?
    var time: Double?

    init(scene: ArtScene, cell: CGFloat, kind: ArtSurfaceKind, mask: ArtMask = .none, grid: LoomTheme.Canvas.Mask = .radial,
         time: Double? = nil) {
        self.scene = scene
        self.cell = cell
        self.kind = kind
        self.mask = mask
        self.grid = grid
        self.time = time
    }

    init(place: ArtPlace, grid: LoomTheme.Canvas.Mask, band: ArtBandCue? = nil, time: Double? = nil) {
        self.init(scene: place.scene, cell: place.cell, kind: place.kind, mask: place.mask, grid: grid, time: time)
        self.band = band
    }

    var body: some View {
        ZStack(alignment: .top) {
            CanvasGrid(mask: grid)
            ArtSurface(scene: scene, cell: cell, kind: kind, mask: mask, time: time)
                .bandCue(band)
                .frame(maxWidth: .infinity, maxHeight: grid == .band ? LoomTheme.Canvas.bandHeight : .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension ArtSurface {
    func bandCue(_ cue: ArtBandCue?) -> ArtSurface {
        var copy = self
        copy.band = cue
        return copy
    }
}
