import AppKit
import SwiftUI

/// The sidebar's two quiet utilities; usage belongs to the window-wide status bar.
struct SidebarFooter: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: LoomTheme.StatusBar.sidebarUtilityGap) {
            Button { model.showSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(ChromeButtonStyle(size: LoomTheme.StatusBar.sidebarUtilitySize))
                .help("Settings").accessibilityLabel("Settings")
            SidebarHelpButton()
            Spacer(minLength: 0)
        }
        .focusEffectDisabled()
        .padding(.horizontal, LoomTheme.StatusBar.sidebarUtilityInset)
        .frame(height: LoomTheme.StatusBar.sidebarUtilityHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// Open the app's actual Help menu at its utility button, keeping its own menu items and actions.
private struct SidebarHelpButton: View {
    @State private var anchor = SidebarHelpAnchor()

    var body: some View {
        Button { anchor.open() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.StatusBar.sidebarUtilitySize))
            .background(SidebarHelpAnchorView(anchor: anchor))
            .help("Help").accessibilityLabel("Help").accessibilityHint("Opens the Help menu")
    }
}

@MainActor private final class SidebarHelpAnchor {
    weak var view: NSView?

    func open() {
        guard let view, let menu = NSApp.helpMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }
}

private struct SidebarHelpAnchorView: NSViewRepresentable {
    let anchor: SidebarHelpAnchor

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
