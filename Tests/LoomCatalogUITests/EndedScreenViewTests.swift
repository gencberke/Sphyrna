import AppKit
import Foundation
import LoomTerminal
import Testing
@testable import LoomCatalogUI

/// FB4-3: the ended session's last screen is a static, selectable text view of the snapshot.
@MainActor
struct EndedScreenViewTests {
    private func snapshot(_ feed: String) throws -> TerminalScreenSnapshot {
        let surface = TerminalSurface()
        surface.view.feed(text: feed)
        return try #require(surface.captureVisibleScreen())
    }

    @Test func theViewShowsTheSnapshotsTextInTheTerminalsFontAndBackground() throws {
        let snapshot = try snapshot("first row\r\nsecond \u{1B}[1;31mbold red\u{1B}[0m \u{1B}[4munder\u{1B}[0m \u{1B}[44mon blue\u{1B}[0m")
        let view = EndedScreenContainerView()
        view.show(snapshot, fontSize: 14)
        #expect(view.textView.string == snapshot.text)
        #expect(view.textView.backgroundColor == TerminalTheme.background)
        let storage = try #require(view.textView.textStorage)
        let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == TerminalSurface.font(size: 14).pointSize)
        #expect(font.isFixedPitch)
    }

    @Test func theTextCanBeSelectedAndCopiedButNotEdited() {
        let view = EndedScreenContainerView()
        #expect(view.textView.isSelectable && !view.textView.isEditable)
    }

    @Test func runsAreDrawnWithTheirColorsAndDecorations() throws {
        let snapshot = try snapshot("plain \u{1B}[1;31mbold red\u{1B}[0m \u{1B}[4munder\u{1B}[0m \u{1B}[44mon blue\u{1B}[0m")
        let text = EndedScreenContainerView.attributedString(for: snapshot, fontSize: 14)
        func attributes(of word: String) throws -> [NSAttributedString.Key: Any] {
            let range = (text.string as NSString).range(of: word)
            return text.attributes(at: range.location, effectiveRange: nil)
        }
        let bold = try attributes(of: "bold red")
        #expect(NSFontManager.shared.traits(of: try #require(bold[.font] as? NSFont)).contains(.boldFontMask))
        #expect(bold[.foregroundColor] as? NSColor == TerminalTheme.palette[9].nsColor)
        #expect(try attributes(of: "under")[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(try attributes(of: "on blue")[.backgroundColor] != nil)
        #expect(try attributes(of: "plain")[.backgroundColor] == nil)
    }

    @Test func aTallerScreenThanTheAreaScrollsVerticallyAndOpensAtTheBottom() throws {
        let rows = (0..<200).map { "row \($0)" }.joined(separator: "\r\n")
        let surface = TerminalSurface()
        surface.view.feed(text: rows)
        let snapshot = try #require(surface.captureEndedScreen())
        let view = EndedScreenContainerView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        view.layoutSubtreeIfNeeded()
        view.show(snapshot, fontSize: 14)
        let scroll = try #require(view.textView.enclosingScrollView)
        #expect(scroll.hasVerticalScroller)
        let visible = scroll.contentView.bounds
        #expect(view.textView.frame.height > visible.height, "the text is taller than the area")
        #expect(visible.maxY >= view.textView.frame.height - 1, "it opens at the bottom, where the last output is")
    }

    @Test func aFullRowIsAsWideAsTheTerminalAndTheScreenOpensAtItsFirstColumn() throws {
        let surface = TerminalSurface()
        let columns = surface.view.terminalDimensions.cols
        let row = "A" + String(repeating: "x", count: columns - 2) + "Z"
        surface.view.feed(text: Array(repeating: row, count: 60).joined(separator: "\r\n"))
        let snapshot = try #require(surface.captureVisibleScreen())
        // Every character is one terminal cell wide: the font's advance snapped to the pixel grid, as the engine
        // draws it. At the font's own advance a full row came out wider than the terminal.
        let font = TerminalSurface.font(size: 14)
        let cell = (font.advancement(forGlyph: font.glyph(withName: "W")).width * 2).rounded() / 2
        let text = EndedScreenContainerView.attributedString(for: snapshot, fontSize: 14, scale: 2)
        let first = text.attributedSubstring(from: NSRange(location: 0, length: columns)).size().width
        #expect(abs(first - CGFloat(columns) * cell) < 1, "a full row is \(first) wide, the terminal \(CGFloat(columns) * cell)")

        // An area narrower and shorter than the screen opens at the last row, with the rows' first column in view,
        // also when the screen is shown before the area has a size, as the app does.
        let view = EndedScreenContainerView()
        view.show(snapshot, fontSize: 14)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        view.layoutSubtreeIfNeeded()
        let clip = try #require(view.textView.enclosingScrollView).contentView
        #expect(view.textView.frame.width > clip.bounds.width, "the rows are wider than the area")
        #expect(clip.bounds.minX == 0, "the first column is in view")
        #expect(clip.bounds.maxY >= view.textView.frame.height - 1, "the last row is in view")
    }

    @Test func theSameCaptureAtTheSameSizeIsNotDrawnAgain() throws {
        let snapshot = try snapshot("once")
        let view = EndedScreenContainerView()
        view.show(snapshot, fontSize: 14)
        let storage = try #require(view.textView.textStorage)
        view.textView.setSelectedRange(NSRange(location: 1, length: 2))
        view.show(snapshot, fontSize: 14)
        #expect(view.textView.selectedRange() == NSRange(location: 1, length: 2), "a redraw would reset the selection")
        #expect(storage === view.textView.textStorage)
        view.show(snapshot, fontSize: 16)
        let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == TerminalSurface.font(size: 16).pointSize)
    }
}
