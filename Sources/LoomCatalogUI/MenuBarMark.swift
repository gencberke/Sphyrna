import AppKit
import Foundation
import SwiftUI

/// A minimal SVG path reader for the menu bar mark: absolute and relative M, L, C and Z (and the
/// implicit repeats of M and L), nothing else. The mark ships as path data in the source, not as an
/// asset, so the packaging stays as it is.
enum SVGPathParser {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " \t\r\n,")
        var current = CGPoint.zero, start = CGPoint.zero
        var command: Character?
        let letters = CharacterSet(charactersIn: "MmLlCcZz")

        func number() -> Double? { scanner.scanDouble() }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacters(from: letters) {
                // Several letters in a row cannot occur in valid data; take the last as the command.
                command = letter.last
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    current = start
                    continue
                }
            }
            guard let active = command else { break }
            let relative = active.isLowercase
            switch active {
            case "M", "m":
                guard let target = point(relative: relative) else { return path }
                path.move(to: target)
                current = target
                start = target
                command = relative ? "l" : "L" // further pairs are lines
            case "L", "l":
                guard let target = point(relative: relative) else { return path }
                path.addLine(to: target)
                current = target
            case "C", "c":
                guard let first = point(relative: relative), let second = point(relative: relative),
                      let target = point(relative: relative) else { return path }
                path.addCurve(to: target, control1: first, control2: second)
                current = target
            default:
                return path
            }
        }
        return path
    }
}

/// The Loom mark for the menu bar (`assets/Loom-menubar.svg`, one colour): its path data, the box it is
/// drawn in, and the path in that box.
public enum MenuBarMark {
    /// viewBox 0 0 512 512 under `translate(0 512) scale(.1 -.1)`.
    static let data = """
        M2794 3710 c-129 -33 -299 -135 -359 -214 -21 -28 -26 -42 -21 -63 9 -38 154 -178 199 -192 32 -11 41 -9 104 23
        171 86 354 70 475 -43 150 -138 150 -379 0 -511 -107 -95 -278 -94 -386 2 l-46 40 -11 -29 c-16 -40 -14 -122 4
        -164 60 -144 264 -222 452 -174 360 92 559 494 430 868 -36 103 -81 173 -175 267 -71 72 -100 93 -180 132 -52 26
        -127 54 -167 62 -96 21 -230 20 -319 -4z M2183 3695 c-116 -32 -221 -108 -273 -199 -17 -28 -30 -54 -30 -58 0 -4
        20 1 45 12 66 28 220 68 294 76 64 7 65 7 137 83 40 41 71 77 69 79 -2 2 -21 8 -42 13 -55 12 -140 10 -200 -6z
        M2212 3388 c-159 -22 -390 -122 -559 -241 -299 -210 -585 -600 -609 -828 -12 -118 40 -251 125 -318 96 -76 178
        -98 426 -116 110 -8 224 -21 254 -29 125 -34 230 -115 272 -211 11 -24 24 -81 30 -127 20 -170 65 -271 166 -374
        34 -35 63 -65 63 -67 0 -1 -10 -27 -22 -57 -29 -76 -37 -259 -14 -350 42 -170 158 -318 311 -397 44 -23 98 -46
        120 -52 22 -6 45 -14 51 -18 5 -5 15 -48 22 -96 6 -48 14 -92 17 -97 4 -6 415 -10 1131 -10 l1124 0 0 1584 0 1585
        -55 -19 c-84 -29 -143 -68 -232 -154 l-83 -78 -54 49 c-111 102 -233 151 -391 160 -113 6 -199 -10 -298 -54 l-60
        -27 -26 34 c-37 51 -120 134 -127 128 -3 -4 0 -34 7 -67 17 -89 7 -268 -21 -356 -103 -328 -377 -545 -688 -545
        -161 0 -273 41 -373 137 -37 35 -66 75 -85 116 -79 173 -8 407 124 407 44 0 68 -14 117 -66 74 -78 167 -82 238 -9
        60 62 72 147 33 231 -42 90 -120 130 -238 122 -50 -4 -85 -14 -131 -37 -89 -45 -122 -52 -176 -40 -92 20 -262 163
        -302 253 -11 25 -21 45 -22 45 -1 -1 -30 -6 -65 -11z m-256 -505 c115 -88 129 -102 132 -131 2 -18 -2 -40 -9 -49
        -7 -8 -69 -55 -138 -105 -103 -73 -130 -88 -151 -83 -35 8 -51 34 -48 74 3 31 12 42 83 92 44 31 80 61 82 66 1 4
        -30 31 -69 58 -39 28 -77 56 -85 63 -18 19 -16 72 4 94 32 35 63 23 199 -79z m528 -88 c23 -24 28 -52 14 -82 l-13
        -28 -141 -3 c-130 -2 -142 -1 -158 17 -23 26 -24 66 -1 91 16 18 32 20 151 20 105 0 136 -3 148 -15z
        """

