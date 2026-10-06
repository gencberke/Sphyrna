import AppKit
import LoomCatalogUI
import LoomTerminal
import SwiftUI

/// The one Settings window: dark, a fixed 680×520, reused by Cmd+, the gear and the usage chip.
/// The title bar is transparent so the section switcher sits on the same 26 pt centerline as the
/// main window's controls; the window is built on first use and only hidden when closed.
@MainActor
final class SettingsWindowController {
    static let contentSize = NSSize(width: 680, height: 520)

    let navigation = SettingsNavigation()
    private let model: CatalogModel
    private let usage: UsageModel?
    private let about: SettingsAbout
    private(set) var window: NSWindow?

    init(model: CatalogModel, usage: UsageModel?, about: SettingsAbout) {
        self.model = model
        self.usage = usage
        self.about = about
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window (building it once). A section jumps to it; nil keeps the current one.
    func show(section: SettingsSection?) {
        navigation.open(section)
        let window = window ?? makeWindow()
        self.window = window
        usage?.refresh(reason: .settingsOpened)
        window.makeKeyAndOrderFront(nil)
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = TerminalTheme.background
        for kind in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        let hosting = NSHostingController(
            rootView: SettingsView(model: model, usage: usage, navigation: navigation, about: about))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.contentSize)
        window.center()
        return window
    }
}
