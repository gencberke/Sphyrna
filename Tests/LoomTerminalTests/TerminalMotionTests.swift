import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import LoomTerminal

/// FB6-11: a program that asks for mouse motion (Claude Code in fullscreen) gets one report for each cell the pointer enters, not
/// one for each of the ~120 moves a second a trackpad delivers.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalMotionTests {
    final class Capture: TerminalViewDelegate {
        var bytes: [UInt8] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        /// The engine hands a report to the delegate on the main queue: count after it has run.
        var reports: Int { String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1b}[<").count - 1 }
    }

    private func rig(_ modes: String) -> (LoomTerminalView, Capture, NSWindow) {
        let view = LoomTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let capture = Capture()
        view.terminalDelegate = capture
        // A window that is never shown gives the pointer's coordinates a base to convert from.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.feed(text: modes)
        return (view, capture, window)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }

    private func move(_ view: LoomTerminalView, to point: NSPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 0, pressure: 0)!
        view.mouseMoved(with: event)
    }

    @Test func aRunOfMouseMovesInsideOneCellSendsOneMotionReport() async throws {
        let (view, capture, window) = rig("\u{1b}[?1003h\u{1b}[?1006h")
        let cell = try #require(view.cellDimension)
        let origin = NSPoint(x: cell.width * 4.1, y: 300 - cell.height * 2.1)
        for step in 0..<30 {
            move(view, to: NSPoint(x: origin.x + CGFloat(step % 3) * 0.2, y: origin.y - CGFloat(step % 4) * 0.2), in: window)
        }
        try await settle()
        #expect(capture.reports == 1, "30 moves in one cell: \(capture.reports) reports")
        // The next cell is one more report; coming back to the first is another.
        move(view, to: NSPoint(x: origin.x + cell.width, y: origin.y), in: window)
        try await settle()
        #expect(capture.reports == 2)
        move(view, to: origin, in: window)
        try await settle()
        #expect(capture.reports == 3)
    }

    @Test func thePixelProtocolReportsEachPixelItEnters() async throws {
        let (view, capture, window) = rig("\u{1b}[?1003h\u{1b}[?1016h")
        let cell = try #require(view.cellDimension)
        let origin = NSPoint(x: cell.width * 4.1, y: 300 - cell.height * 2.1)
        for step in 0..<4 {
            move(view, to: NSPoint(x: origin.x + CGFloat(step) * 2, y: origin.y), in: window)
        }
        try await settle()
        #expect(capture.reports == 4, "four different pixels in one cell: \(capture.reports)")
        move(view, to: NSPoint(x: origin.x + 6, y: origin.y), in: window)
        try await settle()
        #expect(capture.reports == 4, "the same pixel again reports nothing")
    }

    @Test func aPointerThatLeavesAndComesBackInTheSameCellReportsAgain() async throws {
        let (view, capture, window) = rig("\u{1b}[?1003h\u{1b}[?1006h")
        let cell = try #require(view.cellDimension)
        let point = NSPoint(x: cell.width * 4.1, y: 300 - cell.height * 2.1)
        move(view, to: point, in: window)
        move(view, to: point, in: window)
        try await settle()
        #expect(capture.reports == 1)
        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          trackingNumber: 0, userData: nil)!
        view.mouseExited(with: exit)
        move(view, to: point, in: window)
        try await settle()
        #expect(capture.reports == 2, "an entry is a move to a cell")
    }
}
