import Foundation
import SwiftTerm

/// A static, bounded copy of what a terminal showed: a grid size and rows of styled text runs, colours
/// already resolved to RGB. It holds no engine, no view and no AppKit object, so a stopped session can keep
/// its last screen for nothing more than the text (FB4-3). Memory-only: never persisted.
public struct TerminalScreenSnapshot: Sendable, Equatable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let bold = Style(rawValue: 1)
        public static let italic = Style(rawValue: 2)
        public static let underline = Style(rawValue: 4)
        public static let strikethrough = Style(rawValue: 8)
    }

    /// Cells that share one look. `background` is nil where it is the terminal's own background.
    public struct Run: Sendable, Equatable {
        public let text: String
        public let foreground: TerminalRGB
        public let background: TerminalRGB?
        public let style: Style
    }

    /// Tells one capture from another, so a view draws a capture once.
    public let captureID = UUID()
    /// Columns of the terminal the rows were taken from.
    public let columns: Int
    /// One array of runs per row, top first. A blank row is empty.
    public let lines: [[Run]]
    /// An estimate of the memory it holds, for the keeper's budget.
    public let approximateBytes: Int

    /// The plain text, one line per row.
    public var text: String {
        lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
    }

    public var isBlank: Bool { lines.isEmpty }

    /// Copies `copy` into a snapshot of at most `maxLines` rows (the last ones) and about `maxBytes`
    /// (the first rows go). Trailing blank rows and trailing blank cells are dropped.
    public init(_ copy: Terminal.BufferRowsCopy, maxLines: Int, maxBytes: Int) {
        var resolver = Resolver()
        var built = copy.rows.suffix(max(0, maxLines)).map { resolver.runs(of: $0, columns: copy.columns) }
        while built.last?.isEmpty == true { built.removeLast() }
        var cost = built.reduce(0) { $0 + Self.bytes(of: $1) }
        var drop = 0
        while cost > maxBytes, drop < built.count {
            cost -= Self.bytes(of: built[drop])
            drop += 1
        }
        columns = copy.columns
        lines = drop == 0 ? built : Array(built.dropFirst(drop))
        approximateBytes = max(0, cost)
    }

    /// Each run costs its struct, its string header and bytes, and a share of the array; each row an array header.
    private static func bytes(of runs: [Run]) -> Int {
        runs.reduce(48) { $0 + MemoryLayout<Run>.stride + 32 + $1.text.utf8.count }
    }

    /// Colours and styles of cells the way the engine's renderer draws them: the 16 installed colours then the
    /// xterm cube, bright colours for bold text below ANSI 7, inverse swaps the pair (the default pair swaps to
    /// the other default), dim moves the text colour half way to the background, invisible text is blank.
    private struct Resolver {
        let defaultForeground = TerminalTheme.foregroundRGB
        let defaultBackground = TerminalTheme.backgroundRGB
        private var cache: [Attribute: (fg: TerminalRGB, bg: TerminalRGB, style: Style, hidden: Bool)] = [:]

        mutating func runs(of cells: [CharData], columns: Int) -> [Run] {
            var runs: [Run] = []
            var text = ""
            var current: (fg: TerminalRGB, bg: TerminalRGB?, style: Style)?
            var pendingBlanks = 0   // blank cells not yet written: trailing ones are dropped
            func flush() {
                guard let look = current, !text.isEmpty else { return }
                runs.append(Run(text: text, foreground: look.fg, background: look.bg, style: look.style))
                text = ""
            }
            for cell in cells.prefix(max(columns, 1)) where cell.width != 0 {
                let resolved = resolve(cell.attribute)
                var glyph = resolved.hidden ? " " : cell.getText()
                if glyph.isEmpty || glyph.unicodeScalars.first.map({ $0.value < 0x20 || $0.value == 0x7f }) == true {
                    glyph = " "
                }
                let shown = resolved.bg != defaultBackground || !resolved.style.isDisjoint(with: [.underline, .strikethrough])
                if glyph == " " && !shown {
                    pendingBlanks += 1
                    continue
                }
                // A blank cell with nothing to paint takes the look of its neighbour, so runs stay long.
                let look = (fg: resolved.fg, bg: resolved.bg == defaultBackground ? nil : resolved.bg, style: resolved.style)
                if let open = current, open != look { flush() }
                current = look
                if pendingBlanks > 0 {
                    text.append(String(repeating: " ", count: pendingBlanks))
                    pendingBlanks = 0
                }
                text.append(glyph)
            }
            flush()
            return runs
        }

        private mutating func resolve(_ attribute: Attribute) -> (fg: TerminalRGB, bg: TerminalRGB, style: Style, hidden: Bool) {
            if let known = cache[attribute] { return known }
            var fg = attribute.fg, bg = attribute.bg
            let flags = attribute.style
            if flags.contains(.inverse) {
                swap(&fg, &bg)
                if fg == .defaultColor { fg = .defaultInvertedColor }
                if bg == .defaultColor { bg = .defaultInvertedColor }
            }
            let bold = flags.contains(.bold)
            let background = color(bg, isForeground: false, bold: false)
            var foreground = color(fg, isForeground: true, bold: bold)
            if flags.contains(.dim) { foreground = foreground.midpoint(with: background) }
            var style: Style = []
            if bold { style.insert(.bold) }
            if flags.contains(.italic) { style.insert(.italic) }
            if flags.contains(.underline) { style.insert(.underline) }
            if flags.contains(.crossedOut) { style.insert(.strikethrough) }
            let resolved = (fg: foreground, bg: background, style: style, hidden: flags.contains(.invisible))
            if cache.count < 1_024 { cache[attribute] = resolved }
            return resolved
        }

        private func color(_ color: Attribute.Color, isForeground: Bool, bold: Bool) -> TerminalRGB {
            switch color {
            case .defaultColor:
                return isForeground ? defaultForeground : defaultBackground
            case .defaultInvertedColor:
                return isForeground ? defaultBackground : defaultForeground
            case let .ansi256(code):
                let index = Int(code)
                return TerminalTheme.palette[code < 7 && bold ? index + 8 : index]
            case let .trueColor(red, green, blue):
                return TerminalRGB(red: red, green: green, blue: blue)
            }
        }
    }
}
