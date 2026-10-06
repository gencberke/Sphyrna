import AppKit
@testable import SwiftTerm
import Testing
@testable import LoomTerminal

/// CP5 UI item 7: a real surface must keep the standard xterm 256-color cube
/// (the engine default blends it toward the base 16 and mutes every index).
@MainActor
@Suite(.serialized)
struct TerminalThemeTests {
    private func rgb(_ color: Color?) -> [Int] {
        guard let color else { return [] }
        return [Int(color.red) / 257, Int(color.green) / 257, Int(color.blue) / 257]
    }

    @Test func surfaceUsesStandardCubeAndInstalledPalette() {
        let surface = TerminalSurface()
        let terminal = surface.view.terminal!
        #expect(rgb(terminal.paletteColor(index: 1)) == [205, 49, 49])
        #expect(rgb(terminal.paletteColor(index: 15)) == [255, 255, 255])
        // xterm cube: 196 is pure red, 231 pure white, 46 pure green; grays start at 8.
        #expect(rgb(terminal.paletteColor(index: 196)) == [255, 0, 0])
        #expect(rgb(terminal.paletteColor(index: 46)) == [0, 255, 0])
        #expect(rgb(terminal.paletteColor(index: 231)) == [255, 255, 255])
        #expect(rgb(terminal.paletteColor(index: 232)) == [8, 8, 8])
        #expect(rgb(terminal.paletteColor(index: 255)) == [238, 238, 238])
    }
}
