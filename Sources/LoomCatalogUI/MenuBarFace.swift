import AppKit

/// The face of the menu bar item (D-52): the mark, and in its lower right corner the working mark or a
/// status dot. Idle is a plain template image; with a badge the image is drawn by the app
/// (`MenuBarArt`) so the mark still follows the bar's appearance. The working mark is the spinner's first
/// frame, standing still: an animation in the menu bar made WindowServer's energy score read about 8 for as
/// long as any session worked, the window hidden or not (RESCUE-PLAN §5).
@MainActor
public final class MenuBarFace {
    private let button: NSStatusBarButton
    private let host = BarHost()
    private let spinner = BrailleSpinner.LayerView(style: .menuBar)
    private var images: [MenuBarBadge: NSImage] = [:]
    private var contrastObserver: NSObjectProtocol?
    public private(set) var summary = MenuBarSummary.idle

    public var badge: MenuBarBadge { summary.badge }
    /// Evidence: whether the spinner moves on the item (the evidence key is still "chaseRunning"); it never does.
    public var isChaseRunning: Bool { badge == .working && spinner.isRunning }
    public var spinnerFrame: Int? { spinner.presentedFrame }
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
        let side = LoomTheme.Spinner.menuBarSide
        spinner.frame = CGRect(x: theme.chaseOrigin.x, y: theme.canvas.height - (theme.chaseOrigin.y + side),
                               width: side, height: side)
        spinner.isHidden = true
        host.addSubview(spinner)
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

    /// Shows the summary: the image for its badge, the label, and the spinner only while it works.
    public func apply(_ summary: MenuBarSummary) {
        let wasWorking = self.summary.badge == .working
        self.summary = summary
        if images[summary.badge] == nil {
            images[summary.badge] = summary.badge == .none ? MenuBarArt.templateImage() : MenuBarArt.badgedImage(summary.badge)
        }
        if button.image !== images[summary.badge] { button.image = images[summary.badge] }
        button.setAccessibilityLabel(summary.accessibilityLabel)
        let working = summary.badge == .working
        spinner.isHidden = !working
        if working, !wasWorking { restyle() } // the mark is left alone while it keeps working
        spinner.setAnimating(false)
    }

    /// The layer colours follow the bar's appearance and Increase Contrast.
    private func restyle() {
        spinner.configure(color: MenuBarArt.spinnerColor(darkBar: MenuBarArt.isDark(button.effectiveAppearance)))
        button.needsDisplay = true
    }

    private func contrastChanged() {
        // The images draw themselves again with the new setting.
        images = [:]
        apply(summary)
        restyle()
    }

    /// Reports an appearance change of the bar (its button's effective appearance).
    private final class BarHost: NSView {
        var onAppearanceChange: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearanceChange?()
        }
    }
}
