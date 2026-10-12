import AppKit

/// The face of the menu bar item (D-52): the mark, and in its lower right corner the working chase or a
/// status dot. Idle is a plain template image; with a badge the image is drawn by Loom
/// (`MenuBarArt`) so the mark still follows the bar's appearance. The chase is a render-server layer
/// animation on top of the image, added when the badge becomes working and removed in every other state:
/// no timer, no polling, no image swaps per step, so the item costs the app no wakeups while it moves.
@MainActor
public final class MenuBarFace {
    private let button: NSStatusBarButton
    private let host = ChaseHost()
    private let chase = ChaseDots.LayerView(scale: LoomTheme.MenuBar.chaseScale)
    private var images: [MenuBarBadge: NSImage] = [:]
    private var contrastObserver: NSObjectProtocol?
    public private(set) var summary = MenuBarSummary.idle

    public var badge: MenuBarBadge { summary.badge }
    /// Evidence: whether the chase animation is installed on the item.
    public var isChaseRunning: Bool { badge == .working && chase.isRunning }
    public var chaseOpacities: [Float] { chase.presentedOpacities }
    public var appearanceName: String { button.effectiveAppearance.name.rawValue }

    public init(button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            host.widthAnchor.constraint(equalToConstant: MenuBarArt.canvas.width),
            host.heightAnchor.constraint(equalToConstant: MenuBarArt.canvas.height),
        ])
        let theme = LoomTheme.MenuBar.self
        let side = LoomTheme.Layout.chaseSide * theme.chaseScale
        chase.frame = CGRect(x: theme.markOrigin.x + theme.chaseOrigin.x,
                             y: theme.canvas.height - (theme.markOrigin.y + theme.chaseOrigin.y + side),
                             width: side, height: side)
        chase.isHidden = true
        host.addSubview(chase)
        host.onAppearanceChange = { [weak self] in self?.restyle() }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.contrastChanged() }
        }
        apply(.idle)
    }

    isolated deinit {
        if let contrastObserver { NSWorkspace.shared.notificationCenter.removeObserver(contrastObserver) }
    }

    /// Shows the summary: the image for its badge, the label, and the chase only while it works.
    public func apply(_ summary: MenuBarSummary) {
        let wasWorking = self.summary.badge == .working
        self.summary = summary
        if images[summary.badge] == nil {
            images[summary.badge] = summary.badge == .none ? MenuBarArt.templateImage() : MenuBarArt.badgedImage(summary.badge)
        }
        if button.image !== images[summary.badge] { button.image = images[summary.badge] }
        button.setAccessibilityLabel(summary.accessibilityLabel)
        let working = summary.badge == .working
        chase.isHidden = !working
        if working, !wasWorking { restyle() } // a running chase is left alone while it keeps working
        chase.setAnimating(working)
    }

    /// The layer colours follow the bar's appearance and Increase Contrast.
    private func restyle() {
        let colors = MenuBarArt.chaseColors(
            darkBar: MenuBarArt.isDark(button.effectiveAppearance),
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        chase.configure(color: colors.color, trail: colors.trail, rest: colors.rest)
        button.needsDisplay = true
    }

    private func contrastChanged() {
        // The images draw themselves again with the new setting.
        images = [:]
        apply(summary)
        restyle()
    }

    /// Reports an appearance change of the bar (its button's effective appearance).
    private final class ChaseHost: NSView {
        var onAppearanceChange: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearanceChange?()
        }
    }
}
