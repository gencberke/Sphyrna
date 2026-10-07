import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// I3: contrast-aware tokens, gated transitions, search focus and VoiceOver structure.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MotionAccessibilityTests {
    typealias RGB = LoomTheme.RGB

    // MARK: Increase Contrast tokens

    private static let surfaces: [RGB] = [
        LoomTheme.Surface.sidebarRGB, LoomTheme.Surface.panelRGB,
        RGB(red: 1, green: 1, blue: 1).composited(over: LoomTheme.Surface.sidebarRGB, opacity: LoomTheme.Surface.selectedOpacity),
    ]

    @Test func increaseContrastRaisesTheHairlineToThirtyPercent() {
        #expect(LoomTheme.Surface.hairlineOpacity(for: .standard) == 0.10)
        #expect(LoomTheme.Surface.hairlineOpacity(for: .increased) == 0.30)
        #expect(LoomTheme.Surface.hairlineStyle.tone(for: .standard).opacity == 0.10)
        #expect(LoomTheme.Surface.hairlineStyle.tone(for: .increased).opacity == 0.30)
    }

    @Test func increaseContrastLiftsSecondaryTextToAAAOnEverySurface() {
        #expect(LoomTheme.Text.secondaryRGB(for: .standard) == LoomTheme.Text.secondaryRGB)
        let lifted = LoomTheme.Text.secondaryRGB(for: .increased)
        for surface in Self.surfaces {
            #expect(lifted.contrast(with: surface) >= 7)
            #expect(lifted.contrast(with: surface) > LoomTheme.Text.secondaryRGB.contrast(with: surface))
        }
        // Still a secondary tier: never brighter than the primary text.
        #expect(lifted.luminance < LoomTheme.Text.primaryRGB.luminance)
    }

    @Test func focusRingIsThickerUnderIncreaseContrast() {
        #expect(LoomTheme.Line.focusRing(for: .standard) == LoomTheme.Line.focusRing)
        #expect(LoomTheme.Line.focusRing(for: .increased) > LoomTheme.Line.focusRing)
    }

    @Test func aContrastStyleResolvesAgainstTheEnvironment() {
        func resolved(_ style: LoomTheme.ContrastStyle, _ environment: EnvironmentValues) -> [Float] {
            let value = style.resolve(in: environment).resolve(in: environment)
            return [value.red, value.green, value.blue, value.opacity]
        }
        func expected(_ rgb: RGB, _ opacity: Double, _ environment: EnvironmentValues) -> [Float] {
            let value = rgb.color.opacity(opacity).resolve(in: environment)
            return [value.red, value.green, value.blue, value.opacity]
        }
        var environment = EnvironmentValues()
        #expect(resolved(LoomTheme.Text.secondaryStyle, environment) == expected(LoomTheme.Text.secondaryRGB, 1, environment))
        #expect(resolved(LoomTheme.Surface.hairlineStyle, environment) == expected(RGB(red: 1, green: 1, blue: 1), 0.10, environment))
        environment._colorSchemeContrast = .increased
        #expect(resolved(LoomTheme.Text.secondaryStyle, environment)
                == expected(LoomTheme.Text.secondaryIncreasedRGB, 1, environment))
        #expect(resolved(LoomTheme.Surface.hairlineStyle, environment) == expected(RGB(red: 1, green: 1, blue: 1), 0.30, environment))
    }

    // MARK: Motion tokens

    @Test func transitionsAreShortEaseOutAndInstantUnderReduceMotion() {
        #expect(LoomTheme.Motion.selectionDuration == 0.12)
        #expect(LoomTheme.Motion.bannerDuration == 0.20)
        for transition in [LoomTheme.Motion.Transition.selection, .banner] {
            #expect(LoomTheme.Motion.duration(of: transition) <= 0.2)
            #expect(LoomTheme.Motion.animation(transition, reduceMotion: true) == nil)
            #expect(LoomTheme.Motion.animation(transition, reduceMotion: false)
                    == .easeOut(duration: LoomTheme.Motion.duration(of: transition)))
        }
    }

    // MARK: Hit area

    @Test func smallControlsReachTheMinimumHitTarget() {
        let project = ChromeButtonStyle.hitSize(for: LoomTheme.Layout.projectMenuButton)
        #expect(project == LoomTheme.Layout.minimumHitTarget)
        for size in [LoomTheme.Layout.chromeButton, LoomTheme.Layout.footerButton] {
            #expect(ChromeButtonStyle.hitSize(for: size) == size) // already large enough: unchanged
        }
        #expect(LoomTheme.Layout.minimumHitTarget.width >= 24 && LoomTheme.Layout.minimumHitTarget.height >= 24)
    }

    // MARK: Search focus

    @Test func escapeClearsATextSearchAndLeavesAnEmptyOne() {
        #expect(SearchField.escapeClearsSearch("rocket"))
        #expect(!SearchField.escapeClearsSearch(""))
    }

    @Test func aProjectIsExpandedWhileSearchingWhateverItsFlagSays() {
        #expect(ProjectHeader.isExpanded(collapsed: false, searching: false))
        #expect(!ProjectHeader.isExpanded(collapsed: true, searching: false))
        #expect(ProjectHeader.isExpanded(collapsed: true, searching: true))
    }
}
