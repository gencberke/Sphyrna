import AppKit
import Foundation
import Testing
@testable import LoomTerminal

/// FB6-9: a new terminal starts at the last laid-out frame, not at the 800 × 500 of a view that was never laid out, and a grid under
/// 20 columns (a view in the middle of a layout) is not a size to give the program.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalLaunchSizeTests {
    @Test func aNewTerminalStartsAtTheLastLaidOutFrame() {
        TerminalSurface.forgetLaidOutFrame()
        defer { TerminalSurface.forgetLaidOutFrame() }
        #expect(TerminalSurface().view.frame.size == TerminalSurfaceLimits.fallbackFrame, "none laid out yet")
        let laidOut = TerminalSurface()
        laidOut.view.setFrameSize(NSSize(width: 1000, height: 600))
        laidOut.sizeChanged(source: laidOut.view, newCols: 120, newRows: 40)
        #expect(TerminalSurface().view.frame.size == CGSize(width: 1000, height: 600))
        let columns = TerminalSurface().gridSize.columns
        #expect(columns > 95, "the program is launched at the width it will have: \(columns) columns")
    }

    @Test func aGridUnderTwentyColumnsIsNotTheFrameANewTerminalStartsAt() {
        TerminalSurface.forgetLaidOutFrame()
        defer { TerminalSurface.forgetLaidOutFrame() }
        let surface = TerminalSurface()
        surface.view.setFrameSize(NSSize(width: 90, height: 600))
        surface.sizeChanged(source: surface.view, newCols: 12, newRows: 40)
        #expect(TerminalSurface().view.frame.size == TerminalSurfaceLimits.fallbackFrame)
        #expect(TerminalSurfaceLimits.minimumColumns == 20)
    }
}