    /// The mark in the SVG's own 512 x 512 space, y pointing down.
    nonisolated(unsafe) static let path: CGPath = {
        var flip = CGAffineTransform(a: 0.1, b: 0, c: 0, d: -0.1, tx: 0, ty: 512)
        return SVGPathParser.parse(data).copy(using: &flip) ?? CGPath(rect: .zero, transform: nil)
    }()

    /// The mark fitted to `MenuBarMark` points: its box scaled to `LoomTheme.MenuBar.markWidth`, origin at
    /// the top-left of the mark's box (y pointing down).
    static func fitted(origin: CGPoint) -> CGPath {
        let box = LoomTheme.MenuBar.markBox
        let scale = LoomTheme.MenuBar.markWidth / box.width
        var transform = CGAffineTransform(translationX: origin.x, y: origin.y)
            .scaledBy(x: scale, y: scale).translatedBy(x: -box.minX, y: -box.minY)
        return path.copy(using: &transform) ?? path
    }
}

/// The Loom mark as a SwiftUI shape: the menu bar mark's own path data (no second asset), fitted to the
/// frame it is given and filled with the winding rule.
struct LoomMarkShape: Shape {
    /// The width-to-height ratio of the mark's box.
    static var aspect: CGFloat { LoomTheme.MenuBar.markBox.width / LoomTheme.MenuBar.markBox.height }

    func path(in rect: CGRect) -> Path {
        let box = LoomTheme.MenuBar.markBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale).translatedBy(x: -box.minX, y: -box.minY)
        return Path(MenuBarMark.path.copy(using: &transform) ?? MenuBarMark.path)
    }
}

/// How the menu bar item is drawn (D-52). One drawing routine serves the real item (the spinner is a layer
/// animation on top of it), the evidence pictures (the spinner's first frame drawn in) and the idle
/// template. All geometry and colour is `LoomTheme.MenuBar`.
public enum MenuBarArt {
    public static var canvas: CGSize { LoomTheme.MenuBar.canvas }

