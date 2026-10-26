import SwiftUI

/// The sidebar is one plain fill (FB6-6, D-57): the canvas, raised 1 or Deep, at Solid or one of the translucent steps. A
/// translucent step draws that fill straight over what is behind the window: there is no material and no blur, so the one fill is
/// all there is and nothing animates or redraws because of it. The detail pane stays opaque. Reduce Transparency draws Solid
/// whatever the step says.
struct SidebarBackground: View {
    let reduceTransparency: Bool
    var appearance: SidebarAppearance = .standard

    static func effectiveOpacity(_ appearance: SidebarAppearance, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : LoomTheme.Surface.sidebarTintOpacity(for: appearance.opacity)
    }

    var body: some View {
        LoomTheme.Surface.sidebarFillColor(appearance.fill)
            .opacity(Self.effectiveOpacity(appearance, reduceTransparency: reduceTransparency))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
