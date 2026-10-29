import AppKit
import Foundation
import Synchronization
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// The quick question (V22): the panel's holder (one question at a time, a closed panel drops a late answer, a session that can
/// no longer take a question closes it), the field's keys, the theme's contrast, and the menu and palette state on the real
/// model with a driver on the fake provider. Nothing is drawn.

struct QuickQuestionKeysTests {
    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], markedText: Bool = false, repeated: Bool = false)
        -> ComposerKeys.Action {
        var state = ComposerKeys.State()
        state.mode = .quick
        state.hasMarkedText = markedText
        state.isRepeat = repeated
        return ComposerKeys.resolve(keyCode: keyCode, modifiers: modifiers, state: state)
    }

    @Test func returnAsksShiftReturnMakesALineAndEscapeClosesThePanel() {
        #expect(action(ComposerKeys.returnKey) == .send)
        #expect(action(ComposerKeys.keypadEnter) == .send)
        #expect(action(ComposerKeys.returnKey, [.shift]) == .newline)
        #expect(action(ComposerKeys.escape) == .closePanel)
        // A held Return asks once; an input method that composes keeps Return and Esc.
        #expect(action(ComposerKeys.returnKey, repeated: true) == .ignore)
        #expect(action(ComposerKeys.returnKey, markedText: true) == .passThrough)
        #expect(action(ComposerKeys.escape, markedText: true) == .passThrough)
        // The composer's menus and the stream view key are not the quick field's.
        #expect(action(ComposerKeys.letterA, [.command, .shift]) == .passThrough)
        #expect(action(ComposerKeys.letterO, [.control]) == .passThrough)
    }

    @Test func theOtherFieldsKeepTheirEscape() {
        var live = ComposerKeys.State()
        live.working = true
        #expect(ComposerKeys.resolve(keyCode: ComposerKeys.escape, modifiers: [], state: live) == .interrupt)
        var draft = ComposerKeys.State()
        draft.mode = .draft
        #expect(ComposerKeys.resolve(keyCode: ComposerKeys.escape, modifiers: [], state: draft) == .ignore)
    }
}
