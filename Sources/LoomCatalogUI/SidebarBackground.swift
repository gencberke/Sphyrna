import SwiftUI

/// The sidebar is the canvas: Solid (opaque) by default, or in the Transparent style (D-57, RESCUE C3) the canvas at partial
/// opacity straight over what is behind the window. There is no material and no blur: the window is clear and the sidebar's
/// split item draws nothing of its own, so the one fill is all there is and nothing animates or redraws because of it. The detail
/// pane stays opaque. Reduce Transparency draws Solid whatever the style says.
struct SidebarBackground: View {
    let reduceTransparency: Bool
    var style: SidebarStyle = .solid

    static func effectiveStyle(_ style: SidebarStyle, reduceTransparency: Bool) -> SidebarStyle {
        reduceTransparency ? .solid : style
    }

    var body: some View {
        let opacity = LoomTheme.Surface.sidebarTintOpacity(for: Self.effectiveStyle(style, reduceTransparency: reduceTransparency))
        LoomTheme.Surface.sidebar.opacity(opacity)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
