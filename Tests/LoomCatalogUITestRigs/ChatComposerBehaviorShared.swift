import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// A text view stand-in for the model's bridge: the text, a caret, and the same call back a real field makes.
@MainActor
final class FakeComposerEditor: ComposerEditorBridge {
    var text = ""
    var caret = 0
    weak var model: ChatComposerModel?

    init(model: ChatComposerModel) {
        self.model = model
        model.editor = self
    }

    func hasMarkedText() -> Bool { false }
    var caretLocation: Int { caret }
    var hasSelection: Bool { false }
    var utf16Length: Int { text.utf16.count }
    func currentText() -> String { text }
    func replaceAll(with value: String) { text = value; caret = value.utf16.count }
    func substring(_ range: NSRange) -> String { (text as NSString).substring(with: range) }
    func replace(_ range: NSRange, with value: String) {
        text = (text as NSString).replacingCharacters(in: range, with: value)
        caret = range.location + (value as NSString).length
        model?.textChanged(text)
    }
    func insertAtCaret(_ value: String) { replace(NSRange(location: caret, length: 0), with: value) }
    func caretLines() -> (first: Bool, last: Bool) { (true, true) }
    var focusCount = 0
    func focus() { focusCount += 1 }

    /// The user types: one character after another, each reported as a keystroke is.
    func type(_ value: String) { for character in value { insertAtCaret(String(character)) } }
}
