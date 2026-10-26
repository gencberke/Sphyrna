import AppKit
import Observation
import SwiftUI
import Synchronization

/// Appearance-aware tokens (D-63, V26). A token is a dynamic colour with an Ink (dark) and a Paper (light) value.
/// The Ink values are the `…RGB` constants, the pairs hold both as data, so `LoomThemeTests` can compute the
/// contrast of both appearances.
///
/// How a token resolves:
/// - the appearance (Dark, Light) comes from the SwiftUI environment's colour scheme, which follows the
///   window's `NSAppearance` (Settings → Theme → Appearance) and which one subtree can override: the terminal
///   face is drawn under a dark scheme in both appearances (`DetailRoute.drawsDark`);
/// - the tone (`PaneTone`: Neutral, Warm, Cool) is the one app-wide value that cannot ride on a colour scheme. The six
///   greys (`Surface.canvas`, `raised1`, `raised2`, `popover`, `segmentOn`, `tree`) and the Night Fleece names that
///   alias them read it from `ThemeState`, an observable: a view that draws one of those tokens reads the tone while its
///   body runs, so a change of tone redraws exactly those views. Do not keep such a token in a `static let` (it would
///   freeze the tone it was first read with); `scripts/check-theme-literals.sh` flags it.
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

    /// Paper's ink `#1E1C1A`: overlays, hairlines and fills are this colour at an opacity where Ink uses white.
    static let inkRGB = RGB(hex: 0x1E1C1A)
    static let whiteRGB = RGB(red: 1, green: 1, blue: 1)
    static let blackRGB = RGB(red: 0, green: 0, blue: 0)

    /// A white overlay in Ink, an ink overlay in Paper.
    static func overlay(dark: Double, light: Double) -> AdaptiveTone {
        AdaptiveTone(dark: Tone(rgb: whiteRGB, opacity: dark), light: Tone(rgb: inkRGB, opacity: light))
    }

    /// The tone, app-wide and observable. Set by `CatalogModel` (Settings → Theme → Tone).
    final class ThemeState: Observable, @unchecked Sendable {
        static let shared = ThemeState()
        private let registrar = ObservationRegistrar()
        private let storage = Mutex(PaneTone.neutral)

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

extension LoomTheme.RGB {
    /// The channels as 0...255 integers.
    var bytes: (Int, Int, Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    init(bytes: (Int, Int, Int)) {
        self.init(red: Double(bytes.0) / 255, green: Double(bytes.1) / 255, blue: Double(bytes.2) / 255)
    }
}
