import AppKit
import CoreText
import SwiftUI

/// The pre-drawn frames of Ink's working spinner and the one animation that steps them (DESIGN §4).
/// A frame is an image of one braille glyph at its size, in the colour of its appearance and at the screen's scale.
enum BrailleFrames {
    /// The sizes the spinner is drawn at.
    enum Style: Equatable {
        /// 14 pt in the 12 pt status slot, in primary.
        case status
        /// 12.5 pt in a subagent row, in secondary.
        case subagent
        /// The menu bar badge, in the bar's own white or black.
        case menuBar

        var pointSize: CGFloat {
            switch self {
            case .status: LoomTheme.Spinner.statusPointSize
            case .subagent: LoomTheme.Spinner.subagentPointSize
            case .menuBar: LoomTheme.Spinner.menuBarPointSize
            }
        }

        var side: CGFloat { self == .menuBar ? LoomTheme.Spinner.menuBarSide : LoomTheme.Spinner.side }

        /// The colour that follows the appearance; the menu bar takes a fixed one.
        func color(_ appearance: LoomTheme.Appearance, increasedContrast: Bool) -> CGColor {
            switch self {
            case .status, .menuBar: LoomTheme.Text.primaryPair[appearance].cgColor
            case .subagent:
                (increasedContrast ? LoomTheme.Text.secondaryIncreasedPair : LoomTheme.Text.secondaryPair)[appearance].cgColor
            }
        }
    }

    /// The layer's animation key.

    static var frameCount: Int { LoomTheme.Spinner.frames.count }

    /// One frame as an image of `style.side` points square at `scale`, the glyph centred by the full cell's ink so
    /// every frame stands where the others do.
    static func image(frame: Int, style: Style, color: CGColor, scale: CGFloat) -> CGImage? {
        let pixels = Int((style.side * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(pixels) / style.side, y: CGFloat(pixels) / style.side)
        let font = NSFont.monospacedSystemFont(ofSize: style.pointSize, weight: .regular)
        func line(_ glyph: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
        }
        // The full cell (all eight dots) is the same in every frame and sets where the glyph goes.
        let cell = CTLineGetImageBounds(line("\u{283F}"), context)
        context.setFillColor(color)
        context.textPosition = CGPoint(x: (style.side - cell.width) / 2 - cell.minX,
                                       y: (style.side - cell.height) / 2 - cell.minY)
        CTLineDraw(line(LoomTheme.Spinner.frames[frame]), context)
        return context.makeImage()
    }

    /// Draws `frame` into a context whose y axis points down (the menu bar art and the menu's glyph), in `rect`.
    static func draw(frame: Int, style: Style, color: CGColor, in context: CGContext, rect: CGRect, scale: CGFloat) {
        guard let image = image(frame: frame, style: style, color: color, scale: scale) else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// Steps every moving spinner of the process on one clock, twice a second (D-125). The render-server animation of 1.8.0
/// (a 12 fps `CAKeyframeAnimation`) cost the app no wakeups, but while it ran WindowServer composited the window at the
/// display's rate: about 9 % of one core while a session worked in view, against 2.2 % with the spinner standing still.
/// Each step set from the app costs WindowServer one composite, so the rate sets the cost: 3.6 % at two steps a second
/// (`evidence/r9/release-1.8.0/ENERGY.md`). The clock runs only while a spinner moves; the app's spinners share `shared`, and
/// a test gives its spinners a clock of their own.
@MainActor final class SpinnerClock {
    static let shared = SpinnerClock()
    private let views = NSHashTable<BrailleSpinner.LayerView>.weakObjects()
    private var loop: Task<Void, Never>?
    /// The frame every moving spinner shows now: they step together.
    private(set) var frame = 0

    init() {}

    /// Whether the clock runs (test seam).
    var isTicking: Bool { loop != nil }

    func start(_ view: BrailleSpinner.LayerView) {
        views.add(view)
        view.show(frame: frame)
        guard loop == nil else { return }
        let step = Duration.seconds(1 / LoomTheme.Spinner.framesPerSecond)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: step, tolerance: step / 10)
                guard !Task.isCancelled, let self else { return }
                self.step()
            }
        }
    }

    func stop(_ view: BrailleSpinner.LayerView) {
        views.remove(view)
        if views.allObjects.isEmpty { halt() }
    }

    private func step() {
        let moving = views.allObjects
        guard !moving.isEmpty else { return halt() }
        frame = (frame + 1) % BrailleFrames.frameCount
        for view in moving { view.show(frame: frame) }
    }

    private func halt() {
        loop?.cancel()
        loop = nil
    }
}

