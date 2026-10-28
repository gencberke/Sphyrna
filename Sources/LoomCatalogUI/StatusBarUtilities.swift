import AppKit
import SwiftUI

/// The window-wide strip's two quiet utilities.
struct StatusBarUtilities: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: LoomTheme.StatusBar.utilityGap) {
            Button { model.showSettings() } label: { Image(systemName: "gearshape") }
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
        Button { anchor.open() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.StatusBar.utilitySize))
            .background(StatusBarHelpAnchorView(anchor: anchor))
            .help("Help").accessibilityLabel("Help").accessibilityHint("Opens the Help menu")
    }
}

@MainActor private final class StatusBarHelpAnchor {
    weak var view: NSView?

    func open() {
        guard let view, let menu = NSApp.helpMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
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
