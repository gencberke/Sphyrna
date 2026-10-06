import AppKit
import SwiftTerm

/// Terminal colors (CP5 UI item 7). The engine's defaults washed colors out in
/// two ways: the 16-color palette is Terminal.app's (dark red/blue), and the
/// extended 256-color palette was derived from it by LAB interpolation toward
/// the default foreground (`.base16Lab`), so every cube color was pulled
/// toward the base 16 and white topped out at the foreground gray. Providers
/// that start without COLORTERM=truecolor emit those 256-color indices.
/// Loom installs the VS Code dark terminal palette and the standard xterm
/// cube and gray ramp, all in sRGB.
public enum TerminalTheme {
    public static let background = NSColor(srgbRed: 29 / 255, green: 28 / 255, blue: 34 / 255, alpha: 1)
    public static let foreground = NSColor(srgbRed: 232 / 255, green: 230 / 255, blue: 238 / 255, alpha: 1)

    /// ANSI 0-7 then bright 8-15.
    public static let ansi: [Color] = [
        (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
        (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
        (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
        (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
    ].map { Color(red8: UInt16($0.0), green8: UInt16($0.1), blue8: UInt16($0.2)) }
}
