import AppKit
import LoomCore
import Observation
import SwiftUI
import Testing
import LoomTerminal
@testable import LoomCatalogUI

/// Themes (D-63, V26) and Ink's contrast floors (DESIGN §3 Contrast): every rule in both appearances (Ink, Paper) and for
/// every tone (Neutral, Warm, Cool), the way a token resolves (appearance, tone, the terminal face's dark scope), and the
/// settings that drive it.
struct ThemeAppearanceTests {
    private final class Flag: @unchecked Sendable { var value = false }

    typealias RGB = LoomTheme.RGB
    typealias Appearance = LoomTheme.Appearance

    private static let ink = LoomTheme.inkRGB
    private static let white = RGB(red: 1, green: 1, blue: 1)
    private static let black = RGB(red: 0, green: 0, blue: 0)

    // MARK: Surfaces the tiers are checked on

    private static func greys(_ appearance: Appearance, _ tone: PaneTone) -> LoomTheme.Surface.Greys {
        LoomTheme.Surface.greys(appearance, tone: tone)
    }

    /// The four levels text sits on.
    private static func levels(_ appearance: Appearance, _ tone: PaneTone) -> [(name: String, rgb: RGB)] {
        let greys = greys(appearance, tone)
        return [("canvas", greys.canvas), ("raised 1", greys.raised1), ("raised 2", greys.raised2), ("popover", greys.popover)]
    }

    /// The pill's fills over a level (white in Ink, the ink in Paper).
    private static func fills(_ appearance: Appearance, over level: (name: String, rgb: RGB))
        -> [(name: String, rgb: RGB)] {
        let overlay = appearance == .dark ? white : ink
        return [("hover", LoomTheme.Surface.hoverTone), ("selected", LoomTheme.Surface.selectedTone),
                ("pressed", LoomTheme.Surface.pressedTone)].map { state in
            let tone = state.1[appearance]
            return ("\(level.name)+\(state.0)", overlay.composited(over: level.rgb, opacity: tone.opacity))
        }
    }

    /// A floor, with the pair's name and figure in the failure.
    private static func floor(_ value: Double, _ floor: Double, _ id: String) {
        #expect(value >= floor, "\(id): \(value)")
    }

    /// Where the sidebar tint sits: opaque (Solid, Reduce Transparency), and over the glass material at its two
    /// extremes. Ink: the dark material lets a white window show at 0.5 gray (measured, 12 Oct 2026) and black at
    /// black. Paper: the light material over a white window is white; over a dark desktop it is assumed to lift to
    /// 0.70 gray (not measured; DESIGN §3 says so). The tint is the tone's canvas.
    private static func sidebarBackdrops(_ appearance: Appearance, _ tone: PaneTone) -> [(name: String, rgb: RGB, worst: Bool)] {
        let tint = LoomTheme.Surface.sidebarTintOpacity
        let opaque = greys(appearance, tone).canvas
        switch appearance {
        case .dark:
            return [("opaque", opaque, false), ("over black", opaque.composited(over: black, opacity: tint), false),
                    ("over white", opaque.composited(over: RGB(red: 0.5, green: 0.5, blue: 0.5), opacity: tint), true)]
        case .light:
            return [("opaque", opaque, false), ("over white", opaque.composited(over: white, opacity: tint), false),
                    ("over dark desktop", opaque.composited(over: RGB(red: 0.7, green: 0.7, blue: 0.7), opacity: tint), true)]
        }
    }

    private static func selectedOnSidebar(_ appearance: Appearance, _ tone: PaneTone) -> RGB {
        let overlay = appearance == .dark ? white : ink
        return overlay.composited(over: greys(appearance, tone).canvas,
                                  opacity: LoomTheme.Surface.selectedTone[appearance].opacity)
    }

    // MARK: Tiers on the levels and the pill, both appearances, every tone

