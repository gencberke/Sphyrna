import AppKit
import Foundation
import LoomCore
import SwiftTerm
import Testing
@testable import LoomTerminal

/// Window-menu shortcuts still reach the menu with the terminal as first responder instead of being typed into
/// it; and an ended surface refuses input loudly (the last screen of an ended run is a snapshot, not a surface).
@MainActor
struct TerminalKeptScreenTests {
    @Test func aRunEndedSurfaceRefusesInputLoudly() {
        let surface = TerminalSurface()
        surface.runEnded()
        var errors: [TerminalInputError] = []
        surface.onInputError = { errors.append($0) }
        surface.view.send(data: Array("x".utf8)[...])
        #expect(errors == [.writeFailed("run has ended")])
    }

    // MARK: Menu key equivalents with the terminal focused

    final class Recorder: NSObject {
        var hits: [String] = []
        @objc func hit(_ sender: NSMenuItem) { hits.append(sender.title) }
    }

    final class Capture: TerminalViewDelegate {
        var bytes: [UInt8] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func key(_ character: String, ignoring: String? = nil, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: character, charactersIgnoringModifiers: ignoring ?? character,
                         isARepeat: false, keyCode: code)!
    }

    /// Runs `body` with a main menu holding the Window-menu session shortcuts, restoring the old menu after.
    private func withMenu(_ body: (Recorder) -> Void) {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        let recorder = Recorder()
        let menu = NSMenu(title: "Window")
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        for (title, equivalent, mask) in [
            ("Jump to Next Session That Needs You", "j", NSEvent.ModifierFlags([.command])),
            ("Jump to Previous Session That Needs You", "j", [.command, .shift]),
            ("Jump to Previous Session That Needs You", "J", [.command, .shift]),
            ("Select Next Session", down, [.command, .option]),
            ("Select Previous Session", up, [.command, .option]),
        ] {
            let item = menu.addItem(withTitle: title, action: #selector(Recorder.hit(_:)), keyEquivalent: equivalent)
            item.keyEquivalentModifierMask = mask
            item.target = recorder
        }
        let main = NSMenu()
        let top = NSMenuItem()
        top.submenu = menu
        main.addItem(top)
        app.mainMenu = main
        body(recorder)
    }

    @Test func sessionShortcutsReachTheMenuAndNeverTheTerminalsInput() {
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        let cases: [(NSEvent, String)] = [
            (key(down, code: 125, flags: [.command, .option, .numericPad, .function]), "Select Next Session"),
            (key(up, code: 126, flags: [.command, .option, .numericPad, .function]), "Select Previous Session"),
            (key("j", code: 38, flags: [.command]), "Jump to Next Session That Needs You"),
            // Whichever way the keyboard reports the shifted letter.
            (key("J", code: 38, flags: [.command, .shift]), "Jump to Previous Session That Needs You"),
            (key("j", code: 38, flags: [.command, .shift]), "Jump to Previous Session That Needs You"),
            (key("J", ignoring: "j", code: 38, flags: [.command, .shift]), "Jump to Previous Session That Needs You"),
        ]
        withMenu { recorder in
            // AppKit offers the key to the main menu first.
            for (event, title) in cases {
                #expect(NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) == true, "\(title)")
            }
            #expect(Self.sameItems(recorder.hits, cases.map(\.1)), "\(recorder.hits)")
            // And a key that reaches `keyDown` of the focused terminal gives the menu its chance before it
            // is encoded for the program (the path a Command key takes when no one claimed it earlier).
            recorder.hits = []
            for (event, _) in cases {
                let view = LoomTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
                let capture = Capture()
                view.terminalDelegate = capture
                view.keyDown(with: event)
                #expect(capture.bytes.isEmpty, "the PTY gets nothing")
            }
            #expect(Self.sameItems(recorder.hits, cases.map(\.1)), "\(recorder.hits)")
        }
    }

    /// One hit per key, on the expected item; the two J items are interchangeable here (the app's action
    /// decides the direction from Shift, see `SessionShortcut.attentionDirection`).
    static func sameItems(_ hits: [String], _ expected: [String]) -> Bool {
        hits.count == expected.count && zip(hits, expected).allSatisfy { hit, want in
            hit == want || (hit.hasPrefix("Jump to") && want.hasPrefix("Jump to"))
        }
    }

    @Test func aKeyTheMenuDoesNotOwnIsStillTyped() {
        withMenu { recorder in
            let view = LoomTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            let capture = Capture()
            view.terminalDelegate = capture
            view.keyDown(with: key("x", code: 7, flags: []))
            #expect(capture.bytes == Array("x".utf8))
            #expect(recorder.hits.isEmpty)
        }
    }
}
