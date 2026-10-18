import AppKit
import LoomCore
import Observation
import SwiftUI
import Testing
import LoomTerminal
@testable import LoomCatalogUI

/// Themes (D-63, V26): every contrast rule of DESIGN §6 in both appearances and for every tone, the way a
/// token resolves (appearance, tone, the terminal face's dark scope), and the settings that drive it.
struct ThemeAppearanceTests {
    private final class Flag: @unchecked Sendable { var value = false }

    typealias RGB = LoomTheme.RGB
    typealias Appearance = LoomTheme.Appearance

    private static let ink = LoomTheme.inkRGB
    private static let white = RGB(red: 1, green: 1, blue: 1)
    private static let black = RGB(red: 0, green: 0, blue: 0)

    // MARK: Surfaces the tiers are checked on

    /// The opaque levels of one appearance and tone. Light adds the fills drawn over the panel and the canvas (the
    /// selection, a control, hover), which are new rules of the new theme; Dark keeps the levels the tiers were set on.
    private static func surfaces(_ appearance: Appearance, _ tone: PaneTone) -> [(name: String, rgb: RGB)] {
        let levels = LoomTheme.Surface.levels(appearance, tone: tone)
        let plain = [("inspector", levels.inspector), ("canvas", levels.canvas), ("panel", levels.panel),
                     ("card", levels.card), ("raised", levels.raised), ("popover", levels.popover)]
        guard appearance == .light else { return plain }
        return plain + [
            ("panel+selected", ink.composited(over: levels.panel, opacity: LoomTheme.Surface.selectedLightOpacity)),
            ("panel+control", ink.composited(over: levels.panel, opacity: LoomTheme.Surface.controlLightOpacity)),
            ("canvas+hover", ink.composited(over: levels.canvas, opacity: LoomTheme.Surface.controlHoverLightOpacity))]
    }

    /// Where the sidebar tint sits: opaque (Solid, Reduce Transparency), and over the glass material at its two
    /// extremes. Dark: the dark material lets a white window show at 0.5 gray (measured, 12 Oct 2026) and black at
    /// black. Light: the light material over a white window is white; over a dark desktop it is assumed to lift to
    /// 0.70 gray (not measured; DESIGN §3 says so).
    private static func sidebarBackdrops(_ appearance: Appearance) -> [(name: String, rgb: RGB, worst: Bool)] {
        let tint = LoomTheme.Surface.sidebarTintOpacity
        let opaque = LoomTheme.Surface.sidebarPair[appearance]
        switch appearance {
        case .dark:
            return [("opaque", opaque, false), ("over black", opaque.composited(over: black, opacity: tint), false),
                    ("over white", opaque.composited(over: RGB(red: 0.5, green: 0.5, blue: 0.5), opacity: tint), true)]
        case .light:
            return [("opaque", opaque, false), ("over white", opaque.composited(over: white, opacity: tint), false),
                    ("over dark desktop", opaque.composited(over: RGB(red: 0.7, green: 0.7, blue: 0.7), opacity: tint), true)]
        }
    }

    private static func selectedOnSidebar(_ appearance: Appearance) -> RGB {
        let overlay = appearance == .dark ? white : ink
        let opacity = appearance == .dark ? LoomTheme.Surface.selectedOpacity : LoomTheme.Surface.selectedLightOpacity
        return overlay.composited(over: LoomTheme.Surface.sidebarPair[appearance], opacity: opacity)
    }

    // MARK: Tiers on the panel family, both appearances, every tone

