import AppKit
import LoomCore
import LoomTerminal
import SwiftUI

/// design/DESIGN.md §3 source colors.
enum CatalogTheme {
    static let sidebar = Color(red: 0.043, green: 0.055, blue: 0.086)
    /// The panel and the terminal share one background (TerminalTheme is the source).
    static let panel = Color(nsColor: TerminalTheme.background)
    static let accent = Color(red: 0.53, green: 0.57, blue: 0.81)
    static let text = Color(red: 0.88, green: 0.86, blue: 0.92)
    static let secondary = Color(red: 0.46, green: 0.48, blue: 0.55)
    static let hairline = Color.white.opacity(0.10)
    static let selection = Color.white.opacity(0.07)
    static let attention = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let unviewed = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let failure = Color(red: 0.95, green: 0.38, blue: 0.36)

    static let sidebarWidthRange = UIPreferences.sidebarWidthRange
    // Header geometry. The unified toolbar centers the native window buttons
    // 26 pt below the window top (x 19...79), which is also the center of the
    // 52 pt sidebar header row and of the detail header row.
    static let headerHeight: CGFloat = 52
    static let detailRowHeight: CGFloat = 36
    /// Sidebar header: space before the toggle so it clears the native buttons.
    static let sidebarButtonsGap: CGFloat = 76
    /// Detail header (collapsed sidebar): space reserved for the native buttons.
    static let detailButtonsGap: CGFloat = 66
}

@MainActor
enum ProviderImages {
    private static var cache: [String: NSImage] = [:]

    static func image(for provider: ManagedSession.Provider) -> NSImage? {
        let name: String
        switch provider {
        case .claude: name = "harness-claude"
        case .codex: name = "harness-codex"
        case .synthetic: return nil
        }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

struct ProviderIcon: View {
    let provider: ManagedSession.Provider
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let image = ProviderImages.image(for: provider) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: provider == .synthetic ? "terminal" : "sparkles")
                    .resizable().aspectRatio(contentMode: .fit).foregroundStyle(CatalogTheme.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// design/DESIGN.md §5: small colored indicators. Working is eight dots chasing
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
    static let framesPerSecond = 10.0

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
                ChaseDots(animating: animating).frame(width: 12, height: 12)
            case .waitingForApproval, .waitingForInput:
                dot(CatalogTheme.attention)
            case .unviewedCompletion:
                dot(CatalogTheme.unviewed)
            case .failed, .stopUnverified, .problem:
                dot(CatalogTheme.failure)
            case .identityUnclear:
                Circle().strokeBorder(CatalogTheme.attention, lineWidth: 1.5).frame(width: 8, height: 8)
            case .unknown:
                Circle().strokeBorder(CatalogTheme.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
            case .ready, .idle, .stale, .ended:
                Color.clear
            }
        }
        .frame(width: 12, height: 16)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Eight dots on a rounded rectangle; the bright head advances one dot per step.
/// The chase is a Core Animation discrete keyframe animation: it runs in the
/// render server, so an animating indicator costs the app no wakeups and no
/// SwiftUI updates (a TimelineView re-evaluated the whole view graph per tick).
struct ChaseDots: NSViewRepresentable {
    let animating: Bool
    static let dotCount = 8
    /// Opacity by distance behind the head.
    static let trail: [Double] = [1, 0.8, 0.55, 0.35]
    static let rest = 0.16

    static func opacity(dot: Int, step: Int) -> Double {
        let behind = ((step - dot) % dotCount + dotCount) % dotCount
        return behind < trail.count ? trail[behind] : rest
    }

    func makeNSView(context: Context) -> LayerView { LayerView() }

    func updateNSView(_ view: LayerView, context: Context) { view.setAnimating(animating) }

    final class LayerView: NSView {
        static let key = "chase"
        private var dots: [CALayer] = []
        private var wantsAnimation = false

        /// Whether the keyframe animation is installed (test seam).
        var isRunning: Bool { dots.first?.animation(forKey: Self.key) != nil }
        /// What the render server currently shows per dot (evidence).
        var presentedOpacities: [Float] { dots.map { $0.presentation()?.opacity ?? $0.opacity } }

        override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 12) }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            let side: CGFloat = 12, inset: CGFloat = 1.6, radius: CGFloat = 1.45
            let span = side - 2 * inset
            // Clockwise from the top-left corner: corners and edge midpoints (view y points up).
            let unit: [(CGFloat, CGFloat)] = [(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)]
            for (index, point) in unit.enumerated() {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
                dot.cornerRadius = radius
                dot.position = CGPoint(x: inset + point.0 * span, y: side - (inset + point.1 * span))
                dot.backgroundColor = NSColor(CatalogTheme.text).cgColor
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
                    animation.values = (0..<steps).map { Float(ChaseDots.opacity(dot: index, step: $0)) }
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
        case .waitingForApproval, .waitingForInput, .identityUnclear: CatalogTheme.attention
        case .failed, .stopUnverified, .problem: CatalogTheme.failure
        case .unviewedCompletion: CatalogTheme.unviewed
        default: CatalogTheme.secondary
        }
    }
}

extension ProjectAttention {
    var color: Color {
        switch self {
        case .failure: CatalogTheme.failure
        case .attention: CatalogTheme.attention
        case .unviewed: CatalogTheme.unviewed
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