/// Ink's working mark: the braille spinner (DESIGN §4). A layer holds the current frame; while it moves, `SpinnerClock`
/// sets the next of the ten pre-drawn frames as its contents, twice a second, with no redraw and no SwiftUI update.
struct BrailleSpinner: NSViewRepresentable {
    let animating: Bool
    var style: BrailleFrames.Style = .status

    func makeNSView(context: Context) -> LayerView { LayerView(style: style) }

    func updateNSView(_ view: LayerView, context: Context) {
        // The spinner takes the scheme the SwiftUI environment resolves (the terminal face's header is dark in Light).
        view.setAppearance(LoomTheme.Appearance(context.environment.colorScheme),
                           increasedContrast: context.environment.colorSchemeContrast == .increased)
        view.setAnimating(animating)
    }

    final class LayerView: NSView {
        let style: BrailleFrames.Style
        private let imageLayer = CALayer()
        private var frames: [CGImage] = []
        private var renderedColor: CGColor?
        private var renderedScale: CGFloat = 0
        private var wantsAnimation = false
        private var appearanceOverride: LoomTheme.Appearance?
        private var increasedContrast = false
        /// A fixed colour (the menu bar item) replaces the one that follows the appearance.
        private var fixedColor: CGColor?
        private let clock: SpinnerClock
        /// How many times the frames were drawn (test seam): once per colour or scale, never per step.
        private(set) var renderCount = 0

        /// Whether the spinner moves, stepped by `SpinnerClock` (test seam).
        private(set) var isRunning = false
        /// The ten frames as drawn now, in order (test seam).
        var frameImages: [CGImage] { frames }
        /// The colour the frames are drawn in now (test seam).
        var glyphColor: CGColor? { renderedColor }
        /// The index of the frame the render server shows now (evidence); nil before the first frame.
        var presentedFrame: Int? {
            guard let shown = imageLayer.presentation()?.contents ?? imageLayer.contents else { return nil }
            return frames.firstIndex { CFEqual($0, shown as CFTypeRef) }
        }

        override var intrinsicContentSize: NSSize { NSSize(width: style.side, height: style.side) }

        override convenience init(frame: NSRect) { self.init(style: .status) }

        init(style: BrailleFrames.Style, clock: SpinnerClock = .shared) {
            self.style = style
            self.clock = clock
            super.init(frame: NSRect(origin: .zero, size: NSSize(width: style.side, height: style.side)))
            wantsLayer = true
            layer?.masksToBounds = false
            // A standalone layer fades its contents in by default; the spinner steps.
            imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            imageLayer.bounds = CGRect(origin: .zero, size: CGSize(width: style.side, height: style.side))
            layer?.addSublayer(imageLayer)
            render()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// The look the SwiftUI environment resolves for this spinner; nil follows the view's own appearance.
        func setAppearance(_ appearance: LoomTheme.Appearance?, increasedContrast: Bool = false) {
            guard appearance != appearanceOverride || increasedContrast != self.increasedContrast else { return }
            appearanceOverride = appearance
            self.increasedContrast = increasedContrast
            render()
        }

        /// A spinner in one fixed colour (the menu bar item follows the bar's appearance).
        func configure(color: CGColor) {
            fixedColor = color
            render()
        }

        func setAnimating(_ value: Bool) {
            wantsAnimation = value
            apply()
        }

        override func layout() {
            super.layout()
            imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            render()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            render()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            render()
            apply() // a spinner out of a window stops
        }

        private func resolvedColor() -> CGColor {
            fixedColor ?? style.color(appearanceOverride ?? LoomTheme.Appearance(effectiveAppearance),
                                      increasedContrast: increasedContrast)
        }

        /// Draws the frames again when the colour or the screen's scale changed since the last time.
        private func render() {
            let color = resolvedColor()
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            guard frames.isEmpty || color != renderedColor || scale != renderedScale else { return }
            let drawn = (0..<BrailleFrames.frameCount).compactMap { BrailleFrames.image(frame: $0, style: style, color: color, scale: scale) }
            guard drawn.count == BrailleFrames.frameCount else { return }
            renderCount += 1
            frames = drawn
            renderedColor = color
            renderedScale = scale
            imageLayer.contentsScale = scale
            imageLayer.contents = drawn[isRunning ? clock.frame : 0]
            apply()
        }

        /// The clock's step: the frame's contents, with no implicit fade (`actions` maps contents to none).
        func show(frame: Int) {
            guard frames.indices.contains(frame) else { return }
            imageLayer.contents = frames[frame]
        }

        private func apply() {
            if wantsAnimation && window != nil && !frames.isEmpty {
                guard !isRunning else { return }
                isRunning = true
                clock.start(self)
            } else {
                if isRunning { clock.stop(self) }
                isRunning = false
                if let first = frames.first { imageLayer.contents = first }
            }
        }
    }
}
