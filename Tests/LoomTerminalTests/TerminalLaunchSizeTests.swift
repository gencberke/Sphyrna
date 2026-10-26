import AppKit
import Foundation
import Testing
@testable import LoomTerminal

/// FB6-9: a new terminal can start at the last laid-out frame, not at the 800 × 500 of a view that was never laid out, and a grid
/// under 20 columns (a view in the middle of a layout) is not a frame to start the next one at.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalLaunchSizeTests {
    @Test func aSurfaceStartsAtTheFrameItIsGivenAndOtherwiseAtTheFallback() {
        #expect(TerminalSurface().view.frame.size == TerminalSurfaceLimits.fallbackFrame)
        let wide = TerminalSurface(launchFrame: CGSize(width: 1000, height: 600))
        #expect(wide.view.frame.size == CGSize(width: 1000, height: 600))
        #expect(wide.gridSize.columns > TerminalSurface().gridSize.columns, "the program is launched at the width it will have")
    }

    @Test func aLaidOutGridIsReportedAndOneUnderTwentyColumnsIsNot() {
        let surface = TerminalSurface()
        var frames: [CGSize] = []
        surface.onLaidOut = { frames.append($0) }
        surface.sizeChanged(source: surface.view, newCols: 120, newRows: 40)
        #expect(frames == [surface.view.frame.size])
        surface.sizeChanged(source: surface.view, newCols: 12, newRows: 40)
        #expect(frames.count == 1, "a view in the middle of a layout is not a frame to start at")
        #expect(TerminalSurfaceLimits.minimumColumns == 20)
    }
}
