import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import SwiftTerm
@testable import LoomTerminal

/// Option is a character layer on many layouts (Turkish Q: Option+Q is "@", Option+8 is "[",
/// Option+\ starts the "`" dead key). Those keys must type; Option combinations without a
/// character stay Meta for terminal shortcuts (Option+Return, Option+Backspace, Option+arrows,
/// Option+Space).
@MainActor
struct TerminalOptionKeyTests {
    final class Capture: TerminalViewDelegate {
        var bytes: [UInt8] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func view() -> (LoomTerminalView, Capture) {
        let view = LoomTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let capture = Capture()
        view.terminalDelegate = capture
        return (view, capture)
    }

    func key(_ characters: String, ignoring: String, code: Int, flags: NSEvent.ModifierFlags = [.option],
             type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoring, isARepeat: false,
                         keyCode: UInt16(code))!
    }

    func typed(_ events: [NSEvent], kittyFlags: Int? = nil) -> [UInt8] {
        let (view, capture) = view()
        if let kittyFlags { view.feed(text: "\u{1b}[>\(kittyFlags)u") }   // the app pushes kitty flags
        for event in events {
            if event.type == .keyUp { view.keyUp(with: event) } else { view.keyDown(with: event) }
        }
        return capture.bytes
    }

    /// nil: legacy input; 1: kitty disambiguate; 11: disambiguate, report events and all keys.
    @Test(arguments: [nil, 1, 11] as [Int?])
    func optionCharactersOfTheLayoutAreTyped(kittyFlags: Int?) {
        let at = key("@", ignoring: "q", code: kVK_ANSI_Q)
        let open = key("[", ignoring: "8", code: kVK_ANSI_8)
        let euro = key("€", ignoring: "e", code: kVK_ANSI_E)
        #expect(typed([at], kittyFlags: kittyFlags) == Array("@".utf8))
        #expect(typed([at, open, euro], kittyFlags: kittyFlags) == Array("@[€".utf8))
        // The release of a key that typed text reports nothing.
        let release = key("@", ignoring: "q", code: kVK_ANSI_Q, type: .keyUp)
        #expect(typed([at, release], kittyFlags: kittyFlags) == Array("@".utf8))
    }

    @Test func aDeadKeyGoesToTheInputSystemInsteadOfMeta() {
        // Turkish Q: Option+\ is the "`" dead key; its key-down carries no text yet.
        let dead = typed([key("", ignoring: "\\", code: kVK_ANSI_Backslash)])
        #expect(!dead.starts(with: [0x1b]), "\(dead)")
    }

    @Test func optionLettersTypeTheLayoutsSymbol() {
        // Documents the trade-off: on layouts with a symbol, Option+P types it (no Meta+P).
        #expect(typed([key("π", ignoring: "p", code: kVK_ANSI_P)]) == Array("π".utf8))
    }

    @Test func optionWithoutACharacterStaysMeta() {
        // Option+Return (newline in Claude Code) and Option+Backspace (delete word): ESC prefix.
        #expect(typed([key("\r", ignoring: "\r", code: kVK_Return)]) == [0x1b, 0x0d])
        #expect(typed([key("\u{7f}", ignoring: "\u{7f}", code: kVK_Delete)]) == [0x1b, 0x7f])
        // Option+Left keeps its Alt-modified cursor key (word back), as before.
        let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        #expect(typed([key(left, ignoring: left, code: kVK_LeftArrow, flags: [.option, .function, .numericPad])])
                == Array("\u{1b}[1;3D".utf8))
        // Option+Space types a no-break space on most layouts; it stays Meta (ESC space).
        #expect(typed([key("\u{a0}", ignoring: " ", code: kVK_Space)]) == [0x1b, 0x20])
    }

    @Test func plainKeysAndTheMetaToggleAreUnchanged() {
        let (view, capture) = view()
        view.keyDown(with: key("a", ignoring: "a", code: kVK_ANSI_A, flags: []))
        #expect(capture.bytes == Array("a".utf8))
        view.keyDown(with: key("@", ignoring: "q", code: kVK_ANSI_Q))
        #expect(view.optionAsMetaKey)   // still Meta after a typed Option key
        // Cmd+Option+O turns Meta off for the terminal (no ESC prefix any more) and on again.
        let toggle = key("ø", ignoring: "o", code: kVK_ANSI_O, flags: [.option, .command])
        view.keyDown(with: toggle)
        #expect(!view.optionAsMetaKey)
        capture.bytes = []
        view.keyDown(with: key("\r", ignoring: "\r", code: kVK_Return))
        #expect(!capture.bytes.starts(with: [0x1b]), "\(capture.bytes)")
        view.keyDown(with: toggle)
        #expect(view.optionAsMetaKey)
    }
}
