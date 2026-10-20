import AppKit
import Foundation
import LoomChat

/// The live composer as the text view's host (`ComposerEditorHost`): the key state it reports, what it does for each key.
extension ChatComposerModel: ComposerEditorHost {
    var keyMode: ComposerKeys.Mode { .live }
    var syncsByRevision: Bool { true }
    var modelText: String { text }

    func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State {
        var keys = ComposerKeys.State()
        keys.mode = .live
        keys.working = state.turnRunning
        keys.cardWaiting = state.requestCount > 0
        keys.cardShown = cardShown
        keys.menuOpen = menu != nil
        keys.editingQueued = editing != nil
        keys.hasMarkedText = hasMarkedText
        keys.isRepeat = isRepeat
        keys.isEmpty = bridge.utf16Length == 0
        keys.hasSelection = bridge.hasSelection
        let lines = bridge.caretLines()
        keys.caretOnFirstLine = lines.first
        keys.caretOnLastLine = lines.last
        keys.recalling = history.isRecalling
        // The text is compared with the recall only when a recall is under way (a key press, not a keystroke).
        keys.holdsUneditedRecall = history.isRecalling && history.isUneditedRecall(bridge.currentText())
        keys.hasHistory = true
        return keys
    }

    func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool {
        switch action {
        case .send: submit(secondary: false)
        case .sendSecondary: submit(secondary: true)
        case .interrupt: interrupt(byEscape: true)
        case .closeMenu: closeMenu()
        case .cancelEdit: cancelEdit()
        case let .menuMove(delta): menuMove(delta)
        case .menuInsert: chooseSelected()
        case .recallOlder: recallOlder()
        case .recallNewer: recallNewer()
        case .pastePlain: paste(from: .general, plain: true)
        case let .openMenu(request):
            if request == .attach { pickFiles(in: window) } else { openMenu(request) }
        case .focusCard: cards?.focus()
        case .cycleView: environment.cycleView?()
        case .ignore: break
        case .newline, .passThrough, .closePanel: return false
        }
        return true
    }

    func editorEndedEditing() { flushDraft() }

    /// A printable key was typed while the stream had the keyboard: the field takes the focus and the event, so the
    /// first key goes through the input method like the rest (Option characters such as `@` or `|`).
    func typeToFocus(_ event: NSEvent) {
        editor?.typeIn(event)
    }

    /// The field gained or lost the keyboard: the cards' typing guard follows it (leaving the composer lets a held stack show).
    func editorFocusChanged(_ focused: Bool) {
        hasEditorFocus = focused
        cards?.composerFocusChanged(focused)
    }

    func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool { paste(from: pasteboard, plain: plain) }

    func drop(_ pasteboard: NSPasteboard) -> Bool { drop(from: pasteboard) }

    func editorDetached(_ bridge: any ComposerEditorBridge) {
        guard editor === bridge else { return }
        editorAttached(nil)
    }

    func editorAttached(_ bridge: (any ComposerEditorBridge)?) {
        // The field going away is leaving the composer, whether or not it resigned first.
        if bridge == nil, hasEditorFocus { editorFocusChanged(false) }
        editor = bridge
        if bridge != nil { start() }
    }

    // MARK: History (↑ and ↓)

    /// ↑: the newest earlier message of the session, then older ones.
    func recallOlder() {
        if !history.isRecalling { history.load(environment.historyTexts()) }
        guard let text = history.older() else { return }
        setText(text)
    }

    /// ↓: forward again, and past the newest the composer is cleared.
    func recallNewer() {
        guard let step = history.newer() else { return }
        switch step {
        case let .text(text): setText(text)
        case .clear: setText("")
        }
    }
}

extension ChatComposerModel {
    /// Types text as the user would (evidence and tests): through the text view when it is there, so the same delegate path
    /// runs; the model alone otherwise.
    func typeForEvidence(_ value: String) {
        if let editor { editor.insertAtCaret(value) } else { textChanged(text + value) }
    }
}