    @Test func primaryAndSecondaryHoldTheirTiersOnEveryLevelInBothAppearancesAndTones() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                for (name, level) in Self.surfaces(appearance, tone) {
                    let id = "\(appearance) \(tone) \(name)"
                    #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: level) >= 7, "primary on \(id)")
                    #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: level) >= 4.5, "secondary on \(id)")
                    // Increase Contrast lifts secondary to at least 7:1 (the dark theme's own 5.4 to 8 is not the floor).
                    #expect(LoomTheme.Text.secondaryIncreasedPair[appearance].contrast(with: level) >= 7,
                            "secondary, Increase Contrast, on \(id)")
                }
            }
        }
    }

    @Test func tertiaryTextHoldsItsFloorWhereDesignAllowsIt() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                for (name, level) in Self.surfaces(appearance, tone) where name != "popover" || appearance == .light {
                    #expect(LoomTheme.Text.tertiaryPair[appearance].contrast(with: level) >= 2.5, "\(appearance) \(tone) \(name)")
                }
            }
        }
    }

    @Test func accentAndStatusHuesAreAAOnTheLevelsBelowAPopover() {
        for appearance in Appearance.allCases {
            let hues: [(String, RGB)] = [
                ("accent", LoomTheme.Accent.basePair[appearance]), ("attention", LoomTheme.Status.attentionPair[appearance]),
                ("unviewed", LoomTheme.Status.unviewedPair[appearance]), ("failure", LoomTheme.Status.failurePair[appearance])]
            for tone in PaneTone.allCases {
                for (name, level) in Self.surfaces(appearance, tone) where name != "popover" {
                    for (hue, rgb) in hues {
                        #expect(rgb.contrast(with: level) >= 4.5, "\(appearance) \(tone) \(hue) on \(name)")
                    }
                }
            }
        }
    }

    @Test func theHighAccentTheVariantsAndSuccessAreAAOnEveryLevel() {
        for appearance in Appearance.allCases {
            let texts: [(String, RGB)] = [
                ("accent high", LoomTheme.Accent.highPair[appearance]),
                ("attention light", LoomTheme.Status.attentionLightPair[appearance]),
                ("unviewed light", LoomTheme.Status.unviewedLightPair[appearance]),
                ("failure light", LoomTheme.Status.failureLightPair[appearance]),
                ("success", LoomTheme.Success.basePair[appearance]), ("success light", LoomTheme.Success.lightPair[appearance])]
            for tone in PaneTone.allCases {
                for (name, level) in Self.surfaces(appearance, tone) {
                    for (text, rgb) in texts {
                        #expect(rgb.contrast(with: level) >= 4.5, "\(appearance) \(tone) \(text) on \(name)")
                    }
                }
            }
        }
    }

    /// The popover rules (DESIGN §3): placeholders are secondary, accent text is the high step, the unviewed and
    /// failure text are their light variants. They hold on every tone's popover in both appearances.
    @Test func theOnPopoverTokensAreAAOnEveryPopover() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let popover = LoomTheme.Surface.levels(appearance, tone: tone).popover
                for (name, pair) in [("placeholder", LoomTheme.OnPopover.placeholderPair), ("accent", LoomTheme.OnPopover.accentPair),
                                     ("unviewed", LoomTheme.OnPopover.unviewedPair), ("failure", LoomTheme.OnPopover.failurePair),
                                     ("attention", LoomTheme.Status.attentionPair)] {
                    #expect(pair[appearance].contrast(with: popover) >= 4.5, "\(appearance) \(tone) \(name) on popover")
                }
            }
        }
    }

    /// The chat bar's mode colours (V24) are text and icons on the composer card and on the popover list, also under the
    /// pointer: AA on every tone's card, popover, panel and canvas in both appearances, and a different colour per mode.
    @Test func theModeTonesAreAAOnTheCardAndThePopoverInBothAppearances() {
        let modes = ClaudePermissionMode.menuModes.map(\.rawValue)
        for appearance in Appearance.allCases {
            let overlay = appearance == .dark ? Self.white : Self.ink
            let hover = appearance == .dark ? LoomTheme.Surface.controlHoverOpacity : LoomTheme.Surface.controlHoverLightOpacity
            for tone in PaneTone.allCases {
                let levels = LoomTheme.Surface.levels(appearance, tone: tone)
                for mode in modes {
                    let rgb = LoomTheme.Composer.ModeTone.pair(forRaw: mode)[appearance]
                    for (name, back) in [("card", levels.card), ("popover", levels.popover), ("panel", levels.panel),
                                         ("canvas", levels.canvas)] {
                        #expect(rgb.contrast(with: back) >= 4.5, "\(appearance) \(tone) \(mode) on \(name)")
                        let hovered = overlay.composited(over: back, opacity: hover)
                        #expect(rgb.contrast(with: hovered) >= 4.5, "\(appearance) \(tone) \(mode) on hovered \(name)")
                    }
                }
            }
            let distinct = Set(modes.map { LoomTheme.Composer.ModeTone.pair(forRaw: $0)[appearance].bytes }.map { "\($0)" })
            #expect(distinct.count == modes.count, "\(appearance): one colour per mode")
        }
        // A mode Loom does not offer takes the secondary text colour.
        #expect(LoomTheme.Composer.ModeTone.pair(forRaw: "dontAsk") == LoomTheme.Text.secondaryPair)
    }

    /// The banner above the composer (V19) is drawn on the card: its icon, message, action and dismiss glyph hold AA there
    /// in both appearances and on every tone; the handover notice (the header's status text and the composer's
    /// "Moving to the terminal…") is secondary text on the panel or the card.
    @Test func theBannerAndTheHandoverNoticeAreAAInBothAppearances() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let levels = LoomTheme.Surface.levels(appearance, tone: tone)
                for (name, pair) in [("icon", LoomTheme.Status.attentionLightPair), ("message", LoomTheme.Text.primaryPair),
                                     ("action", LoomTheme.Accent.basePair), ("dismiss", LoomTheme.Text.secondaryPair)] {
                    #expect(pair[appearance].contrast(with: levels.card) >= 4.5, "\(appearance) \(tone) banner \(name)")
                }
                for (name, back) in [("header", levels.panel), ("composer", levels.card)] {
                    #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: back) >= 4.5, "\(appearance) \(tone) notice on \(name)")
                }
            }
        }
    }

    /// The effort slider (V24): the thumb stands out from the accent fill it slides over, the dots on the fill stay
    /// readable on it, in both appearances.
    @Test func theEffortSliderPartsSeparateFromTheAccentFillInBothAppearances() {
        for appearance in Appearance.allCases {
            let fill = LoomTheme.Accent.basePair[appearance]
            // A control's boundary needs 3:1 (WCAG 1.4.11).
            #expect(LoomTheme.Composer.effortThumbPair[appearance].contrast(with: fill) >= 3, "\(appearance) thumb on fill")
            let dot = LoomTheme.Composer.effortDotOnTone[appearance]
            #expect(dot.rgb.composited(over: fill, opacity: dot.opacity).contrast(with: fill) >= 1.5, "\(appearance) dot on fill")
            // The pointer's fills are the control fills of the appearance, not a white that would vanish on paper.
            let pointer = appearance == .dark ? Self.white : Self.ink
            #expect(LoomTheme.Composer.effortTrackTone[appearance].rgb == pointer)
            #expect(LoomTheme.Composer.effortDotOffTone[appearance].rgb == pointer)
        }
    }

    @Test func textOnAFilledAccentIsAAInBothAppearances() {
        for appearance in Appearance.allCases {
            #expect(LoomTheme.Accent.onAccentPair[appearance].contrast(with: LoomTheme.Accent.basePair[appearance]) >= 4.5, "\(appearance)")
        }
        // Dark text on the periwinkle in Dark, a warm paper white on the deep indigo in Light.
        #expect(LoomTheme.Accent.onAccentPair.dark.luminance < LoomTheme.Accent.basePair.dark.luminance)
        #expect(LoomTheme.Accent.onAccentPair.light.luminance > LoomTheme.Accent.basePair.light.luminance)
    }

    @Test func theLowAccentNeverCarriesTextInEitherAppearance() {
        for appearance in Appearance.allCases {
            // Dark: primary text on the low accent is 4.33:1, under the 4.5:1 a text pair needs.
            if appearance == .dark { #expect(LoomTheme.Text.primaryPair.dark.contrast(with: LoomTheme.Accent.lowPair.dark) < 4.5) }
            let texts = [LoomTheme.Text.primaryPair, LoomTheme.Text.secondaryPair, LoomTheme.Text.tertiaryPair,
                         LoomTheme.Text.secondaryIncreasedPair, LoomTheme.Accent.basePair, LoomTheme.Accent.highPair,
                         LoomTheme.OnPopover.accentPair, LoomTheme.Success.basePair]
            #expect(!texts.contains(LoomTheme.Accent.lowPair))
        }
    }

    // MARK: The sidebar

    @Test func sidebarTextHoldsItsTiersInBothAppearances() {
        for appearance in Appearance.allCases {
            let surfaces = Self.sidebarBackdrops(appearance).map { ($0.name, $0.rgb, $0.worst) }
                + [("selected card", Self.selectedOnSidebar(appearance), false)]
            for (name, surface, worst) in surfaces {
                let id = "\(appearance) sidebar \(name)"
                #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: surface) >= 7, "primary on \(id)")
                // As in Dark since 12 Oct: AA everywhere but the glass's worst case, which must not fall under 3:1.
                #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: surface) >= (worst ? 3 : 4.5), "secondary on \(id)")
                if !worst { #expect(LoomTheme.Text.tertiaryPair[appearance].contrast(with: surface) >= 2.5, "tertiary on \(id)") }
                if !worst {
                    for (hue, rgb) in [("accent", LoomTheme.Accent.basePair), ("attention", LoomTheme.Status.attentionPair),
                                       ("unviewed", LoomTheme.Status.unviewedPair), ("failure", LoomTheme.Status.failurePair)] {
                        #expect(rgb[appearance].contrast(with: surface) >= 4.5, "\(hue) on \(id)")
                    }
                }
                #expect(LoomTheme.Text.secondaryIncreasedPair[appearance].contrast(with: surface) >= (worst ? 4.5 : 7),
                        "secondary, Increase Contrast, on \(id)")
            }
        }
    }

    // MARK: The values

    /// The default tone in Dark gives back the values the tokens always had, so a user who changes nothing sees no change.
    @Test func nightFleeceInDarkIsTodaysPanelFamilyExactly() {
        let levels = LoomTheme.Surface.levels(.dark, tone: .nightFleece)
        #expect(levels.all == LoomTheme.Surface.panelLevelsRGB)
        #expect(levels.all == [RGB(hex: 0x141318), RGB(hex: 0x19181E), RGB(hex: 0x1D1C22), RGB(hex: 0x222128),
                               RGB(hex: 0x2A2930), RGB(hex: 0x302F38)])
        #expect(LoomTheme.Surface.terminalRGB == levels.panel && LoomTheme.Surface.panelRGB == levels.panel)
        #expect(TerminalRGB(red: 29, green: 28, blue: 34) == TerminalTheme.defaultBackgroundRGB)
    }

    @Test func theThreeTonesAreTheIdentityDirectionsPanels() {
        #expect(LoomTheme.Surface.darkPanelRGB(.nightFleece) == RGB(hex: 0x1D1C22))
        #expect(LoomTheme.Surface.darkPanelRGB(.workshop) == RGB(hex: 0x1E1C1A))
        #expect(LoomTheme.Surface.darkPanelRGB(.instrument) == RGB(hex: 0x16171B))
        // The terminal's background is the dark panel: one value per tone.
        for tone in PaneTone.allCases {
            #expect(LoomTheme.Surface.levels(.dark, tone: tone).panel == LoomTheme.Surface.darkPanelRGB(tone))
            #expect(LoomTheme.Surface.levels(.light, tone: tone).panel == LoomTheme.Surface.lightPanelRGB(tone))
        }
        #expect(PaneTone.allCases.map(\.title) == ["Night fleece", "Workshop", "Instrument"])
    }

    @Test func everyLevelIsStepsFromThePanelAndTheDarkOnesStayDarkerThanTheLightOnes() {
        for tone in PaneTone.allCases {
            let dark = LoomTheme.Surface.levels(.dark, tone: tone), light = LoomTheme.Surface.levels(.light, tone: tone)
            // Dark: the inspector, the canvas and the panel go up; the card, raised and popover are lifted. The inspector is
            // the darkest, the popover the lightest.
            #expect(dark.all == dark.all.sorted { $0.luminance < $1.luminance })
            // Light: the card and the popover are lighter than the panel, the canvas and the inspector darker; raised (a
            // card's hover) is darker than the panel.
            #expect(light.popover.luminance > light.card.luminance && light.card.luminance > light.panel.luminance)
            #expect(light.panel.luminance > light.canvas.luminance && light.canvas.luminance > light.inspector.luminance)
            #expect(light.raised.luminance < light.panel.luminance)
            for level in light.all { #expect(level.luminance > 0.7, "Light is a paper, not a mid grey (\(tone))") }
            for level in dark.all { #expect(level.luminance < 0.05, "Dark stays dark (\(tone))") }
        }
    }

    /// Cozy, never stark: no light surface is a pure white, and the warm tones lean warm (red over blue).
    @Test func theLightSurfacesAreAWarmOffWhiteNeverStarkWhite() {
        for tone in PaneTone.allCases {
            for level in LoomTheme.Surface.levels(.light, tone: tone).all {
                let bytes = level.bytes
                #expect(max(bytes.0, bytes.1, bytes.2) <= 0xFD, "\(tone): \(bytes)")
            }
        }
        let sand = LoomTheme.Surface.sidebarLightRGB.bytes
        #expect(sand.0 > sand.2 && max(sand.0, sand.1, sand.2) <= 0xF0, "the sidebar is a warm sand")
        for tone in [PaneTone.nightFleece, .workshop] {
            let panel = LoomTheme.Surface.levels(.light, tone: tone).panel
            #expect(panel.red > panel.blue, "\(tone) leans warm")
        }
        // Light text is a warm near-black, not black.
        #expect(LoomTheme.Text.primaryPair.light != Self.black && LoomTheme.Text.primaryPair.light == LoomTheme.inkRGB)
    }

    @Test func theDarkValuesOfEveryPairAreTheTokensTheyAlwaysHad() {
        #expect(LoomTheme.Text.primaryRGB == RGB(hex: 0xECE8F4) && LoomTheme.Text.secondaryRGB == RGB(hex: 0x9A9EB0))
        #expect(LoomTheme.Text.tertiaryRGB == RGB(hex: 0x636779) && LoomTheme.Text.secondaryIncreasedRGB == RGB(hex: 0xBCC0D0))
        #expect(LoomTheme.Accent.baseRGB == RGB(hex: 0x8791CF) && LoomTheme.Accent.highRGB == RGB(hex: 0xA9B0E3))
        #expect(LoomTheme.Accent.lowRGB == RGB(hex: 0x5E68A8) && LoomTheme.Accent.onAccentRGB == LoomTheme.Surface.sidebarRGB)
        #expect(LoomTheme.Status.attentionRGB == RGB(hex: 0xFF9E0A) && LoomTheme.Status.unviewedRGB == RGB(hex: 0x5C8CFF))
        #expect(LoomTheme.Status.failureRGB == RGB(hex: 0xF2615C))
        #expect(LoomTheme.Status.attentionLightRGB == RGB(hex: 0xFFB547) && LoomTheme.Status.unviewedLightRGB == RGB(hex: 0x8FB0FF))
        #expect(LoomTheme.Status.failureLightRGB == RGB(hex: 0xFF8A85))
        #expect(LoomTheme.Success.baseRGB == RGB(hex: 0x4CC38A) && LoomTheme.Success.lightRGB == RGB(hex: 0x7BDBA8))
        #expect(LoomTheme.Surface.sidebarRGB == RGB(red: 0.043, green: 0.055, blue: 0.086))
        for tone in ProjectTone.allCases {
            #expect(LoomTheme.ProjectColor.baseRGB(tone, .dark) == LoomTheme.ProjectColor.baseRGB(tone))
            #expect(LoomTheme.ProjectColor.increasedRGB(tone, .dark) == LoomTheme.ProjectColor.increasedRGB(tone))
        }
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
            for backdrop in Self.sidebarBackdrops(.light) {
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
            let panel = LoomTheme.Surface.levels(.light, tone: tone).panel
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
                let levels = LoomTheme.Surface.levels(appearance, tone: tone)
                let backs = [levels.card, levels.canvas, levels.panel]
                    + [(appearance == .dark ? Self.white : Self.ink).composited(over: levels.canvas, opacity: 0.07)]
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
            #expect(close(card, LoomTheme.Surface.levels(appearance, tone: .nightFleece).card), "\(appearance) card: \(card.bytes)")
        }
    }

    /// The terminal face is dark in Light: one subtree under a dark scheme inside a light parent draws the dark panel
    /// (the way `DetailView` scopes its panel), and the parent around it stays light.
    @MainActor @Test func aDarkScopeInsideALightParentDrawsTheDarkPanelAndLeavesTheRestLight() throws {
        let scoped = Rectangle().fill(LoomTheme.Surface.panel).environment(\.colorScheme, .dark)
        let drawn = try Self.pixel(scoped.environment(\.colorScheme, .light))
        #expect(close(drawn, LoomTheme.Surface.levels(.dark, tone: .nightFleece).panel), "scoped: \(drawn.bytes)")
        let outside = try Self.pixel(Rectangle().fill(LoomTheme.Surface.panel).environment(\.colorScheme, .light))
        #expect(close(outside, LoomTheme.Surface.levels(.light, tone: .nightFleece).panel), "outside: \(outside.bytes)")
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
        state.tone = .nightFleece
        let changed = Flag()
        withObservationTracking({ _ = LoomTheme.Surface.card }, onChange: { changed.value = true })
        #expect(!changed.value)
        state.tone = .workshop
        #expect(changed.value, "reading Surface.card subscribes to the tone")
        #expect(LoomTheme.Surface.card == LoomTheme.Surface.colors(for: .workshop).card)
        state.tone = .instrument
        #expect(LoomTheme.Surface.panel == LoomTheme.Surface.colors(for: .instrument).panel)
    }

    @MainActor @Test func theTonePicksThePanelOfEachTone() throws {
        let state = LoomTheme.ThemeState.shared
        let before = state.tone
        defer { state.tone = before }
        for tone in PaneTone.allCases {
            state.tone = tone
            for appearance in Appearance.allCases {
                let drawn = try Self.pixel(Rectangle().fill(LoomTheme.Surface.panel).environment(\.colorScheme, appearance.colorScheme))
                #expect(close(drawn, LoomTheme.Surface.levels(appearance, tone: tone).panel), "\(appearance) \(tone): \(drawn.bytes)")
            }
        }
    }

    // MARK: Layers

    /// A layer cannot see the SwiftUI environment: the working chase follows its view's appearance when that changes.
    @MainActor @Test func theWorkingChaseFollowsAnAppearanceChange() throws {
        let view = ChaseDots.LayerView(scale: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        let dark = try #require(view.dotColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(close(RGB(bytes: (Int(dark.redComponent * 255), Int(dark.greenComponent * 255), Int(dark.blueComponent * 255))),
                      LoomTheme.Text.primaryPair.dark), "Dark: the primary text colour")
        window.appearance = NSAppearance(named: .aqua)
        let light = try #require(view.dotColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(close(RGB(bytes: (Int(light.redComponent * 255), Int(light.greenComponent * 255), Int(light.blueComponent * 255))),
                      LoomTheme.Text.primaryPair.light), "Light: the ink")
    }

    /// The SwiftUI environment can override the view's look (the terminal face's header is dark in Light).
    @MainActor @Test func theWorkingChaseTakesTheEnvironmentsLookWhenItIsGiven() throws {
        let view = ChaseDots.LayerView(scale: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.setAppearance(.dark)
        let color = try #require(view.dotColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(color.redComponent > 0.8, "light dots on a dark panel inside a light window")
    }

    // MARK: Settings

    @Test func theAppearanceAndToneAreKeptAndAnOldFileReadsAsDarkNightFleece() throws {
        let stored = UIPreferences(appearance: .light, paneTone: .workshop)
        let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(stored))
        #expect(again.appearance == .light && again.paneTone == .workshop && again == stored)
        let old = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(old.appearance == .dark && old.paneTone == .nightFleece)
        let odd = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"appearance": "sepia", "paneTone": 7}"#.utf8))
        #expect(odd.appearance == .dark && odd.paneTone == .nightFleece)
        #expect(AppearanceSetting.allCases.map(\.title) == ["Dark", "Light", "Match system"])
    }

    @Test func settingsHasAThemeSectionBetweenGeneralAndUsage() {
        #expect(SettingsSection.available(cleanupReview: false).map(\.title) == ["General", "Theme", "Usage", "About"])
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
        #expect(model.paneTone == .nightFleece && state.tone == .nightFleece)
        #expect(TerminalTheme.backgroundRGB == TerminalTheme.defaultBackgroundRGB)
        var applied = 0
        model.onThemeChange = { applied += 1 }

        model.setPaneTone(.workshop)
        #expect(state.tone == .workshop && applied == 1)
        #expect(TerminalTheme.backgroundRGB == TerminalRGB(red: 0x1E, green: 0x1C, blue: 0x1A), "the terminal is the dark panel")
        #expect(try stored(root).paneTone == .workshop)
        model.setPaneTone(.instrument)
        #expect(TerminalTheme.backgroundRGB == TerminalRGB(red: 0x16, green: 0x17, blue: 0x1B))
        model.setPaneTone(.instrument)
        #expect(applied == 2, "no change, no signal")

        // A launch installs the stored tone; a model made by a test touches no global.
        state.tone = .nightFleece
        let again = self.model(at: root)
        #expect(again.paneTone == .instrument && state.tone == .nightFleece)
        again.installTheme()
        #expect(state.tone == .instrument)
    }
}
