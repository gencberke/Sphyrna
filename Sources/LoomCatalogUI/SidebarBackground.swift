import AppKit
import SwiftUI

/// The sidebar is the canvas: Solid (opaque) by default, or in the Glass style (D-57) the canvas at 0.8 over the native
/// behind-window material. Nothing else uses the material. Reduce Transparency draws Solid whatever the style says.
struct SidebarBackground: View {
    let reduceTransparency: Bool
    var style: SidebarStyle = .solid

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
