import SwiftUI
import Testing
@testable import LoomCatalogUI

/// Ink v4's control family (DESIGN §0.1, §0.3, §0.4): six button roles at four heights, the neutral default action, the focus ring,
/// and the sizes of the shared controls. The values are data, so the rules are checked without a window.
struct ControlFamilyTests {
    typealias RGB = LoomTheme.RGB
    private static let white = RGB(red: 1, green: 1, blue: 1)

    @Test func thereAreSixButtonRolesNamedAsDesignSays() {
        #expect(ControlButtonStyle.Kind.allCases.map { "\($0)" } == ["default", "secondary", "outline", "ghost", "link", "destructive"])
    }

    /// Four heights (24, 28, 32, 36) and one radius (8) for every button.
    @Test func thereAreFourHeightsAndOneRadiusForEveryButton() {
        #expect(LoomTheme.Control.Size.allCases.map(\.height) == [24, 28, 32, 36])
        #expect(LoomTheme.Control.Size.allCases.allSatisfy { $0.radius == 8 })
    }

    /// The default action is neutral (Q1): Ink's `#EDEDED` with `#171717` text, Paper's `#171717` with `#FAFAFA`; hover at 90 %.
    @Test func theDefaultActionIsNeutralAndItsTextHoldsSevenToOne() {
        #expect(LoomTheme.Control.defaultFillPair == LoomTheme.Adaptive(dark: RGB(hex: 0xEDEDED), light: RGB(hex: 0x171717)))
        #expect(LoomTheme.Control.defaultTextPair == LoomTheme.Adaptive(dark: RGB(hex: 0x171717), light: RGB(hex: 0xFAFAFA)))
        #expect(LoomTheme.Control.defaultHoverOpacity == 0.9)
        for appearance in LoomTheme.Appearance.allCases {
            let contrast = LoomTheme.Control.defaultTextPair[appearance].contrast(with: LoomTheme.Control.defaultFillPair[appearance])
            #expect(contrast >= 7, "\(appearance): \(contrast)")
        }
    }

    /// Destructive is the failure red (60 % in Ink, solid in Paper) with white text; its text holds 4.5:1 at rest and under the pointer.
    @Test func theDestructiveTextHoldsFourAndAHalfOnItsFillInBothAppearances() {
        for appearance in LoomTheme.Appearance.allCases {
            let canvas = LoomTheme.Surface.greys(appearance, tone: .neutral).canvas
            for tone in [LoomTheme.Control.destructiveFill[appearance], LoomTheme.Control.destructiveHover[appearance]] {
                let fill = tone.rgb.composited(over: canvas, opacity: tone.opacity)
                #expect(Self.white.contrast(with: fill) >= 4.5, "\(appearance): \(Self.white.contrast(with: fill))")
            }
        }
        #expect(LoomTheme.Control.destructiveFill.dark.opacity == 0.60 && LoomTheme.Control.destructiveFill.light.opacity == 1)
    }

    /// The focus ring (DESIGN §0.1): a 1 pt accent edge and a 3 pt halo of the accent at 45 % outside the control.
    @Test func theFocusRingIsAnAccentEdgeAndAThreePointHalo() {
        #expect(LoomTheme.Control.focusEdge == 1 && LoomTheme.Control.focusHalo == 3)
        #expect(LoomTheme.Control.focusHaloOpacity == 0.45)
        #expect(LoomTheme.Control.focusHaloIncreasedOpacity > LoomTheme.Control.focusHaloOpacity)
    }

    /// The shared controls (DESIGN §0.4): a switch is 32 × 18, a field and the segmented control are 32 high, a badge 18 high, and a
    /// key cap is radius 4.
    @Test func theSharedControlsHaveDesignsSizes() {
        #expect(LoomTheme.Control.switchSize == CGSize(width: 32, height: 18))
        #expect(LoomTheme.Control.segmentedHeight == 32 && LoomTheme.Control.segmentRadius == 6)
        #expect(LoomTheme.Control.fieldHeight == 32 && LoomTheme.Control.fieldRadius == 8)
        #expect(LoomTheme.Control.badgeHeight == 18)
        #expect(LoomTheme.Control.keyCapRadius == 4)
    }
}
