import AppKit
import Foundation

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

/// Front, the menu bar mark (D-77; `design/identity/menubar-front.svg`, one colour): the hammerhead seen from the front.
/// Its path data is in the 20 pt canvas' own space (y pointing down), 18 wide; each path is filled on its own with
/// the even-odd rule, as the SVG fills it, so the eye holes stay open and the overlapping parts stay filled.
public enum MenuBarMark {
    static let data: [String] = [
        // The dorsal fin.
        "M8.75 7.2C9.25 5.4 9.65 3.9 10 2.7C10.35 3.9 10.75 5.4 11.25 7.2Z",
        // The hammer, with an eye hole at each tip.
        "M.95 8.85C.95 7.85 1.6 7.3 2.5 7.25C5.2 7.05 7.6 6.5 10 6.5C12.4 6.5 14.8 7.05 17.5 7.25C18.4 7.3 19.05 7.85 19.05 8.85C19.05 9.9 18.35 10.45 17.45 10.35C14.75 10.05 12.6 9.75 10 9.75C7.4 9.75 5.25 10.05 2.55 10.35C1.65 10.45 .95 9.9 .95 8.85ZM3.3 8.8C3.3 9.214225 2.964225 9.55 2.55 9.55C2.1357749999999998 9.55 1.7999999999999998 9.214225 1.7999999999999998 8.8C1.7999999999999998 8.385775 2.1357749999999998 8.05 2.55 8.05C2.964225 8.05 3.3 8.385775 3.3 8.8ZM18.2 8.8C18.2 9.214225 17.864224999999998 9.55 17.45 9.55C17.035775 9.55 16.7 9.214225 16.7 8.8C16.7 8.385775 17.035775 8.05 17.45 8.05C17.864224999999998 8.05 18.2 8.385775 18.2 8.8Z",
        // The jaw.
        "M7.5 9.5C7.5 11.85 8.55 13.2 10 13.2C11.45 13.2 12.5 11.85 12.5 9.5Z",
        // The left pectoral fin.
        "M8.7 11C7.25 11.8 5.65 12.75 4.1 14.05C5.8 13.95 7.45 13.4 8.95 12.6Z",
        // The right pectoral fin.
        "M11.3 11C12.75 11.8 14.35 12.75 15.9 14.05C14.2 13.95 12.55 13.4 11.05 12.6Z",
    ]

    /// The parts, in canvas points.
    nonisolated(unsafe) static let paths: [CGPath] = data.map(SVGPathParser.parse)

    /// The mark's box in the canvas.
    static var bounds: CGRect { paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) } }

    /// Fills the mark in the context's current colour (its origin at the canvas' top-left, y pointing down).
    static func fill(in context: CGContext) {
        for path in paths {
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
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

    /// With a badge the app draws the item itself: the handler runs with the bar's appearance (and the
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
        return CGRect(x: theme.chaseOrigin.x, y: theme.chaseOrigin.y, width: side, height: side)
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
        MenuBarMark.fill(in: context)
        context.restoreGState()
        // The badge.
        if let attention = badge.dotClass {
            let diameter = increasedContrast ? theme.dotDiameterIncreased : theme.dotDiameter
            let center = increasedContrast ? theme.dotCenterIncreased : theme.dotCenter
            context.setFillColor(theme.dotRGB(attention, darkBar: darkBar, increasedContrast: increasedContrast).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                           width: diameter, height: diameter))
        } else if badge == .working, let frame = spinnerFrame {
            BrailleFrames.draw(frame: frame, style: .menuBar, color: spinnerColor(darkBar: darkBar), in: context,
                               rect: spinnerRect(), scale: 4)
        }
    }

    private static func circle(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
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

    /// A session row's dot (12 pt image, 7 pt dot) in the colour of its class; it follows the menu's appearance.
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
