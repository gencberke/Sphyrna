import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import LoomTerminal

/// FB4-3: the last screen of an ended run is a snapshot taken from the engine, not a kept surface. The user's
/// Claude runs fullscreen (`"tui": "fullscreen"`): it draws in the alternate screen and leaves it with
/// `CSI ? 1049 l`, which clears that screen, before it prints the resume hint to the main buffer.
@MainActor
struct TerminalScreenSnapshotTests {
    private let enterAlt = "\u{1B}[?1049h"
    private let leaveAlt = "\u{1B}[?1049l"
    private let hint = "Resume this session with:\r\nclaude --resume 0000\r\n"

    private func lines(_ snapshot: TerminalScreenSnapshot?) -> [String] {
        (snapshot?.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func theScreenALeavingProgramDrewIsKeptThoughLeavingClearsIt() throws {
        let surface = TerminalSurface()
        surface.view.feed(text: "before\r\n" + enterAlt + "\u{1B}[2J\u{1B}[HCONVERSATION\r\nsecond row" + leaveAlt + hint)
        // What the engine still shows is the hint alone: this is why a kept surface lost the conversation.
        #expect(!surface.screenText().contains("CONVERSATION"))
        #expect(surface.screenText().contains("claude --resume"))

        let kept = try #require(surface.captureEndedScreen())
        #expect(kept.text.contains("CONVERSATION"))
        #expect(kept.text.contains("second row"))
        #expect(!kept.text.contains("claude --resume"), "the conversation, not the hint printed after it")
    }

    @Test func aProgramThatDiedInsideTheAlternateScreenLeavesThatScreen() throws {
        let surface = TerminalSurface()
        surface.view.feed(text: "main buffer text\r\n" + enterAlt + "\u{1B}[2J\u{1B}[HALT CONTENT")
        let kept = try #require(surface.captureEndedScreen())
        #expect(kept.text.contains("ALT CONTENT") && !kept.text.contains("main buffer text"))
        // The user's Stop takes the same visible rows before any signal.
        #expect(try #require(surface.captureVisibleScreen()).text.contains("ALT CONTENT"))
    }

    @Test func aProgramThatNeverUsedTheAlternateScreenKeepsTheMainBufferWithATailOfScrollback() throws {
        let surface = TerminalSurface()
        let total = 600
        surface.view.feed(text: (1...total).map { "line \($0)\r\n" }.joined() + "last line")
        let kept = try #require(surface.captureEndedScreen())
        let rows = lines(kept)
        #expect(rows.last == "last line")
        // More than the visible rows are kept (the scrollback tail), up to the cap, the oldest going first.
        let visible = surface.gridSize.rows
        #expect(rows.count > Int(visible))
        #expect(rows.count <= TerminalSurfaceLimits.endedScreenLines)
        #expect(rows.contains("line \(total)") && !rows.contains("line 1"))
    }

    @Test func theTailIsCappedByLinesAndByBytes() throws {
        let surface = TerminalSurface()
        // Far more than the engine's 2 000 lines of scrollback, each line long.
        let line = String(repeating: "0123456789", count: 8)
        surface.view.feed(text: (0..<3_000).map { _ in line + "\r\n" }.joined())
        let kept = try #require(surface.captureEndedScreen())
        #expect(kept.lines.count <= TerminalSurfaceLimits.endedScreenLines)
        #expect(kept.approximateBytes <= TerminalSurfaceLimits.endedScreenBytes)

        // A byte cap smaller than the lines drops the oldest rows, never the newest.
        let copy = try #require(surface.view.copyRows(kind: .normal, scrollbackLines: 400, atViewport: false))
        let small = TerminalScreenSnapshot(copy, maxLines: 400, maxBytes: 4_000)
        #expect(small.approximateBytes <= 4_000 && small.lines.count < 400 && !small.lines.isEmpty)
        #expect(small.lines.last == kept.lines.last)
    }

    @Test func aScreenWithNothingOnItKeepsNothing() {
        #expect(TerminalSurface().captureEndedScreen() == nil)
        #expect(TerminalSurface().captureVisibleScreen() == nil)
    }

    @Test func withoutAHandlerLeavingTheAlternateScreenIsAsBefore() {
        let surface = TerminalSurface()
        surface.view.setAlternateBufferLeavingHandler(nil)
        surface.view.feed(text: enterAlt + "ALT" + leaveAlt + "main")
        #expect(surface.screenText().contains("main") && !surface.screenText().contains("ALT"))
        #expect(surface.view.copyRows(kind: .alt)?.rows.allSatisfy { $0.allSatisfy { $0.getText() == "\0" || $0.getText() == " " } } == true,
                "the alternate screen is cleared as always")
    }

    @Test func aScreenErasedBeforeLeavingDoesNotReplaceTheOneBefore() throws {
        let surface = TerminalSurface()
        surface.view.feed(text: enterAlt + "DRAWN" + leaveAlt + enterAlt + "\u{1B}[2J" + leaveAlt + hint)
        let kept = try #require(surface.captureEndedScreen())
        #expect(kept.text.contains("DRAWN"))
    }

    @Test func onlyTheLatestLeftScreenIsKept() throws {
        let surface = TerminalSurface()
        surface.view.feed(text: enterAlt + "FIRST" + leaveAlt + enterAlt + "SECOND" + leaveAlt)
        let kept = try #require(surface.captureEndedScreen())
        #expect(kept.text.contains("SECOND") && !kept.text.contains("FIRST"))
    }

    // MARK: Styles

    private func runs(_ feed: String) throws -> [TerminalScreenSnapshot.Run] {
        let surface = TerminalSurface()
        surface.view.feed(text: enterAlt + feed + leaveAlt)
        return try #require(surface.captureEndedScreen()).lines.first ?? []
    }

    @Test func colorsAreResolvedToRGBWithTheSurfacesPalette() throws {
        let theme = TerminalTheme.self
        let found = try runs("plain \u{1B}[31mred\u{1B}[0m \u{1B}[38;5;196mcube\u{1B}[0m \u{1B}[38;2;1;2;3mtrue\u{1B}[0m \u{1B}[44mon blue")
        func run(_ text: String) throws -> TerminalScreenSnapshot.Run {
            try #require(found.first { $0.text.contains(text) })
        }
        #expect(try run("plain").foreground == theme.foregroundRGB && (try run("plain").background) == nil)
        #expect(try run("red").foreground == TerminalRGB(red: 205, green: 49, blue: 49))
        #expect(try run("cube").foreground == TerminalRGB(red: 255, green: 0, blue: 0))
        #expect(try run("true").foreground == TerminalRGB(red: 1, green: 2, blue: 3))
        #expect(try run("on blue").background == TerminalRGB(red: 36, green: 114, blue: 200))
    }

    @Test func boldItalicUnderlineAndStrikethroughAreStyles() throws {
        let found = try runs("\u{1B}[1mB\u{1B}[0m\u{1B}[3mI\u{1B}[0m\u{1B}[4mU\u{1B}[0m\u{1B}[9mS\u{1B}[0m\u{1B}[1;3;4mALL")
        func style(_ text: String) throws -> TerminalScreenSnapshot.Style {
            try #require(found.first { $0.text.contains(text) }).style
        }
        #expect(try style("B") == .bold && (try style("I")) == .italic)
        #expect(try style("U") == .underline && (try style("S")) == .strikethrough)
        #expect(try style("ALL") == [.bold, .italic, .underline])
    }

    @Test func boldBrightensTheLowAnsiColorsAndDimMovesTowardsTheBackground() throws {
        // The renderer brightens ANSI 0-6 for bold text (not 7), and draws dim halfway to the background.
        let found = try runs("\u{1B}[1;31mbold\u{1B}[0m \u{1B}[1;37mwhite\u{1B}[0m \u{1B}[2mdim")
        func run(_ text: String) throws -> TerminalScreenSnapshot.Run { try #require(found.first { $0.text.contains(text) }) }
        #expect(try run("bold").foreground == TerminalTheme.palette[9])
        #expect(try run("white").foreground == TerminalTheme.palette[7])
        let dim = try run("dim").foreground
        let fg = TerminalTheme.foregroundRGB, bg = TerminalTheme.backgroundRGB
        #expect(abs(Int(dim.red) - (Int(fg.red) + Int(bg.red)) / 2) <= 1)
        #expect(dim != fg && dim != bg)
    }

    @Test func inverseSwapsTheColorsAndTheDefaultPairSwapsToTheOtherDefault() throws {
        let found = try runs("\u{1B}[7mdefault\u{1B}[0m \u{1B}[7;31mred")
        func run(_ text: String) throws -> TerminalScreenSnapshot.Run { try #require(found.first { $0.text.contains(text) }) }
        #expect(try run("default").foreground == TerminalTheme.backgroundRGB)
        #expect(try run("default").background == TerminalTheme.foregroundRGB)
        // Inverse red: red becomes the background, the text takes the default background.
        #expect(try run("red").background == TerminalRGB(red: 205, green: 49, blue: 49))
        #expect(try run("red").foreground == TerminalTheme.backgroundRGB)
    }

    @Test func theResolvedPaletteMatchesTheEnginesForAllTwoHundredFiftySixIndices() {
        let terminal = TerminalSurface().view.terminal!
        for index in 0..<256 {
            let engine = terminal.paletteColor(index: index)
            let mine = TerminalTheme.palette[index]
            #expect(Int(engine?.red ?? 0) / 257 == Int(mine.red), "red of \(index)")
            #expect(Int(engine?.green ?? 0) / 257 == Int(mine.green), "green of \(index)")
            #expect(Int(engine?.blue ?? 0) / 257 == Int(mine.blue), "blue of \(index)")
        }
    }

    @Test func blankCellsAreTrimmedAndWideCharactersKeepTheirText() throws {
        let surface = TerminalSurface()
        surface.view.feed(text: enterAlt + "a  b   \r\n\r\n日本語 ok" + leaveAlt)
        let kept = try #require(surface.captureEndedScreen())
        #expect(lines(kept) == ["a  b", "", "日本語 ok"])
    }

    // MARK: Size

    /// A full-screen TUI's worth of styled rows: its snapshot is small. Reported with the measured size.
    @Test func aTypicalFullscreenScreenIsAFewTensOfKilobytes() throws {
        let surface = TerminalSurface()
        surface.view.setFrameSize(NSSize(width: 1_400, height: 900))   // about 170 x 55 cells
        var screen = enterAlt + "\u{1B}[2J\u{1B}[H"
        for row in 0..<50 {
            screen += "\u{1B}[38;5;\(40 + row % 6)m\u{1B}[1m> \u{1B}[0mconversation row \(row) with some words in it "
            screen += "\u{1B}[2m(dim \(row))\u{1B}[0m \u{1B}[48;5;236m status \(row) \u{1B}[0m `code(\(row))`\r\n"
        }
        surface.view.feed(text: screen)
        let kept = try #require(surface.captureVisibleScreen())
        print("MEASURED typical snapshot: rows=\(kept.lines.count) runs=\(kept.lines.reduce(0) { $0 + $1.count }) approximateBytes=\(kept.approximateBytes)")
        #expect(kept.approximateBytes < 64 * 1024)
    }
}
