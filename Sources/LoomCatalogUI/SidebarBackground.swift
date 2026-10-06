import AppKit
import SwiftUI

/// The terminal remains opaque; only the sidebar uses native behind-window material.
struct SidebarBackground: View {
    let reduceTransparency: Bool
    /// The dark tone dominates; the material only adds a slight depth (a lower
    /// value let a blue wallpaper glow through).
    static let tintOpacity = 0.86

    var body: some View {
        Group {
            if reduceTransparency {
                CatalogTheme.sidebar
            } else {
                SidebarMaterial().overlay(CatalogTheme.sidebar.opacity(Self.tintOpacity))
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
