import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// The Chat composer on the real Chat driver and the fake provider (V17): the keys' meanings through the model, delivery
// states, Read now, the queue, drafts, attachments, the chips and the menus. Nothing here sends a message to a real Claude.

// MARK: The text view

@MainActor
struct ComposerTextViewTests {
    /// Text the model puts in (a menu choice, a recall) carries the composer's font and colour. Without the typing
    /// attributes it took the storage's default: small and black on a dark card (seen in the first evidence run).
    @Test func textInsertedThroughTheBridgeKeepsTheComposersFontAndColour() throws {
        let view = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        view.isRichText = false
        view.font = NSFont.systemFont(ofSize: LoomTheme.TypeScale.readingSize)
        view.textColor = NSColor(LoomTheme.Text.primary)
        view.insertAtCaret("hello")
        let storage = try #require(view.textStorage)
        #expect(storage.length == 5)
        let attributes = storage.attributes(at: 0, effectiveRange: nil)
        #expect(attributes[.font] as? NSFont == view.font)
        #expect(attributes[.foregroundColor] as? NSColor == view.textColor)
        view.replace(NSRange(location: 0, length: 5), with: "bye")
        let after = storage.attributes(at: 0, effectiveRange: nil)
        #expect(after[.font] as? NSFont == view.font)
        #expect(after[.foregroundColor] as? NSColor == view.textColor)
    }

    /// The Edit menu's Undo, Redo and Cut are the standard selectors sent to the first responder (`AppDelegate+Menus`): the
    /// composer's text view must be that responder and answer them. The menu itself lives in the app target, so this sends the
    /// same selectors the menu items do, through the responder chain of a window that is never shown.
    @Test func theEditMenusUndoRedoAndCutReachTheComposersTextView() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isRichText = false
        view.allowsUndo = true
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view), "the field takes the focus")
        #expect(window.firstResponder === view)
        let undo = Selector(("undo:")), redo = Selector(("redo:")), cut = #selector(NSText.cut(_:))
        #expect(view.responds(to: cut))

        func type(_ text: String) { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        type("hello world")
        #expect(view.string == "hello world")
        // Undo and Redo from the menu have a nil target: the action walks the responder chain from the first responder.
        #expect(view.tryToPerform(undo, with: nil), "something in the chain answers undo:")
        #expect(view.string.isEmpty, "Undo took back the typing: \(view.string)")
        #expect(view.tryToPerform(redo, with: nil), "something in the chain answers redo:")
        #expect(view.string == "hello world", "Redo put it back: \(view.string)")
        // Cut is enabled for a selection and not without one (it is not performed here: it would take the user's clipboard).
        let item = NSMenuItem(title: "Cut", action: cut, keyEquivalent: "x")
        view.setSelectedRange(NSRange(location: 5, length: 6))
        #expect(view.validateMenuItem(item), "Cut is enabled with a selection")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(!view.validateMenuItem(item), "and disabled without one")
    }
}
