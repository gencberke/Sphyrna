import AppKit
import Observation
import SwiftUI
import Synchronization

/// Appearance-aware tokens (D-63, V26). Every colour token keeps its name and its `Color` type; what changed is
/// that a token is now a dynamic colour with a dark and a light value. The dark values are the ones the tokens
/// always had (the `…RGB` constants and the tests read them), the light values live beside them as `…Light…`
/// data so `LoomThemeTests` can compute the contrast of both appearances.
///
/// How a token resolves:
/// - the appearance (Dark, Light) comes from the SwiftUI environment's colour scheme, which follows the
///   window's `NSAppearance` (Settings → Theme → Appearance) and which one subtree can override: the terminal
///   face is drawn under a dark scheme in both appearances (`DetailRoute.drawsDark`);
/// - the main pane's tone (`PaneTone`) is the one app-wide value that cannot ride on a colour scheme. The panel
///   family (`Surface.panel`, `canvas`, `inspector`, `card`, `raised`, `popover`) reads it from `ThemeState`,
///   an observable: a view that draws one of those tokens reads the tone while its body runs, so a change of
///   tone redraws exactly those views. Do not keep such a token in a `static let` (it would freeze the tone
///   it was first read with); `scripts/check-theme-literals.sh` flags it.
extension LoomTheme {
    /// The two looks a token resolves to.
    enum Appearance: String, CaseIterable, Sendable {
        case dark
        case light

        /// The look of an `NSAppearance` (any of the aqua, dark aqua and vibrant families).
        init(_ appearance: NSAppearance) {
            self = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }

        init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }

        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    /// An opaque colour with a value per appearance.
    struct Adaptive: Equatable, Sendable {
        let dark: RGB
        let light: RGB

        subscript(appearance: Appearance) -> RGB { appearance == .dark ? dark : light }

        var nsColor: NSColor {
            let dark = dark, light = light
            return NSColor(name: nil) { appearance in
                (Appearance(appearance) == .dark ? dark : light).nsColor
            }
        }

        var color: Color { Color(nsColor: nsColor) }
    }

    /// A colour at an opacity with a value per appearance (the white overlays of the dark theme are ink overlays in the
    /// light one).
    struct AdaptiveTone: Equatable, Sendable {
        let dark: Tone
        let light: Tone

        subscript(appearance: Appearance) -> Tone { appearance == .dark ? dark : light }

        var nsColor: NSColor {
            let dark = dark, light = light
            return NSColor(name: nil) { appearance in
                let tone = Appearance(appearance) == .dark ? dark : light
                return NSColor(srgbRed: tone.rgb.red, green: tone.rgb.green, blue: tone.rgb.blue, alpha: tone.opacity)
            }
        }

        var color: Color { Color(nsColor: nsColor) }
    }

    /// The warm ink of the light theme: overlays, hairlines and fills are this colour at an opacity where the dark
    /// theme uses white.
    static let inkRGB = RGB(hex: 0x2A2622)
    static let whiteRGB = RGB(red: 1, green: 1, blue: 1)

    /// A white overlay in Dark, an ink overlay in Light.
    static func overlay(dark: Double, light: Double) -> AdaptiveTone {
        AdaptiveTone(dark: Tone(rgb: whiteRGB, opacity: dark), light: Tone(rgb: inkRGB, opacity: light))
    }

    /// Settings → Theme → Main pane: a tone tile, the pane in miniature.
    enum ThemeTile {
        static let tilePadding: CGFloat = 8
        static let previewHeight: CGFloat = 58
        static let previewPadding: CGFloat = 8
        static let previewGap: CGFloat = 6
        static let previewLine: CGFloat = 54
        static let previewLineHeight: CGFloat = 5
        static let previewButton: CGFloat = 28
        static let previewCard: CGFloat = 24
        static let captionGap: CGFloat = 4
    }

    /// The main pane's tone, app-wide and observable. Set by `CatalogModel` (Settings → Theme → Main pane).
    final class ThemeState: Observable, @unchecked Sendable {
        static let shared = ThemeState()
        private let registrar = ObservationRegistrar()
        private let storage = Mutex(PaneTone.nightFleece)

        var tone: PaneTone {
            get {
                registrar.access(self, keyPath: \.tone)
                return storage.withLock { $0 }
            }
            set {
                registrar.withMutation(of: self, keyPath: \.tone) { storage.withLock { $0 = newValue } }
            }
        }
    }
}

// MARK: Panel family

extension LoomTheme.Surface {
    /// The six opaque levels of the main pane, back to front, for one appearance and tone.
    struct Levels: Equatable, Sendable {
        let inspector: LoomTheme.RGB
        let canvas: LoomTheme.RGB
        let panel: LoomTheme.RGB
        let card: LoomTheme.RGB
        let raised: LoomTheme.RGB
        let popover: LoomTheme.RGB

