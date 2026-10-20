import AppKit
import SwiftTerm
import Synchronization

/// An sRGB colour as a plain value, so a kept screen holds no AppKit object.
public struct TerminalRGB: Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// The midpoint with `other`: how the engine's renderer draws dim (SGR 2) text towards the background.
    func midpoint(with other: TerminalRGB) -> TerminalRGB {
        func half(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Int(a) + Int(b) + 1) / 2) }
        return TerminalRGB(red: half(red, other.red), green: half(green, other.green), blue: half(blue, other.blue))
    }
}

/// Terminal colors (CP5 UI item 7). The engine's defaults washed colors out in
/// two ways: the 16-color palette is Terminal.app's (dark red/blue), and the
/// extended 256-color palette was derived from it by LAB interpolation toward
/// the default foreground (`.base16Lab`), so every cube color was pulled
/// toward the base 16 and white topped out at the foreground gray. Providers
/// that start without COLORTERM=truecolor emit those 256-color indices.
/// Loom installs the VS Code dark terminal palette and the standard xterm
/// cube and gray ramp, all in sRGB.
public enum TerminalTheme {
    /// Ink's Neutral canvas `#0C0C0E`, the default tone (D-81); the app sets the chosen tone's canvas at launch.
    public static let defaultBackgroundRGB = TerminalRGB(red: 12, green: 12, blue: 14)
    public static let foregroundRGB = TerminalRGB(red: 232, green: 230, blue: 238)
    public static let foreground = foregroundRGB.nsColor

    /// The terminal face is dark in both appearances (D-63): the chosen dark tone's panel is its background.
    /// Settings → Theme → Main pane changes it (`setBackground`), and the app applies it to the live
    /// terminals (`TerminalSurface.applyTheme`). Read on the engine's feeding thread too, hence the lock.
    private static let currentBackground = Mutex(defaultBackgroundRGB)
    public static var backgroundRGB: TerminalRGB { currentBackground.withLock { $0 } }
    public static var background: NSColor { backgroundRGB.nsColor }

    public static func setBackground(_ rgb: TerminalRGB) {
        currentBackground.withLock { $0 = rgb }
    }

    /// ANSI 0-7 then bright 8-15.
    private static let base16: [TerminalRGB] = [
        (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
        (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
        (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
        (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
    ].map { TerminalRGB(red: $0.0, green: $0.1, blue: $0.2) }

    public static let ansi: [Color] = base16.map {
        Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue))
    }

    /// All 256 indices as the engine resolves them: the installed 16, then the xterm cube and gray ramp.
    public static let palette: [TerminalRGB] = {
        let levels: [UInt8] = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
        var colors = base16
        for index in 0..<216 {
            colors.append(TerminalRGB(red: levels[(index / 36) % 6], green: levels[(index / 6) % 6], blue: levels[index % 6]))
        }
        for step in 0..<24 {
            let gray = UInt8(8 + step * 10)
            colors.append(TerminalRGB(red: gray, green: gray, blue: gray))
        }
        return colors
    }()
}