    @Test func primaryHoldsSevenToOneOnEveryLevelAndUnderEveryFill() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                for level in Self.levels(appearance, tone) {
                    Self.floor(LoomTheme.Text.primaryPair[appearance].contrast(with: level.rgb), 7, "\(appearance) \(tone) \(level.name)")
                    guard level.name != "popover" else { continue }
                    for fill in Self.fills(appearance, over: level) {
                        Self.floor(LoomTheme.Text.primaryPair[appearance].contrast(with: fill.rgb), 7, "\(appearance) \(tone) \(fill.name)")
                    }
                }
            }
        }
    }

    @Test func secondaryHoldsItsFloorOnTheLevelsUnderTheFillsAndOnAPopoverUnderHover() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                for level in Self.levels(appearance, tone) {
                    let text = LoomTheme.Text.secondaryPair[appearance]
                    Self.floor(text.contrast(with: level.rgb), 4.5, "\(appearance) \(tone) \(level.name)")
                    if level.name == "popover" {
                        // On a popover quiet text is secondary, also under the hover fill.
                        let hover = Self.fills(appearance, over: level)[0]
                        Self.floor(LoomTheme.OnPopover.secondary(lit: true).tone(for: .standard, appearance: appearance).rgb
                            .contrast(with: hover.rgb), 4.5, "\(appearance) \(tone) \(hover.name)")
                    } else {
                        for fill in Self.fills(appearance, over: level) {
                            Self.floor(text.contrast(with: fill.rgb), 4.5, "\(appearance) \(tone) \(fill.name)")
                        }
                    }
                }
            }
        }
    }

    /// Tertiary is the quiet voice, readable: 4.5:1 on the canvas and both raised levels, and under the hover and selected
    /// fills over the canvas. A press is momentary, so the pressed fill has no text floor (the main planner, 21 Oct).
    @Test func tertiaryHoldsItsFloorOnTheLevelsAndUnderTheFillsOverTheCanvas() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let text = LoomTheme.Text.tertiaryPair[appearance]
                for level in Self.levels(appearance, tone) where level.name != "popover" {
                    Self.floor(text.contrast(with: level.rgb), 4.5, "\(appearance) \(tone) \(level.name)")
                }
                let canvas = Self.levels(appearance, tone)[0]
                for fill in Self.fills(appearance, over: canvas) where !fill.name.hasSuffix("+pressed") {
                    Self.floor(text.contrast(with: fill.rgb), 4.5, "\(appearance) \(tone) \(fill.name)")
                }
            }
        }
    }

    @Test func increaseContrastSecondaryHoldsSevenToOneOnEveryLevel() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                for level in Self.levels(appearance, tone) {
                    Self.floor(LoomTheme.Text.secondaryIncreasedPair[appearance].contrast(with: level.rgb), 7,
                               "\(appearance) \(tone) \(level.name)")
                }
            }
        }
        // Under Increase Contrast tertiary takes secondary's normal value.
        #expect(LoomTheme.Text.tertiaryIncreasedPair == LoomTheme.Text.secondaryPair)
        #expect(LoomTheme.Text.tertiaryStyle.tone(for: .increased).rgb == LoomTheme.Text.secondaryRGB)
        #expect(LoomTheme.Text.tertiaryStyle.tone(for: .standard).rgb == LoomTheme.Text.tertiaryRGB)
    }

    @Test func statusTextTheHighAccentAndSuccessHoldFourAndAHalfOnEveryLevel() {
        for appearance in Appearance.allCases {
            let texts: [(String, RGB)] = [
                ("accent high", LoomTheme.Accent.highPair[appearance]),
                ("attention text", LoomTheme.Status.attentionLightPair[appearance]),
                ("unviewed text", LoomTheme.Status.unviewedLightPair[appearance]),
                ("failure text", LoomTheme.Status.failureLightPair[appearance]),
                ("success", LoomTheme.Success.basePair[appearance]), ("success text", LoomTheme.Success.lightPair[appearance])]
            for tone in PaneTone.allCases {
                for level in Self.levels(appearance, tone) {
                    for (text, rgb) in texts { Self.floor(rgb.contrast(with: level.rgb), 4.5, "\(appearance) \(tone) \(text) on \(level.name)") }
                }
            }
        }
    }

    @Test func theMarksTheFocusRingAndFaintHoldTheirFloorsOnTheCanvas() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let canvas = Self.greys(appearance, tone).canvas
                // A mark needs 3:1: the three status dots and the focus ring (the accent base).
                for (name, rgb) in [("attention dot", LoomTheme.Status.attentionPair), ("unviewed dot", LoomTheme.Status.unviewedPair),
                                    ("failure dot", LoomTheme.Status.failurePair), ("focus ring", LoomTheme.Accent.basePair)] {
                    Self.floor(rgb[appearance].contrast(with: canvas), 3, "\(appearance) \(tone) \(name)")
                }
                // Faint is never text you need.
                Self.floor(LoomTheme.Text.faintPair[appearance].contrast(with: canvas), 2.5, "\(appearance) \(tone) faint")
            }
        }
    }

    /// The subagent tree is structure, like the hairlines, and carries no state (the row's mark does), so it has no 3:1
    /// floor (the main planner, 21 Oct). It is opaque and stays visible on the canvas in every cast: at least 1.5:1 (Ink's
    /// greys give 1.76 to 1.82 in Ink and 1.55 to 1.65 in Paper).
    @Test func theTreeStaysVisibleOnTheCanvas() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let greys = Self.greys(appearance, tone)
                Self.floor(greys.tree.contrast(with: greys.canvas), 1.5, "\(appearance) \(tone) tree")
            }
        }
    }

    /// The chat bar's mode colours are text and icons on the composer (raised 2) and on the popover list, also under the
    /// pointer, and on the canvas: 4.5:1 on every tone in both appearances, and a different colour per mode.
    @Test func theModeTonesHoldFourAndAHalfOnRaised2ThePopoverAndTheCanvasAlsoUnderHover() {
        let modes = ClaudePermissionMode.menuModes.map(\.rawValue)
        for appearance in Appearance.allCases {
            let overlay = appearance == .dark ? Self.white : Self.ink
            let hover = LoomTheme.Surface.hoverTone[appearance].opacity
            for tone in PaneTone.allCases {
                let greys = Self.greys(appearance, tone)
                for mode in modes {
                    let rgb = LoomTheme.Composer.ModeTone.pair(forRaw: mode)[appearance]
                    for (name, back) in [("raised 2", greys.raised2), ("popover", greys.popover), ("canvas", greys.canvas)] {
                        Self.floor(rgb.contrast(with: back), 4.5, "\(appearance) \(tone) \(mode) on \(name)")
                        Self.floor(rgb.contrast(with: overlay.composited(over: back, opacity: hover)), 4.5,
                                   "\(appearance) \(tone) \(mode) on hovered \(name)")
                    }
                }
            }
            let distinct = Set(modes.map { LoomTheme.Composer.ModeTone.pair(forRaw: $0)[appearance].bytes }.map { "\($0)" })
            #expect(distinct.count == modes.count, "\(appearance): one colour per mode")
        }
        // A mode Loom does not offer takes the secondary text colour.
        #expect(LoomTheme.Composer.ModeTone.pair(forRaw: "dontAsk") == LoomTheme.Text.secondaryPair)
    }

    /// The popover rules (DESIGN §3): placeholders are secondary, accent text is the high step, the unviewed and failure
    /// words are their text variants, and attention's text variant. They hold on every tone's popover in both appearances.
    @Test func theOnPopoverTokensHoldFourAndAHalfOnEveryPopover() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let popover = Self.greys(appearance, tone).popover
                for (name, pair) in [("placeholder", LoomTheme.OnPopover.placeholderPair), ("accent", LoomTheme.OnPopover.accentPair),
                                     ("unviewed", LoomTheme.OnPopover.unviewedPair), ("failure", LoomTheme.OnPopover.failurePair),
                                     ("attention", LoomTheme.Status.attentionLightPair)] {
                    Self.floor(pair[appearance].contrast(with: popover), 4.5, "\(appearance) \(tone) \(name) on popover")
                }
            }
        }
    }

    /// The banner above the composer is drawn on raised 1: its icon, message, action and dismiss glyph hold 4.5:1 there in
    /// both appearances and on every tone; the handover notice (the header's status text and the composer's "Moving to the
    /// terminal…") is secondary text on the canvas or the composer.
    @Test func theBannerAndTheHandoverNoticeHoldFourAndAHalfInBothAppearances() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let greys = Self.greys(appearance, tone)
                // The symbol takes the tone's text variant (`ChatBannerTone.symbolStyle`): the attention and the failure pair.
                for (name, pair) in [("icon", LoomTheme.Status.attentionLightPair), ("failure icon", LoomTheme.Status.failureLightPair),
                                     ("message", LoomTheme.Text.primaryPair),
                                     ("action", LoomTheme.Accent.basePair), ("dismiss", LoomTheme.Text.secondaryPair)] {
                    Self.floor(pair[appearance].contrast(with: greys.raised1), 4.5, "\(appearance) \(tone) banner \(name)")
                    // The family's box itself is raised 2 (the chat's banner and the top stack).
                    Self.floor(pair[appearance].contrast(with: greys.raised2), 4.5, "\(appearance) \(tone) banner \(name) on raised 2")
                }
                for (name, back) in [("header", greys.canvas), ("composer", greys.raised2)] {
                    Self.floor(LoomTheme.Text.secondaryPair[appearance].contrast(with: back), 4.5, "\(appearance) \(tone) notice on \(name)")
                }
            }
        }
    }

    /// The effort slider: the thumb stands out from the accent fill it slides over, the dots on the fill stay
    /// readable on it, in both appearances; the track is the strong hairline.
    @Test func theEffortSliderPartsSeparateFromTheAccentFillInBothAppearances() {
        for appearance in Appearance.allCases {
            let fill = LoomTheme.Accent.basePair[appearance]
            // A control's boundary needs 3:1 (WCAG 1.4.11).
            #expect(LoomTheme.Composer.effortThumbPair[appearance].contrast(with: fill) >= 3, "\(appearance) thumb on fill")
            let dot = LoomTheme.Composer.effortDotOnTone[appearance]
            #expect(dot.rgb.composited(over: fill, opacity: dot.opacity).contrast(with: fill) >= 1.5, "\(appearance) dot on fill")
            let pointer = appearance == .dark ? Self.white : Self.ink
            #expect(LoomTheme.Composer.effortTrackTone[appearance].rgb == pointer)
            #expect(LoomTheme.Composer.effortTrackTone == LoomTheme.Surface.strongHairlineTone)
            #expect(LoomTheme.Composer.effortDotOffTone[appearance].rgb == pointer)
            #expect(LoomTheme.Composer.effortDotOffTone[appearance].opacity == 0.22)
        }
    }

    @Test func textOnAFilledAccentHoldsFourAndAHalfInBothAppearances() {
        for appearance in Appearance.allCases {
            Self.floor(LoomTheme.Accent.onAccentPair[appearance].contrast(with: LoomTheme.Accent.basePair[appearance]), 4.5, "\(appearance)")
        }
        // Dark text on the periwinkle in Ink, a warm paper white on the deep indigo in Paper; light text on the Ink accent is
        // 3.0:1, so it is not allowed.
        #expect(LoomTheme.Accent.onAccentPair.dark.luminance < LoomTheme.Accent.basePair.dark.luminance)
        #expect(LoomTheme.Accent.onAccentPair.light.luminance > LoomTheme.Accent.basePair.light.luminance)
        #expect(LoomTheme.Text.primaryPair.dark.contrast(with: LoomTheme.Accent.basePair.dark) < 4.5)
    }

    @Test func theLowAccentNeverCarriesTextInEitherAppearance() {
        let texts = [LoomTheme.Text.primaryPair, LoomTheme.Text.secondaryPair, LoomTheme.Text.tertiaryPair,
                     LoomTheme.Text.secondaryIncreasedPair, LoomTheme.Accent.basePair, LoomTheme.Accent.highPair,
                     LoomTheme.OnPopover.accentPair, LoomTheme.Success.basePair]
        #expect(!texts.contains(LoomTheme.Accent.lowPair))
    }

    // MARK: The sidebar

    @Test func sidebarTextHoldsItsTiersInBothAppearancesAndTones() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let surfaces = Self.sidebarBackdrops(appearance, tone).map { ($0.name, $0.rgb, $0.worst) }
                    + [("selected row", Self.selectedOnSidebar(appearance, tone), false)]
                for (name, surface, worst) in surfaces {
                    let id = "\(appearance) \(tone) sidebar \(name)"
                    Self.floor(LoomTheme.Text.primaryPair[appearance].contrast(with: surface), 7, "primary on \(id)")
                    // AA everywhere but the glass's worst case, which must not fall under 3:1.
                    Self.floor(LoomTheme.Text.secondaryPair[appearance].contrast(with: surface), worst ? 3 : 4.5, "secondary on \(id)")
                    if !worst {
                        for (hue, rgb) in [("accent", LoomTheme.Accent.basePair), ("attention", LoomTheme.Status.attentionPair),
                                           ("unviewed", LoomTheme.Status.unviewedPair), ("failure", LoomTheme.Status.failurePair)] {
                            Self.floor(rgb[appearance].contrast(with: surface), 3, "\(hue) dot on \(id)")
                        }
                    }
                    Self.floor(LoomTheme.Text.secondaryIncreasedPair[appearance].contrast(with: surface), worst ? 4.5 : 7,
                               "secondary, Increase Contrast, on \(id)")
                }
            }
        }
    }

    // MARK: The values

    private static func hex(_ greys: LoomTheme.Surface.Greys) -> [UInt32] {
        [greys.canvas, greys.raised1, greys.raised2, greys.popover, greys.segmentOn, greys.tree].map {
            let bytes = $0.bytes
            return UInt32(bytes.0 << 16 | bytes.1 << 8 | bytes.2)
        }
    }

    /// DESIGN §3 Surfaces and Tones, token by token: canvas, raised 1, raised 2, popover, segment on, tree.
    @Test func theSixGreysAreDesignsTableInEveryToneAndAppearance() {
        #expect(Self.hex(Self.greys(.dark, .neutral)) == [0x0C0C0E, 0x121215, 0x17171B, 0x1C1C21, 0x26262C, 0x3B3B41])
        #expect(Self.hex(Self.greys(.light, .neutral)) == [0xF7F6F3, 0xFBFAF8, 0xFEFDFC, 0xFFFFFF, 0xFFFFFF, 0xC4C2BE])
        #expect(Self.hex(Self.greys(.dark, .warm)) == [0x0E0C0A, 0x15120F, 0x1A1714, 0x201C18, 0x2C2721, 0x433C34])
        #expect(Self.hex(Self.greys(.light, .warm)) == [0xF8F2E8, 0xFCF8F1, 0xFEFCF8, 0xFFFDF9, 0xFFFDF9, 0xCFC4B3])
        #expect(Self.hex(Self.greys(.dark, .cool)) == [0x0A0C10, 0x0F1217, 0x14171D, 0x191D24, 0x232833, 0x363E4C])
        #expect(Self.hex(Self.greys(.light, .cool)) == [0xF1F3F6, 0xF8F9FB, 0xFCFDFE, 0xFFFFFF, 0xFFFFFF, 0xBCC2CB])
        // The terminal face is dark in both appearances and takes the tone's Ink canvas.
        for tone in PaneTone.allCases { #expect(LoomTheme.Surface.terminalBackground(tone: tone) == Self.greys(.dark, tone).canvas) }
    }

    @Test func theLevelsRiseInBothAppearancesAndTheCastsLeanTheirWay() {
        for tone in PaneTone.allCases {
            let dark = Self.greys(.dark, tone), light = Self.greys(.light, tone)
            // Ink and Paper both lift what you act on: the canvas is the lowest, the popover the highest.
            for greys in [dark, light] {
                #expect(greys.levels == greys.levels.sorted { $0.luminance < $1.luminance }, "\(tone)")
            }
            for level in light.levels { #expect(level.luminance > 0.8, "Paper is a paper, not a mid grey (\(tone))") }
            for level in dark.levels { #expect(level.luminance < 0.05, "Ink stays dark (\(tone))") }
        }
        // Warm leans red over blue and Cool blue over red, in both appearances; Neutral is Ink's own greys.
        for appearance in Appearance.allCases {
            let warm = Self.greys(appearance, .warm).canvas, cool = Self.greys(appearance, .cool).canvas
            #expect(warm.red > warm.blue, "warm \(appearance)")
            #expect(cool.blue > cool.red, "cool \(appearance)")
        }
        #expect(LoomTheme.Text.primaryPair.light != Self.black && LoomTheme.Text.primaryPair.light == LoomTheme.Text.primaryPair[.light])
        #expect(LoomTheme.inkRGB == RGB(hex: 0x1E1C1A))
    }

    @Test func theTextAccentAndStatusRolesAreDesignsValues() {
        typealias Text = LoomTheme.Text
        #expect(Text.primaryPair == LoomTheme.Adaptive(dark: RGB(hex: 0xECECEF), light: RGB(hex: 0x19181B)))
        #expect(Text.secondaryPair == LoomTheme.Adaptive(dark: RGB(hex: 0x9E9EA8), light: RGB(hex: 0x5F5D63)))
        #expect(Text.tertiaryPair == LoomTheme.Adaptive(dark: RGB(hex: 0x868690), light: RGB(hex: 0x67656B)))
        #expect(Text.faintPair == LoomTheme.Adaptive(dark: RGB(hex: 0x6B6B75), light: RGB(hex: 0x8E8B91)))
        #expect(Text.secondaryIncreasedPair == LoomTheme.Adaptive(dark: RGB(hex: 0xBDBDC6), light: RGB(hex: 0x47454B)))
        typealias Accent = LoomTheme.Accent
        #expect(Accent.basePair == LoomTheme.Adaptive(dark: RGB(hex: 0x8791CF), light: RGB(hex: 0x4B56A8)))
        #expect(Accent.highPair == LoomTheme.Adaptive(dark: RGB(hex: 0xA9B0E3), light: RGB(hex: 0x3A4491)))
        #expect(Accent.lowPair == LoomTheme.Adaptive(dark: RGB(hex: 0x5E68A8), light: RGB(hex: 0xA3ABDD)))
        #expect(Accent.onAccentPair == LoomTheme.Adaptive(dark: RGB(hex: 0x0B0E16), light: RGB(hex: 0xFBF8F2)))
        #expect(Accent.washTone.dark.opacity == 0.16 && Accent.washTone.light.opacity == 0.11)
        typealias Status = LoomTheme.Status
        #expect(Status.attentionPair == LoomTheme.Adaptive(dark: RGB(hex: 0xFF9E0A), light: RGB(hex: 0xC46A00)))
        #expect(Status.unviewedPair == LoomTheme.Adaptive(dark: RGB(hex: 0x5C8CFF), light: RGB(hex: 0x2557CC)))
        #expect(Status.failurePair == LoomTheme.Adaptive(dark: RGB(hex: 0xF2615C), light: RGB(hex: 0xC8322C)))
        #expect(Status.attentionLightPair == LoomTheme.Adaptive(dark: RGB(hex: 0xFFB547), light: RGB(hex: 0x7A3A00)))
        #expect(Status.unviewedLightPair == LoomTheme.Adaptive(dark: RGB(hex: 0x8FB0FF), light: RGB(hex: 0x1B43A3)))
        #expect(Status.failureLightPair == LoomTheme.Adaptive(dark: RGB(hex: 0xFF8A85), light: RGB(hex: 0x8E1D19)))
        #expect([Status.attentionWashTone.dark.opacity, Status.unviewedWashTone.dark.opacity, Status.failureWashTone.dark.opacity] == [0.13, 0.13, 0.13])
        #expect([Status.attentionWashTone.light.opacity, Status.unviewedWashTone.light.opacity, Status.failureWashTone.light.opacity] == [0.11, 0.10, 0.10])
        #expect(LoomTheme.Success.basePair == LoomTheme.Adaptive(dark: RGB(hex: 0x4CC38A), light: RGB(hex: 0x186E43)))
        #expect(LoomTheme.Success.lightPair == LoomTheme.Adaptive(dark: RGB(hex: 0x7BDBA8), light: RGB(hex: 0x125A36)))
        #expect(LoomTheme.Changes.addedBandTone.dark.opacity == 0.09 && LoomTheme.Changes.addedBandTone.light.opacity == 0.08)
        #expect(LoomTheme.Changes.removedBandTone.dark.opacity == 0.09 && LoomTheme.Changes.removedBandTone.light.opacity == 0.08)
        // Both washes and bands are the status colours' own hues.
        #expect(LoomTheme.Changes.addedBandTone.dark.rgb == LoomTheme.Success.basePair.dark)
        #expect(LoomTheme.Changes.removedBandTone.light.rgb == LoomTheme.Status.failurePair.light)
    }

    @Test func theLinesTheFillsAndTheOtherRolesAreDesignsValues() {
        typealias Surface = LoomTheme.Surface
        func opacities(_ tone: LoomTheme.AdaptiveTone) -> [Double] { [tone.dark.opacity, tone.light.opacity] }
        #expect(opacities(Surface.hairlineTone) == [0.075, 0.085])
        #expect(opacities(Surface.strongHairlineTone) == [0.115, 0.13])
        #expect(opacities(Surface.strongerHairlineTone) == [0.20, 0.24])
        #expect([Surface.hairlineIncreasedOpacity, Surface.hairlineIncreasedLightOpacity] == [0.30, 0.45])
        #expect(opacities(Surface.hoverTone) == [0.05, 0.045])
        #expect(opacities(Surface.selectedTone) == [0.08, 0.07])
        #expect(opacities(Surface.pressedTone) == [0.12, 0.10])
        #expect(opacities(Surface.gridTone) == [0.034, 0.06])
        #expect(opacities(Surface.scrimTone) == [0.40, 0.22])
        #expect(Surface.scrimTone.dark.rgb == Self.black && Surface.scrimTone.light.rgb == Self.ink)
        #expect(Surface.artPair == LoomTheme.Adaptive(dark: RGB(hex: 0xECECF0), light: RGB(hex: 0x161518)))
        for tone in [Surface.hairlineTone, Surface.strongHairlineTone, Surface.strongerHairlineTone, Surface.hoverTone,
                     Surface.selectedTone, Surface.pressedTone, Surface.gridTone] {
            #expect(tone.dark.rgb == Self.white && tone.light.rgb == Self.ink)
        }
        // The pill's fills are the Highlight tokens.
        #expect(LoomTheme.Highlight.hoverTone == Surface.hoverTone && LoomTheme.Highlight.selectedTone == Surface.selectedTone
                && LoomTheme.Highlight.pressedTone == Surface.pressedTone)
        // Increase Contrast's hairline.
        #expect(Surface.hairlineStyle.tone(for: .increased, appearance: .dark) == LoomTheme.Tone(rgb: Self.white, opacity: 0.30))
        #expect(Surface.hairlineStyle.tone(for: .increased, appearance: .light) == LoomTheme.Tone(rgb: Self.ink, opacity: 0.45))
    }

    @Test func theDepthsAreTheReferencesShadows() {
        typealias Elevation = LoomTheme.Elevation
        #expect(Elevation.card.dark.drops.map(\.blur) == [2] && Elevation.card.dark.insetHighlight?.opacity == 0.03)
        #expect(Elevation.card.dark.drops.first?.color.opacity == 0.45 && Elevation.card.light.drops.first?.color.opacity == 0.06)
        #expect(Elevation.popover.dark.drops.map(\.blur) == [64, 8] && Elevation.popover.dark.drops.map(\.y) == [24, 2])
        #expect(Elevation.popover.dark.ring?.opacity == 0.08 && Elevation.popover.light.drops.map(\.blur) == [60, 6])
        #expect(Elevation.composer.dark.drops.map(\.blur) == [90] && Elevation.composer.dark.ring?.opacity == 0.12)
        #expect(Elevation.composer.dark.insetHighlight?.opacity == 0.045)
        #expect(Elevation.window.dark.drops.map(\.blur) == [140] && Elevation.window.dark.drops.first?.y == 50)
        #expect(Elevation.window.light.drops.first?.color.opacity == 0.22 && Elevation.window.light.ring?.opacity == 0.13)
        #expect(Elevation.popover.dark.drops.first?.radius == 32, "a CSS blur of B is a SwiftUI radius of B / 2")
    }

    @Test func theTonesAreNeutralWarmAndCoolAndTheAppearancesAreInkAndPaper() {
        #expect(PaneTone.allCases.map(\.title) == ["Neutral", "Warm", "Cool"])
        #expect(PaneTone.allCases.map(\.detail) == ["Ink's own greys.", "A slight brown cast.", "A slight blue cast."])
        #expect(PaneTone.allCases.map(\.rawValue) == ["neutral", "warm", "cool"])
        #expect(AppearanceSetting.allCases.map(\.title) == ["Ink", "Paper", "Match system"])
        #expect(AppearanceSetting.allCases.map(\.rawValue) == ["dark", "light", "system"])
    }

    // MARK: Project colours in Light

    private static func hue(_ c: RGB) -> Double {
        let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue), delta = high - low
        guard delta > 0 else { return 0 }
        let sector: Double
        if high == c.red { sector = ((c.green - c.blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == c.green { sector = (c.blue - c.red) / delta + 2 }
        else { sector = (c.red - c.green) / delta + 4 }
        return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func hueDistance(_ a: RGB, _ b: RGB) -> Double {
        let difference = abs(hue(a) - hue(b)).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? 360 - difference : difference
    }

    @Test func lightProjectStripesHoldAsStripesOnTheLightSidebar() {
        for tone in ProjectTone.allCases {
            for backdrop in PaneTone.allCases.flatMap({ Self.sidebarBackdrops(.light, $0) }) {
                #expect(LoomTheme.ProjectColor.baseRGB(tone, .light).contrast(with: backdrop.rgb) >= 3, "\(tone) over \(backdrop.name)")
                #expect(LoomTheme.ProjectColor.increasedRGB(tone, .light).contrast(with: backdrop.rgb) >= 4.5,
                        "\(tone), Increase Contrast, over \(backdrop.name)")
            }
            // Increase Contrast goes deeper in Light, where it goes lighter in Dark.
            #expect(LoomTheme.ProjectColor.increasedRGB(tone, .light).luminance < LoomTheme.ProjectColor.baseRGB(tone, .light).luminance)
        }
    }

    @Test func lightProjectTonesStayThirtyDegreesFromTheStatusHuesAndTheAccent() {
        let reserved = [LoomTheme.Status.attentionPair.light, LoomTheme.Status.unviewedPair.light,
                        LoomTheme.Status.failurePair.light, LoomTheme.Accent.basePair.light]
        for tone in ProjectTone.allCases {
            for other in reserved {
                #expect(Self.hueDistance(LoomTheme.ProjectColor.baseRGB(tone, .light), other) >= 30, "\(tone)")
            }
            // The Light tone keeps the Dark tone's family (within 25 degrees of hue), only deeper.
            #expect(Self.hueDistance(LoomTheme.ProjectColor.baseRGB(tone, .light), LoomTheme.ProjectColor.baseRGB(tone, .dark)) < 25, "\(tone)")
        }
    }

    @Test func textOnTheLightTintedTabsKeepsTheTiers() {
        for tone in PaneTone.allCases {
            let panel = Self.greys(.light, tone).canvas
            for project in ProjectTone.allCases {
                let selectedBase = Self.ink.composited(over: panel, opacity: LoomTheme.Surface.selectedLightOpacity)
                let base = LoomTheme.ProjectColor.baseRGB(project, .light)
                let open = base.composited(over: selectedBase, opacity: LoomTheme.ProjectColor.tabWashOpen)
                let hover = base.composited(over: panel, opacity: LoomTheme.ProjectColor.tabWashHover)
                let rest = base.composited(over: panel, opacity: LoomTheme.ProjectColor.tabWash)
                for (name, fill) in [("open", open), ("hover", hover), ("rest", rest)] {
                    #expect(LoomTheme.Text.primaryPair.light.contrast(with: fill) >= 7, "\(tone) \(project) \(name)")
                }
                #expect(LoomTheme.Text.secondaryOnTintPair.light.contrast(with: rest) >= 4.5, "\(tone) \(project) rest secondary")
                #expect(LoomTheme.Text.secondaryOnTintPair.light.contrast(with: open) >= 3, "\(tone) \(project) open glyph")
                #expect(LoomTheme.Text.secondaryIncreasedPair.light.contrast(with: rest) >= 4.5, "\(tone) \(project) rest, Increase Contrast")
            }
        }
    }

    // MARK: Chat: code and output

    @Test func syntaxAndOutputColoursAreAAOnACardAndTheCanvasInBothAppearances() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let greys = Self.greys(appearance, tone)
                let backs = [greys.raised1, greys.canvas]
                    + [(appearance == .dark ? Self.white : Self.ink).composited(over: greys.canvas, opacity: LoomTheme.Surface.selectedTone[appearance].opacity)]
                // The dark palette is VS Code Dark+ and xterm's, unchanged since Release A (its ANSI blue and black are
                // decoration, not text to read at length; its comment green is 4.4:1); the light palette is deeper and every colour of it reads.
                let texts = LoomTheme.Chat.syntaxPairs + [LoomTheme.Chat.outputPair, LoomTheme.Chat.inlineCodePair]
                    + (appearance == .light ? LoomTheme.Chat.ansiStandardPairs + LoomTheme.Chat.ansiBrightPairs : [])
                for back in backs {
                    for (index, pair) in texts.enumerated() {
                        #expect(pair[appearance].contrast(with: back) >= (appearance == .light ? 4.5 : 4.3), "\(appearance) \(tone) text #\(index)")
                    }
                }
            }
        }
    }

    // MARK: Resolution

    /// Renders `content` and returns the colour of its middle pixel.
    @MainActor private static func pixel<Content: View>(_ content: Content) throws -> RGB {
        let renderer = ImageRenderer(content: content.frame(width: 16, height: 16))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return RGB(bytes: (Int(data[0]), Int(data[1]), Int(data[2])))
    }

    private func close(_ a: RGB, _ b: RGB, by tolerance: Int = 3) -> Bool {
        let (x, y) = (a.bytes, b.bytes)
        return abs(x.0 - y.0) <= tolerance && abs(x.1 - y.1) <= tolerance && abs(x.2 - y.2) <= tolerance
    }

    @MainActor @Test func aTokenResolvesToTheAppearanceOfTheEnvironment() throws {
        for appearance in Appearance.allCases {
            let drawn = try Self.pixel(Rectangle().fill(LoomTheme.Text.primary).environment(\.colorScheme, appearance.colorScheme))
            #expect(close(drawn, LoomTheme.Text.primaryPair[appearance]), "\(appearance): \(drawn.bytes)")
            let card = try Self.pixel(Rectangle().fill(LoomTheme.Surface.card).environment(\.colorScheme, appearance.colorScheme))
            #expect(close(card, Self.greys(appearance, .neutral).raised1), "\(appearance) card: \(card.bytes)")
        }
    }

    /// The terminal face is dark in Light: one subtree under a dark scheme inside a light parent draws the dark panel
    /// (the way `DetailView` scopes its panel), and the parent around it stays light.
    @MainActor @Test func aDarkScopeInsideALightParentDrawsTheDarkPanelAndLeavesTheRestLight() throws {
        let scoped = Rectangle().fill(LoomTheme.Surface.canvas).environment(\.colorScheme, .dark)
        let drawn = try Self.pixel(scoped.environment(\.colorScheme, .light))
        #expect(close(drawn, Self.greys(.dark, .neutral).canvas), "scoped: \(drawn.bytes)")
        let outside = try Self.pixel(Rectangle().fill(LoomTheme.Surface.canvas).environment(\.colorScheme, .light))
        #expect(close(outside, Self.greys(.light, .neutral).canvas), "outside: \(outside.bytes)")
    }

    @Test func onlyTheTerminalFaceIsDrawnDarkWhateverTheAppearanceIs() {
        let id = UUID()
        let dark: [DetailRoute] = [.devTerminal, .terminal(sessionID: id), .endedScreen(sessionID: id)]
        let follows: [DetailRoute] = [.startupError("x"), .record(sessionID: id), .chat(sessionID: id), .home,
                                      .draft(projectID: nil), .projectPage(projectID: id), .noSelection]
        for route in dark { #expect(route.drawsDark, "\(route)") }
        for route in follows { #expect(!route.drawsDark, "\(route)") }
    }

    /// A view that draws a panel-family token reads the tone while its body runs, so a change of tone reaches it.
    @MainActor @Test func theToneIsObservedByWhatReadsAPanelToken() async {
        let state = LoomTheme.ThemeState.shared
        let before = state.tone
        defer { state.tone = before }
        // Every tone-aware token subscribes: Ink's six greys and the Night Fleece names that alias them, the sidebar and the
        // backdrop included (the sidebar's tint follows a tone change).
        let tokens: [(String, () -> Color)] = [
            ("canvas", { LoomTheme.Surface.canvas }), ("raised1", { LoomTheme.Surface.raised1 }),
            ("raised2", { LoomTheme.Surface.raised2 }), ("popover", { LoomTheme.Surface.popover }),
            ("segmentOn", { LoomTheme.Surface.segmentOn }), ("tree", { LoomTheme.Surface.tree }),
            ("sidebar", { LoomTheme.Surface.sidebar }), ("backdrop", { LoomTheme.Surface.backdrop }),
            ("inspector", { LoomTheme.Surface.inspector }), ("panel", { LoomTheme.Surface.panel }),
            ("card", { LoomTheme.Surface.card }),
        ]
        for (name, token) in tokens {
            state.tone = .neutral
            let changed = Flag()
            withObservationTracking({ _ = token() }, onChange: { changed.value = true })
            #expect(!changed.value, "\(name)")
            state.tone = .warm
            #expect(changed.value, "reading Surface.\(name) subscribes to the tone")
        }
        #expect(LoomTheme.Surface.card == LoomTheme.Surface.colors(for: .warm).raised1)
        state.tone = .cool
        #expect(LoomTheme.Surface.sidebar == LoomTheme.Surface.colors(for: .cool).canvas)
        #expect(LoomTheme.Surface.panel == LoomTheme.Surface.colors(for: .cool).canvas)
    }

    @MainActor @Test func theTonePicksTheCanvasOfEachToneAndTheSidebarFollowsIt() throws {
        let state = LoomTheme.ThemeState.shared
        let before = state.tone
        defer { state.tone = before }
        for tone in PaneTone.allCases {
            state.tone = tone
            for appearance in Appearance.allCases {
                let drawn = try Self.pixel(Rectangle().fill(LoomTheme.Surface.panel).environment(\.colorScheme, appearance.colorScheme))
                #expect(close(drawn, Self.greys(appearance, tone).canvas), "\(appearance) \(tone): \(drawn.bytes)")
                let sidebar = try Self.pixel(Rectangle().fill(LoomTheme.Surface.sidebar).environment(\.colorScheme, appearance.colorScheme))
                #expect(close(sidebar, Self.greys(appearance, tone).canvas), "sidebar \(appearance) \(tone): \(sidebar.bytes)")
            }
        }
    }

    // MARK: Layers

    /// A layer cannot see the SwiftUI environment: the working spinner follows its view's appearance when that changes.
    @MainActor @Test func theWorkingSpinnerFollowsAnAppearanceChange() throws {
        let view = BrailleSpinner.LayerView(style: .status)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        let dark = try #require(view.glyphColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(close(RGB(bytes: (Int(dark.redComponent * 255), Int(dark.greenComponent * 255), Int(dark.blueComponent * 255))),
                      LoomTheme.Text.primaryPair.dark), "Dark: the primary text colour")
        window.appearance = NSAppearance(named: .aqua)
        let light = try #require(view.glyphColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(close(RGB(bytes: (Int(light.redComponent * 255), Int(light.greenComponent * 255), Int(light.blueComponent * 255))),
                      LoomTheme.Text.primaryPair.light), "Light: the ink")
    }

    /// The SwiftUI environment can override the view's look (the terminal face's header is dark in Light).
    @MainActor @Test func theWorkingSpinnerTakesTheEnvironmentsLookWhenItIsGiven() throws {
        let view = BrailleSpinner.LayerView(style: .status)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.setAppearance(.dark)
        let color = try #require(view.glyphColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(color.redComponent > 0.8, "a light glyph on a dark panel inside a light window")
    }

    // MARK: Settings

    @Test func theAppearanceAndToneAreKeptAndAnOldFileReadsAsInkNeutral() throws {
        let stored = UIPreferences(appearance: .light, paneTone: .warm)
        let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(stored))
        #expect(again.appearance == .light && again.paneTone == .warm && again == stored)
        let old = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(old.appearance == .dark && old.paneTone == .neutral)
        let odd = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"appearance": "sepia", "paneTone": 7}"#.utf8))
        #expect(odd.appearance == .dark && odd.paneTone == .neutral)
        // A value written now is the cast's own name.
        let written = try JSONEncoder().encode(UIPreferences(paneTone: .cool))
        #expect(String(decoding: written, as: UTF8.self).contains(#""paneTone":"cool""#))
    }

    /// Night Fleece 2 stored `nightFleece`, `workshop` and `instrument`; they decode as the casts Neutral, Warm and Cool,
    /// the new names decode as themselves, and an unknown string as Neutral.
    @Test func aStoredNightFleeceToneDecodesAsTheCast() throws {
        func tone(_ stored: String) throws -> PaneTone {
            try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"paneTone": "\#(stored)"}"#.utf8)).paneTone
        }
        #expect(try tone("nightFleece") == .neutral)
        #expect(try tone("workshop") == .warm)
        #expect(try tone("instrument") == .cool)
        for cast in PaneTone.allCases { #expect(try tone(cast.rawValue) == cast) }
        #expect(try tone("sepia") == .neutral)
        // The tone alone, outside a preferences file.
        #expect(try JSONDecoder().decode([PaneTone].self, from: Data(#"["workshop","cool","nightFleece"]"#.utf8)) == [.warm, .cool, .neutral])
    }

    @Test func settingsHasAThemeSectionBetweenGeneralAndUsage() {
        #expect(SettingsSection.available(cleanupReview: false).map(\.title) == ["General", "Theme", "Usage", "Remora", "About"])
    }
}