        /// In the order of `panelLevelsRGB`.
        var all: [LoomTheme.RGB] { [inspector, canvas, panel, card, raised, popover] }
    }

    /// The panel of each tone in Dark (the terminal's background): direction A, B and C of design/identity-preview.html.
    static func darkPanelRGB(_ tone: PaneTone) -> LoomTheme.RGB {
        switch tone {
        case .nightFleece: LoomTheme.RGB(hex: 0x1D1C22)
        case .workshop: LoomTheme.RGB(hex: 0x1E1C1A)
        case .instrument: LoomTheme.RGB(hex: 0x16171B)
        }
    }

    /// The light counterpart of each tone's panel: a warm paper, a warmer cream, a cool grey.
    static func lightPanelRGB(_ tone: PaneTone) -> LoomTheme.RGB {
        switch tone {
        case .nightFleece: LoomTheme.RGB(hex: 0xF7F4EE)
        case .workshop: LoomTheme.RGB(hex: 0xF9F1E4)
        case .instrument: LoomTheme.RGB(hex: 0xEFF0F1)
        }
    }

    /// Every level sits at a fixed step from the panel, so the three tones keep one rhythm. The dark steps are
    /// Night Fleece 2's own (they give back `#141318`, `#19181E`, `#222128`, `#2A2930` and `#302F38` for the
    /// default tone). In Light the card and the popover are lighter than the panel (never pure white: the
    /// channels stop at `FC` and `FD`), the inspector and the canvas are a step darker, and the raised level, the
    /// hover fill of a card, is darker than the card.
    static func levels(_ appearance: LoomTheme.Appearance, tone: PaneTone) -> Levels {
        func step(_ base: LoomTheme.RGB, _ delta: (Int, Int, Int), cap: Int = 255) -> LoomTheme.RGB {
            let bytes = base.bytes
            func moved(_ value: Int, _ by: Int) -> Int { min(cap, max(0, value + by)) }
            return LoomTheme.RGB(bytes: (moved(bytes.0, delta.0), moved(bytes.1, delta.1), moved(bytes.2, delta.2)))
        }
        switch appearance {
        case .dark:
            let panel = darkPanelRGB(tone)
            return Levels(inspector: step(panel, (-9, -9, -10)), canvas: step(panel, (-4, -4, -4)), panel: panel,
                          card: step(panel, (5, 5, 6)), raised: step(panel, (13, 13, 14)),
                          popover: step(panel, (19, 19, 22)))
        case .light:
            let panel = lightPanelRGB(tone)
            return Levels(inspector: step(panel, (-9, -9, -9)), canvas: step(panel, (-4, -4, -4)), panel: panel,
                          card: step(panel, (5, 5, 6), cap: 0xFC), raised: step(panel, (-6, -6, -6)),
                          popover: step(panel, (8, 8, 9), cap: 0xFD))
        }
    }

    /// The panel family as colours for one tone, built once.
    struct LevelColors {
        let inspector: Color
        let canvas: Color
        let panel: Color
        let card: Color
        let raised: Color
        let popover: Color
        let panelNS: NSColor

        init(tone: PaneTone) {
            let dark = LoomTheme.Surface.levels(.dark, tone: tone), light = LoomTheme.Surface.levels(.light, tone: tone)
            func pair(_ path: KeyPath<Levels, LoomTheme.RGB>) -> LoomTheme.Adaptive {
                LoomTheme.Adaptive(dark: dark[keyPath: path], light: light[keyPath: path])
            }
            inspector = pair(\.inspector).color
            canvas = pair(\.canvas).color
            panel = pair(\.panel).color
            card = pair(\.card).color
            raised = pair(\.raised).color
            popover = pair(\.popover).color
            panelNS = pair(\.panel).nsColor
        }
    }

    private static let levelColors: [PaneTone: LevelColors] = Dictionary(
        uniqueKeysWithValues: PaneTone.allCases.map { ($0, LevelColors(tone: $0)) })

    /// The panel family of the current tone. Reading it inside a view body subscribes the view to the tone.
    static func colors(for tone: PaneTone) -> LevelColors { levelColors[tone] ?? LevelColors(tone: .nightFleece) }
    static var current: LevelColors { colors(for: LoomTheme.ThemeState.shared.tone) }
}

extension LoomTheme.RGB {
    /// The channels as 0...255 integers.
    var bytes: (Int, Int, Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    init(bytes: (Int, Int, Int)) {
        self.init(red: Double(bytes.0) / 255, green: Double(bytes.1) / 255, blue: Double(bytes.2) / 255)
    }
}