    /// Whether `appearance` is a dark one: the mark is white on a dark bar, black on a light one.
    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Idle: the plain template image, which macOS tints.
    @MainActor
    public static func templateImage() -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, badge: .none, darkBar: false, increasedContrast: false, spinnerFrame: nil)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// With a badge Loom draws the item itself: the handler runs with the bar's appearance (and the
    /// system's Increase Contrast setting) every time the image is drawn, so the mark stays black on a
    /// light bar and white on a dark one. The spinner, when there is one, is not drawn here.
    @MainActor
    public static func badgedImage(_ badge: MenuBarBadge) -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, badge: badge, darkBar: isDark(NSAppearance.currentDrawing()),
                 increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, spinnerFrame: nil)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The badge slot as a rectangle in the canvas: the spinner's layer on the live item, its first frame in a picture.
    static func spinnerRect() -> CGRect {
        let theme = LoomTheme.MenuBar.self
        let side = LoomTheme.Spinner.menuBarSide
        return CGRect(x: theme.markOrigin.x + theme.chaseOrigin.x, y: theme.markOrigin.y + theme.chaseOrigin.y,
                      width: side, height: side)
    }

    /// The spinner on a bar: white on a dark one, black on a light one, as the mark is. Increase Contrast changes
    /// nothing here: the glyph has no dim part to lift (the chase's trail did).
    static func spinnerColor(darkBar: Bool) -> CGColor { LoomTheme.MenuBar.markRGB(darkBar: darkBar).cgColor }

    /// Draws the item into a context whose origin is the canvas' top-left (y pointing down). `spinnerFrame`
    /// draws the working spinner at that frame (evidence); the live item leaves it to the layer.
    static func draw(in context: CGContext, badge: MenuBarBadge, darkBar: Bool, increasedContrast: Bool, spinnerFrame: Int?) {
        let theme = LoomTheme.MenuBar.self
        context.saveGState()
        defer { context.restoreGState() }
        // The mark, cut away around the badge.
        context.saveGState()
        let box = CGRect(origin: .zero, size: theme.canvas)
        var cutout: CGRect?
        switch badge {
        case .none: break
        case .working:
            cutout = circle(center: theme.chaseCutoutCenter, radius: theme.chaseCutoutRadius)
        case .failure, .attention, .unviewed:
            cutout = increasedContrast
                ? circle(center: theme.dotCenterIncreased, radius: theme.dotCutoutRadiusIncreased)
                : circle(center: theme.dotCenter, radius: theme.dotCutoutRadius)
        }
        if let cutout {
            context.addRect(box)
            context.addEllipse(in: cutout)
            context.clip(using: .evenOdd)
        }
        context.setFillColor(theme.markRGB(darkBar: darkBar).cgColor)
        context.addPath(MenuBarMark.fitted(origin: theme.markOrigin))
        context.fillPath(using: .winding)
        context.restoreGState()
        // The badge.
        if let attention = badge.dotClass {
            let diameter = increasedContrast ? theme.dotDiameterIncreased : theme.dotDiameter
            let center = increasedContrast ? theme.dotCenterIncreased : theme.dotCenter
            context.setFillColor(theme.dotRGB(attention, darkBar: darkBar, increasedContrast: increasedContrast).cgColor)
            context.fillEllipse(in: CGRect(x: theme.markOrigin.x + center.x - diameter / 2,
                                           y: theme.markOrigin.y + center.y - diameter / 2,
                                           width: diameter, height: diameter))
        } else if badge == .working, let frame = spinnerFrame {
            BrailleFrames.draw(frame: frame, style: .menuBar, color: spinnerColor(darkBar: darkBar), in: context,
                               rect: spinnerRect(), scale: 4)
        }
    }

    private static func circle(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: LoomTheme.MenuBar.markOrigin.x + center.x - radius, y: LoomTheme.MenuBar.markOrigin.y + center.y - radius,
               width: radius * 2, height: radius * 2)
    }

    /// Evidence: the item as it looks on a bar of the given appearance, at `scale`x, as PNG data. The spinner
    /// is its first frame, drawn in. This is the item's own drawing, not a capture of the screen.
    public static func evidencePNG(badge: MenuBarBadge, darkBar: Bool, increasedContrast: Bool, scale: Int = 2) -> Data? {
        let theme = LoomTheme.MenuBar.self
        let pixelsWide = Int(theme.barWidth) * scale, pixelsHigh = Int(theme.barHeight) * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // y points down from here.
        context.translateBy(x: 0, y: theme.barHeight)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor((darkBar ? theme.barDarkRGB : theme.barLightRGB).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: theme.barWidth, height: theme.barHeight))
        context.translateBy(x: (theme.barWidth - theme.canvas.width) / 2, y: (theme.barHeight - theme.canvas.height) / 2)
        draw(in: context, badge: badge, darkBar: darkBar, increasedContrast: increasedContrast, spinnerFrame: 0)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Menu glyphs

    /// A session row's dot (12 pt image, 8 pt dot) in the colour of its class; it follows the menu's appearance.
    @MainActor
    public static func rowDotImage(_ attention: ProjectAttention) -> NSImage {
        let theme = LoomTheme.MenuBar.self
        let image = NSImage(size: NSSize(width: theme.rowGlyph, height: theme.rowGlyph), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let color = theme.dotRGB(attention, darkBar: isDark(NSAppearance.currentDrawing()),
                                     increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: (rect.width - theme.rowDot) / 2, y: (rect.height - theme.rowDot) / 2,
                                           width: theme.rowDot, height: theme.rowDot))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A working session's glyph: the spinner on its first frame, static, as a template so a highlighted row inverts it.
    @MainActor
    public static func rowSpinnerImage() -> NSImage {
        let glyph = LoomTheme.MenuBar.rowGlyph
        let image = NSImage(size: NSSize(width: glyph, height: glyph), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The pixels the menu draws at: the context's own scale.
            let scale = max(1, (context.userSpaceToDeviceSpaceTransform.a).rounded())
            BrailleFrames.draw(frame: 0, style: .status, color: CGColor(gray: 0, alpha: 1), in: context,
                               rect: CGRect(x: (rect.width - LoomTheme.Spinner.side) / 2, y: (rect.height - LoomTheme.Spinner.side) / 2,
                                            width: LoomTheme.Spinner.side, height: LoomTheme.Spinner.side), scale: scale)
            return true
        }
        image.isTemplate = true
        return image
    }
}
