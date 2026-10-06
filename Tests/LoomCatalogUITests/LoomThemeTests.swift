import Testing
@testable import LoomCatalogUI

/// Contrast of today's token values (WCAG 2.x relative luminance). The sidebar
/// is a translucent tint over a material, so it is checked over the darkest
/// and the lightest possible backdrop and as the opaque Reduce Transparency color.
struct LoomThemeTests {
    typealias RGB = LoomTheme.RGB
    private static let black = RGB(red: 0, green: 0, blue: 0)
    private static let white = RGB(red: 1, green: 1, blue: 1)

    private static let sidebarOpaque = LoomTheme.Surface.sidebarRGB
    private static let sidebarOverBlack = LoomTheme.Surface.sidebarRGB
        .composited(over: black, opacity: LoomTheme.Surface.sidebarTintOpacity)
    private static let sidebarOverWhite = LoomTheme.Surface.sidebarRGB
        .composited(over: white, opacity: LoomTheme.Surface.sidebarTintOpacity)
    private static let panel = LoomTheme.Surface.panelRGB
    private static let selectedCard = white.composited(over: sidebarOpaque, opacity: LoomTheme.Surface.selectedOpacity)

    @Test func contrastMathMatchesTheWCAGReferences() {
        #expect(abs(Self.white.contrast(with: Self.black) - 21) < 0.001)
        #expect(abs(Self.white.contrast(with: Self.white) - 1) < 0.001)
        #expect(abs(RGB(red: 0.5, green: 0.5, blue: 0.5).luminance - 0.2140) < 0.001)
    }

    @Test func primaryTextIsAAAOnEverySurface() {
        for surface in [Self.sidebarOpaque, Self.sidebarOverBlack, Self.sidebarOverWhite, Self.panel, Self.selectedCard] {
            #expect(LoomTheme.Text.primaryRGB.contrast(with: surface) >= 7)
        }
    }

    @Test func secondaryTextIsAAOnTheSidebar() {
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOpaque) >= 4.5)
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.sidebarOverBlack) >= 4.5)
    }

    /// Known issue today (4.0 on the panel, 4.0 on the selected card); I2 changes
    /// `Text.secondary`, and this block then reports as no longer failing.
    @Test func secondaryTextIsAAOnPanelAndSelectedCard() {
        withKnownIssue("text.secondary is #757A8C today; I2 raises it to #828799") {
            #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.panel) >= 4.5)
            #expect(LoomTheme.Text.secondaryRGB.contrast(with: Self.selectedCard) >= 4.5)
        }
    }

    @Test func statusColorsAreAAOnSidebarPanelAndSelectedCard() {
        for status in [LoomTheme.Status.attentionRGB, LoomTheme.Status.unviewedRGB, LoomTheme.Status.failureRGB] {
            for surface in [Self.sidebarOpaque, Self.sidebarOverBlack, Self.panel, Self.selectedCard] {
                #expect(status.contrast(with: surface) >= 4.5)
            }
        }
    }

    @Test func colorTokensAreBackedByTheirRGBData() {
        // The SwiftUI `Color` and the RGB data must not drift apart: one value, two views.
        #expect(LoomTheme.Surface.sidebarRGB == RGB(red: 0.043, green: 0.055, blue: 0.086))
        #expect(LoomTheme.Text.primaryRGB == RGB(red: 0.88, green: 0.86, blue: 0.92))
        #expect(LoomTheme.Text.secondaryRGB == RGB(red: 0.46, green: 0.48, blue: 0.55))
        #expect(LoomTheme.Status.attentionRGB == RGB(red: 1.0, green: 0.62, blue: 0.04))
        #expect(LoomTheme.Status.unviewedRGB == RGB(red: 0.36, green: 0.55, blue: 1.0))
        #expect(LoomTheme.Status.failureRGB == RGB(red: 0.95, green: 0.38, blue: 0.36))
        #expect(LoomTheme.Surface.sidebarTintOpacity == 0.86)
    }
}
