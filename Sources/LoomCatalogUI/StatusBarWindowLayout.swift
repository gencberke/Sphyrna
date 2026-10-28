import AppKit

/// The actual main-window container: the split above the strip, and every window-level layer over both.
@MainActor
public final class StatusBarWindowLayout: NSViewController {
    private let split: NSViewController
    private let bar: NSViewController
    private let overlays: [NSView]
    private let popoverHost: InkHost?
    private var barHeight: NSLayoutConstraint?
    private var observers: [any NSObjectProtocol] = []

    public init(split: NSViewController, bar: NSViewController, overlays: [NSView], popoverHost: InkHost? = nil) {
        self.split = split
        self.bar = bar
        self.overlays = overlays
        self.popoverHost = popoverHost
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func loadView() {
        let root = StatusBarRootView()
        root.windowChanged = { [weak self] window in self?.observe(window) }
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        addChild(split)
        addChild(bar)
        let panes = split.view
        let strip = bar.view
        for child in [panes, strip] + overlays {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        let height = strip.heightAnchor.constraint(equalToConstant: LoomTheme.StatusBar.height)
        barHeight = height
        NSLayoutConstraint.activate([
            panes.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panes.topAnchor.constraint(equalTo: view.topAnchor),
            panes.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        for overlay in overlays {
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func observe(_ window: NSWindow?) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        setFullScreen(window.styleMask.contains(.fullScreen))
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let entering = note.name == NSWindow.willEnterFullScreenNotification || note.name == NSWindow.didEnterFullScreenNotification
                MainActor.assumeIsolated { self?.setFullScreen(entering) }
            }
            observers.append(observer)
        }
    }

    private func setFullScreen(_ fullScreen: Bool) {
        if fullScreen { popoverHost?.state.dismiss() }
        barHeight?.constant = fullScreen ? 0 : LoomTheme.StatusBar.height
        bar.view.isHidden = fullScreen
    }
}

private final class StatusBarRootView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}
