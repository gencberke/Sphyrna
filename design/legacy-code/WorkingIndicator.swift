import AppKit
import QuartzCore
import SwiftUI

struct WorkingDots: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> WorkingIndicatorView {
        let view = WorkingIndicatorView()
        view.reduceMotion = reduceMotion
        return view
    }

    func updateNSView(_ view: WorkingIndicatorView, context: Context) {
        view.reduceMotion = reduceMotion
        view.refreshActivity()
    }

    static func dismantleNSView(_ view: WorkingIndicatorView, coordinator: ()) {
        view.prepareForRemoval()
    }
}

@MainActor
final class WorkingIndicatorView: NSView {
    private static let animationKey = "herdr.working.rotation"
    private let spinnerLayer = CALayer()
    private var dots: [CAShapeLayer] = []
    private var isRegistered = false

    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            refreshActivity()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(spinnerLayer)
        for index in 0..<8 {
            let dot = CAShapeLayer()
            dot.opacity = Float(0.15 + Double(index) * 0.11)
            spinnerLayer.addSublayer(dot)
            dots.append(dot)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Agent is working")
        registerForActivityChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard !bounds.isEmpty else { return }
        spinnerLayer.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let orbitRadius = min(bounds.width, bounds.height) * 0.36
        let dotSide = max(2, min(bounds.width, bounds.height) * 0.15)
        let dotRect = CGRect(x: -dotSide / 2, y: -dotSide / 2, width: dotSide, height: dotSide)

        for (index, dot) in dots.enumerated() {
            let angle = Double(index) * .pi / 4 - .pi / 2
            dot.path = CGPath(ellipseIn: dotRect, transform: nil)
            dot.position = CGPoint(
                x: center.x + CGFloat(cos(angle)) * orbitRadius,
                y: center.y + CGFloat(sin(angle)) * orbitRadius
            )
        }
        updateScaleAndColor()
        refreshActivity()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScaleAndColor()
        refreshActivity()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaleAndColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateScaleAndColor()
    }

    func refreshActivity() {
        let shouldAnimate = !reduceMotion
            && window != nil
            && NSApp.isActive
            && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor

        if shouldAnimate {
            guard spinnerLayer.animation(forKey: Self.animationKey) == nil else { return }
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = Double.pi * 2
            rotation.duration = 1
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = true
            spinnerLayer.add(rotation, forKey: Self.animationKey)
        } else {
            spinnerLayer.removeAnimation(forKey: Self.animationKey)
        }
    }

    func prepareForRemoval() {
        spinnerLayer.removeAllAnimations()
        if isRegistered {
            WorkingIndicatorActivityMonitor.shared.unregister(self)
            isRegistered = false
        }
    }

    private func registerForActivityChanges() {
        guard !isRegistered else { return }
        WorkingIndicatorActivityMonitor.shared.register(self)
        isRegistered = true
    }

    private func updateScaleAndColor() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        spinnerLayer.contentsScale = scale
        let color = NSColor(red: 0.88, green: 0.86, blue: 0.92, alpha: 1).cgColor
        for dot in dots {
            dot.contentsScale = scale
            dot.fillColor = color
        }
    }
}

@MainActor
private final class WorkingIndicatorActivityMonitor: NSObject {
    static let shared = WorkingIndicatorActivityMonitor()
    private let indicators = NSHashTable<WorkingIndicatorView>.weakObjects()

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(activityChanged),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(activityChanged),
                           name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(activityChanged),
                           name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(activityChanged),
                           name: NSWindow.didMiniaturizeNotification, object: nil)
        center.addObserver(self, selector: #selector(activityChanged),
                           name: NSWindow.didDeminiaturizeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func register(_ indicator: WorkingIndicatorView) {
        indicators.add(indicator)
        indicator.refreshActivity()
    }

    func unregister(_ indicator: WorkingIndicatorView) {
        indicators.remove(indicator)
    }

    @objc private func activityChanged() {
        for indicator in indicators.allObjects { indicator.refreshActivity() }
    }
}
