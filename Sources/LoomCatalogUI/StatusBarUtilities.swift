import AppKit
import SwiftUI

/// The window-wide strip's two quiet utilities.
struct StatusBarUtilities: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: LoomTheme.StatusBar.utilityGap) {
            Button { model.showSettings() } label: { InkIcon(.gear, size: LoomTheme.Icon.navigation) }
                .buttonStyle(ChromeButtonStyle(size: LoomTheme.StatusBar.utilitySize))
                .help("Settings").accessibilityLabel("Settings")
            StatusBarHelpButton()
        }
        .focusEffectDisabled()
    }
}

/// Open the app's actual Help menu at its utility button, keeping its own menu items and actions.
private struct StatusBarHelpButton: View {
    @State private var anchor = StatusBarHelpAnchor()

    var body: some View {
        Button { anchor.open() } label: { InkIcon(.question, size: LoomTheme.Icon.navigation) }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.StatusBar.utilitySize))
            .background(StatusBarHelpAnchorView(anchor: anchor))
            .help("Help").accessibilityLabel("Help").accessibilityHint("Opens the Help menu")
    }
}

@MainActor private final class StatusBarHelpAnchor {
    weak var view: NSView?
    private var pendingOrOpen = false

    func open() {
        guard !pendingOrOpen, let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
        pendingOrOpen = true
        // Return from an accessibility press before AppKit enters the menu's nested tracking loop.
        DispatchQueue.main.async { [weak self, weak view, weak window] in
            guard let self else { return }
            defer { self.pendingOrOpen = false }
            guard let view, let window, self.view === view, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  let menu = NSApp.helpMenu else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
        }
    }
}

private struct StatusBarHelpAnchorView: NSViewRepresentable {
    let anchor: StatusBarHelpAnchor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