/// Settings → Theme applies at once and is kept (D-63). The suite is serial and puts back what it changes: the tone
/// and the terminal's background are process-wide.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ThemeSettingsModelTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-theme-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func model(at root: URL) -> CatalogModel {
        CatalogModel(catalog: nil, startupError: nil, events: SessionEventHub(),
                     preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
    }

    private func stored(_ root: URL) throws -> UIPreferences {
        try JSONDecoder().decode(UIPreferences.self, from: Data(contentsOf: root.appendingPathComponent("ui-preferences.json")))
    }

    @Test func theAppearanceAppliesLiveAndIsKept() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        #expect(model.appearance == .dark, "the default: today's users see no change")
        var applied = 0
        model.onThemeChange = { applied += 1 }

        model.setAppearance(.light)
        #expect(model.appearance == .light && applied == 1)
        #expect(try stored(root).appearance == .light)
        model.setAppearance(.light)
        #expect(applied == 1, "no change, no signal")
        model.setAppearance(.system)
        #expect(try stored(root).appearance == .system && applied == 2)
        #expect(self.model(at: root).appearance == .system, "a new window reads what was saved")
    }

    @Test func theToneAppliesLiveToTheViewsAndTheTerminalAndIsKept() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = LoomTheme.ThemeState.shared
        let (tone, background) = (state.tone, TerminalTheme.backgroundRGB)
        defer { state.tone = tone; TerminalTheme.setBackground(background) }
        let model = model(at: root)
        model.installTheme()
        #expect(model.paneTone == .neutral && state.tone == .neutral)
        #expect(TerminalTheme.backgroundRGB == TerminalRGB(red: 0x0C, green: 0x0C, blue: 0x0E), "the terminal is Neutral's Ink canvas")
        var applied = 0
        model.onThemeChange = { applied += 1 }

        model.setPaneTone(.warm)
        #expect(state.tone == .warm && applied == 1)
        #expect(TerminalTheme.backgroundRGB == TerminalRGB(red: 0x0E, green: 0x0C, blue: 0x0A), "the terminal is the tone's Ink canvas")
        #expect(try stored(root).paneTone == .warm)
        model.setPaneTone(.cool)
        #expect(TerminalTheme.backgroundRGB == TerminalRGB(red: 0x0A, green: 0x0C, blue: 0x10))
        model.setPaneTone(.cool)
        #expect(applied == 2, "no change, no signal")

        // A launch installs the stored tone; a model made by a test touches no global.
        state.tone = .neutral
        let again = self.model(at: root)
        #expect(again.paneTone == .cool && state.tone == .neutral)
        again.installTheme()
        #expect(state.tone == .cool)
    }
}
