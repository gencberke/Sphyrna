import AppKit
import LoomCatalogUI
import LoomTerminal
import SwiftUI

/// The one Settings window: a fixed 680×520, reused by Cmd+, the gear and the usage chip.
/// The title bar is transparent so the section switcher sits on the same 26 pt centerline as the
/// main window's controls; the window is built on first use and only hidden when closed.
@MainActor
final class SettingsWindowController {
    static let contentSize = NSSize(width: 680, height: 520)

    let navigation = SettingsNavigation()
    private let model: CatalogModel
    private let usage: UsageModel?
    private let about: SettingsAbout
    private let diagnostics: DiagnosticsCollection?
    private(set) var window: NSWindow?

    init(model: CatalogModel, usage: UsageModel?, about: SettingsAbout, diagnostics: DiagnosticsCollection? = nil) {
        self.model = model
        self.usage = usage
        self.about = about
        self.diagnostics = diagnostics
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window (building it once). A section jumps to it; nil keeps the current one.
    func show(section: SettingsSection?) {
        navigation.open(section)
        let window = window ?? makeWindow()
        self.window = window
        usage?.refresh(reason: .settingsOpened)
        model.integration.refresh() // what the system says about notifications and the login item
        window.makeKeyAndOrderFront(nil)
        usage?.setSettingsWindowVisible(true) // the occlusion notifications correct it if the window is covered
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("loom-settings")
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        // The window follows the app's appearance (Settings → Theme); its background is the main pane's panel.
        window.backgroundColor = model.themePanelBackground
        for kind in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        let hosting = NSHostingController(
            rootView: SettingsView(model: model, usage: usage, navigation: navigation, about: about,
                                   diagnostics: diagnostics))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.contentSize)
        window.center()
        observeVisibility(of: window)
        return window
    }

    /// The Usage page counts as visible while this window is on screen, not covered, not minimized
    /// (it is a separate window, so the main window's activity says nothing about it).
    private func observeVisibility(of window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] notification in
                let closing = notification.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    guard let window else { return }
                    let showing = !closing && window.isVisible && !window.isMiniaturized
                        && window.occlusionState.contains(.visible)
                    self?.usage?.setSettingsWindowVisible(showing)
                }
            }
        }
    }
}
