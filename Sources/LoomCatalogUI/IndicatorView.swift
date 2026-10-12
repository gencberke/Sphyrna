import AppKit
import LoomCore
import SwiftUI

/// design/DESIGN.md §4: small colored indicators. Working is eight dots chasing
/// around a rounded rectangle; attention and results are single dots.
extension EnvironmentValues {
    /// Whether working indicators may animate: the window is visible and
    /// active and the surface carrying them is on screen. Set by the root views
    /// from the model; static by default.
    @Entry var indicatorsAnimate = false
}

struct IndicatorView: View {
    let indicator: SessionIndicator
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    /// Stepped, low-rate animation (not display-rate).
    static let framesPerSecond = LoomTheme.Motion.chaseFramesPerSecond

    /// The chase runs only for a working conversation in an active, visible
    /// window (contract §10); otherwise it is a static frame. Like the system's
    /// own small progress spinners it keeps running under Reduce Motion (user
    /// decision, 6 Oct 2026).
    static func isAnimating(_ indicator: SessionIndicator, indicatorsAnimate: Bool) -> Bool {
        indicator == .working && indicatorsAnimate
    }

    var body: some View {
        Group {
            switch indicator {
            case .working:
                let animating = Self.isAnimating(indicator, indicatorsAnimate: indicatorsAnimate)
                ChaseDots(animating: animating).frame(width: LoomTheme.Layout.chaseSide, height: LoomTheme.Layout.chaseSide)
            case .waitingForApproval, .waitingForInput:
                dot(LoomTheme.Status.attention)
            case .unviewedCompletion:
                dot(LoomTheme.Status.unviewed)
            case .failed, .stopUnverified, .problem:
                dot(LoomTheme.Status.failure)
            case .identityUnclear:
                ring(LoomTheme.Status.attention)
            case .unknown:
                ring(LoomTheme.Text.secondary)
            case .ready, .idle, .stale, .ended:
                Color.clear
            }
        }
        .frame(width: LoomTheme.Layout.indicatorSlot.width, height: LoomTheme.Layout.indicatorSlot.height)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: LoomTheme.Layout.pip, height: LoomTheme.Layout.pip)
    }

    private func ring(_ color: Color) -> some View {
        Circle().strokeBorder(color, lineWidth: LoomTheme.Line.indicatorRing)
            .frame(width: LoomTheme.Layout.pip, height: LoomTheme.Layout.pip)
    }
}

/// Eight dots on a rounded rectangle; the bright head advances one dot per step.
/// The chase is a Core Animation discrete keyframe animation: it runs in the
/// render server, so an animating indicator costs the app no wakeups and no
/// SwiftUI updates (a TimelineView re-evaluated the whole view graph per tick).
struct ChaseDots: NSViewRepresentable {
    let animating: Bool
    /// 1 for the card's indicator; a subagent row draws the same chase smaller (same layers, same rate).
    var scale: CGFloat = 1
    static let dotCount = LoomTheme.Motion.chaseDotCount
    /// Opacity by distance behind the head.
    static let trail = LoomTheme.Motion.chaseTrail
    static let rest = LoomTheme.Motion.chaseRest

    static func opacity(dot: Int, step: Int, trail: [Double] = ChaseDots.trail, rest: Double = ChaseDots.rest) -> Double {
        let behind = ((step - dot) % dotCount + dotCount) % dotCount
        return behind < trail.count ? trail[behind] : rest
    }

    /// The dots' places on the rounded rectangle as fractions of its span, clockwise from the top-left
    /// corner (y points down): corners and edge midpoints.
    static let unit: [(x: CGFloat, y: CGFloat)] = [(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)]

    func makeNSView(context: Context) -> LayerView { LayerView(scale: scale) }

    func updateNSView(_ view: LayerView, context: Context) { view.setAnimating(animating) }

    final class LayerView: NSView {
        static let key = "chase"
        private var dots: [CALayer] = []
        private var wantsAnimation = false
        private let scale: CGFloat
        private var trail = ChaseDots.trail
        private var rest = ChaseDots.rest

