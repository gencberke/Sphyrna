import AppKit
import SwiftUI

/// The terminal remains opaque; only the sidebar uses native behind-window material.
struct SidebarBackground: View {
    let reduceTransparency: Bool

    var body: some View {
        Group {
            if reduceTransparency {
                LoomTheme.Surface.sidebar
            } else {
                SidebarMaterial().overlay(LoomTheme.Surface.sidebar.opacity(LoomTheme.Surface.sidebarTintOpacity))
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
