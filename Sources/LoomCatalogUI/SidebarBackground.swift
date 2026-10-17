import AppKit
import SwiftUI

/// The terminal remains opaque; only the sidebar uses native behind-window material, and only in the Glass
/// style (D-57). Reduce Transparency draws Solid whatever the style says.
struct SidebarBackground: View {
    let reduceTransparency: Bool
    var style: SidebarStyle = .glass

    static func effectiveStyle(_ style: SidebarStyle, reduceTransparency: Bool) -> SidebarStyle {
        reduceTransparency ? .solid : style
    }

    var body: some View {
        let tint = LoomTheme.Surface.sidebarTintOpacity(for: Self.effectiveStyle(style, reduceTransparency: reduceTransparency))
        Group {
            if tint >= 1 {
                LoomTheme.Surface.sidebar
            } else {
                SidebarMaterial().overlay(LoomTheme.Surface.sidebar.opacity(tint))
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