        /// Whether the keyframe animation is installed (test seam).
        var isRunning: Bool { dots.first?.animation(forKey: Self.key) != nil }
        /// What the render server currently shows per dot (evidence).
        var presentedOpacities: [Float] { dots.map { $0.presentation()?.opacity ?? $0.opacity } }

        override var intrinsicContentSize: NSSize {
            NSSize(width: LoomTheme.Layout.chaseSide * scale, height: LoomTheme.Layout.chaseSide * scale)
        }

        override convenience init(frame: NSRect) { self.init(frame: frame, scale: 1) }

        convenience init(scale: CGFloat) { self.init(frame: .zero, scale: scale) }

        private init(frame: NSRect, scale: CGFloat) {
            self.scale = scale
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            let side = LoomTheme.Layout.chaseSide * scale, inset = LoomTheme.Layout.chaseInset * scale
            let radius = LoomTheme.Layout.chaseDotRadius * scale
            let span = side - 2 * inset
            // Clockwise from the top-left corner: corners and edge midpoints (view y points up).
            for (index, point) in ChaseDots.unit.enumerated() {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
                dot.cornerRadius = radius
                dot.position = CGPoint(x: inset + point.x * span, y: side - (inset + point.y * span))
                dot.backgroundColor = LoomTheme.Status.workingNS.cgColor
                dot.opacity = Float(ChaseDots.opacity(dot: index, step: 0))
                layer?.addSublayer(dot)
                dots.append(dot)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func setAnimating(_ value: Bool) {
            wantsAnimation = value
            apply()
        }

        /// A chase in another colour and trail (the menu bar item follows the bar's appearance and
        /// Increase Contrast). A running animation is rebuilt with the new opacities.
        func configure(color: CGColor, trail: [Double], rest: Double) {
            self.trail = trail
            self.rest = rest
            for (index, dot) in dots.enumerated() {
                dot.backgroundColor = color
                dot.opacity = Float(ChaseDots.opacity(dot: index, step: 0, trail: trail, rest: rest))
                dot.removeAnimation(forKey: Self.key)
            }
            apply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply() // animations do not survive leaving a window
        }

        private func apply() {
            for (index, dot) in dots.enumerated() {
                if wantsAnimation && window != nil {
                    guard dot.animation(forKey: Self.key) == nil else { continue }
                    let steps = ChaseDots.dotCount
                    let animation = CAKeyframeAnimation(keyPath: "opacity")
                    animation.calculationMode = .discrete
                    animation.values = (0..<steps).map { Float(ChaseDots.opacity(dot: index, step: $0, trail: trail, rest: rest)) }
                    animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
                    animation.duration = Double(steps) / IndicatorView.framesPerSecond
                    animation.repeatCount = .infinity
                    animation.isRemovedOnCompletion = false
                    dot.add(animation, forKey: Self.key)
                } else {
                    dot.removeAnimation(forKey: Self.key)
                }
            }
        }
    }
}

extension SessionIndicator {
    var labelColor: Color {
        switch self {
        case .waitingForApproval, .waitingForInput, .identityUnclear: LoomTheme.Status.attention
        case .failed, .stopUnverified, .problem: LoomTheme.Status.failure
        case .unviewedCompletion: LoomTheme.Status.unviewed
        default: LoomTheme.Text.secondary
        }
    }
}

extension ProjectAttention {
    var color: Color {
        switch self {
        case .failure: LoomTheme.Status.failure
        case .attention: LoomTheme.Status.attention
        case .unviewed: LoomTheme.Status.unviewed
        }
    }
}

/// Evidence: the chase animations currently installed in a window's view tree.
public enum IndicatorEvidence {
    @MainActor public static func chases(in view: NSView) -> [String: Any] {
        func find(_ view: NSView) -> [ChaseDots.LayerView] {
            (view as? ChaseDots.LayerView).map { [$0] } ?? view.subviews.flatMap(find)
        }
        let all = find(view)
        return ["total": all.count, "running": all.filter(\.isRunning).count,
                "presentedOpacities": all.first(where: \.isRunning)?.presentedOpacities.map { Double($0) } ?? []]
    }
}
