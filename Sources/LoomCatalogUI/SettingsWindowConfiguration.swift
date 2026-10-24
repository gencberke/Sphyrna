import AppKit
import SwiftUI

/// The one Settings window's shape: a fixed 680×520 with a transparent title bar over an empty unified toolbar, so the close button
/// sits on the same 26 pt centerline as the main window's controls and the section tabs draw in the 52 pt band. The app's window
/// controller and the window tests build it here, so the tests click in the real window and not in a copy.
@MainActor
public enum SettingsWindowConfiguration {
    public static var contentSize: NSSize { NSSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height) }

    /// A window hosting `content`, centred and not yet shown. Closing it closes the sheet open over Settings, so the window comes
    /// back without it.
    public static func makeWindow(content: SettingsView, background: NSColor) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("loom-settings")
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar, as the main window has (`AppDelegate.makeWindow`): AppKit centres the close button in the
        // unified titlebar height, on y = 26. No item or separator is shown.
        window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("loom-settings"))
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        // Not movable by its background: in such a window AppKit takes a mouse-down on SwiftUI's drawn controls as the start of a
        // drag, and the section tabs and the pages' controls never saw their clicks (1.6.0). The title strip still moves it.
        window.backgroundColor = background
        for kind in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(contentSize)
        window.center()
        let navigation = content.navigation
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { navigation.sheets.dismiss() }
        }
        return window
    }
}
