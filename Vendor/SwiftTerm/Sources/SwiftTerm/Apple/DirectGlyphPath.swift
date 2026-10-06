//
//  DirectGlyphPath.swift
//  SwiftTerm
//
//  Loom patch (patches/swiftterm-direct-glyph-runs.patch): the Core Graphics
//  renderer draws maximal runs of simple cells from cached glyph IDs instead
//  of building an NSAttributedString and a CTLine for them every frame.
//
//  A simple cell is single width printable ASCII (U+0020...U+007E, or an
//  empty cell drawn as a space) with no grapheme cluster, in a row without
//  BiDi layout or direction override, not blinking and without host glyph
//  fallback. Box/block/Powerline code points are outside that range, so their
//  dedicated renderers keep those cells. Everything else takes the unchanged
//  attributed-string path. The run carries the same batch attribute
//  dictionary that path would use, so fonts, colors, dim, inverse, selection
//  and decorations resolve identically.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation
import CoreGraphics
import CoreText

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One maximal run of simple cells with one batch attribute dictionary.
struct DirectGlyphRun {
    /// First visual column of the run.
    let column: Int
    /// Offset of the run's bytes in `SnapshotTextBuilder.directCodes`.
    let codeStart: Int
    /// Number of cells, one glyph per cell.
    let count: Int
    let attributes: SnapshotTextAttributes
}

/// Glyph IDs of printable ASCII per font, owned by one renderer.
///
/// A font is used only when CoreText shaping provably reproduces its
/// character-to-glyph map on the probe below: one glyph per character, the
/// cmap glyph, the font itself (no cascade) and a zero baseline offset. That
/// excludes fonts whose ligatures or contextual alternates change ASCII
/// glyphs; such fonts keep the attributed-string path for every cell.
final class DirectGlyphTable {
    static let firstCode: UInt8 = 0x20
    static let lastCode: UInt8 = 0x7E
    static let codeCount = Int(lastCode - firstCode) + 1

    private struct Entry {
        let font: TTFont
        let glyphs: [CGGlyph]?
        let spaceIsBlank: Bool
    }

    /// The four style faces of a context plus any earlier font set; bounded.
    private var entries: [Entry] = []

    /// The byte a simple cell's code draws, or nil when it is not printable
    /// ASCII. Code 0 is an empty cell, which the attributed path draws as " ".
    @inline(__always)
    static func code(for cellCode: Int32) -> UInt8? {
        if cellCode == 0 { return firstCode }
        guard cellCode >= Int32(firstCode), cellCode <= Int32(lastCode) else { return nil }
        return UInt8(cellCode)
    }

    /// Glyphs indexed by `code - firstCode`, or nil when the font is not
    /// eligible. Fonts are compared by identity; the render context keeps
    /// the same font objects until the view's font changes.
    func glyphs(for font: TTFont) -> [CGGlyph]? {
        entry(for: font).glyphs
    }

    /// The glyphs plus whether the space glyph has no outline, so drawing it
    /// paints nothing and the renderer may leave it out. Core Animation
    /// computes outline bounds for every recorded glyph, blank or not.
    func drawingGlyphs(for font: TTFont) -> (glyphs: [CGGlyph], spaceIsBlank: Bool)? {
        let entry = entry(for: font)
        return entry.glyphs.map { ($0, entry.spaceIsBlank) }
    }

    private func entry(for font: TTFont) -> Entry {
        for entry in entries where entry.font === font {
            return entry
        }
        if entries.count >= 16 {
            entries.removeAll(keepingCapacity: true)
        }
        let glyphs = Self.verifiedGlyphs(for: font)
        let spaceIsBlank = glyphs.map { Self.isBlank(font: font, glyph: $0[0]) } ?? false
        let entry = Entry(font: font, glyphs: glyphs, spaceIsBlank: spaceIsBlank)
        entries.append(entry)
        return entry
    }

    /// True when the glyph has no outline and is not a color/bitmap glyph,
    /// i.e. filling it paints no pixel.
    static func isBlank(font: TTFont, glyph: CGGlyph) -> Bool {
        let ctFont = font as CTFont
        if CTFontGetSymbolicTraits(ctFont).contains(.traitColorGlyphs) {
            return false
        }
        var g = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &g, &rect, 1)
        guard rect.isEmpty else { return false }
        guard let path = CTFontCreatePathForGlyph(ctFont, glyph, nil) else { return true }
        return path.isEmpty
    }

    /// Every ordered pair of printable ASCII characters, followed by every
    /// triple of non-alphanumeric printable ASCII characters (the sequences
    /// programming ligatures use) separated by spaces.
    static let shapingProbe: [UniChar] = {
        let printable = (UniChar(firstCode)...UniChar(lastCode)).map { $0 }
        let symbols = printable.filter { code in
            !(0x30...0x39).contains(code) && !(0x41...0x5A).contains(code)
                && !(0x61...0x7A).contains(code) && code != 0x20
        }
        var probe: [UniChar] = []
        probe.reserveCapacity(printable.count * printable.count * 2
                              + symbols.count * symbols.count * symbols.count * 4)
        for first in printable {
            for second in printable {
                probe.append(first)
                probe.append(second)
            }
        }
        for first in symbols {
            for second in symbols {
                for third in symbols {
                    probe.append(first)
                    probe.append(second)
                    probe.append(third)
                    probe.append(0x20)
                }
            }
        }
        return probe
    }()

    static func verifiedGlyphs(for font: TTFont) -> [CGGlyph]? {
        let ctFont = font as CTFont
        var characters = (UniChar(firstCode)...UniChar(lastCode)).map { $0 }
        var glyphs = [CGGlyph](repeating: 0, count: codeCount)
        guard CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, codeCount),
              !glyphs.contains(0) else {
            return nil
        }

        let probe = shapingProbe
        guard let string = CFStringCreateWithCharacters(nil, probe, probe.count) else {
            return nil
        }
        let attributes = [kCTFontAttributeName as String: ctFont] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, string, attributes) else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        var shapedCount = 0
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = runAttributes.object(forKey: kCTFontAttributeName) else {
                return nil
            }
            // A cascade font in the run would mean the font lacks a glyph.
            guard CFEqual(runFont as CFTypeRef, ctFont) else { return nil }
            var runGlyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &runGlyphs)
            CTRunGetStringIndices(run, CFRange(), &indices)
            CTRunGetPositions(run, CFRange(), &positions)
            for i in 0..<count {
                let index = indices[i]
                guard index == shapedCount + i, index < probe.count,
                      runGlyphs[i] == glyphs[Int(probe[index]) - Int(firstCode)],
                      positions[i].y == 0 else {
                    return nil
                }
            }
            shapedCount += count
        }
        return shapedCount == probe.count ? glyphs : nil
    }
}
#endif
#endif // !SWIFTTERM_EMBEDDED
